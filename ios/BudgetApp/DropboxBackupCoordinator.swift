import AuthenticationServices
import BudgetStorage
import Combine
import Foundation
import UIKit

enum DropboxBackupOperationError: LocalizedError {
    case alreadyWorking
    var errorDescription: String? { "A Dropbox operation is already in progress. Wait for it to finish before trying again." }
}

@MainActor
final class DropboxBackupCoordinator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let appKeyInfoKey = "ClearPocketDropboxAppKey"
    static let redirectURI = "clearpocket://dropbox-oauth"
    static let callbackScheme = "clearpocket"

    @Published private(set) var isConfigured: Bool
    @Published private(set) var isConnected = false
    @Published private(set) var generations: [DropboxBackupEntry] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastSuccessfulBackupAt: Date?
    @Published private(set) var pendingLocalGenerationURL: URL?
    @Published var errorMessage: String?
    @Published private(set) var publicationWarning: String?
    @Published var retention: Int {
        didSet { defaults.set(retention, forKey: retentionKey) }
    }
    @Published var automaticBackupEnabled: Bool {
        didSet { defaults.set(automaticBackupEnabled, forKey: automaticBackupEnabledKey) }
    }
    @Published var automaticBackupIntervalDays: Int {
        didSet {
            if Self.supportedAutomaticIntervals.contains(automaticBackupIntervalDays) {
                defaults.set(automaticBackupIntervalDays, forKey: automaticBackupIntervalKey)
            }
        }
    }

    private let defaults: UserDefaults
    private let retentionKey = "backup.dropbox.retention"
    private let lastSuccessfulBackupKey = "backup.dropbox.last-success"
    private let automaticBackupEnabledKey = "backup.dropbox.automatic-enabled"
    private let automaticBackupIntervalKey = "backup.dropbox.automatic-interval-days"
    private let pendingLocalGenerationKey = "backup.dropbox.pending-local-generation"
    private let pendingRetryAtKey = "backup.dropbox.pending-retry-at"
    private var pendingRetryAt: Date?
    private let automaticRetryAtKey = "backup.dropbox.automatic-retry-at"
    private var automaticRetryAt: Date?
    static let pendingRetryInterval: TimeInterval = 30 * 60
    static let supportedAutomaticIntervals = [1, 7]
    private var automaticBackupClaimed = false
    private var automaticBackupStartedAt: Date?
    private let credential: DropboxOAuthCredential?
    private var authenticationSession: ASWebAuthenticationSession?
    private var pendingAuthorization: DropboxPKCEAuthorization?

    init(
        appKey: String? = nil,
        defaults: UserDefaults = .standard,
        tokenStore: DropboxRefreshTokenStoring = DropboxRefreshTokenKeychainStore()
    ) {
        self.defaults = defaults
        let savedRetention = defaults.integer(forKey: retentionKey)
        retention = [3, 5, 10, 20].contains(savedRetention) ? savedRetention : 10
        lastSuccessfulBackupAt = defaults.object(forKey: lastSuccessfulBackupKey) as? Date
        pendingRetryAt = defaults.object(forKey: pendingRetryAtKey) as? Date
        automaticRetryAt = defaults.object(forKey: automaticRetryAtKey) as? Date
        if let path = defaults.string(forKey: pendingLocalGenerationKey) {
            let candidate = URL(fileURLWithPath: path, isDirectory: true)
            if Self.isValidPendingGeneration(candidate) { pendingLocalGenerationURL = candidate }
            else { defaults.removeObject(forKey: pendingLocalGenerationKey) }
        }
        automaticBackupEnabled = defaults.bool(forKey: automaticBackupEnabledKey)
        let savedInterval = defaults.integer(forKey: automaticBackupIntervalKey)
        automaticBackupIntervalDays = Self.supportedAutomaticIntervals.contains(savedInterval) ? savedInterval : 1
        #if DEBUG
        let environmentKey = ProcessInfo.processInfo.environment["BUDGETAPP_DROPBOX_APP_KEY"]
        #else
        let environmentKey: String? = nil
        #endif
        let bundledKey = Bundle.main.object(forInfoDictionaryKey: Self.appKeyInfoKey) as? String
        let resolvedKey = (appKey ?? environmentKey ?? bundledKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedKey, !resolvedKey.isEmpty,
           let configuration = try? DropboxOAuthConfiguration(appKey: resolvedKey, redirectURI: Self.redirectURI) {
            credential = DropboxOAuthCredential(configuration: configuration, store: tokenStore)
            isConfigured = true
        } else {
            credential = nil
            isConfigured = false
        }
        super.init()
    }

    func refresh() async {
        guard let credential else {
            isConnected = false; generations = []
            return
        }
        isConnected = await credential.isConnected()
        if isConnected { await refreshGenerations() } else { generations = [] }
    }

    func connect() {
        guard !isWorking, let credential else {
            errorMessage = "Dropbox is not configured for this build."
            return
        }
        do {
            let authorization = try credential.beginAuthorization()
            pendingAuthorization = authorization
            errorMessage = nil
            let session = ASWebAuthenticationSession(
                url: authorization.authorizationURL,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] callback, error in
                Task { @MainActor [weak self] in await self?.completeAuthorization(callback: callback, error: error) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            isWorking = true
            if !session.start() {
                authenticationSession = nil; pendingAuthorization = nil; isWorking = false
                errorMessage = "Dropbox sign-in could not be opened."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func upload(packageURL: URL) async throws -> DropboxBackupPublication {
        guard !isWorking else { throw DropboxBackupOperationError.alreadyWorking }
        let destination = try destination()
        isWorking = true; errorMessage = nil; publicationWarning = nil
        defer { isWorking = false }
        do {
            let result = try await destination.publish(packageURL: packageURL)
            return await finalizePublication(result) { try await destination.generations() }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Called only after the destination has committed a verified immutable generation.
    func finalizePublication(_ result: DropboxBackupPublication,
                             listGenerations: () async throws -> [DropboxBackupEntry]) async -> DropboxBackupPublication {
        recordSuccessfulBackup()
        var warnings: [String] = []
        if result.retentionCleanupPending {
            warnings.append("Backup saved. Older-backup cleanup is pending; it will be attempted with the next backup.")
        }
        do { generations = try await listGenerations() }
        catch {
            let entry = DropboxBackupEntry(path: result.remotePath,
                name: (result.remotePath as NSString).lastPathComponent, isFolder: true)
            if !generations.contains(where: { $0.path == result.remotePath }) { generations.append(entry) }
            generations.sort { $0.name > $1.name }
            warnings.append("Backup saved. The backup list could not refresh; refresh it later. Do not upload this generation again.")
        }
        publicationWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        return result
    }

    func download(_ generation: DropboxBackupEntry) async throws -> URL {
        guard !isWorking else { throw DropboxBackupOperationError.alreadyWorking }
        let destination = try destination()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dropbox-\(UUID().uuidString)-\(generation.name)", isDirectory: true
        )
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            try await destination.download(remotePath: generation.path, destinationURL: output)
            return output
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func delete(_ generation: DropboxBackupEntry) async throws {
        guard !isWorking else { throw DropboxBackupOperationError.alreadyWorking }
        let destination = try destination()
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            try await destination.deleteGeneration(remotePath: generation.path)
            generations.removeAll { $0.path == generation.path }
            // Deletion is already authoritative. A transient list failure must not misreport the
            // completed destructive operation as failed or encourage the user to repeat it.
            if let refreshed = try? await destination.generations() { generations = refreshed }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func revoke() async {
        guard let credential, !isWorking else { return }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            try await credential.revoke()
            isConnected = false; generations = []; automaticBackupEnabled = false
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshGenerations() async {
        guard let destination = try? destination() else { return }
        do { generations = try await destination.generations() }
        catch { errorMessage = error.localizedDescription }
    }

    func recordSuccessfulBackup(at completedAt: Date = Date()) {
        lastSuccessfulBackupAt = completedAt
        defaults.set(completedAt, forKey: lastSuccessfulBackupKey)
        automaticRetryAt = nil
        defaults.removeObject(forKey: automaticRetryAtKey)
    }

    func automaticBackupIsDue(at date: Date = Date()) -> Bool {
        guard automaticBackupEnabled else { return false }
        if let automaticRetryAt, date < automaticRetryAt { return false }
        if pendingLocalGenerationURL != nil { return date >= (pendingRetryAt ?? .distantPast) }
        guard let lastSuccessfulBackupAt else { return true }
        return date >= lastSuccessfulBackupAt.addingTimeInterval(TimeInterval(automaticBackupIntervalDays * 86_400))
    }

    func nextAutomaticBackupAt() -> Date? {
        guard automaticBackupEnabled else { return nil }
        let scheduled: Date?
        if pendingLocalGenerationURL != nil { scheduled = pendingRetryAt ?? .distantPast }
        else { scheduled = lastSuccessfulBackupAt?.addingTimeInterval(TimeInterval(automaticBackupIntervalDays * 86_400)) }
        if let automaticRetryAt { return max(scheduled ?? .distantPast, automaticRetryAt) }
        return scheduled
    }

    /// Claims one due automatic run before capture begins. Scene activation and SwiftUI task
    /// delivery can overlap, so the claim covers both the local snapshot and the later upload.
    func claimAutomaticBackupIfDue(at date: Date = Date()) -> Bool {
        guard !automaticBackupClaimed, !isWorking, automaticBackupIsDue(at: date) else { return false }
        automaticBackupClaimed = true
        automaticBackupStartedAt = date
        return true
    }

    func finishAutomaticBackupAttempt(at date: Date = Date()) {
        // Failures before capture have no retained generation to carry an upload cooldown.
        // An attempt is successful only after verified publication, never after local capture.
        if let startedAt = automaticBackupStartedAt,
           (lastSuccessfulBackupAt ?? .distantPast) < startedAt {
            automaticRetryAt = date.addingTimeInterval(Self.pendingRetryInterval)
            defaults.set(automaticRetryAt, forKey: automaticRetryAtKey)
        }
        automaticBackupClaimed = false
        automaticBackupStartedAt = nil
    }

    func retainPendingLocalGeneration(_ url: URL, at date: Date = Date()) {
        guard Self.isValidPendingGeneration(url) else { return }
        pendingLocalGenerationURL = url
        defaults.set(url.path, forKey: pendingLocalGenerationKey)
        pendingRetryAt = date.addingTimeInterval(Self.pendingRetryInterval)
        defaults.set(pendingRetryAt, forKey: pendingRetryAtKey)
    }

    func clearPendingLocalGeneration() {
        pendingLocalGenerationURL = nil
        defaults.removeObject(forKey: pendingLocalGenerationKey)
        pendingRetryAt = nil
        defaults.removeObject(forKey: pendingRetryAtKey)
    }

    private static func isValidPendingGeneration(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        return standardized.pathExtension == "clearpocketbackup"
            && FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func completeAuthorization(callback: URL?, error: Error?) async {
        defer {
            authenticationSession = nil; pendingAuthorization = nil; isWorking = false
        }
        guard let credential, let authorization = pendingAuthorization else { return }
        if let error = error as? ASWebAuthenticationSessionError,
           error.code == .canceledLogin { return }
        if let error { errorMessage = error.localizedDescription; return }
        guard let callback else { errorMessage = DropboxOAuthError.invalidCallback.localizedDescription; return }
        do {
            let code = try DropboxOAuthCredential.authorizationCode(
                from: callback, expectedRedirectURI: Self.redirectURI, expectedState: authorization.state
            )
            _ = try await credential.installAuthorizationCode(code, verifier: authorization.verifier)
            isConnected = true
            await refreshGenerations()
        } catch { errorMessage = error.localizedDescription }
    }

    private func destination() throws -> DropboxBackupDestination {
        guard let credential else { throw DropboxOAuthError.invalidConfiguration }
        return try DropboxBackupDestination(
            transport: DropboxHTTPTransport(tokenProvider: credential),
            retention: retention
        )
    }
}

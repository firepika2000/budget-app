import AuthenticationServices
import BudgetStorage
import Combine
import Foundation
import UIKit

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
    static let supportedAutomaticIntervals = [1, 7]
    private var automaticBackupClaimed = false
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
        let destination = try destination()
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await destination.publish(packageURL: packageURL)
            generations = try await destination.generations()
            recordSuccessfulBackup()
            return result
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func download(_ generation: DropboxBackupEntry) async throws -> URL {
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
    }

    func automaticBackupIsDue(at date: Date = Date()) -> Bool {
        guard automaticBackupEnabled, pendingLocalGenerationURL == nil else { return false }
        guard let lastSuccessfulBackupAt else { return true }
        return date >= lastSuccessfulBackupAt.addingTimeInterval(TimeInterval(automaticBackupIntervalDays * 86_400))
    }

    func nextAutomaticBackupAt() -> Date? {
        guard automaticBackupEnabled, let lastSuccessfulBackupAt else { return nil }
        return lastSuccessfulBackupAt.addingTimeInterval(TimeInterval(automaticBackupIntervalDays * 86_400))
    }

    /// Claims one due automatic run before capture begins. Scene activation and SwiftUI task
    /// delivery can overlap, so the claim covers both the local snapshot and the later upload.
    func claimAutomaticBackupIfDue(at date: Date = Date()) -> Bool {
        guard !automaticBackupClaimed, !isWorking, automaticBackupIsDue(at: date) else { return false }
        automaticBackupClaimed = true
        return true
    }

    func finishAutomaticBackupAttempt() {
        automaticBackupClaimed = false
    }

    func retainPendingLocalGeneration(_ url: URL) {
        guard Self.isValidPendingGeneration(url) else { return }
        pendingLocalGenerationURL = url
        defaults.set(url.path, forKey: pendingLocalGenerationKey)
    }

    func clearPendingLocalGeneration() {
        pendingLocalGenerationURL = nil
        defaults.removeObject(forKey: pendingLocalGenerationKey)
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

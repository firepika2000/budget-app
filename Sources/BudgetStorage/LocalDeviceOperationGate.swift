import Foundation

/// Serializes compound Local Device persistence operations that span SQLite and attachment files.
///
/// SQLite and the encrypted object vault each serialize their own work, but a full-fidelity backup
/// observes both stores. Callers use this gate around workspace publication, attachment lifecycle
/// changes, and backup capture so a generation cannot contain database metadata from one instant
/// and attachment bytes from another.
public actor LocalDeviceOperationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func release() {
        precondition(isHeld, "Local Device operation gate released without an owner")
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

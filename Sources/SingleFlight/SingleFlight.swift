/// Deduplicates concurrent async work by key.
///
/// While an operation for a key is running, every other call for the same key
/// waits for that operation and receives its result (or error) instead of
/// starting a new one. Once it finishes, the next call starts fresh: results
/// are shared, not cached.
///
/// ```swift
/// let tokens = SingleFlight<String, Token>()
///
/// // Five requests failing with 401 at once trigger one refresh, not five.
/// let token = try await tokens.run("refresh") {
///     try await api.refreshToken()
/// }
/// ```
///
/// The operation runs in its own task, so cancelling one caller does not
/// cancel the work for the others. Use ``cancel(_:)`` to cancel the shared
/// operation itself.
public actor SingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private struct Flight {
        let id: UInt64
        let task: Task<Value, any Error>
        var callers: Int
    }

    private var flights: [Key: Flight] = [:]
    private var nextID: UInt64 = 0

    /// Creates an empty group.
    public init() {}

    /// Runs `operation` for `key`, or joins the operation already running for
    /// it.
    ///
    /// - Returns: The value produced by the shared operation.
    /// - Throws: The error thrown by the shared operation, or
    ///   `CancellationError` if it was cancelled with ``cancel(_:)``.
    public func run(
        _ key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await join(key, operation: operation).task.value
    }

    /// Like ``run(_:operation:)``, but also reports whether this call shared
    /// a result with an operation started by another caller.
    public func runReportingShared(
        _ key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> (value: Value, shared: Bool) {
        let flight = join(key, operation: operation)
        let value = try await flight.task.value
        return (value, flight.shared)
    }

    /// Whether an operation is currently running for `key`.
    public func isRunning(_ key: Key) -> Bool {
        flights[key] != nil
    }

    /// The number of calls that have joined the operation running for `key`,
    /// including the one that started it. Zero if nothing is running.
    public func callerCount(for key: Key) -> Int {
        flights[key]?.callers ?? 0
    }

    /// Cancels the operation running for `key`, if any.
    ///
    /// Every caller waiting on it receives the operation's result, which is
    /// usually a `CancellationError` if the operation checks for
    /// cancellation.
    public func cancel(_ key: Key) {
        flights[key]?.task.cancel()
    }

    /// Stops sharing the operation running for `key`.
    ///
    /// Callers already waiting still receive its result, but the next call
    /// for `key` starts a new operation. Useful when you know the running
    /// result is already stale.
    public func forget(_ key: Key) {
        flights[key] = nil
    }

    private func join(
        _ key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) -> (task: Task<Value, any Error>, shared: Bool) {
        if var flight = flights[key] {
            flight.callers += 1
            flights[key] = flight
            return (flight.task, true)
        }

        nextID &+= 1
        let id = nextID
        // The flight is removed before the result is delivered, so a call
        // made after the operation finishes always starts a new one.
        let task = Task<Value, any Error> {
            do {
                let value = try await operation()
                self.finish(key, id: id)
                return value
            } catch {
                self.finish(key, id: id)
                throw error
            }
        }
        flights[key] = Flight(id: id, task: task, callers: 1)
        return (task, false)
    }

    private func finish(_ key: Key, id: UInt64) {
        // Only remove the flight this task belongs to; it may already have
        // been forgotten and replaced by a newer one.
        if flights[key]?.id == id {
            flights[key] = nil
        }
    }
}

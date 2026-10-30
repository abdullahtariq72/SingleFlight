import SingleFlight
import XCTest

/// Suspends callers of `wait()` until `open()` is called.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

private struct TestError: Error, Equatable {}

/// Waits until `condition` holds, failing the test after about a second.
private func eventually(
    _ condition: @Sendable () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<1000 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Condition was not met in time", file: file, line: line)
}

final class SingleFlightTests: XCTestCase {
    func testConcurrentCallsShareOneOperation() async throws {
        let group = SingleFlight<String, Int>()
        let gate = Gate()
        let runs = Counter()

        let results = Task {
            try await withThrowingTaskGroup(of: (Int, Bool).self) { tasks in
                for _ in 0..<10 {
                    tasks.addTask {
                        let result = try await group.runReportingShared("key") {
                            await gate.wait()
                            return await runs.increment()
                        }
                        return (result.value, result.shared)
                    }
                }
                return try await tasks.reduce(into: []) { $0.append($1) }
            }
        }

        await eventually { await group.callerCount(for: "key") == 10 }
        await gate.open()
        let all = try await results.value

        let runCount = await runs.value
        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(all.map(\.0), Array(repeating: 1, count: 10))
        XCTAssertEqual(all.filter { !$0.1 }.count, 1, "exactly one caller starts the work")
    }

    func testDifferentKeysRunIndependently() async throws {
        let group = SingleFlight<Int, Int>()
        async let a = group.run(1) { 10 }
        async let b = group.run(2) { 20 }
        let (resultA, resultB) = try await (a, b)
        XCTAssertEqual(resultA, 10)
        XCTAssertEqual(resultB, 20)
    }

    func testResultsAreNotCached() async throws {
        let group = SingleFlight<String, Int>()
        let runs = Counter()
        let first = try await group.run("key") { await runs.increment() }
        let second = try await group.run("key") { await runs.increment() }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        let isRunning = await group.isRunning("key")
        XCTAssertFalse(isRunning)
    }

    func testErrorsAreSharedWithAllCallers() async {
        let group = SingleFlight<String, Int>()
        let gate = Gate()

        let first = Task {
            try await group.run("key") {
                await gate.wait()
                throw TestError()
            }
        }
        await eventually { await group.isRunning("key") }
        let second = Task { try await group.run("key") { 42 } }
        await eventually { await group.callerCount(for: "key") == 2 }
        await gate.open()

        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("Expected an error")
            } catch {
                XCTAssertEqual(error as? TestError, TestError())
            }
        }
        let isRunning = await group.isRunning("key")
        XCTAssertFalse(isRunning)
    }

    func testCancelCancelsSharedOperation() async {
        let group = SingleFlight<String, Int>()
        let caller = Task {
            try await group.run("key") {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return 1
            }
        }
        await eventually { await group.isRunning("key") }
        await group.cancel("key")

        do {
            _ = try await caller.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellingOneCallerDoesNotCancelTheOperation() async throws {
        let group = SingleFlight<String, Int>()
        let gate = Gate()

        let first = Task {
            try await group.run("key") {
                await gate.wait()
                try Task.checkCancellation()
                return 7
            }
        }
        await eventually { await group.isRunning("key") }
        let second = Task { try await group.run("key") { 0 } }
        await eventually { await group.callerCount(for: "key") == 2 }

        first.cancel()
        await gate.open()

        let secondValue = try await second.value
        XCTAssertEqual(secondValue, 7)
    }

    func testForgetStartsANewOperation() async throws {
        let group = SingleFlight<String, String>()
        let staleGate = Gate()
        let freshGate = Gate()

        let stale = Task {
            try await group.run("key") {
                await staleGate.wait()
                return "stale"
            }
        }
        await eventually { await group.isRunning("key") }
        await group.forget("key")

        let fresh = Task {
            try await group.run("key") {
                await freshGate.wait()
                return "fresh"
            }
        }
        await eventually { await group.callerCount(for: "key") == 1 }

        await staleGate.open()
        let staleValue = try await stale.value
        XCTAssertEqual(staleValue, "stale")
        // The stale operation finishing must not remove the fresh one.
        let freshStillShared = await group.isRunning("key")
        XCTAssertTrue(freshStillShared)

        await freshGate.open()
        let freshValue = try await fresh.value
        XCTAssertEqual(freshValue, "fresh")
    }
}

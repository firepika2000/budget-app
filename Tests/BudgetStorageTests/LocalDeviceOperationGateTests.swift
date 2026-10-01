import XCTest
@testable import BudgetStorage

final class LocalDeviceOperationGateTests: XCTestCase {
    func testWaitersRunInFIFOOrderAndNeverOverlapCapture() async {
        let gate = LocalDeviceOperationGate()
        let observations = ObservationLog()

        await gate.acquire()
        let first = Task {
            await gate.acquire()
            await observations.append("first-enter")
            try? await Task.sleep(for: .milliseconds(20))
            await observations.append("first-exit")
            await gate.release()
        }
        await Task.yield()
        let second = Task {
            await gate.acquire()
            await observations.append("second-enter")
            await observations.append("second-exit")
            await gate.release()
        }
        await Task.yield()

        let beforeRelease = await observations.values
        XCTAssertEqual(beforeRelease, [])
        await gate.release()
        _ = await (first.result, second.result)
        let afterCompletion = await observations.values
        XCTAssertEqual(afterCompletion, ["first-enter", "first-exit", "second-enter", "second-exit"])
    }
}

private actor ObservationLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

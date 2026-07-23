import XCTest
@testable import sand

final class VMShutdownCoordinatorTests: XCTestCase {
    private func makeCoordinator() -> VMShutdownCoordinator {
        let logger = Logger(label: "test.shutdown", minimumLevel: .info)
        let destroyer = VMDestroyer(tart: makeTart(MockProcessRunner()), logger: logger)
        return VMShutdownCoordinator(destroyer: destroyer, logger: logger)
    }

    func testCleanupRunsDeregistrationOnce() async {
        let coordinator = makeCoordinator()
        await coordinator.activate(name: "vm")
        let counter = Counter()
        await coordinator.setDeregistration {
            await counter.increment()
        }
        await coordinator.cleanup(reason: "test")
        await coordinator.cleanup(reason: "test again")
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testActivateClearsPreviousDeregistration() async {
        let coordinator = makeCoordinator()
        await coordinator.activate(name: "vm1")
        let counter = Counter()
        await coordinator.setDeregistration {
            await counter.increment()
        }
        await coordinator.activate(name: "vm2")
        await coordinator.cleanup(reason: "test")
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    func testCleanupWithoutDeregistrationDestroysVM() async {
        let coordinator = makeCoordinator()
        await coordinator.activate(name: "vm")
        await coordinator.cleanup(reason: "test")
    }
}

actor Counter {
    var value = 0

    func increment() {
        value += 1
    }
}

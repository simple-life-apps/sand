import XCTest
@testable import sand

final class SSHFailureDetailTests: XCTestCase {
    func testReportsExitCodeAndLastStderrLine() {
        let error = ProcessRunnerError.failed(
            exitCode: 255,
            stdout: "",
            stderr: "Warning: something\nkex_exchange_identification: Connection closed by remote host\n",
            command: ["sshpass", "ssh"]
        )
        XCTAssertEqual(
            Runner.sshFailureDetail(for: error),
            "exit 255: kex_exchange_identification: Connection closed by remote host"
        )
    }

    func testReportsExitCodeAloneWhenStderrIsEmpty() {
        let error = ProcessRunnerError.failed(exitCode: 255, stdout: "", stderr: "   \n", command: ["sshpass", "ssh"])
        XCTAssertEqual(Runner.sshFailureDetail(for: error), "exit 255")
    }

    func testFallsBackToTheErrorDescription() {
        struct Boom: Error {}
        XCTAssertTrue(Runner.sshFailureDetail(for: Boom()).contains("Boom"))
    }
}

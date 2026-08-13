import Foundation
import XCTest
@testable import sand

final class LoggerFileTests: XCTestCase {
    func testLoggerWritesToFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let logger = Logger(label: "test.logger", minimumLevel: .info, sink: sink)
        logger.info("hello")

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("[info] test.logger hello"))
    }

    func testConcurrentLoggingFromTheCooperativePoolCompletes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let logger = Logger(label: "test.logger", minimumLevel: .info, sink: sink)

        // Enough writers to occupy every cooperative-pool thread at once: a
        // sink that parks its calling thread while waiting on pool capacity
        // deadlocks here instead of finishing.
        let writers = ProcessInfo.processInfo.activeProcessorCount * 4
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<writers {
                group.addTask { logger.info("line \(index)") }
            }
        }

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.split(separator: "\n").count, writers)
    }
}

// Lightweight test support, replacing XCTest.
// Reason: the CommandLineTools environment has no XCTest.framework and `swift test`
// is unavailable, so tests run in an executable target with assertions via `swift run AppleTVControlTests`.

import Foundation

struct TestFailure {
    let message: String
    let file: String
    let line: Int
}

var testFailures: [TestFailure] = []

private func record(_ message: String, file: String, line: Int) {
    testFailures.append(TestFailure(message: message, file: file, line: line))
    print("❌ FAIL: \(message)  [\((file as NSString).lastPathComponent):\(line)]")
}

func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if !condition { record(message, file: file, line: line) }
}

func expectEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: String, file: String = #file, line: Int = #line
) {
    if actual != expected {
        record("\(message) — expected \(expected), got \(actual)", file: file, line: line)
    }
}

func expectHexEqual(
    _ actual: [UInt8], _ expected: [UInt8], _ message: String, file: String = #file, line: Int = #line
) {
    if actual != expected {
        record("\(message) — expected \(hex(expected)), got \(hex(actual))", file: file, line: line)
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func hex(_ data: Data) -> String {
    hex([UInt8](data))
}

/// Test suite entry point that groups results by name so main can call them uniformly.
func runSuite(_ name: String, _ body: () -> Void) {
    print("— \(name)")
    let before = testFailures.count
    body()
    let delta = testFailures.count - before
    print("  \(delta == 0 ? "✅" : "❌") \(name): \(delta) failure(s)")
}

/// Async test suite (for pairing/connection flows that need await).
func runSuiteAsync(_ name: String, _ body: () async throws -> Void) async {
    print("— \(name)")
    let before = testFailures.count
    do {
        try await body()
    } catch {
        record("\(name) threw: \(error)", file: #file, line: #line)
    }
    let delta = testFailures.count - before
    print("  \(delta == 0 ? "✅" : "❌") \(name): \(delta) failure(s)")
}

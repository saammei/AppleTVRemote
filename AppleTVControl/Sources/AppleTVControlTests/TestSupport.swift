// 轻量测试辅助,替代 XCTest。
// 原因:CommandLineTools 环境没有 XCTest.framework,`swift test` 不可用,
// 因此用可执行 target + 断言在 `swift run AppleTVControlTests` 下跑测试。

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

/// 测试套件入口按名称汇总到此处,便于在 main 中统一调用。
func runSuite(_ name: String, _ body: () -> Void) {
    print("— \(name)")
    let before = testFailures.count
    body()
    let delta = testFailures.count - before
    print("  \(delta == 0 ? "✅" : "❌") \(name): \(delta) failure(s)")
}

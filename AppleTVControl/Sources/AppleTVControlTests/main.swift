import Foundation
import AppleTVControl

// 各测试套件在此注册。后续 Phase 逐步加入:
//   runSuite("OPACK") { runOPACKTests() }
//   runSuite("TLV8") { runTLV8Tests() }
//   runSuite("SRP") { runSRPTests() }
//   ...

runSuite("占位") {
    expectEqual(AppleTVControl.version, "0.1.0", "版本号")
}

if testFailures.isEmpty {
    print("✅ All tests passed")
} else {
    print("❌ \(testFailures.count) test(s) failed")
    exit(1)
}

import Foundation
import AppleTVControl

// 无缓冲 stdout:崩溃时仍能看到已打印的测试输出(诊断用)。
setvbuf(stdout, nil, _IONBF, 0)

// 各测试套件在此注册。后续 Phase 逐步加入:
//   runSuite("OPACK") { runOPACKTests() }
//   runSuite("TLV8") { runTLV8Tests() }
//   runSuite("SRP") { runSRPTests() }
//   ...

runDiscoveryTests()
runCryptoTests()
runOPACKTests()
runBinaryPlistTests()
await runCompanionTests()
await runCompanionAPITests()

if testFailures.isEmpty {
    print("✅ All tests passed")
} else {
    print("❌ \(testFailures.count) test(s) failed")
    exit(1)
}

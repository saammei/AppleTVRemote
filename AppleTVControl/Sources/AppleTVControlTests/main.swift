import Foundation
import AppleTVControl

// Unbuffered stdout: printed test output stays visible even on crash (for diagnostics).
setvbuf(stdout, nil, _IONBF, 0)

// All test suites are registered here. Later phases add more:
//   runSuite("OPACK") { runOPACKTests() }
//   runSuite("TLV8") { runTLV8Tests() }
//   runSuite("SRP") { runSRPTests() }
//   ...

runDiscoveryTests()
runCredentialsStoreTests()
runCryptoTests()
runOPACKTests()
runBinaryPlistTests()
await runCompanionTests()
await runCompanionAPITests()
await runMRPTests()

if testFailures.isEmpty {
    print("✅ All tests passed")
} else {
    print("❌ \(testFailures.count) test(s) failed")
    exit(1)
}

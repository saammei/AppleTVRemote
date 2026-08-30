import Foundation
import AppleTVControl

func runCredentialsStoreTests() {
    runSuite("credentials persistence round-trip") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atv-credentials-test-\(UUID().uuidString)")
        let store = CredentialsStore(fileURL: dir.appendingPathComponent("credentials.json"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let creds = HapCredentials(
            ltpk: Data(repeating: 0x11, count: 32),
            ltsk: Data(repeating: 0x22, count: 32),
            atvId: Data("atv-id".utf8),
            clientId: Data("client-id".utf8))

        expect(store.credentials(for: "dev-1") == nil, "initially empty")
        expect(store.save(creds, for: "dev-1"), "save succeeds")

        let loaded = store.credentials(for: "dev-1")
        expect(loaded == creds, "read back matches")

        // A new instance reads from disk (verifying actual persistence).
        let store2 = CredentialsStore(fileURL: dir.appendingPathComponent("credentials.json"))
        expect(store2.credentials(for: "dev-1") == creds, "cross-instance read matches")

        expect(store2.remove(identifier: "dev-1"), "remove succeeds")
        expect(store2.credentials(for: "dev-1") == nil, "empty after removal")
    }
}

import Foundation
import AppleTVControl

func runCredentialsStoreTests() {
    runSuite("凭证持久化 round-trip") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atv-credentials-test-\(UUID().uuidString)")
        let store = CredentialsStore(fileURL: dir.appendingPathComponent("credentials.json"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let creds = HapCredentials(
            ltpk: Data(repeating: 0x11, count: 32),
            ltsk: Data(repeating: 0x22, count: 32),
            atvId: Data("atv-id".utf8),
            clientId: Data("client-id".utf8))

        expect(store.credentials(for: "dev-1") == nil, "初始为空")
        expect(store.save(creds, for: "dev-1"), "保存成功")

        let loaded = store.credentials(for: "dev-1")
        expect(loaded == creds, "读取回一致凭证")

        // 新实例从磁盘读取(验证真实落盘)。
        let store2 = CredentialsStore(fileURL: dir.appendingPathComponent("credentials.json"))
        expect(store2.credentials(for: "dev-1") == creds, "跨实例读取一致")

        expect(store2.remove(identifier: "dev-1"), "删除成功")
        expect(store2.credentials(for: "dev-1") == nil, "删除后为空")
    }
}

// 凭证持久化:按设备 identifier 保存 HapCredentials 到本地 JSON 文件。
// 对应 pyatv 的 FileStorage(pyatv.json)——配对一次后,后续连接用保存的凭证做
// Pair-Verify,无需再次输入 PIN。
//
// 存储格式(JSON):
//   { "<identifier>": "<detailString>" }
// detailString 即 HapCredentials 的 "ltpk:ltsk:atv_id:client_id"(各字段 hex)。

import Foundation

public final class CredentialsStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 读取全部已保存凭证,返回 identifier -> credentials。
    public func load() -> [String: HapCredentials] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        var result: [String: HapCredentials] = [:]
        for (identifier, detail) in json {
            if let credentials = HapCredentials.parse(detail) {
                result[identifier] = credentials
            }
        }
        return result
    }

    /// 读取指定设备的凭证。
    public func credentials(for identifier: String) -> HapCredentials? {
        load()[identifier]
    }

    /// 保存某设备的凭证(覆盖已有)。
    @discardableResult
    public func save(_ credentials: HapCredentials, for identifier: String) -> Bool {
        var all = load()
        all[identifier] = credentials
        return write(all)
    }

    /// 删除某设备的凭证。
    @discardableResult
    public func remove(identifier: String) -> Bool {
        var all = load()
        all.removeValue(forKey: identifier)
        return write(all)
    }

    private func write(_ map: [String: HapCredentials]) -> Bool {
        let dict = map.mapValues { $0.detailString }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

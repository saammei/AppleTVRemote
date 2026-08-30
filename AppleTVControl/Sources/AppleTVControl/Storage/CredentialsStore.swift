// Credential persistence: saves HapCredentials to a local JSON file keyed by device identifier.
// Corresponds to pyatv's FileStorage (pyatv.json) — after pairing once, subsequent connections
// use the saved credentials for Pair-Verify without re-entering the PIN.
//
// Storage format (JSON):
//   { "<identifier>": "<detailString>" }
// detailString is HapCredentials' "ltpk:ltsk:atv_id:client_id" (each field hex).

import Foundation

public final class CredentialsStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads all saved credentials, returning identifier -> credentials.
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

    /// Loads the credentials for the specified device.
    public func credentials(for identifier: String) -> HapCredentials? {
        load()[identifier]
    }

    /// Saves the credentials for a device (overwrites any existing entry).
    @discardableResult
    public func save(_ credentials: HapCredentials, for identifier: String) -> Bool {
        var all = load()
        all[identifier] = credentials
        return write(all)
    }

    /// Removes the credentials for a device.
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
            // Tighten permissions: only the current user can read/write, preventing other
            // processes on the same machine from reading the long-term private key.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }
}

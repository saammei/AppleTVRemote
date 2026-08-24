// HAP 配对凭证。对应 pyatv 的 HapCredentials。
// 配对完成后,这四项信息用于后续 Pair-Verify 重新建立加密会话。

import Foundation

public struct HapCredentials: Equatable {
    /// Apple TV 的长期公钥(Ed25519,32 字节)。
    public let ltpk: Data
    /// 本机(控制器)的长期私钥(Ed25519 seed,32 字节)。
    public let ltsk: Data
    /// Apple TV 的配对标识。
    public let atvId: Data
    /// 本机(控制器)的配对标识(client_id)。
    public let clientId: Data

    public init(ltpk: Data, ltsk: Data, atvId: Data, clientId: Data) {
        self.ltpk = ltpk
        self.ltsk = ltsk
        self.atvId = atvId
        self.clientId = clientId
    }

    /// 序列化为 "ltpk:ltsk:atv_id:client_id"(各字段 hex),与 pyatv 的 str 一致。
    /// 用于持久化到文件或设置。
    public var detailString: String {
        [ltpk, ltsk, atvId, clientId].map { $0.hex }.joined(separator: ":")
    }

    /// 从 detailString 解析。
    public static func parse(_ string: String) -> HapCredentials? {
        let parts = string.split(separator: ":").map(String.init)
        guard parts.count == 4,
              let ltpk = Data(hex: parts[0]),
              let ltsk = Data(hex: parts[1]),
              let atvId = Data(hex: parts[2]),
              let clientId = Data(hex: parts[3]) else { return nil }
        return HapCredentials(ltpk: ltpk, ltsk: ltsk, atvId: atvId, clientId: clientId)
    }
}

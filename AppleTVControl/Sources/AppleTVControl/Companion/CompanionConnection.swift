// 连接层抽象:上层(协议层/配对流程)不关心具体传输(TCP / 测试 mock)。
// 对应 pyatv 的 pyatv/protocols/companion/connection.py 的 CompanionConnection 接口。
//
// 具体 TCP 实现(NWConnection)在 Phase 3 接入;本抽象让配对流程可脱离网络做端到端测试。

import Foundation

public protocol CompanionConnectionListener: AnyObject {
    /// 收到一帧。payload 已由连接层解密(若已启用加密)。
    func connection(_ connection: CompanionConnection, didReceive frameType: FrameType, payload: Data)
}

public protocol CompanionConnection: AnyObject {
    var isConnected: Bool { get }
    var listener: CompanionConnectionListener? { get set }

    /// 建立连接(异步,完成后可收发)。
    func connect() async throws

    /// 关闭连接。
    func close()

    /// 发送一帧。帧体由连接层负责打包/加密。
    func send(_ frameType: FrameType, payload: Data) throws

    /// 启用连接层加密(输出/输入两把独立密钥,各带独立计数器)。
    func enableEncryption(outputKey: Data, inputKey: Data)
}

public enum CompanionError: Error {
    case notConnected
    case timeout
    case invalidResponse
    case protocolError(String)
    case authenticationFailed(String)
}

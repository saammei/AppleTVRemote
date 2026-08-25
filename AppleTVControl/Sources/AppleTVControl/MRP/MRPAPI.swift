// MRP 控制层:在协议层之上维护 now-playing 元数据缓存(订阅推送驱动)。
// 对应 pyatv 的 pyatv/protocols/mrp/metadata.py 的 PlayerStateManager。
//
// now-playing 元数据来自设备订阅推送(ClientUpdatesConfigMessage 打开 nowPlayingUpdates):
//   - SetStateMessage.nowPlayingInfo → 标题/艺术家/专辑/时长/已播放时间
//   - SetStateMessage.playbackState  → 播放状态
//   - UpdateContentItemMessage      → ContentItem.metadata(更完整的曲目元数据 + mediaType)
//   - UpdateContentItemArtworkMessage / SetArtworkMessage → 封面 JPEG
// 与 Companion 不同,这里不主动轮询,`nowPlaying()` 直接返回缓存。

import Foundation
import os

/// 一条 now-playing 元数据快照。
public struct MRPNowPlaying {
    public let title: String?
    public let artist: String?
    public let album: String?
    /// 已播放秒数。
    public let position: Double?
    /// 总时长秒数。
    public let duration: Double?
    public let playbackState: PlaybackState.Enum
    /// 媒体类型字符串(Music / Podcast / AudioBook / iTunesU / Video / Audio / Unknown)。
    public let mediaType: String?

    public init(
        title: String?, artist: String?, album: String?,
        position: Double?, duration: Double?,
        playbackState: PlaybackState.Enum, mediaType: String?
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.position = position
        self.duration = duration
        self.playbackState = playbackState
        self.mediaType = mediaType
    }
}

public final class MRPAPI: MRPProtocolDelegate {
    public let protocolLayer: MRPProtocol

    private var lock = os_unfair_lock()
    private var setState: SetStateMessage?
    private var contentItems: [ContentItem] = []
    /// 内容标识 -> JPEG 封面(来自 UpdateContentItemArtworkMessage)。
    private var artworkByID: [String: Data] = [:]
    /// 最新封面(来自 SetArtworkMessage)。
    private var jpegData: Data?

    public init(protocolLayer: MRPProtocol) {
        self.protocolLayer = protocolLayer
        protocolLayer.delegate = self
    }

    /// 连接断开回调(转发自协议层,由连接层触发)。
    public var onDisconnect: (() -> Void)? {
        get { protocolLayer.onDisconnect }
        set { protocolLayer.onDisconnect = newValue }
    }

    public func connect(credentials: HapCredentials?, deviceInfo: MRPDeviceInfo) async throws {
        try await protocolLayer.start(credentials: credentials, deviceInfo: deviceInfo)
    }

    public func disconnect() {
        protocolLayer.stop()
    }

    // MARK: - MRPProtocolDelegate

    public func mrpProtocol(_ protocol: MRPProtocol, didReceive message: ProtocolMessageMessage) {
        switch message.type {
        case .setStateMessage:
            withLock { setState = message.setStateMessage }
        case .updateContentItemMessage:
            withLock { contentItems = message.updateContentItemMessage.contentItems }
        case .updateContentItemArtworkMessage:
            let items = message.updateContentItemArtworkMessage.contentItems
            withLock {
                for item in items where !item.identifier.isEmpty && !item.artworkData.isEmpty {
                    artworkByID[item.identifier] = item.artworkData
                }
            }
        case .setArtworkMessage:
            withLock { jpegData = message.setArtworkMessage.jpegData }
        default:
            break
        }
    }

    // MARK: - 查询

    /// 返回缓存的 now-playing 元数据(未收到任何推送时为默认空值)。
    public func nowPlaying() -> MRPNowPlaying {
        withLock {
            let info = setState?.nowPlayingInfo
            let meta = contentItems.first?.metadata

            let title = meta?.title.nonEmpty ?? info?.title.nonEmpty
            let artist = meta?.trackArtistName.nonEmpty ?? info?.artist.nonEmpty
            let album = meta?.albumName.nonEmpty ?? info?.album.nonEmpty
            let duration = meta?.duration.positive ?? info?.duration.positive
            let position = info?.elapsedTime

            return MRPNowPlaying(
                title: title, artist: artist, album: album,
                position: position, duration: duration,
                playbackState: setState?.playbackState ?? .unknown,
                mediaType: Self.mediaTypeString(meta))
        }
    }

    /// 返回缓存的封面 JPEG(优先按内容标识匹配,其次 SetArtworkMessage 数据)。
    public func artwork() -> Data? {
        withLock {
            if let id = contentItems.first?.identifier, let data = artworkByID[id], !data.isEmpty {
                return data
            }
            if let jpegData, !jpegData.isEmpty {
                return jpegData
            }
            // 任意一张封面兜底。
            return artworkByID.values.first(where: { !$0.isEmpty })
        }
    }

    /// 从 ContentItemMetadata 映射为媒体类型字符串(与 pyatv 的 MediaType 一致)。
    private static func mediaTypeString(_ meta: ContentItemMetadata?) -> String? {
        guard let meta else { return nil }
        switch meta.mediaSubType {
        case .music: return "Music"
        case .podcast: return "Podcast"
        case .audioBook: return "AudioBook"
        case .itunesU: return "iTunesU"
        default: break
        }
        switch meta.mediaType {
        case .video: return "Video"
        case .audio: return "Audio"
        default: return "Unknown"
        }
    }

    // MARK: - 工具

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}

private extension String {
    /// 空串视为 nil。
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Double {
    /// 非正视为 nil。
    var positive: Double? { self > 0 ? self : nil }
}

// MRP control layer: maintains a now-playing metadata cache on top of the protocol layer
// (driven by subscription push).
// Corresponds to pyatv's PlayerStateManager in pyatv/protocols/mrp/metadata.py.
//
// now-playing metadata comes from device subscription pushes (ClientUpdatesConfigMessage enables nowPlayingUpdates):
//   - SetStateMessage.nowPlayingInfo → title/artist/album/duration/elapsed time
//   - SetStateMessage.playbackState  → playback state
//   - UpdateContentItemMessage      → ContentItem.metadata (fuller track metadata + mediaType)
//   - UpdateContentItemArtworkMessage / SetArtworkMessage → cover JPEG
// Unlike Companion, this layer does not poll; `nowPlaying()` returns the cache directly.

import Foundation
import os

/// A now-playing metadata snapshot.
public struct MRPNowPlaying {
    public let title: String?
    public let artist: String?
    public let album: String?
    /// Elapsed time in seconds.
    public let position: Double?
    /// Total duration in seconds.
    public let duration: Double?
    public let playbackState: PlaybackState.Enum
    /// Media type string (Music / Podcast / AudioBook / iTunesU / Video / Audio / Unknown).
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
    /// Content identifier -> JPEG artwork (from UpdateContentItemArtworkMessage).
    private var artworkByID: [String: Data] = [:]
    /// Latest artwork (from SetArtworkMessage).
    private var jpegData: Data?

    public init(protocolLayer: MRPProtocol) {
        self.protocolLayer = protocolLayer
        protocolLayer.delegate = self
    }

    /// Disconnect callback (forwarded from the protocol layer, triggered by the connection layer).
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

    // MARK: - Queries

    /// Returns the cached now-playing metadata (defaults to empty values when no push has been received).
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

    /// Returns the cached cover JPEG (prefers matching by content identifier, then SetArtworkMessage data).
    public func artwork() -> Data? {
        withLock {
            if let id = contentItems.first?.identifier, let data = artworkByID[id], !data.isEmpty {
                return data
            }
            if let jpegData, !jpegData.isEmpty {
                return jpegData
            }
            // Fall back to any available artwork.
            return artworkByID.values.first(where: { !$0.isEmpty })
        }
    }

    /// Maps ContentItemMetadata to a media type string (same as pyatv's MediaType).
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

    // MARK: - Utilities

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}

private extension String {
    /// Treats an empty string as nil.
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Double {
    /// Treats a non-positive value as nil.
    var positive: Double? { self > 0 ? self : nil }
}

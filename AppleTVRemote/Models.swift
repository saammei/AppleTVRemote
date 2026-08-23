import Foundation

struct ATVDevice: Identifiable, Codable, Equatable {
    let identifier: String
    let name: String
    let address: String
    let model: String
    let services: [String]

    var id: String { identifier }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

struct NowPlaying: Decodable, Equatable {
    let title: String?
    let artist: String?
    let album: String?
    let mediaType: String?
    let deviceState: String?
    let position: Double?
    let totalTime: Double?
    let artwork: Data?
    let powerState: String?
}

struct RemoteApp: Identifiable, Codable, Equatable {
    let identifier: String
    let name: String
    var id: String { identifier }
}

enum RemoteKey: String {
    case up, down, left, right, select, menu, home
    case playPause = "play_pause"
    case next, previous
    case topMenu = "top_menu"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"

    var symbol: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .select: "return"
        case .menu: "arrow.uturn.backward"
        case .home: "house.fill"
        case .playPause: "playpause.fill"
        case .next: "forward.end.fill"
        case .previous: "backward.end.fill"
        case .topMenu: "menucard"
        case .volumeUp: "speaker.plus.fill"
        case .volumeDown: "speaker.minus.fill"
        }
    }
}

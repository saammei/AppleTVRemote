// Apple TV device model mapping, corresponding to pyatv's DeviceModel / lookup_model.
// Data from pyatv/support/device_info.py (a static mapping obtained by reverse engineering; safe to port).

public enum DeviceModel: String {
    case unknown = "Unknown Device"
    case gen2 = "Apple TV (2nd Generation)"
    case gen3 = "Apple TV (3rd Generation)"
    case gen4 = "Apple TV HD (4th Generation)"
    case gen4K = "Apple TV 4K (1st Generation)"
    case appleTV4KGen2 = "Apple TV 4K (2nd Generation)"
    case appleTV4KGen3 = "Apple TV 4K (3rd Generation)"
    case homePod = "HomePod"
    case homePodMini = "HomePod mini"
    case homePodGen2 = "HomePod (2nd Generation)"

    /// Looks up the model name from the `rpmd` (hardware model code) in the mDNS TXT record.
    public static func lookup(_ identifier: String) -> DeviceModel {
        if let model = modelList[identifier] { return model }
        if let model = internalNameList[identifier] { return model }
        return .unknown
    }

    /// Looks up the tvOS version from the `systembuildversion` in the MRP TXT record (incomplete list).
    public static func lookupVersion(_ build: String) -> String? {
        versionList[build]
    }

    private static let modelList: [String: DeviceModel] = [
        "AppleTV1,1": .gen2,
        "AppleTV2,1": .gen2,
        "AppleTV3,1": .gen3,
        "AppleTV3,2": .gen3,
        "AppleTV5,3": .gen4,
        "AppleTV6,2": .gen4K,
        "AppleTV11,1": .appleTV4KGen2,
        "AppleTV14,1": .appleTV4KGen3,
        "AudioAccessory1,1": .homePod,
        "AudioAccessory1,2": .homePod,
        "AudioAccessory5,1": .homePodMini,
        "AudioAccessorySingle5,1": .homePodMini,
        "AudioAccessory6,1": .homePodGen2,
    ]

    private static let internalNameList: [String: DeviceModel] = [
        "K66AP": .gen2,
        "J33AP": .gen3,
        "J33IAP": .gen3,
        "J42dAP": .gen4,
        "J105aAP": .gen4K,
        "J305AP": .appleTV4KGen2,
        "J255AP": .appleTV4KGen3,
    ]

    private static let versionList: [String: String] = [
        "22J357": "18.0", "22J580": "18.1",
        "22J354": "17.0", "21K69": "17.1", "21K365": "17.2", "21K646": "17.3",
        "21L227": "17.4", "21L569": "17.5", "21L580": "17.5.1", "21M71": "17.6",
        "21M80": "17.6.1",
        "20J373": "16.0", "20K71": "16.1", "20K362": "16.2", "20K650": "16.3",
        "20L497": "16.4", "20L563": "16.5", "20M73": "16.6",
        "19J346": "15.0", "19K53": "15.2", "19K547": "15.3", "19L440": "15.4",
        "19L570": "15.5", "19M65": "15.6",
    ]
}

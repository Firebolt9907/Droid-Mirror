import Foundation

struct AndroidDevice: Identifiable, Hashable {
    let id: String
    let state: String
    let model: String
    let product: String
    let transport: String

    var isOnline: Bool { state == "device" }
    var isWireless: Bool { id.contains(":") }
    var displayName: String {
        model.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? (isWireless ? "Wireless Android" : "Android device")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264, h265
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264 (compatible)" : "HEVC (efficient)" }
}

enum KeyboardMode: String, CaseIterable, Identifiable, Codable {
    case sdk, uhid
    var id: String { rawValue }
    var label: String { self == .sdk ? "Smart text input" : "Physical keyboard (UHID)" }
}

enum ScrollMode: String, CaseIterable, Identifiable, Codable {
    case direct, touchSwipe
    var id: String { rawValue }
    var label: String {
        self == .direct ? "Direct mouse scrolling" : "Touch-style swipes"
    }
}

struct MirrorPreferences: Codable {
    var autoStart = true
    var turnDeviceScreenOff = true
    var powerOffOnClose = false
    var stayAwake = true
    var alwaysOnTop = false
    var forwardAudio = true
    var maxFPS = 60
    var bitRateMbps = 12
    var maxSize = 1920
    var codec: VideoCodec = .h264
    var keyboard: KeyboardMode = .sdk
    var scrollMode: ScrollMode = .touchSwipe
    var showTouches = false

    private enum CodingKeys: String, CodingKey {
        case autoStart, turnDeviceScreenOff, powerOffOnClose, stayAwake
        case alwaysOnTop, forwardAudio, maxFPS, bitRateMbps, maxSize
        case codec, keyboard, scrollMode, showTouches
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoStart = try values.decodeIfPresent(Bool.self, forKey: .autoStart) ?? autoStart
        turnDeviceScreenOff = try values.decodeIfPresent(Bool.self, forKey: .turnDeviceScreenOff) ?? turnDeviceScreenOff
        powerOffOnClose = try values.decodeIfPresent(Bool.self, forKey: .powerOffOnClose) ?? powerOffOnClose
        stayAwake = try values.decodeIfPresent(Bool.self, forKey: .stayAwake) ?? stayAwake
        alwaysOnTop = try values.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? alwaysOnTop
        forwardAudio = try values.decodeIfPresent(Bool.self, forKey: .forwardAudio) ?? forwardAudio
        maxFPS = try values.decodeIfPresent(Int.self, forKey: .maxFPS) ?? maxFPS
        bitRateMbps = try values.decodeIfPresent(Int.self, forKey: .bitRateMbps) ?? bitRateMbps
        maxSize = try values.decodeIfPresent(Int.self, forKey: .maxSize) ?? maxSize
        codec = try values.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? codec
        keyboard = try values.decodeIfPresent(KeyboardMode.self, forKey: .keyboard) ?? keyboard
        scrollMode = try values.decodeIfPresent(ScrollMode.self, forKey: .scrollMode) ?? scrollMode
        showTouches = try values.decodeIfPresent(Bool.self, forKey: .showTouches) ?? showTouches
    }
}

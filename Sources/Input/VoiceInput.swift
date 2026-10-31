import Foundation
import ApplicationServices

enum VoiceInputTarget: String, CaseIterable {
    case wechat, voicekey

    var title: String { self == .wechat ? L("语音：微信") : L("语音：VoiceKey") }
    var name: String { self == .wechat ? L("微信") : "VoiceKey" }
}

struct VoiceShortcut: Equatable {
    let codes: [UInt16]
    let name: String
    static let fn = VoiceShortcut(codes: [63], name: "Fn")

    static func modifier(_ code: UInt16) -> CGEventFlags? {
        switch code {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    var valid: Bool {
        guard !codes.isEmpty, codes.allSatisfy({ $0 < 128 }), Set(codes).count == codes.count else { return false }
        let ordinary = codes.filter { Self.modifier($0) == nil }
        let functionKeys: Set<UInt16> = [64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122]
        if codes.count == 1 { return ordinary.isEmpty || functionKeys.contains(codes[0]) }
        let strong = codes.contains { code in
            guard let flag = Self.modifier(code) else { return false }
            return flag != .maskShift
        }
        return ordinary.count <= 1 && strong
    }

    // Modifiers precede the ordinary key, and release in the opposite order.
    var orderedCodes: [UInt16] {
        codes.filter { Self.modifier($0) != nil } + codes.filter { Self.modifier($0) == nil }
    }

    func events(down: Bool, flags initial: CGEventFlags) -> [CGEvent]? {
        var flags = initial
        let ordered = down ? orderedCodes : Array(orderedCodes.reversed())
        var remaining = ordered
        var events: [CGEvent] = []
        for code in ordered {
            remaining.removeFirst()
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { return nil }
            if let modifier = Self.modifier(code) {
                event.type = .flagsChanged
                if down { flags.insert(modifier) }
                else if !remaining.contains(where: { Self.modifier($0) == modifier }) { flags.remove(modifier) }
            }
            event.flags = flags
            // Same marker as Remote Vibe's FnKey, distinct from VoiceKey's replay marker.
            event.setIntegerValueField(.eventSourceUserData, value: 0x524D5642)
            events.append(event)
        }
        return events
    }
}

// Decode only the public input settings. Never read credentials or write VoiceKey's file.
struct VoiceKeyInputSettings: Decodable {
    struct Combo: Decodable { let codes: [UInt16]; let name: String }
    struct Tap: Decodable { let code: UInt16; let mods: UInt8 }
    let holdKey: String?
    let holdCombo: Combo?
    let tapShortcut: Tap?
    let mic: String?

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceKey/settings.json")
    }

    enum SetupError: LocalizedError, Equatable {
        case unavailable, microphone, shortcut, sharedTap
        var errorDescription: String? {
            switch self {
            case .unavailable: return L("请先打开 VoiceKey 并完成设置")
            case .microphone: return L("请在 VoiceKey 中选择 Chromecast Mic 或系统默认麦克风")
            case .shortcut: return L("无法读取 VoiceKey 长按快捷键，请在 VoiceKey 中重新设置")
            case .sharedTap: return L("请将 VoiceKey 的长按快捷键与点按快捷键分开")
            }
        }
    }

    static func load() throws -> Self {
        guard let data = try? Data(contentsOf: url), data.count <= 65536,
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { throw SetupError.unavailable }
        return settings
    }

    func shortcut() throws -> VoiceShortcut {
        guard mic == nil || mic == "" || mic == "Chromecast Mic" else { throw SetupError.microphone }
        let shortcut: VoiceShortcut
        if holdKey == "custom", let combo = holdCombo {
            shortcut = VoiceShortcut(codes: combo.codes, name: combo.name)
        } else {
            let presets: [String: VoiceShortcut] = [
                "rightAlt": .init(codes: [61], name: L("右 ⌥")),
                "rightMeta": .init(codes: [54], name: L("右 ⌘")),
                "rightCtrl": .init(codes: [62], name: L("右 ⌃")),
                "fn": .fn
            ]
            guard let preset = presets[holdKey ?? "rightAlt"] else { throw SetupError.shortcut }
            shortcut = preset
        }
        guard shortcut.valid else { throw SetupError.shortcut }
        // A short/cancelled remote session must never become a latched tap-to-talk session.
        if shortcut.codes.count == 1, VoiceShortcut.modifier(shortcut.codes[0]) != nil,
           tapShortcut?.code == shortcut.codes[0], tapShortcut?.mods == 0 { throw SetupError.sharedTap }
        return shortcut
    }
}

final class HeldVoiceShortcut {
    private(set) var shortcut: VoiceShortcut?
    var held: Bool { shortcut != nil }
    private var fallbackRelease: [CGEvent] = []
    private let trusted: () -> Bool
    private let flags: () -> CGEventFlags
    private let keyDown: (UInt16) -> Bool
    private let post: (CGEvent) -> Void

    init(trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         flags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
         keyDown: @escaping (UInt16) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.trusted = trusted; self.flags = flags; self.keyDown = keyDown; self.post = post
    }

    func down(_ shortcut: VoiceShortcut) -> Bool {
        guard !held, trusted(), shortcut.valid else { return false }
        let current = flags()
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        var releaseFlags = current
        shortcut.codes.compactMap(VoiceShortcut.modifier).forEach { releaseFlags.insert($0) }
        guard current.intersection(modifiers).isEmpty, !shortcut.codes.contains(where: keyDown),
              let press = shortcut.events(down: true, flags: current),
              let release = shortcut.events(down: false, flags: releaseFlags) else { return false }
        self.shortcut = shortcut
        fallbackRelease = release
        press.forEach(post)
        return true
    }

    func up() {
        guard let shortcut else { return }
        let release = shortcut.events(down: false, flags: flags()) ?? fallbackRelease
        release.forEach(post)
        self.shortcut = nil; fallbackRelease.removeAll()
    }
}

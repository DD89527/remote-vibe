import Foundation
import ApplicationServices

@main
enum AppSupportTest {
    static func main() throws {
        func release(_ version: String, asset: Bool = true, draft: Bool = false, prerelease: Bool = false,
                     architecture: ReleaseUpdate.Architecture = .current, state: String = "uploaded", size: Int = 1024) throws -> ReleaseUpdate {
            let number = version.hasPrefix("v") ? String(version.dropFirst()) : version
            let json: [String: Any] = ["tag_name": version, "draft": draft, "prerelease": prerelease,
                "assets": asset ? [["name": "Remote-Vibe-\(number)-App-\(architecture.rawValue).zip", "state": state, "size": size]] : []]
            return try JSONDecoder().decode(ReleaseUpdate.self, from: JSONSerialization.data(withJSONObject: json))
        }
        // Real release boundaries: numeric ordering, development versions and incomplete uploads.
        let newer = try release("v0.4.10")
        precondition(newer.message(installed: "0.4.9") == L("可下载新版本 %@ · 打开发布页", "v0.4.10"))
        precondition(newer.message(installed: "0.4.10") == L("已是最新版本 %@", "0.4.10"))
        precondition(newer.message(installed: "0.5.0") == L("当前 %@ 比正式版 %@ 更新", "0.5.0", "v0.4.10"))
        let incomplete = try release("v0.4.10", asset: false)
        precondition(incomplete.message(installed: "0.4.9") == L("发现 %@，下载包尚未就绪", "v0.4.10"))
        for architecture in ReleaseUpdate.Architecture.allCases {
            let matching = try release("v0.4.10", architecture: architecture)
            let other: ReleaseUpdate.Architecture = architecture == .intel ? .appleSilicon : .intel
            precondition(matching.message(installed: "0.4.9", architecture: architecture) == L("可下载新版本 %@ · 打开发布页", "v0.4.10"))
            precondition(matching.message(installed: "0.4.9", architecture: other) == L("发现 %@，下载包尚未就绪", "v0.4.10"))
            for pending in [try release("v0.4.10", architecture: architecture, state: "new"),
                            try release("v0.4.10", architecture: architecture, size: 0)] {
                precondition(pending.message(installed: "0.4.9", architecture: architecture) == L("发现 %@，下载包尚未就绪", "v0.4.10"))
            }
        }
        for hidden in [try release("v0.4.10", draft: true), try release("v0.4.10", prerelease: true)] {
            precondition(hidden.message(installed: "0.4.9") == L("发布版本无法识别，请打开发布页"))
        }
        for invalid in ["", "1.2", "1.2.3-beta", "1.2.3.4", "-1.2.3", "1.2.x", "1..3", " 1.2.3", "99999999999999999999.1.2"] {
            precondition(ReleaseUpdate.version(invalid) == nil)
        }
        try voiceInput()
        print("PASS: stable release comparison, architecture readiness and VoiceKey shortcut lifecycle (no network or input injection).")
    }

    private static func voiceInput() throws {
        func settings(_ values: [String: Any]) throws -> VoiceKeyInputSettings {
            try JSONDecoder().decode(VoiceKeyInputSettings.self, from: JSONSerialization.data(withJSONObject: values))
        }
        func rejects(_ values: [String: Any], _ expected: VoiceKeyInputSettings.SetupError) throws {
            do { _ = try settings(values).shortcut(); preconditionFailure("Expected setup error") }
            catch let error as VoiceKeyInputSettings.SetupError { precondition(error == expected) }
        }
        for (key, code) in [("rightAlt", UInt16(61)), ("rightMeta", 54), ("rightCtrl", 62), ("fn", 63)] {
            let config = try settings(["holdKey": key, "mic": "Chromecast Mic"])
            let resolved = try config.shortcut()
            precondition(resolved.codes == [code])
        }
        let current = try settings(["holdKey": "rightMeta", "mic": "Chromecast Mic",
                                    "tapShortcut": ["code": 63, "mods": 0], "silenceStop": false])
        let shortcut = try current.shortcut()
        precondition(shortcut.codes == [54]) // Must follow HOLD, never the Fn tap toggle.
        let systemDefault = try settings(["holdKey": "fn", "mic": ""])
        let defaultShortcut = try systemDefault.shortcut()
        precondition(defaultShortcut == .fn)
        try rejects(["holdKey": "fn", "mic": "MiRemoteV 2ch"], .microphone)
        try rejects(["holdKey": "unknown"], .shortcut)
        try rejects(["holdKey": "fn", "tapShortcut": ["code": 63, "mods": 0]], .sharedTap)
        for codes in [[], [54, 54], [128], [0], [56, 0], [54, 0, 1]] as [[Int]] {
            try rejects(["holdKey": "custom", "holdCombo": ["codes": codes, "name": "invalid"]], .shortcut)
        }
        let combo = try settings(["holdKey": "custom", "holdCombo": ["codes": [49, 59, 58], "name": "Ctrl+Alt+Space"]]).shortcut()
        precondition(combo.orderedCodes == [59, 58, 49])
        let functionKey = try settings(["holdKey": "custom", "holdCombo": ["codes": [79], "name": "F18"]]).shortcut()
        precondition(functionKey.valid)

        var allowed = true, currentFlags = CGEventFlags()
        var events: [CGEvent] = []
        let trigger = HeldVoiceShortcut(trusted: { allowed }, flags: { currentFlags }, keyDown: { _ in false }, post: { event in
            events.append(event); currentFlags = event.flags
        })
        for _ in 0..<20 {
            precondition(trigger.down(shortcut))
            precondition(trigger.held && currentFlags.contains(.maskCommand))
            precondition(!trigger.down(.fn)) // Changed settings cannot replace an active session's release.
            trigger.up(); trigger.up()
            precondition(!trigger.held && currentFlags.intersection([.maskCommand, .maskSecondaryFn]).isEmpty)
        }
        precondition(events.count == 40)
        precondition(events.allSatisfy { $0.type == .flagsChanged && $0.getIntegerValueField(.keyboardEventKeycode) == 54 })
        events.removeAll()
        precondition(trigger.down(combo)); trigger.up()
        precondition(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [59, 58, 49, 49, 58, 59])
        precondition(events[2].type == .keyDown && events[3].type == .keyUp)
        precondition(events[3].flags.contains([.maskControl, .maskAlternate]))
        precondition(currentFlags.intersection([.maskControl, .maskAlternate]).isEmpty)
        let count = events.count
        allowed = false
        precondition(!trigger.down(.fn))
        allowed = true; currentFlags = .maskCommand
        precondition(!trigger.down(.fn))
        precondition(events.count == count && !trigger.held)
        let physical = HeldVoiceShortcut(trusted: { true }, flags: { [] }, keyDown: { _ in true }, post: { _ in preconditionFailure() })
        precondition(!physical.down(.fn))
    }
}

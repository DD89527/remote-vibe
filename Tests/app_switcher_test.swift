import AppKit

enum AppSwitcherTests {
    private final class Environment {
        var allowed = true
        var flags: CGEventFlags = []
        var physical: CGEventFlags = []
        var keys = Set<CGKeyCode>()
        var now: TimeInterval = 0
        var events: [CGEvent] = []
        var ended = 0
        lazy var switcher: AppSwitcher = {
            let value = AppSwitcher(trusted: { [unowned self] in self.allowed },
                flags: { [unowned self] in self.flags },
                hardwareFlags: { [unowned self] in self.physical },
                keyDown: { [unowned self] in self.keys.contains($0) },
                post: { [unowned self] event in self.events.append(event); self.flags = event.flags },
                clock: { [unowned self] in self.now }, automaticLifecycle: false)
            value.onEnd = { [unowned self] in self.ended += 1 }
            return value
        }()
        func keyCodes(_ type: CGEventType) -> [Int64] {
            events.filter { $0.type == type }.map { $0.getIntegerValueField(.keyboardEventKeycode) }
        }
    }

    static func run() throws {
        try compatibility()
        routing()
        for reverse in [false, true] {
            let env = Environment()
            precondition(env.switcher.open(reverse: reverse))
            precondition(env.switcher.active && env.switcher.opens == 1 && env.switcher.closes == 0)
            precondition(env.flags == .maskCommand)
            precondition(env.events.count == (reverse ? 5 : 3))
            precondition(env.keyCodes(.keyDown) == [48] && env.keyCodes(.keyUp) == [48])
            let tab = env.events.first { $0.type == .keyDown }!
            precondition(tab.flags.contains(.maskShift) == reverse)
            precondition(!env.switcher.open(reverse: reverse)) // Never double-hold ⌘.
            env.switcher.externalInput(marker: AppSwitcher.eventMarker)
            precondition(env.switcher.active) // Own events cannot immediately dismiss it.
            env.switcher.perform(.next)
            env.switcher.perform(.previous)
            precondition(env.keyCodes(.keyDown) == [48, 124, 123])
            precondition(env.flags == .maskCommand)
            env.switcher.perform(.confirm)
            precondition(!env.switcher.active && env.switcher.opens == env.switcher.closes)
            precondition(env.flags.isEmpty && env.ended == 1)
            precondition(!env.keyCodes(.keyDown).contains(36)) // Confirmation is only ⌘ release, never Enter.
            precondition(!env.keyCodes(.keyDown).contains(53)) // Confirmation never cancels.
            let count = env.events.count
            env.switcher.cancel(); env.switcher.perform(.next); env.switcher.externalInput(marker: 0)
            precondition(env.events.count == count && env.ended == 1)
            precondition(env.events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == AppSwitcher.eventMarker })
        }

        let cancelled = Environment()
        precondition(cancelled.switcher.open(reverse: false))
        cancelled.switcher.perform(.cancel)
        precondition(cancelled.keyCodes(.keyDown) == [48, 53])
        precondition(cancelled.keyCodes(.keyUp) == [48, 53])
        precondition(cancelled.events.last?.type == .flagsChanged && cancelled.flags.isEmpty)

        let preserve = Environment()
        precondition(preserve.switcher.open(reverse: false))
        preserve.flags.formUnion(.maskControl)
        preserve.physical = [.maskControl, .maskShift]
        preserve.switcher.cancel()
        precondition(preserve.flags == [.maskControl, .maskShift])

        let timer = Environment()
        precondition(timer.switcher.open(reverse: false))
        timer.now = 19.9; timer.switcher.expire(at: timer.now)
        precondition(timer.switcher.active)
        timer.switcher.perform(.next) // Navigation extends the inactivity deadline.
        timer.now = 20; timer.switcher.expire(at: timer.now)
        precondition(timer.switcher.active)
        timer.now = 39.91; timer.switcher.expire(at: timer.now)
        precondition(!timer.switcher.active && timer.flags.isEmpty)

        let external = Environment()
        precondition(external.switcher.open(reverse: false))
        external.flags.formUnion(.maskShift)
        external.physical = [.maskCommand, .maskShift]
        external.switcher.externalInput(marker: 0)
        precondition(!external.switcher.active && external.keyCodes(.keyDown) == [48])
        precondition(external.flags == [.maskCommand, .maskShift]) // Preserve real hardware state.

        let revoked = Environment()
        precondition(revoked.switcher.open(reverse: false))
        revoked.allowed = false
        revoked.switcher.perform(.next)
        precondition(!revoked.switcher.active && revoked.flags.isEmpty)

        for flag: CGEventFlags in [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn] {
            let blocked = Environment(); blocked.flags = flag
            precondition(!blocked.switcher.open(reverse: false) && blocked.events.isEmpty)
        }
        for key: CGKeyCode in [54, 55] {
            let blocked = Environment(); blocked.keys = [key]
            precondition(!blocked.switcher.open(reverse: false) && blocked.events.isEmpty)
        }
        let untrusted = Environment(); untrusted.allowed = false
        precondition(!untrusted.switcher.open(reverse: false) && untrusted.events.isEmpty)
        let repeated = Environment()
        for index in 0..<30 {
            precondition(repeated.switcher.open(reverse: index % 2 == 0))
            repeated.switcher.perform(index % 2 == 0 ? .confirm : .cancel)
            precondition(!repeated.switcher.active && repeated.flags.isEmpty)
        }
        precondition(repeated.switcher.opens == 30 && repeated.switcher.closes == 30)
        print("PASS: interactive app switcher, balanced modifiers, navigation, confirmation, cancellation, timeout, external input, permissions and 30 repeated sessions (events never posted).")
    }

    private static func compatibility() throws {
        let old = Data(#"{"10":{"kind":"key","usage":43,"modifiers":1048576},"14":{"kind":"openApp","usage":40,"modifiers":0,"appPath":"/Applications/ChatGPT.app"}}"#.utf8)
        let bindings = try JSONDecoder().decode(KeyMapping.Bindings.self, from: old)
        precondition(bindings["10"]!.singleClick.appSwitcherReverse == false)
        let roundtrip = try JSONDecoder().decode(KeyMapping.Bindings.self, from: JSONEncoder().encode(bindings))
        precondition(bindings == roundtrip && bindings["14"]!.singleClick.kind == .openApp)
        let reverse = ButtonAction(kind: .key, usage: 0x2B, modifiers: CGEventFlags([.maskCommand, .maskShift]).rawValue)
        precondition(reverse.appSwitcherReverse == true && reverse.usesListener)
        for flags: CGEventFlags in [[], .maskControl, [.maskCommand, .maskAlternate], [.maskCommand, .maskControl]] {
            precondition(ButtonAction(kind: .key, usage: 0x2B, modifiers: flags.rawValue).appSwitcherReverse == nil)
        }
        precondition(ButtonAction(kind: .key, usage: 0x2C, modifiers: CGEventFlags.maskCommand.rawValue).appSwitcherReverse == nil)
    }

    private static func routing() {
        var state = AppSwitcherRouting()
        state.request(button: 10, reverse: false)
        precondition(state.beginIfReleased([10]) == nil && !state.capturing)
        precondition(state.beginIfReleased([3, 10]) == nil && !state.capturing)
        precondition(state.beginIfReleased([]) == .init(button: 10, reverse: false))
        precondition(state.capturing && state.pending == nil)
        precondition(!state.restoreIfReleased([], active: false)) // Keep suppression during opening refresh.
        state.didOpen()
        precondition(!state.restoreIfReleased([], active: true))
        precondition(state.command(for: 5, launcherReverse: nil) == .previous)
        precondition(state.command(for: 3, launcherReverse: nil) == .previous)
        precondition(state.command(for: 6, launcherReverse: nil) == .next)
        precondition(state.command(for: 4, launcherReverse: nil) == .next)
        precondition(state.command(for: 7, launcherReverse: nil) == .confirm)
        precondition(state.command(for: 11, launcherReverse: nil) == .cancel)
        precondition(state.command(for: 10, launcherReverse: nil) == .next)
        precondition(state.command(for: 14, launcherReverse: true) == .previous)
        precondition(state.command(for: 1, launcherReverse: nil) == .cancel)
        precondition(!state.restoreIfReleased([7], active: false)) // OK is still physically down.
        precondition(state.capturing && state.restoreIfReleased([], active: false) && !state.capturing)
        precondition(!state.restoreIfReleased([], active: false))
        state.request(button: 10, reverse: true); state.cancelRequest()
        precondition(state.beginIfReleased([]) == nil)
        state.request(button: 10, reverse: true)
        precondition(state.beginIfReleased([])?.reverse == true)
        state.cancelRequest() // Failed ownership or permission check before opening.
        precondition(state.restoreIfReleased([], active: false))
        state.request(button: 10, reverse: false); state.reset()
        precondition(state.pending == nil && !state.capturing)
    }
}

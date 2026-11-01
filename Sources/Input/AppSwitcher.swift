import AppKit

// Remap only between physical presses. Keep the temporary suppression until the
// last release, so confirming never leaks an Enter/key-up into the chosen app.
struct AppSwitcherRouting {
    struct Request: Equatable {
        let button: UInt8
        let reverse: Bool
    }
    enum Command: Equatable { case previous, next, confirm, cancel }
    private(set) var pending: Request?
    private(set) var capturing = false
    private(set) var opener: Request?
    private var opening = false

    mutating func request(button: UInt8, reverse: Bool) { pending = .init(button: button, reverse: reverse) }
    mutating func cancelRequest() { pending = nil; opening = false }
    mutating func beginIfReleased(_ held: Set<UInt8>) -> Request? {
        guard held.isEmpty, let pending else { return nil }
        self.pending = nil; capturing = true; opening = true; opener = pending
        return pending
    }
    mutating func didOpen() { opening = false }
    @discardableResult mutating func restoreIfReleased(_ held: Set<UInt8>, active: Bool) -> Bool {
        guard capturing, !opening, !active, held.isEmpty else { return false }
        capturing = false; opener = nil
        return true
    }
    mutating func reset() { pending = nil; capturing = false; opening = false; opener = nil }

    func command(for button: UInt8, launcherReverse: Bool?) -> Command {
        switch button {
        case 3, 5: return .previous
        case 4, 6: return .next
        case 7: return .confirm
        case 11: return .cancel
        default:
            if let reverse = button == opener?.button ? opener?.reverse : launcherReverse {
                return reverse ? .previous : .next
            }
            // Other remote buttons dismiss the switcher, never become ⌘ chords.
            return .cancel
        }
    }
}

// Own just the left Command, with one private event source per session. No
// polling or event monitors remain installed while idle. Tests inject posting,
// time and permissions, and never deliver input to the macOS session.
final class AppSwitcher {
    static let eventMarker: Int64 = 0x524D5653
    static let idleTimeout: TimeInterval = 20
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
    private(set) var active = false
    private(set) var opens = 0
    private(set) var closes = 0
    var onEnd: (() -> Void)?
    private let trusted: () -> Bool
    private let flags: () -> CGEventFlags
    private let hardwareFlags: () -> CGEventFlags
    private let keyDown: (CGKeyCode) -> Bool
    private let post: (CGEvent) -> Void
    private let clock: () -> TimeInterval
    private let automaticLifecycle: Bool
    private var source: CGEventSource?
    private var release: CGEvent?
    private var escape: [CGEvent] = []
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastInput: TimeInterval = 0

    init(trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         flags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
         hardwareFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) },
         keyDown: @escaping (CGKeyCode) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticLifecycle: Bool = true) {
        self.trusted = trusted; self.flags = flags; self.hardwareFlags = hardwareFlags
        self.keyDown = keyDown; self.post = post; self.clock = clock
        self.automaticLifecycle = automaticLifecycle
    }

    deinit { cancel() }

    func open(reverse: Bool) -> Bool {
        guard !active, trusted(), flags().intersection(Self.modifiers).isEmpty,
              !keyDown(55), !keyDown(54), let source = CGEventSource(stateID: .privateState) else { return false }
        let base = flags().subtracting(Self.modifiers), held = base.union(.maskCommand)
        guard let down = modifier(55, down: true, flags: held, source: source),
              let release = modifier(55, down: false, flags: base, source: source),
              let escape = pair(53, flags: held, source: source),
              let tab = pair(48, flags: reverse ? held.union(.maskShift) : held, source: source) else { return false }
        var opening = [down]
        if reverse {
            guard let shiftDown = modifier(56, down: true, flags: held.union(.maskShift), source: source),
                  let shiftUp = modifier(56, down: false, flags: held, source: source) else { return false }
            opening += [shiftDown] + tab + [shiftUp]
        } else { opening += tab }
        self.source = source; self.release = release; self.escape = escape
        active = true; opens += 1
        if automaticLifecycle { installMonitors() }
        opening.forEach(post)
        touch()
        return true
    }

    func perform(_ command: AppSwitcherRouting.Command) {
        guard active else { return }
        switch command {
        case .confirm: finish(cancel: false)
        case .cancel: finish(cancel: true)
        case .previous, .next:
            guard trusted(), let source,
                  let events = pair(command == .previous ? 123 : 124, flags: flags().union(.maskCommand), source: source) else {
                finish(cancel: true); return
            }
            events.forEach(post)
            touch()
        }
    }

    func cancel() { finish(cancel: true) }

    func expire(at time: TimeInterval) {
        guard active, time - lastInput >= Self.idleTimeout else { return }
        finish(cancel: true)
    }

    // Keyboard/mouse input may already have dismissed the system overlay. Only
    // release our modifier here; another Escape could reach an unrelated app.
    func externalInput(marker: Int64) {
        guard active, marker != Self.eventMarker else { return }
        finish(cancel: false)
    }

    private func finish(cancel: Bool) {
        guard active, let release else { return }
        active = false
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        // Preserve physical keyboard modifiers; the private source owns only ⌘.
        release.flags = flags().subtracting(.maskCommand).union(hardwareFlags().intersection(Self.modifiers))
        if cancel { escape.forEach(post) }
        post(release)
        self.release = nil; source = nil; escape.removeAll()
        closes += 1
        onEnd?()
    }

    private func touch() {
        lastInput = clock()
        guard automaticLifecycle else { return }
        scheduleExpiry(after: Self.idleTimeout)
    }

    private func scheduleExpiry(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(0.01, interval), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.expire(at: self.clock())
            if self.active { self.scheduleExpiry(after: Self.idleTimeout - (self.clock() - self.lastInput)) }
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.externalInput(marker: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.externalInput(marker: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
            return event
        }) { monitors.append(local) }
    }

    private func modifier(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
        event.type = .flagsChanged; event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        return event
    }

    private func pair(_ code: CGKeyCode, flags: CGEventFlags, source: CGEventSource) -> [CGEvent]? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        }
        return [down, up]
    }
}

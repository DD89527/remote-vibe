import Foundation

enum VoiceActivation: String, CaseIterable {
    case toggle, hold
    var title: String { self == .toggle ? L("点按开关") : L("按住说话") }
}

// The only injected dependencies are scheduling and monotonic time, for offline tests.
final class RemoteAudioSession {
    typealias Cancel = () -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Cancel
    enum Source { case physical, mappedButton, toggleContinuation }
    private enum Phase {
        case idle, opening(Source), recording(Source, UInt8)
        case closing(Source, UInt8, normal: Bool), failed(Source, UInt8)
    }
    let profile: RemoteProfile
    private(set) var proto: ATVVProtocol
    var ready = false
    var activation = VoiceActivation.hold
    var send: (Data) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onSamples: ([Int16], Int) -> Void = { _, _ in }
    var onEnd: (Bool) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    private var phase = Phase.idle
    private var mappedRetryAfter: TimeInterval = 0
    private var phaseTimer: Cancel?
    private var keepAlive: Cancel?
    private var limit: Cancel?
    private var logicalActive = false
    private var toggleLatched = false
    private var physicalHeld = false
    private var streamReceivedAudio = false
    private let schedule: Schedule
    private let now: () -> TimeInterval
    private(set) var frameCount = 0
    var source: Source? {
        switch phase {
        case .idle: return nil
        case .opening(let source), .recording(let source, _), .closing(let source, _, _), .failed(let source, _): return source
        }
    }
    var opening: Bool { if case .opening = phase { return true }; return false }
    var streaming: Bool {
        switch phase { case .recording, .closing(_, _, true): return true; default: return false }
    }
    var busy: Bool { source != nil }
    var mappedToggleActive: Bool { toggleLatched && source == .mappedButton }
    var toggled: Bool { toggleLatched }
    private var supportsToggle: Bool { profile == .chromecast && proto.capabilities?.version == .v10 }
    private var streamID: UInt8 {
        switch phase { case .recording(_, let id), .closing(_, let id, _), .failed(_, let id): return id; default: return 0 }
    }

    init(profile: RemoteProfile, schedule: @escaping Schedule = { delay, action in
        let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.profile = profile; self.schedule = schedule; self.now = now
        proto = ATVVProtocol(profile: profile)
    }

    func reset() {
        ready = false
        if busy { closeStream(streamID) }
        finish(normal: false)
        mappedRetryAfter = 0
        proto = ATVVProtocol(profile: profile)
    }

    @discardableResult
    func beginMappedVoice() -> Bool {
        if mappedToggleActive { stopToggle(); return true }
        // Only v1.0 can distinguish late host replies from a physical voice press.
        guard profile == .chromecast, ready, now() >= mappedRetryAfter else { return false }
        guard proto.capabilities?.version == .v10 else {
            onStatus(L("此 Google 遥控器使用旧语音协议，请使用原语音键"))
            return false
        }
        return requestOpen(source: .mappedButton)
    }

    private func requestOpen(source: Source) -> Bool {
        guard ready, !busy, let command = try? proto.micOpenCommand() else { return false }
        phase = .opening(source)
        if activation == .toggle && supportsToggle { toggleLatched = true }
        proto.prepareForAudioStream()
        after(1.5) { [weak self] in
            self?.cancel()
            self?.onStatus(L("遥控器没有响应开麦，请松开后重试或使用原语音键"))
        }
        send(command)
        return true
    }

    func endMappedVoice(normal: Bool) {
        guard source == .mappedButton else { return }
        if normal && toggleLatched { return }
        if !normal || opening { cancel() } else { beginClosing(normal: true) }
    }

    func cancel() {
        if opening {
            // Throttle only the next mapped request. Physical presses remain available.
            mappedRetryAfter = now() + 1.5
            finish(normal: false)
            closeStream(0)
        } else { beginClosing(normal: false) }
    }

    func receiveAudio(_ data: Data) {
        guard streaming, let decoded = proto.decodeAudio(data), let codec = proto.codec else { return }
        if !streamReceivedAudio, case .recording = phase { phaseTimer?(); phaseTimer = nil; streamReceivedAudio = true }
        frameCount += 1
        onSamples(decoded.samples, codec.sampleRate)
    }

    func receive(_ event: ATVVControlEvent) {
        switch event {
        case .startSearch:
            if activation == .toggle && supportsToggle {
                if toggleLatched && !physicalHeld { physicalHeld = true; stopToggle(); return }
                guard !physicalHeld else { return }
                physicalHeld = true
            }
            _ = requestOpen(source: .physical)
        case .audioStart(let reason, let codec, let sid):
            guard ready else { return }
            let hostReply = profile == .chromecast && proto.capabilities?.version == .v10 && reason == 0
            if activation == .toggle && supportsToggle && !hostReply {
                if toggleLatched && !physicalHeld {
                    physicalHeld = true
                    let oldID = streamID
                    stopToggle()
                    if sid != oldID { closeStream(sid) }
                    return
                }
                physicalHeld = true
            }
            if hostReply && !opening {
                if busy {
                    if sid != streamID { mappedRetryAfter = now() + 1.5; closeStream(sid) }
                    return
                }
                phase = .closing(.mappedButton, sid, normal: false)
                awaitStop(retry: true); closeStream(sid)
                return
            }
            guard !busy || opening else { return }
            guard profile != .xiaomiRC003 || codec == .adpcm16k else {
                phase = .closing(.physical, sid, normal: false)
                awaitStop(retry: true); closeStream(sid)
                onStatus(L("小米切换到不支持的音频编码"))
                return
            }
            let owner = source ?? .physical
            if activation == .toggle && supportsToggle { toggleLatched = true }
            phaseTimer?(); phaseTimer = nil
            phase = .recording(owner, sid)
            streamReceivedAudio = false
            proto.beginAudioStream(codec: codec)
            if !logicalActive {
                frameCount = 0; logicalActive = true
                onBegin()
            }
            guard case .recording = phase else { return }
            if owner == .mappedButton || owner == .toggleContinuation {
                after(1.5) { [weak self] in
                    self?.cancel()
                    self?.onStatus(L("遥控器没有传回音频，请松开后重试或使用原语音键"))
                }
            }
            scheduleKeepAlive()
            if !toggleLatched { limit = schedule(55) { [weak self] in self?.beginClosing(normal: true) } }
        case .audioSync(let codec, let sequence, let predictor, let stepIndex):
            proto.applyAudioSync(codec: codec, sequence: sequence, predictor: predictor, stepIndex: stepIndex)
        case .audioStop(let reason):
            if toggleLatched { physicalHeld = false }
            if toggleLatched, case .recording(.physical, _) = phase {
                // A native HTT release stops the physical stream. Open a host-owned
                // stream, but keep ONE logical recognizer session and its key held.
                stopTimers(); proto.endAudioStream(); phase = .idle
                if !requestOpen(source: .toggleContinuation) { finish(normal: false) }
                return
            }
            if toggleLatched && opening { return }
            if opening { if source == .physical { cancel() }; return }
            // Only ignore old host-close ACKs during their reply window; an ordinary
            // physical session without a cancelled host request keeps its old behavior.
            if case .recording(.physical, let id) = phase, id != 0,
               proto.capabilities?.version == .v10, reason == 0, now() < mappedRetryAfter { return }
            switch phase {
            case .closing(_, _, let normal): finish(normal: normal)
            case .recording: finish(normal: true)
            default: break
            }
        case .micOpenError:
            guard opening else { return }
            cancel(); onStatus(L("遥控器暂时未能开启麦克风，请松开后重试"))
        case .capabilities, .unknown: break
        }
    }

    private func beginClosing(normal: Bool) {
        guard let owner = source else { return }
        if case .failed = phase { closeStream(streamID); return }
        if case .closing(_, _, let previous) = phase, previous == normal || !previous {
            closeStream(streamID); return
        }
        let id = streamID
        toggleLatched = false
        stopTimers()
        phase = .closing(owner, id, normal: normal)
        awaitStop(retry: true)
        if !normal && logicalActive { logicalActive = false; proto.endAudioStream(); onEnd(false) }
        closeStream(id)
    }

    private func stopToggle() {
        toggleLatched = false
        if opening {
            mappedRetryAfter = now() + 1.5
            finish(normal: true)
            closeStream(0)
        } else { beginClosing(normal: true) }
    }

    private func awaitStop(retry: Bool) {
        after(0.4) { [weak self] in
            guard let self, case .closing(let owner, let id, _) = self.phase else { return }
            if retry {
                self.awaitStop(retry: false); self.closeStream(id)
            } else {
                self.phase = .failed(owner, id) // retain exact id until Bluetooth disconnects
                self.ready = false
                self.proto.endAudioStream()
                if self.logicalActive { self.logicalActive = false; self.onEnd(false) }
                self.onStatus(L("关麦未确认，正在断开遥控器语音连接"))
                self.onDisconnect()
            }
        }
    }

    private func closeStream(_ id: UInt8) {
        if let command = try? proto.micCloseCommand(streamID: id) { send(command) }
    }
    private func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        phaseTimer?()
        phaseTimer = schedule(delay) { [weak self] in self?.phaseTimer = nil; action() }
    }
    private func scheduleKeepAlive() {
        guard profile == .chromecast, case .recording = phase else { return }
        keepAlive = schedule(4) { [weak self] in
            guard let self, case .recording = self.phase else { return }
            if let command = try? self.proto.keepAliveCommand(streamID: self.streamID) { self.send(command) }
            self.scheduleKeepAlive()
        }
    }
    private func stopTimers() {
        phaseTimer?(); phaseTimer = nil
        keepAlive?(); keepAlive = nil
        limit?(); limit = nil
    }
    private func finish(normal: Bool) {
        let began = logicalActive
        logicalActive = false; toggleLatched = false; physicalHeld = false
        stopTimers(); phase = .idle; proto.endAudioStream()
        if began { onEnd(normal) }
    }
}

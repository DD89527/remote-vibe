import AppKit
import ApplicationServices
import CoreBluetooth
import CoreAudio

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let remote = RemoteController()
    private let xiaomiVoiceKey = XiaomiVoiceKeyOverride()
    private let mic = VirtualMicrophone()
    private let voiceTrigger = HeldVoiceShortcut()
    private var voiceTarget = VoiceInputTarget(rawValue: UserDefaults.standard.string(forKey: "voiceInputTarget.v1") ?? "") ?? .wechat
    private var sessionTarget = VoiceInputTarget.wechat
    private var sessionShortcut = VoiceShortcut.fn
    private var voicePicker: NSPopUpButton!
    private var activationPicker: NSPopUpButton!
    private var voiceActivation = VoiceActivation(rawValue: UserDefaults.standard.string(forKey: "voiceActivation.v1") ?? "") ?? .toggle
    private var effectiveActivation: VoiceActivation { remote.profile == .chromecast ? voiceActivation : .hold }
    private let mapping = KeyMapping()
    private lazy var unlock = ComboUnlock(mapping: mapping)
    private var mappingView: KeyMappingView!
    private var unlockView: ComboUnlockView!
    private var pages: NSSegmentedControl!
    private var remotePicker: NSPopUpButton!
    private var discoveryButton: NSButton!
    private var item: NSStatusItem!
    private var window: NSWindow!
    private let connection = NSTextField(wrappingLabelWithString: L("正在连接遥控器…"))
    private let audioLabel = NSTextField(wrappingLabelWithString: L("正在检查麦克风…"))
    private let permission = NSTextField(wrappingLabelWithString: "")
    private let readiness = NSTextField(labelWithString: L("正在检查使用条件…"))
    private let permissionsButton = SettingsTheme.button(L("权限设置"))
    private let message = NSTextField(wrappingLabelWithString: L("准备就绪后，在当前输入框里按住语音键说话。"))
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("开发版")
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    private let updateStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var updateCheck: URLSessionDataTask?
    private var sessionID = UUID()
    private var active = false
    private var released = false
    private var drainStarted = false
    private let voiceSchedule = VoiceSessionSchedule()
    private var voiceTiming = VoiceSessionTiming()
    private var drainTimedOut = false
    private var poll: Timer?
    private var completedSessions = 0
    private var fnDowns = 0
    private var fnUps = 0
    private var triggerDowns = 0
    private var triggerUps = 0
    private var allowPrompted = false
    private var signalSources: [DispatchSourceSignal] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var stopping = false
    private var lastStatus: Data?
    private let statusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RemoteVibe/status.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        buildUI()
        updateRemoteUI()
        if effectiveActivation == .toggle { message.stringValue = L("录音已结束 · 按一下语音键开始") }
        mic.onUnavailable = { [weak self] in
            guard let self, !self.stopping else { return }
            self.remote.cancelVoice(); self.abort()
            self.message.stringValue = L("音频设备已变化，本次语音已取消；请重新按住语音键")
            self.writeStatus()
        }
        mic.onAvailabilityChange = { [weak self] in self?.refreshReadiness(); self?.writeStatus() }
        mapping.onDeviceChange = { [weak self] in self?.refresh() }
        mapping.onMouseModeChange = { [weak self] in
            guard let self else { return }
            self.mappingView.refreshStatus()
            self.updateStatusItem()
            self.writeStatus()
        }
        mapping.onFnChange = { [weak self] in self?.refreshReadiness(); self?.writeStatus() }
        mapping.canPerform = { [weak self] in
            guard let self else { return false }
            return !self.active && !self.remote.voiceBusy && !self.unlock.blocksActions
        }
        mapping.onVoicePress = { [weak self] in
            guard let self, AXIsProcessTrusted(), !self.mapping.fnHeld, self.mic.connect() else { return false }
            return self.remote.beginMappedVoice()
        }
        mapping.onVoiceRelease = { [weak self] normal in self?.remote.endMappedVoice(normal: normal) }
        mapping.canStopVoice = { [weak self] in self?.remote.mappedToggleActive == true }
        unlock.voiceActive = { [weak self] in self?.active == true }
        unlock.onLock = { [weak self] in
            guard let self else { return }
            self.unlockView.leave()
            self.mapping.suspendActions()
            if self.active || self.remote.voiceBusy { self.remote.cancelVoice(); self.abort() }
        }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        remote.onStatus = { [weak self] text in
            guard let self else { return }
            self.connection.stringValue = text
            self.connection.toolTip = text
            self.updateDiscoveryButton()
            self.mapping.refresh()
            self.xiaomiVoiceKey.refresh(enabled: self.remote.xiaomiReady)
            self.refreshReadiness()
            self.writeStatus()
        }
        remote.canBegin = { [weak self] profile in
            guard let self, !self.active, !self.mapping.fnHeld, !self.unlock.blocksActions else { return false }
            if profile == .xiaomiRC003 {
                self.xiaomiVoiceKey.refresh(enabled: self.remote.xiaomiReady)
                guard self.xiaomiVoiceKey.ready else { self.message.stringValue = self.xiaomiVoiceKey.status; return false }
            }
            return true
        }
        remote.onBegin = { [weak self] in self?.begin() }
        remote.onSamples = { [weak self] values, rate in
            guard let self else { return }
            if self.active && !values.isEmpty { self.voiceTiming.mark("firstSamples", at: ProcessInfo.processInfo.systemUptime) }
            self.mic.feed(values, rate: rate)
        }
        remote.onEnd = { [weak self] normal in self?.end(normal) }
        remote.start()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.mapping.suspendActions()
                if name == NSWorkspace.willSleepNotification || name == NSWorkspace.sessionDidResignActiveNotification {
                    if let self, self.active || self.remote.voiceBusy { self.remote.cancelVoice(); self.abort() }
                }
                self?.refresh()
            })
        }
        refresh()
        show()
    }

    private func begin() {
        guard !unlock.blocksActions else { remote.cancelVoice(); message.stringValue = L("锁屏或连招录入期间暂停语音"); return }
        if active { remote.cancelVoice(); abort(); message.stringValue = L("请等上一段结束后再说话"); return }
        guard AXIsProcessTrusted() else { remote.cancelVoice(); message.stringValue = L("请先允许模拟 Fn 按键"); return }
        guard effectiveActivation != .toggle || remote.supportsToggle else {
            remote.cancelVoice(); message.stringValue = L("点按开关需要 Google ATVV 1.0，请切换按住说话"); return
        }
        do { sessionShortcut = try configuredVoiceShortcut() }
        catch { remote.cancelVoice(); message.stringValue = error.localizedDescription; writeStatus(); return }
        sessionTarget = voiceTarget
        voiceTiming.begin(at: ProcessInfo.processInfo.systemUptime)
        drainTimedOut = false
        guard mic.begin() else {
            voiceTiming.finish(at: ProcessInfo.processInfo.systemUptime, cancelled: true)
            remote.cancelVoice(); message.stringValue = L("语音组件暂不可用，请检查安装或稍后重试")
            refreshReadiness(); writeStatus(); return
        }
        voiceTiming.mark("microphoneStarted", at: ProcessInfo.processInfo.systemUptime)
        voiceSchedule.cancel()
        sessionID = UUID()
        let id = sessionID
        active = true; released = false; drainStarted = false
        scheduleMaintenance()
        remotePicker.isEnabled = false
        voicePicker.isEnabled = false
        activationPicker.isEnabled = false
        updateDiscoveryButton()
        mapping.cancelPendingActions()
        updateStatusItem()
        message.stringValue = L("正在准备%@语音输入…", sessionTarget.name)
        // Change the input before the selected recognizer opens its capture session.
        voiceSchedule.after(0.2) { [weak self] in
            guard let self, self.sessionID == id, self.active, !self.released else { return }
            guard self.voiceTrigger.down(self.sessionShortcut) else { self.remote.cancelVoice(); self.abort(); self.message.stringValue = L("快捷键已被按住或没有权限，请重试"); return }
            self.triggerDowns += 1
            if self.sessionShortcut.codes.contains(63) { self.fnDowns += 1 }
            self.voiceTiming.mark("fnDown", at: ProcessInfo.processInfo.systemUptime)
            self.message.stringValue = self.effectiveActivation == .toggle ? L("正在录音 · 再按一次语音键结束") : L("正在说话 · 松开当前按键结束")
            // Also covers VoiceKey's 300 ms long-press threshold without losing the first syllables.
            self.voiceSchedule.after(0.55) { [weak self] in
                guard let self, self.sessionID == id, self.active else { return }
                self.drainStarted = true
                self.mic.startDraining()
                self.voiceTiming.mark("drainStarted", at: ProcessInfo.processInfo.systemUptime)
            }
        }
        refreshReadiness(); writeStatus()
    }

    private func end(_ normal: Bool) {
        guard active else { return }
        guard normal else { abort(); return }
        guard !released else { return }
        guard voiceTrigger.held else { abort(); return }
        released = true
        voiceTiming.mark("audioStopped", at: ProcessInfo.processInfo.systemUptime)
        message.stringValue = L("正在结束，文字由%@生成…", sessionTarget.name)
        let id = sessionID
        voiceSchedule.waitForDrain(ready: { [weak self] in
            guard let self else { return true }
            return self.drainStarted && self.mic.pendingFrames == 0
        }, completion: { [weak self] timedOut in
            guard let self, self.sessionID == id, self.active else { return }
            self.drainTimedOut = timedOut
            self.voiceTiming.mark("drainFinished", at: ProcessInfo.processInfo.systemUptime)
            self.voiceSchedule.after(0.2) { [weak self] in
                guard let self, self.sessionID == id else { return }
                self.releaseVoiceTrigger()
                self.voiceTiming.mark("fnUp", at: ProcessInfo.processInfo.systemUptime)
                self.voiceSchedule.after(0.8) { [weak self] in
                    guard let self, self.sessionID == id else { return }
                    self.mic.end()
                    self.active = false
                    self.voiceTiming.finish(at: ProcessInfo.processInfo.systemUptime, cancelled: false)
                    self.voiceSchedule.cancel()
                    self.scheduleMaintenance()
                    self.remotePicker.isEnabled = true
                    self.voicePicker.isEnabled = true
                    self.activationPicker.isEnabled = self.remote.profile == .chromecast
                    self.updateDiscoveryButton()
                    self.completedSessions += 1
                    self.refreshReadiness()
                    self.updateStatusItem()
                    self.message.stringValue = self.effectiveActivation == .toggle ? L("录音已结束 · 按一下语音键开始") : L("本次语音已结束；可以继续按住语音键说话。")
                    self.writeStatus()
                }
            }
        })
        writeStatus()
    }

    private func abort() {
        sessionID = UUID()
        voiceSchedule.cancel()
        releaseVoiceTrigger()
        mic.end()
        voiceTiming.finish(at: ProcessInfo.processInfo.systemUptime, cancelled: true)
        active = false; released = false
        scheduleMaintenance()
        remotePicker.isEnabled = true
        voicePicker.isEnabled = true
        activationPicker.isEnabled = remote.profile == .chromecast
        updateDiscoveryButton()
        updateStatusItem()
        refreshReadiness(); writeStatus()
    }

    private func configuredVoiceShortcut() throws -> VoiceShortcut {
        guard voiceTarget == .voicekey else { return .fn }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "do.j3.voicekey").isEmpty else {
            throw VoiceKeyInputSettings.SetupError.unavailable
        }
        return try VoiceKeyInputSettings.load().shortcut()
    }

    private func releaseVoiceTrigger() {
        guard voiceTrigger.held else { return }
        voiceTrigger.up(); triggerUps += 1
        if sessionShortcut.codes.contains(63) { fnUps += 1 }
        voiceTiming.mark("fnUp", at: ProcessInfo.processInfo.systemUptime)
    }

    private func updateStatusItem() {
        guard let button = item?.button else { return }
        let icon: StatusBarIcon = active ? .speaking : mapping.mouseModeActive ? .mouse : .normal
        button.title = ""
        button.image = icon.image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = icon.label
        button.setAccessibilityLabel(icon.label)
    }

    private func refresh() {
        guard !stopping else { return }
        mapping.refresh()
        unlock.refresh()
        if settingsVisible {
            if !mappingView.isHidden { mappingView.refreshStatus() }
            if !unlockView.isHidden { unlockView.refresh() }
        }
        xiaomiVoiceKey.refresh(enabled: remote.xiaomiReady)
        _ = mic.connect()
        refreshReadiness()
        if CBCentralManager.authorization == .allowedAlways && !allowPrompted && !AXIsProcessTrusted() {
            allowPrompted = true
            // This only registers the app in the system permission list.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        scheduleMaintenance()
        writeStatus()
    }

    private var settingsVisible: Bool { window?.isVisible == true && window?.isMiniaturized == false && !NSApplication.shared.isHidden }

    private func refreshReadiness() {
        guard settingsVisible else { return }
        let accessibility = AXIsProcessTrusted(), inputMonitoring = mapping.listeningAllowed
        audioLabel.stringValue = mic.available ? L("语音组件：已就绪") : L("语音组件：需要安装")
        permission.stringValue = L("辅助功能：%@\n输入监控：%@", accessibility ? L("已允许") : L("未允许"), inputMonitoring ? L("已允许") : L("未允许（自定义按键）"))
        permissionsButton.title = !accessibility ? L("允许辅助功能") : !inputMonitoring ? L("允许输入监控") : L("权限设置")
        var missing: [String] = []
        if !remote.ready { missing.append(L("连接遥控器")) }
        if !mic.available { missing.append(L("安装语音组件")) }
        if !accessibility { missing.append(L("允许辅助功能")) }
        if remote.xiaomiReady && !xiaomiVoiceKey.ready { missing.append(L("重新连接小米语音键")) }
        if remote.ready && effectiveActivation == .toggle && !remote.supportsToggle {
            missing.append(L("点按开关需要 Google ATVV 1.0，请切换按住说话"))
        }
        if voiceTarget == .voicekey {
            do {
                let shortcut = try configuredVoiceShortcut()
                voicePicker.toolTip = L("VoiceKey 长按快捷键：%@", shortcut.name)
            } catch { missing.append(error.localizedDescription) }
        }
        if !missing.isEmpty {
            readiness.stringValue = L("语音待就绪 · ") + missing.joined(separator: " · ")
        } else if unlock.blocksActions {
            readiness.stringValue = L("语音暂停 · 锁屏或连招录入中")
        } else if active || remote.voiceBusy {
            readiness.stringValue = L("语音处理中 · 请等待本次结束")
        } else if mapping.fnHeld {
            readiness.stringValue = L("语音等待 · 请先松开 Fn 按键")
        } else {
            readiness.stringValue = inputMonitoring ? L("设备与权限已就绪 · %@语音请试说确认", voiceTarget.name) :
                L("语音设备已就绪 · 自定义按键需输入监控 · %@请试说确认", voiceTarget.name)
        }
        readiness.textColor = missing.isEmpty ? SettingsTheme.forest : SettingsTheme.error
        readiness.toolTip = readiness.stringValue
    }

    private func scheduleMaintenance() {
        guard !stopping else { return }
        // Voice and key callbacks run immediately; this timer only audits state and updates diagnostics.
        let interval: TimeInterval = active || settingsVisible || unlock.mode != .idle ? 1 : 10
        guard poll?.timeInterval != interval else { return }
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        poll?.tolerance = interval == 1 ? 0.2 : 2
    }

    private func buildUI() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "Remote Vibe")
        let quitItem = appMenu.addItem(withTitle: L("退出 Remote Vibe"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        mainMenu.addItem(withTitle: "Remote Vibe", action: nil, keyEquivalent: "").submenu = appMenu
        let editMenu = NSMenu(title: L("编辑"))
        for (title, action, key) in [(L("撤销"), "undo:", "z"), (L("重做"), "redo:", "Z"),
                                    (L("剪切"), "cut:", "x"), (L("复制"), "copy:", "c"),
                                    (L("粘贴"), "paste:", "v"), (L("全选"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        mainMenu.addItem(withTitle: L("编辑"), action: nil, keyEquivalent: "").submenu = editMenu
        NSApplication.shared.mainMenu = mainMenu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "Remote Vibe \(version) (\(build))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: L("打开遥控语音"), action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: L("立即结束本次语音"), action: #selector(stopVoice), keyEquivalent: "")
        menu.addItem(withTitle: L("退出鼠标模式"), action: #selector(exitMouseMode), keyEquivalent: "")
        let configurations = NSMenu(title: L("键位配置"))
        for (title, action) in [(L("导入键位到草稿…"), #selector(importMappings)),
                                (L("导出已保存键位…"), #selector(exportMappings)),
                                (L("载入上次有效备份"), #selector(restoreMappings))] {
            configurations.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: L("键位配置"), action: nil, keyEquivalent: "").submenu = configurations
        menu.addItem(.separator())
        menu.addItem(withTitle: L("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updateStatus.isHidden = true
        menu.addItem(updateStatus)
        menu.addItem(withTitle: L("发布说明与下载…"), action: #selector(openReleases), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出"), action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1080, visible.width - 64), height: min(812, visible.height - 76)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.delegate = self
        window.title = L("Remote Vibe %@ · 遥控器设置", version)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = SettingsTheme.canvas
        window.appearance = NSAppearance(named: .aqua)
        window.contentMinSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        remotePicker = NSPopUpButton()
        remotePicker.addItems(withTitles: RemoteProfile.allCases.map { $0.title })
        remotePicker.selectItem(at: RemoteProfile.allCases.firstIndex(of: remote.profile) ?? 0)
        remotePicker.target = self; remotePicker.action = #selector(changeRemote)
        voicePicker = NSPopUpButton()
        voicePicker.addItems(withTitles: VoiceInputTarget.allCases.map(\.title))
        voicePicker.selectItem(at: VoiceInputTarget.allCases.firstIndex(of: voiceTarget) ?? 0)
        voicePicker.target = self; voicePicker.action = #selector(changeVoiceTarget)
        activationPicker = NSPopUpButton()
        activationPicker.addItems(withTitles: VoiceActivation.allCases.map(\.title))
        activationPicker.target = self; activationPicker.action = #selector(changeVoiceActivation)
        discoveryButton = SettingsTheme.button(L("扫描遥控器"), target: self, action: #selector(toggleDiscovery))
        pages = NSSegmentedControl(labels: [L("按键映射"), L("连招解锁")], trackingMode: .selectOne, target: self, action: #selector(changePage))
        pages.selectedSegment = 0
        mappingView = KeyMappingView(mapping: mapping)
        unlockView = ComboUnlockView(controller: unlock, allowPermissions: { [weak self] in self?.mappingView.allowListener() })
        unlockView.isHidden = true
        permissionsButton.target = self; permissionsButton.action = #selector(allowFn)
        let wechatButton = SettingsTheme.button(L("语音设置"), target: self, action: #selector(showVoiceHelp))
        let shell = SettingsView(mapping: mappingView, unlock: unlockView, remote: remotePicker, discovery: discoveryButton,
            pages: pages, connection: connection, audio: audioLabel, permission: permission,
            permissionsButton: permissionsButton, message: message, readiness: readiness, wechatButton: wechatButton,
            voiceInput: voicePicker, voiceActivation: activationPicker)
        let scroll = SettingsScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.backgroundColor = SettingsTheme.canvas
        scroll.documentView = shell
        window.contentView = scroll
    }

    @objc private func show() {
        unlock.reload(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        refresh()
    }
    @objc private func changeRemote() {
        guard !active else { return }
        unlockView.leave()
        xiaomiVoiceKey.stop()
        remote.select(RemoteProfile.allCases[remotePicker.indexOfSelectedItem])
        updateDiscoveryButton()
        updateRemoteUI()
        connection.stringValue = L("%@：正在连接…", remote.sourceName)
        message.stringValue = effectiveActivation == .toggle ? L("录音已结束 · 按一下语音键开始") : L("已选择%@，连接后按住语音键说话。", remote.sourceName)
        writeStatus()
    }
    @objc private func changeVoiceTarget() {
        guard !active, !remote.voiceBusy else {
            voicePicker.selectItem(at: VoiceInputTarget.allCases.firstIndex(of: voiceTarget) ?? 0)
            return
        }
        voiceTarget = VoiceInputTarget.allCases[voicePicker.indexOfSelectedItem]
        UserDefaults.standard.set(voiceTarget.rawValue, forKey: "voiceInputTarget.v1")
        voicePicker.toolTip = nil
        message.stringValue = effectiveActivation == .toggle ? L("已选择%@ · 语音键按一下开始，再按一下结束", voiceTarget.name) : L("已选择%@，按住语音键说话，松开结束。", voiceTarget.name)
        refreshReadiness(); writeStatus()
    }
    @objc private func changeVoiceActivation() {
        guard !active, !remote.voiceBusy else { return }
        voiceActivation = VoiceActivation.allCases[activationPicker.indexOfSelectedItem]
        UserDefaults.standard.set(voiceActivation.rawValue, forKey: "voiceActivation.v1")
        refreshActivationUI()
        message.stringValue = effectiveActivation == .toggle ? L("录音已结束 · 按一下语音键开始") : L("准备就绪后，在当前输入框里按住语音键说话。")
        refreshReadiness(); writeStatus()
    }
    private func refreshActivationUI() {
        remote.activation = effectiveActivation
        activationPicker.selectItem(at: VoiceActivation.allCases.firstIndex(of: effectiveActivation) ?? 0)
        activationPicker.isEnabled = !active && remote.profile == .chromecast
        activationPicker.toolTip = remote.profile == .chromecast ? nil : L("小米目前保留按住说话；点按开关支持 Google ATVV 1.0")
        mappingView.voiceToggle = effectiveActivation == .toggle
    }
    @objc private func toggleDiscovery() {
        guard !active else { return }
        remote.toggleDiscovery()
    }
    private func updateDiscoveryButton() {
        discoveryButton.isEnabled = !active && !remote.ready
        discoveryButton.title = remote.ready ? L("已连接") : remote.scanning ? L("停止扫描") : remote.connecting ? L("取消等待") : L("扫描遥控器")
    }
    private func updateRemoteUI() {
        let google = remote.profile == .chromecast
        refreshActivationUI()
        mapping.selectProfile(remote.profile)
        mappingView.switchProfile()
        mapping.refresh()
        pages.isHidden = !google
        mappingView.isHidden = google && pages.selectedSegment == 1
        unlockView.isHidden = !google || pages.selectedSegment == 0
    }
    @objc private func changePage() {
        let combo = pages.selectedSegment == 1
        if !combo { unlockView.leave() } else { unlock.reload() }
        mappingView.isHidden = combo; unlockView.isHidden = !combo
        if combo { unlockView.refresh() }
        window.makeFirstResponder(nil)
    }
    func windowWillClose(_ notification: Notification) {
        unlockView.leave()
        DispatchQueue.main.async { [weak self] in self?.scheduleMaintenance() }
    }
    func windowDidMiniaturize(_ notification: Notification) { scheduleMaintenance() }
    func windowDidDeminiaturize(_ notification: Notification) { refresh() }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func applicationDidHide(_ notification: Notification) { scheduleMaintenance(); writeStatus() }
    func applicationDidUnhide(_ notification: Notification) { refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    @objc private func allowFn() {
        if AXIsProcessTrusted() { mappingView.allowListener(); return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func showVoiceHelp() {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = L("确认%@语音能出字", voiceTarget.name)
        if voiceTarget == .voicekey {
            alert.informativeText = L("1. 打开 VoiceKey，允许辅助功能和麦克风权限。\n2. 在 VoiceKey 的音频设置中选择 Chromecast Mic 或系统默认，然后离开音频预览页。\n3. 长按快捷键与点按快捷键需分开，例如长按右 ⌘、点按 Fn。Remote Vibe 自动读取长按设置，不会修改 VoiceKey。\n4. 点击目标文本框，按住遥控器语音键说话，松开结束。\n\n空闲时 Remote Vibe 不采音；识别结果由 VoiceKey 处理。")
        } else {
            alert.informativeText = L("1. 在微信启用“长按 Fn 全局语音输入”，并允许微信使用麦克风。\n2. 微信输入设备选择系统默认输入或 Chromecast Mic。\n3. 关闭此说明，点击其他软件的文本框，按住遥控器原语音键说话，松开后确认文字出现。\n\n设备就绪不代表微信识别已验证；App 不读取识别结果。模拟 Fn 按键本身不会开启遥控器麦克风。")
        }
        if effectiveActivation == .toggle {
            alert.informativeText = voiceTarget == .voicekey ?
                L("VoiceKey 使用 Chromecast Mic 或系统默认输入，并设置独立的长按快捷键（如右 ⌘）。离开音频电平预览页。Remote Vibe 会自动保持和释放快捷键，无需手按键盘。") :
                L("启用微信的长按 Fn 全局语音输入，麦克风选择 Chromecast Mic 或系统默认。Fn 由 Remote Vibe 自动保持和释放，无需手按键盘。")
            alert.informativeText += "\n\n" + L("语音键按一下开始，再按一下结束；松手不会结束。结束后等待文字出现。")
        }
        alert.addButton(withTitle: L("知道了，去试说"))
        alert.beginSheetModal(for: window)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(importMappings), #selector(exportMappings), #selector(restoreMappings)].contains(menuItem.action) {
            return !active && !remote.voiceBusy && !unlock.blocksActions && window.attachedSheet == nil
        }
        if menuItem.action == #selector(exitMouseMode) { return mapping.mouseModeActive }
        return menuItem.action != #selector(checkForUpdates) || updateCheck == nil
    }

    private func showMappings() -> Bool {
        guard !active, !remote.voiceBusy, !unlock.blocksActions, window.attachedSheet == nil else { return false }
        pages.selectedSegment = 0; changePage(); show()
        return true
    }
    @objc private func importMappings() { if showMappings() { mappingView.importConfiguration() } }
    @objc private func exportMappings() { if showMappings() { mappingView.exportConfiguration() } }
    @objc private func restoreMappings() { if showMappings() { mappingView.restoreConfiguration() } }

    @objc private func checkForUpdates() {
        guard updateCheck == nil, !stopping else { return }
        updateStatus.isHidden = false; updateStatus.title = L("正在检查 GitHub 发布版本…")
        updateStatus.action = nil
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/jmeviler/remote-vibe/releases/latest")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RemoteVibe/\(version)", forHTTPHeaderField: "User-Agent")
        updateCheck = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                self.updateCheck = nil
                let result: String
                if error != nil {
                    result = L("检查失败，请检查网络或打开发布页")
                } else if let http = response as? HTTPURLResponse,
                          http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
                    result = L("GitHub 暂时限流，请稍后重试或打开发布页")
                } else if (response as? HTTPURLResponse)?.statusCode == 404 {
                    result = L("暂无正式发布版本")
                } else if (response as? HTTPURLResponse)?.statusCode == 200,
                          let data,
                          let release = try? JSONDecoder().decode(ReleaseUpdate.self, from: data) {
                    result = release.message(installed: self.version)
                } else {
                    result = L("GitHub 查询失败，可稍后重试或打开发布页")
                }
                self.updateStatus.title = result
                self.updateStatus.action = #selector(self.openReleases)
                // Keep the result in the menu; no delayed dialog steals a voice-input target.
                if !self.active && !self.remote.voiceBusy {
                    self.message.stringValue = L("%@ · 当前 %@ · 下载请打开菜单中的发布页", result, self.version)
                    self.writeStatus()
                }
            }
        }
        updateCheck?.resume()
    }

    @objc private func openReleases() {
        if !NSWorkspace.shared.open(ReleaseUpdate.releasesURL) {
            updateStatus.isHidden = false; updateStatus.title = L("无法打开浏览器，请手动访问 GitHub 项目")
        }
    }
    @objc private func exitMouseMode() { mapping.exitMouseMode(); mappingView.refreshStatus(); writeStatus() }

    @objc private func stopVoice() { mapping.suspendActions(); remote.cancelVoice(); abort() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func writeStatus() {
        var status: [String: Any] = [
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "mode": "wechat-hold-fn",
            "bluetoothAuthorization": CBCentralManager.authorization.rawValue,
            "accessibility": AXIsProcessTrusted(), "connected": remote.ready,
            "microphoneReady": mic.available, "recording": remote.streaming,
            "sessionActive": active, "fnHeld": (voiceTrigger.held && sessionShortcut.codes.contains(63)) || mapping.fnHeld, "mappedFnHeld": mapping.fnHeld, "fnDowns": fnDowns, "fnUps": fnUps,
            "voiceInputTarget": voiceTarget.rawValue, "voiceShortcut": sessionShortcut.name,
            "voiceShortcutHeld": voiceTrigger.held, "voiceTriggerDowns": triggerDowns, "voiceTriggerUps": triggerUps,
            "voiceActivation": effectiveActivation.rawValue, "voiceToggleActive": remote.toggled,
            "audioFrames": remote.frameCount, "fedSamples": mic.fedFrames, "renderedSamples": mic.renderedFrames,
            "voiceTiming": voiceTiming.diagnostics, "audioBuffer": mic.bufferDiagnostics, "drainTimedOut": drainTimedOut,
            "completedSessions": completedSessions, "status": message.stringValue,
            "voiceSource": remote.sourceName, "voiceProfile": remote.profile.rawValue,
            "voiceProtocol": remote.protocolSummary, "connectionStatus": connection.stringValue,
            "bluetoothScanning": remote.scanning, "bluetoothConnecting": remote.connecting,
            "bluetoothScanStarts": remote.scanStarts,
            "mappedVoiceHeld": mapping.mappedVoiceHeld, "mappedVoiceActive": remote.mappedVoiceActive, "voiceBusy": remote.voiceBusy,
            "xiaomiVoiceKeyReady": xiaomiVoiceKey.ready, "xiaomiVoiceKeyStatus": xiaomiVoiceKey.status,
            "mouseModeActive": mapping.mouseModeActive,
            "keyMappingStatus": mapping.status, "keyMappingConnected": mapping.connected,
            "configurationNotice": mapping.configurationNotice ?? "",
            "inputMonitoring": mapping.listeningAllowed,
            "shortcutListener": mapping.listening,
            "keyActionChoices": ActionCatalog.presets.count,
            "maintenanceInterval": poll?.timeInterval ?? 0,
            "defaultInput": AudioDevices.string(AudioDevices.defaultInput(), kAudioObjectPropertyName) ?? "none"
        ]
        guard let snapshot = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]), snapshot != lastStatus else { return }
        status["updated"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            do { try data.write(to: statusURL, options: .atomic); lastStatus = snapshot } catch { /* Diagnostics must not interrupt input. */ }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopping = true
        mic.onUnavailable = {}; mic.onAvailabilityChange = {}
        updateCheck?.cancel(); updateCheck = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        mapping.onDeviceChange = nil
        mapping.onFnChange = nil
        mapping.onMouseModeChange = nil
        poll?.invalidate(); unlock.stop(); mapping.stop(); remote.shutdown(); xiaomiVoiceKey.stop(); abort(); mic.stop()
    }
}

@main
enum Main {
    static func main() {
        // Reject a second instance before it can acquire devices or run cleanup.
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.ben.RemoteVibe")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            if let url = existing.bundleURL { NSWorkspace.shared.open(url) }
            else { existing.activate(options: []) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppController()
        app.delegate = delegate
        app.run()
    }
}

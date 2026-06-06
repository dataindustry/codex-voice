import Cocoa
import Foundation
import ApplicationServices
import AVFoundation
import Carbon

final class CodexVoiceAgent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let root: String
    private let statusPath: String
    private let indicatorPIDPath: String
    private let configPath: String
    private let transcriptsPath: String
    private let logPath: String
    private let pythonPath: String
    private let voiceScriptPath: String
    private let configHelperPath: String
    private let pasteRequestPath: String
    private let pasteResultPath: String
    private let modelTaskPath: String

    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var detailLine: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var submitItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var indicatorItem: NSMenuItem?
    private var transcriptionModelMenuItem: NSMenuItem?
    private var transcriptionModelMenu: NSMenu?
    private var correctionModelMenuItem: NSMenuItem?
    private var correctionModelMenu: NSMenu?
    private var inputDeviceMenuItem: NSMenuItem?
    private var inputDeviceMenu: NSMenu?
    private var popover: NSPopover?
    private var panelController: CodexVoicePanelController?
    private var cachedInputDevices: [InputDevice] = []
    private var cachedTranscriptionModels: [OllamaModel] = []
    private var cachedCorrectionModels: [OllamaModel] = []
    private var cachedMaintenance: PanelMaintenance?
    private var autoPreparingCorrectionModel = false
    private var lastAutoPreparedCorrectionModel = ""
    private var lastAutoPrepareFailureAt: Date?
    private var lastAutoPrepareFailureModel = ""
    private var quitInProgress = false
    private var lastInputProbeResult = ""
    private var isPanelScanInFlight = false
    private var isInputProbeInFlight = false
    private var timer: Timer?
    private let nativeHotkeyManager = NativeHotkeyManager()
    private var nativeHotkeyStatus = "unregistered"
    private var lastNativeHotkeyAcceptedAt: Date?
    private var lastNativeRecordingStartAt: Date?
    private let nativeHotkeyDebounceInterval: TimeInterval = 0.35
    private let nativeHotkeyStartGraceInterval: TimeInterval = 1.0
    private let autoPrepareRetryInterval: TimeInterval = 30

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        root = ProcessInfo.processInfo.environment["CODEX_VOICE_HOME"] ?? "\(home)/CodexVoice"
        statusPath = "\(root)/state/status.json"
        indicatorPIDPath = "\(root)/state/indicator.pid"
        configPath = "\(root)/config/config.json"
        transcriptsPath = "\(root)/transcripts"
        logPath = "\(root)/logs/codex-voice.log"
        pythonPath = CodexVoiceAgent.resolvePythonPath(root: root)
        voiceScriptPath = "\(root)/bin/codex-voice.py"
        configHelperPath = "\(root)/bin/codex-voice-config.py"
        pasteRequestPath = "\(root)/state/paste.request"
        pasteResultPath = "\(root)/state/paste.result"
        modelTaskPath = "\(root)/state/model-task.json"
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.toolTip = "Codex Voice"
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))

        configurePopover()
        ensureNativeHotkeyDefaults()
        registerNativeHotkey()

        updateStatus()
        timer = Timer.scheduledTimer(
            withTimeInterval: 0.7,
            repeats: true
        ) { [weak self] _ in
            self?.updateStatus()
            self?.processPasteRequest()
        }
        processPasteRequest()
    }

    private func configurePopover() {
        let controller = CodexVoicePanelController()
        controller.onToggleRecording = { [weak self] in
            self?.toggleRecording(nil)
        }
        controller.onSubmitRecording = { [weak self] in
            self?.submitRecording(nil)
        }
        controller.onCancelRecording = { [weak self] in
            self?.cancelRecording(nil)
        }
        controller.onToggleIndicator = { [weak self] in
            self?.toggleRecordingIndicator(nil)
        }
        controller.onRequestMicrophonePermission = { [weak self] in
            self?.requestMicrophonePermission(nil)
        }
        controller.onRequestPastePermission = { [weak self] in
            self?.requestPastePermission(nil)
        }
        controller.onOpenConfig = { [weak self] in
            self?.openConfig(nil)
        }
        controller.onOpenTranscripts = { [weak self] in
            self?.openTranscripts(nil)
        }
        controller.onOpenLog = { [weak self] in
            self?.openLog(nil)
        }
        controller.onQuit = { [weak self] in
            self?.quit(nil)
        }
        controller.onSelectTranscriptionModel = { [weak self] value in
            self?.setTranscriptionModelValue(value)
        }
        controller.onSelectCorrectionModel = { [weak self] value in
            self?.setCorrectionModelValue(value)
        }
        controller.onSelectInputDevice = { [weak self] value in
            self?.setInputDeviceValue(value)
        }
        controller.onWarmTranscriptionModel = { [weak self] in
            self?.warmCurrentTranscriptionModel(nil)
        }
        controller.onWarmCorrectionModel = { [weak self] in
            self?.warmCurrentCorrectionModel(nil)
        }
        controller.onUnloadCorrectionModel = { [weak self] in
            self?.unloadCurrentCorrectionModel(nil)
        }
        controller.onUnloadOllamaModel = { [weak self] model in
            self?.unloadOllamaModel(model)
        }
        controller.onProbeInput = { [weak self] in
            self?.runInputProbeForPanel()
        }
        controller.onSetMaxMinutes = { [weak self] minutes in
            self?.setMaxRecordingMinutes(minutes)
        }
        controller.onSetNativeHotkey = { [weak self] hotkey in
            self?.setNativeHotkey(hotkey)
        }
        controller.onClearNativeHotkey = { [weak self] in
            self?.clearNativeHotkey()
        }
        controller.onResetNativeHotkey = { [weak self] in
            self?.resetNativeHotkey()
        }
        controller.onSetUILanguage = { [weak self] language in
            self?.setUILanguage(language)
        }
        panelController = controller

        let popover = NSPopover()
        controller.onPreferredContentSizeChange = { [weak popover] size in
            guard let popover else {
                return
            }
            if abs(popover.contentSize.width - size.width) > 0.5
                || abs(popover.contentSize.height - size.height) > 0.5 {
                popover.contentSize = size
            }
        }
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.loadViewIfNeeded()
        popover.contentSize = controller.preferredContentSize
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button,
              let popover else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        updateStatus()
        refreshPanelScanIfNeeded(force: true)
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    private static func resolvePythonPath(root: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["CODEX_VOICE_PYTHON"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let envName = environment["CODEX_VOICE_CONDA_ENV"] ?? "codex-voice"
        let candidates = [
            "\(home)/anaconda3/envs/\(envName)/bin/python",
            "\(home)/miniconda3/envs/\(envName)/bin/python",
            "\(home)/miniforge3/envs/\(envName)/bin/python",
            "/opt/homebrew/envs/\(envName)/bin/python"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return candidates[0]
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func i18n(_ key: String, _ args: [String: String] = [:]) -> String {
        CodexVoiceI18n.text(key, config: readConfig(), args)
    }

    private func i18n(_ key: String, config: [String: Any], _ args: [String: String] = [:]) -> String {
        CodexVoiceI18n.text(key, config: config, args)
    }

    private func updateStatus() {
        let voiceStatus = readStatus()
        let color = colorForStatus(voiceStatus.status, stale: voiceStatus.isStale)
        let title = titleForStatus(voiceStatus.status, stale: voiceStatus.isStale)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        ]
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: attributes
        )
        statusItem?.button?.toolTip = tooltipForStatus(voiceStatus)

        let config = readConfig()
        statusLine?.title = i18n("menu.status", config: config, ["value": voiceStatus.label])
        detailLine?.title = detailForMenu(voiceStatus)

        let canControlRecording = voiceStatus.status == "recording" || voiceStatus.status == "submitting"
        let busyAfterRecording = voiceStatus.status == "transcribing"
            || voiceStatus.status == "correcting"
            || voiceStatus.status == "finalizing"
        toggleItem?.title = canControlRecording
            ? i18n("menu.submitCurrent", config: config)
            : i18n("menu.start", config: config)
        toggleItem?.isEnabled = !busyAfterRecording
        submitItem?.isEnabled = canControlRecording
        cancelItem?.isEnabled = canControlRecording
        refreshRecordingIndicatorMenu()
        refreshPanel(status: voiceStatus)
        refreshPanelScanIfNeeded(force: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatus()
        refreshRecordingIndicatorMenu()
        refreshTranscriptionModelMenu()
        refreshCorrectionModelMenu()
        refreshInputDeviceMenu()
    }

    private func refreshPanel(status: VoiceStatus? = nil) {
        guard let controller = panelController else {
            return
        }
        let voiceStatus = status ?? readStatus()
        let config = readConfig()
        let task = readModelTask()
        let maintenance = cachedMaintenance ?? PanelMaintenance(
            pythonPath: pythonPath,
            launchAgentStatus: "com.codexvoice.agent",
            ollamaStatus: i18n("maintenance.scanning", config: config),
            ollamaStatusCode: "scanning",
            ollamaBaseURL: ""
        )
        controller.update(
            status: voiceStatus,
            config: config,
            modelTask: task,
            inputDevices: cachedInputDevices,
            transcriptionModels: cachedTranscriptionModels,
            correctionModels: cachedCorrectionModels,
            inputProbeResult: lastInputProbeResult.isEmpty
                ? i18n("panel.notTested", config: config)
                : lastInputProbeResult,
            isInputProbeInFlight: isInputProbeInFlight,
            isScanningModels: isPanelScanInFlight,
            maintenance: maintenance,
            nativeHotkeyStatus: nativeHotkeyStatus
        )
    }

    private func refreshPanelScanIfNeeded(force: Bool) {
        guard force else {
            return
        }
        if isPanelScanInFlight {
            return
        }

        isPanelScanInFlight = true
        refreshPanel()
        DispatchQueue.global(qos: .utility).async {
            let config = self.readConfig()
            let devices = self.readInputDevices()
            let scan = self.readOllamaScan()
            let launchStatus = self.readLaunchAgentSummary()
            let ollamaStatus: String
            if scan.available {
                ollamaStatus = scan.baseURL.isEmpty
                    ? self.i18n("maintenance.available", config: config)
                    : self.i18n("maintenance.availableAt", config: config, ["url": scan.baseURL])
            } else if scan.status == "ollama_not_installed" {
                ollamaStatus = self.i18n("maintenance.ollamaNotInstalled", config: config)
            } else if scan.status == "service_unavailable" {
                ollamaStatus = scan.error.isEmpty
                    ? self.i18n("maintenance.serviceNotReady", config: config)
                    : self.i18n("maintenance.serviceNotReadyDetail", config: config, ["error": scan.error])
            } else if scan.error.isEmpty {
                ollamaStatus = self.i18n("maintenance.unavailable", config: config)
            } else {
                ollamaStatus = self.i18n("maintenance.unavailableDetail", config: config, ["error": scan.error])
            }
            let maintenance = PanelMaintenance(
                pythonPath: self.pythonPath,
                launchAgentStatus: launchStatus,
                ollamaStatus: ollamaStatus,
                ollamaStatusCode: scan.status,
                ollamaBaseURL: scan.baseURL
            )
            DispatchQueue.main.async {
                self.cachedInputDevices = devices
                self.cachedTranscriptionModels = scan.transcriptionModels
                self.cachedCorrectionModels = scan.correctionModels
                self.cachedMaintenance = maintenance
                self.isPanelScanInFlight = false
                self.maybeAutoPrepareCorrectionModel(scan)
                self.refreshPanel()
            }
        }
    }

    private func readStatus() -> VoiceStatus {
        let config = readConfig()
        let defaultStatus = VoiceStatus(
            status: "idle",
            labelKey: "status.idle",
            label: CodexVoiceI18n.text("status.idle", config: config),
            detailKey: "",
            detailArgs: [:],
            detail: "",
            pid: nil,
            updatedAt: "",
            isStale: false
        )

        let url = URL(fileURLWithPath: statusPath)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return defaultStatus
        }

        let status = dict["status"] as? String ?? "idle"
        let labelKey = dict["label_key"] as? String ?? "status.\(status)"
        let label = CodexVoiceI18n.text(labelKey, config: config)
        let detailKey = dict["detail_key"] as? String ?? ""
        let detailArgs = stringDictionary(dict["detail_args"])
        let detail = dict["detail"] as? String ?? ""
        let pid = dict["pid"] as? Int
        let updatedAt = dict["updated_at"] as? String ?? ""
        let isStale = status != "idle" && statusFileIsStale(url)

        if isStale {
            return VoiceStatus(
                status: "idle",
                labelKey: "status.idle",
                label: CodexVoiceI18n.text("status.idle", config: config),
                detailKey: "detail.stale",
                detailArgs: [:],
                detail: CodexVoiceI18n.text("detail.stale", config: config),
                pid: nil,
                updatedAt: updatedAt,
                isStale: true
            )
        }

        return VoiceStatus(
            status: status,
            labelKey: labelKey,
            label: label,
            detailKey: detailKey,
            detailArgs: detailArgs,
            detail: detailKey.isEmpty ? detail : CodexVoiceI18n.text(detailKey, config: config, detailArgs),
            pid: pid,
            updatedAt: updatedAt,
            isStale: false
        )
    }

    private func statusFileIsStale(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(modified) > 20 * 60
    }

    private func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in dict {
            result[key] = "\(value)"
        }
        return result
    }

    private func titleForStatus(_ status: String, stale: Bool) -> String {
        if stale {
            return "●"
        }
        switch status {
        case "recording":
            return "● REC"
        case "submitting", "transcribing", "correcting", "finalizing":
            return "● REC"
        case "error":
            return "●"
        default:
            return "●"
        }
    }

    private func colorForStatus(_ status: String, stale: Bool) -> NSColor {
        if stale {
            return .white
        }
        switch status {
        case "recording":
            return .systemGreen
        case "submitting", "transcribing", "correcting", "finalizing":
            return .systemYellow
        case "error":
            return .systemRed
        default:
            return .white
        }
    }

    private func tooltipForStatus(_ status: VoiceStatus) -> String {
        if status.detail.isEmpty {
            return "Codex Voice: \(status.label)"
        }
        return "Codex Voice: \(status.label) - \(status.detail)"
    }

    private func detailForMenu(_ status: VoiceStatus) -> String {
        var parts: [String] = []
        if !status.detail.isEmpty {
            parts.append(status.detail)
        }
        if let pid = status.pid, status.status != "idle" {
            parts.append("PID \(pid)")
        }
        if !status.updatedAt.isEmpty {
            parts.append(status.updatedAt)
        }
        return parts.isEmpty ? " " : parts.joined(separator: " | ")
    }

    @objc private func toggleRecording(_ sender: Any?) {
        runVoiceCommand(["--toggle"])
    }

    @objc private func submitRecording(_ sender: Any?) {
        runVoiceCommand(["--submit-current"])
    }

    @objc private func cancelRecording(_ sender: Any?) {
        runVoiceCommand(["--cancel-current"])
    }

    private func nativeHotkeyPressed() {
        let now = Date()
        if let lastAccepted = lastNativeHotkeyAcceptedAt,
           now.timeIntervalSince(lastAccepted) < nativeHotkeyDebounceInterval {
            appendLog("Native hotkey ignored: debounced")
            return
        }

        let voiceStatus = readStatus()
        let busyAfterRecording = ["transcribing", "correcting", "finalizing"].contains(voiceStatus.status)
        if busyAfterRecording {
            appendLog("Native hotkey ignored: busy status=\(voiceStatus.status)")
            return
        }
        if voiceStatus.status == "recording" || voiceStatus.status == "submitting" {
            if let startedAt = lastNativeRecordingStartAt,
               now.timeIntervalSince(startedAt) < nativeHotkeyStartGraceInterval {
                appendLog("Native hotkey ignored: too-soon-submit")
                return
            }
            appendLog("Native hotkey accepted: submit")
            lastNativeRecordingStartAt = nil
        } else {
            if let startedAt = lastNativeRecordingStartAt,
               now.timeIntervalSince(startedAt) < nativeHotkeyStartGraceInterval {
                appendLog("Native hotkey ignored: too-soon-start")
                return
            }
            lastNativeRecordingStartAt = now
            appendLog("Native hotkey accepted: start")
        }

        lastNativeHotkeyAcceptedAt = now
        runVoiceCommand(["--toggle"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateStatus()
        }
    }

    private func ensureNativeHotkeyDefaults() {
        var config = readConfig()
        guard !config.isEmpty else {
            return
        }
        var changed = false
        if config["native_hotkey_enabled"] == nil {
            config["native_hotkey_enabled"] = true
            changed = true
        }
        if config["native_hotkey"] == nil {
            config["native_hotkey"] = NativeHotkey.defaultHotkey.configValue
            changed = true
        }
        if config["ui_language"] == nil {
            config["ui_language"] = "system"
            changed = true
        }
        if changed {
            _ = writeConfig(config)
        }
    }

    private func registerNativeHotkey() {
        let config = readConfig()
        let enabled = (config["native_hotkey_enabled"] as? Bool) ?? true
        let hotkey = NativeHotkey.from(config: config)
        guard enabled else {
            nativeHotkeyManager.unregister()
            nativeHotkeyStatus = "disabled"
            appendLog("Native hotkey disabled")
            refreshPanel()
            return
        }

        let status = nativeHotkeyManager.register(hotkey) { [weak self] in
            self?.nativeHotkeyPressed()
        }
        if status == noErr {
            nativeHotkeyStatus = "registered"
            appendLog("Registered native hotkey: \(hotkey.displayName)")
        } else {
            nativeHotkeyStatus = "conflict:\(status)"
            appendLog("Could not register native hotkey \(hotkey.displayName): \(status)")
        }
        refreshPanel()
    }

    private func setNativeHotkey(_ hotkey: NativeHotkey) {
        var config = readConfig()
        guard !config.isEmpty else {
            appendLog("Could not read config before setting native hotkey")
            return
        }
        if let status = NativeHotkeyConflictChecker.publicAPIStatus(for: hotkey),
           status != noErr {
            nativeHotkeyStatus = "unavailable"
            appendLog("Rejected native hotkey \(hotkey.displayName): public API status \(status)")
            refreshPanel()
            return
        }
        config["native_hotkey_enabled"] = true
        config["native_hotkey"] = hotkey.configValue
        guard writeConfig(config) else {
            return
        }
        appendLog("Set native hotkey: \(hotkey.displayName)")
        registerNativeHotkey()
    }

    private func clearNativeHotkey() {
        var config = readConfig()
        guard !config.isEmpty else {
            appendLog("Could not read config before clearing native hotkey")
            return
        }
        config["native_hotkey_enabled"] = false
        guard writeConfig(config) else {
            return
        }
        nativeHotkeyManager.unregister()
        nativeHotkeyStatus = "disabled"
        appendLog("Cleared native hotkey")
        refreshPanel()
    }

    private func resetNativeHotkey() {
        setNativeHotkey(.defaultHotkey)
    }

    @objc private func toggleRecordingIndicator(_ sender: Any?) {
        let currentValue = readConfigBool("recording_indicator", defaultValue: true)
        let nextValue = !currentValue
        if writeConfigBool("recording_indicator", value: nextValue) {
            indicatorItem?.state = nextValue ? .on : .off
            appendLog("Recording float window set to \(nextValue)")
            if nextValue {
                let status = readStatus()
                if status.status == "recording", let pid = status.pid {
                    startRecordingIndicator(parentPID: pid)
                }
            } else {
                stopRecordingIndicator()
            }
            refreshPanel()
        }
    }

    @objc private func openConfig(_ sender: Any?) {
        runProcess("/usr/bin/open", ["-e", configPath])
    }

    @objc private func openTranscripts(_ sender: Any?) {
        runProcess("/usr/bin/open", [transcriptsPath])
    }

    @objc private func openLog(_ sender: Any?) {
        runProcess("/usr/bin/open", [logPath])
    }

    @objc private func quit(_ sender: Any?) {
        guard !quitInProgress else {
            return
        }
        guard confirmCancelRecordingBeforeQuit() else {
            return
        }
        let loadedModels = loadedOllamaModelsForQuit()
        guard !loadedModels.isEmpty else {
            NSApp.terminate(nil)
            return
        }

        popover?.close()
        let config = readConfig()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = i18n("alert.quitTitle", config: config)
        alert.informativeText = i18n(
            "alert.loadedModels",
            config: config,
            ["models": loadedModels.map { "• \($0)" }.joined(separator: "\n")]
        )
        alert.addButton(withTitle: i18n("alert.unloadAndQuit", config: config))
        alert.addButton(withTitle: i18n("alert.quitOnly", config: config))
        alert.addButton(withTitle: i18n("alert.cancel", config: config))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            unloadModelsThenQuit(loadedModels)
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func confirmCancelRecordingBeforeQuit() -> Bool {
        let status = readStatus()
        guard status.status == "recording" || status.status == "submitting" else {
            return true
        }

        popover?.close()
        let config = readConfig()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = i18n("alert.recordingQuitTitle", config: config)
        alert.informativeText = i18n("alert.recordingQuitInfo", config: config)
        alert.addButton(withTitle: i18n("alert.cancelRecordingAndQuit", config: config))
        alert.addButton(withTitle: i18n("alert.continueRecording", config: config))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        let exitCode = runProcessAndWait(
            pythonPath,
            [voiceScriptPath, "--cancel-current"],
            timeout: 5
        )
        appendLog("Cancel recording before quit exit=\(exitCode)")
        return true
    }

    private func loadedOllamaModelsForQuit() -> [String] {
        let result = runProcessAndCapture(
            pythonPath,
            [configHelperPath, "--list-loaded-ollama-models"]
        )
        if result.exitCode != 0 {
            appendLog("Could not list loaded Ollama models: \(result.output)")
            return []
        }

        guard let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["available"] as? Bool ?? false,
              let models = dict["models"] as? [Any] else {
            return []
        }
        let names = models.compactMap { item -> String? in
            guard let name = item as? String else {
                return nil
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Array(Set(names)).sorted()
    }

    private func unloadModelsThenQuit(_ models: [String]) {
        quitInProgress = true
        for model in models {
            lastAutoPreparedCorrectionModel = model
        }
        appendLog("Quitting after unloading Ollama models: \(models.joined(separator: ", "))")
        DispatchQueue.global(qos: .utility).async {
            for model in models {
                let exitCode = self.runProcessAndWait(
                    self.pythonPath,
                    [self.configHelperPath, "--unload-ollama-model", model],
                    timeout: 20
                )
                self.appendLog("Unload model before quit: \(model), exit=\(exitCode)")
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func requestPastePermission(_ sender: Any?) {
        let trusted = requestAccessibilityPermission(prompt: true)
        appendLog("Accessibility permission trusted=\(trusted)")
    }

    @objc private func requestMicrophonePermission(_ sender: Any?) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            appendLog("Microphone permission already authorized")
            runInputProbeForPanel()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.appendLog("Microphone permission granted=\(granted)")
                    if granted {
                        self.runInputProbeForPanel()
                    } else {
                        self.lastInputProbeResult = self.i18n("menu.noMicrophone")
                        self.refreshPanel()
                    }
                }
            }
        case .denied, .restricted:
            appendLog("Microphone permission denied or restricted; opening Microphone privacy settings")
            lastInputProbeResult = i18n("menu.noMicrophone")
            refreshPanel()
            runProcess(
                "/usr/bin/open",
                ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]
            )
        @unknown default:
            appendLog("Microphone permission status is unknown")
            runInputProbeForPanel()
        }
    }

    private func runInputProbeForPanel() {
        if isInputProbeInFlight {
            return
        }
        isInputProbeInFlight = true
        lastInputProbeResult = i18n("panel.testing")
        refreshPanel()
        DispatchQueue.global(qos: .utility).async {
            let result = self.runProcessAndCapture(
                self.pythonPath,
                [self.configHelperPath, "--probe-input-device"]
            )
            let text = self.inputProbeSummary(exitCode: result.exitCode, output: result.output)
            self.appendLog("Panel microphone probe exit=\(result.exitCode): \(result.output)")
            DispatchQueue.main.async {
                self.lastInputProbeResult = text
                self.isInputProbeInFlight = false
                self.refreshPanel()
            }
        }
    }

    private func inputProbeSummary(exitCode: Int32, output: String) -> String {
        let config = readConfig()
        if exitCode != 0 {
            return output.isEmpty
                ? i18n("panel.testFailed", config: config)
                : "\(i18n("panel.testFailed", config: config)): \(output)"
        }
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return output.isEmpty ? i18n("panel.testDone", config: config) : output
        }
        let rms = (dict["rms"] as? NSNumber)?.doubleValue ?? 0
        let peak = (dict["peak"] as? NSNumber)?.doubleValue ?? 0
        let device = dict["device"] ?? "system default"
        let overflowed = (dict["overflowed"] as? Bool) == true
            ? i18n("panel.overflow", config: config)
            : ""
        if rms == 0 && peak == 0 {
            return i18n(
                "panel.selectedInputNoSignal",
                config: config,
                ["device": "\(device)"]
            )
        }
        return i18n(
            "panel.inputSummary",
            config: config,
            [
                "device": "\(device)",
                "rms": String(format: "%.4f", rms),
                "peak": String(format: "%.4f", peak),
                "overflow": overflowed
            ]
        )
    }

    private func runVoiceCommand(_ arguments: [String]) {
        runProcess(pythonPath, [voiceScriptPath] + arguments)
    }

    private func refreshRecordingIndicatorMenu() {
        indicatorItem?.state = readConfigBool("recording_indicator", defaultValue: true) ? .on : .off
    }

    private func currentTranscriptionProfile(_ config: [String: Any]) -> String {
        if let profile = config["transcription_profile"] as? String, !profile.isEmpty {
            return profile
        }
        if let backend = config["whisper_backend"] as? String {
            if backend == "mlx-whisper" {
                return "mlx-whisper-turbo"
            }
            if backend == "faster-whisper" {
                return "faster-whisper-turbo"
            }
            if backend == "ollama" {
                return "ollama-transcription"
            }
            return backend
        }
        return "mlx-whisper-turbo"
    }

    private func refreshTranscriptionModelMenu() {
        guard let menu = transcriptionModelMenu else {
            return
        }
        menu.removeAllItems()

        let config = readConfig()
        let profile = currentTranscriptionProfile(config)
        let selectedOllamaModel = config["ollama_transcription_model"] as? String ?? ""

        appendModelTaskMenuItems(menu, scope: "transcription")

        menu.addItem(disabledMenuItem(i18n("menu.builtinTranscription", config: config)))
        let mlxItem = actionMenuItem(
            "MLX Whisper large-v3-turbo \(i18n("menu.recommended", config: config))",
            #selector(selectTranscriptionModel(_:))
        )
        mlxItem.representedObject = "profile:mlx-whisper-turbo"
        mlxItem.state = profile == "mlx-whisper-turbo" ? .on : .off
        menu.addItem(mlxItem)

        let fasterItem = actionMenuItem(
            "faster-whisper large-v3-turbo \(i18n("menu.compatible", config: config))",
            #selector(selectTranscriptionModel(_:))
        )
        fasterItem.representedObject = "profile:faster-whisper-turbo"
        fasterItem.state = profile == "faster-whisper-turbo" ? .on : .off
        menu.addItem(fasterItem)

        menu.addItem(.separator())
        menu.addItem(disabledMenuItem(i18n("menu.ollamaTranscription", config: config)))
        let ollamaModels = readOllamaTranscriptionModels()
        if ollamaModels.isEmpty {
            menu.addItem(disabledMenuItem(i18n("menu.noOllamaTranscription", config: config)))
        } else {
            for model in ollamaModels {
                let suffix = model.needsTest ? i18n("menu.needsTest", config: config) : ""
                let item = actionMenuItem(
                    suffix.isEmpty ? model.name : "\(model.name) \(suffix)",
                    #selector(selectTranscriptionModel(_:))
                )
                item.representedObject = "ollama:\(model.name)"
                item.state = (
                    profile == "ollama-transcription" && selectedOllamaModel == model.name
                ) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(disabledMenuItem(i18n("menu.externalAPI", config: config)))
        menu.addItem(disabledMenuItem(i18n("menu.openaiDisabled", config: config)))
    }

    private func currentCorrectionProfile(_ config: [String: Any]) -> String {
        if let profile = config["correction_profile"] as? String, !profile.isEmpty {
            return profile
        }
        if let backend = config["correction_backend"] as? String {
            if backend == "ollama" {
                return "ollama-correction"
            }
            if backend == "rule-only" || backend == "none" {
                return "rule-only"
            }
            return backend
        }
        return "rule-only"
    }

    private func refreshCorrectionModelMenu() {
        guard let menu = correctionModelMenu else {
            return
        }
        menu.removeAllItems()

        let config = readConfig()
        let profile = currentCorrectionProfile(config)
        let selectedOllamaModel = config["ollama_model"] as? String ?? ""

        appendModelTaskMenuItems(menu, scope: "correction")

        menu.addItem(disabledMenuItem(i18n("menu.builtinCorrection", config: config)))
        let ruleItem = actionMenuItem(
            i18n("card.ruleCorrection", config: config),
            #selector(selectCorrectionModel(_:))
        )
        ruleItem.representedObject = "profile:rule-only"
        ruleItem.state = profile == "rule-only" ? .on : .off
        menu.addItem(ruleItem)

        menu.addItem(.separator())
        menu.addItem(disabledMenuItem(i18n("menu.ollamaCorrection", config: config)))
        let ollamaModels = readOllamaCorrectionModels()
        if ollamaModels.isEmpty {
            menu.addItem(disabledMenuItem(i18n("menu.noOllamaCorrection", config: config)))
        } else {
            for model in ollamaModels {
                let item = actionMenuItem(
                    model.name,
                    #selector(selectCorrectionModel(_:))
                )
                item.representedObject = "ollama:\(model.name)"
                item.state = (
                    profile == "ollama-correction" && selectedOllamaModel == model.name
                ) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(disabledMenuItem(i18n("menu.externalAPI", config: config)))
        menu.addItem(disabledMenuItem(i18n("menu.openaiDisabled", config: config)))
    }

    private func appendModelTaskMenuItems(_ menu: NSMenu, scope: String) {
        guard let task = readModelTask(),
              task.scope == scope,
              task.status == "running" else {
            return
        }

        let progressItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        progressItem.view = modelTaskProgressView(task)
        menu.addItem(progressItem)
        menu.addItem(.separator())
    }

    private func modelTaskProgressView(_ task: ModelTask) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 48))

        let title = NSTextField(labelWithString: task.label)
        title.frame = NSRect(x: 12, y: 27, width: 256, height: 16)
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        view.addSubview(title)

        let config = readConfig()
        let detailText = task.detail.isEmpty ? i18n("menu.modelPreparing", config: config) : task.detail
        let detail = NSTextField(labelWithString: detailText)
        detail.frame = NSRect(x: 12, y: 9, width: 256, height: 14)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        view.addSubview(detail)

        let progress = NSProgressIndicator(frame: NSRect(x: 12, y: 2, width: 256, height: 6))
        progress.style = .bar
        progress.controlSize = .small
        if let value = task.progress {
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = max(0, min(1, value))
        } else {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        }
        view.addSubview(progress)
        return view
    }

    private func readModelTask() -> ModelTask? {
        let url = URL(fileURLWithPath: modelTaskPath)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }

        let config = readConfig()
        let labelKey = dict["label_key"] as? String ?? ""
        let labelArgs = stringDictionary(dict["label_args"])
        let detailKey = dict["detail_key"] as? String ?? ""
        let detailArgs = stringDictionary(dict["detail_args"])
        let fallbackLabel = dict["label"] as? String ?? "Model task"
        let fallbackDetail = dict["detail"] as? String ?? ""

        return ModelTask(
            status: dict["status"] as? String ?? "idle",
            scope: dict["scope"] as? String ?? "",
            labelKey: labelKey,
            labelArgs: labelArgs,
            label: CodexVoiceI18n.modelTaskText(
                label: fallbackLabel,
                key: labelKey,
                args: labelArgs,
                config: config
            ),
            detailKey: detailKey,
            detailArgs: detailArgs,
            detail: CodexVoiceI18n.modelTaskText(
                label: fallbackDetail,
                key: detailKey,
                args: detailArgs,
                config: config
            ),
            progress: (dict["progress"] as? NSNumber)?.doubleValue,
            updatedAt: dict["updated_at"] as? String ?? ""
        )
    }

    private func readOllamaTranscriptionModels() -> [OllamaModel] {
        return readOllamaScan().transcriptionModels
    }

    private func readOllamaCorrectionModels() -> [OllamaModel] {
        return readOllamaScan().correctionModels
    }

    private func readOllamaScan() -> OllamaScan {
        let result = runProcessAndCapture(
            pythonPath,
            [configHelperPath, "--list-ollama-models"]
        )
        if result.exitCode != 0 {
            appendLog("Could not list Ollama models: \(result.output)")
            return OllamaScan(
                available: false,
                status: "service_unavailable",
                error: result.output,
                baseURL: "",
                configuredCorrectionModel: "",
                configuredCorrectionModelInstalled: false,
                configuredCorrectionModelLoaded: false,
                transcriptionModels: [],
                correctionModels: []
            )
        }

        guard let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            appendLog("Could not parse Ollama model list: \(result.output)")
            return OllamaScan(
                available: false,
                status: "parse_error",
                error: "Could not parse model scan result",
                baseURL: "",
                configuredCorrectionModel: "",
                configuredCorrectionModelInstalled: false,
                configuredCorrectionModelLoaded: false,
                transcriptionModels: [],
                correctionModels: []
            )
        }

        func parseModels(_ key: String) -> [OllamaModel] {
            guard let modelDicts = dict[key] as? [[String: Any]] else {
                return []
            }
            return modelDicts.compactMap { item in
                guard let name = item["name"] as? String, !name.isEmpty else {
                    return nil
                }
                let capabilities = item["capabilities"] as? [String] ?? []
                let details = item["details"] as? [String: Any] ?? [:]
                let size = (item["size"] as? NSNumber)?.int64Value
                return OllamaModel(
                    name: name,
                    capabilities: capabilities,
                    needsTest: item["transcription_needs_test"] as? Bool ?? false,
                    loaded: item["loaded"] as? Bool ?? false,
                    size: size,
                    family: details["family"] as? String ?? "",
                    families: details["families"] as? [String] ?? [],
                    parameterSize: details["parameter_size"] as? String ?? "",
                    quantization: details["quantization_level"] as? String ?? ""
                )
            }
        }

        let available = dict["available"] as? Bool ?? false
        let status = dict["status"] as? String ?? (available ? "available" : "service_unavailable")
        let error = dict["error"] as? String ?? ""
        let baseURL = dict["base_url"] as? String ?? ""
        let configuredCorrectionModel = dict["configured_correction_model"] as? String ?? ""
        let configuredCorrectionModelInstalled = dict["configured_correction_model_installed"] as? Bool ?? false
        let configuredCorrectionModelLoaded = dict["configured_correction_model_loaded"] as? Bool ?? false
        return OllamaScan(
            available: available,
            status: status,
            error: error,
            baseURL: baseURL,
            configuredCorrectionModel: configuredCorrectionModel,
            configuredCorrectionModelInstalled: configuredCorrectionModelInstalled,
            configuredCorrectionModelLoaded: configuredCorrectionModelLoaded,
            transcriptionModels: parseModels("transcription_models"),
            correctionModels: parseModels("correction_models")
        )
    }

    private func maybeAutoPrepareCorrectionModel(_ scan: OllamaScan) {
        let model = scan.configuredCorrectionModel
        guard scan.available,
              scan.configuredCorrectionModelInstalled,
              !scan.configuredCorrectionModelLoaded,
              !model.isEmpty else {
            return
        }
        let config = readConfig()
        let backend = config["correction_backend"] as? String ?? "ollama"
        let profile = config["correction_profile"] as? String ?? ""
        guard backend == "ollama" || profile == "ollama-correction" else {
            return
        }
        if autoPreparingCorrectionModel {
            return
        }
        if lastAutoPrepareFailureModel == model,
           let failedAt = lastAutoPrepareFailureAt,
           Date().timeIntervalSince(failedAt) < autoPrepareRetryInterval {
            return
        }
        if lastAutoPreparedCorrectionModel == model {
            return
        }
        if let task = readModelTask(),
           task.status == "running",
           task.scope == "correction" {
            return
        }

        autoPreparingCorrectionModel = true
        lastAutoPreparedCorrectionModel = model
        appendLog("Auto preparing Ollama correction model: \(model)")
        runModelTask(["--prepare-current-correction-model"]) { [weak self] exitCode in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.autoPreparingCorrectionModel = false
                if exitCode == 0 {
                    self.lastAutoPrepareFailureAt = nil
                    self.lastAutoPrepareFailureModel = ""
                } else {
                    self.lastAutoPrepareFailureAt = Date()
                    self.lastAutoPrepareFailureModel = model
                    if self.lastAutoPreparedCorrectionModel == model {
                        self.lastAutoPreparedCorrectionModel = ""
                    }
                }
                self.appendLog("Auto prepare correction model finished: \(model), exit=\(exitCode)")
                self.refreshPanelScanIfNeeded(force: true)
            }
        }
    }

    private func readLaunchAgentSummary() -> String {
        let label = "com.codexvoice.agent"
        let result = runProcessAndCapture(
            "/bin/launchctl",
            ["print", "gui/\(getuid())/\(label)"]
        )
        let config = readConfig()
        if result.exitCode == 0 {
            return i18n("maintenance.launchLoaded", config: config, ["label": label])
        }
        return i18n("maintenance.launchNotLoaded", config: config, ["label": label])
    }

    @objc private func selectTranscriptionModel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else {
            return
        }
        setTranscriptionModelValue(value)
    }

    private func setTranscriptionModelValue(_ value: String) {
        let arguments: [String]
        if value.hasPrefix("profile:") {
            let profile = String(value.dropFirst("profile:".count))
            arguments = [configHelperPath, "--set-transcription-profile", profile]
        } else if value.hasPrefix("ollama:") {
            let model = String(value.dropFirst("ollama:".count))
            arguments = [configHelperPath, "--set-ollama-transcription-model", model]
        } else {
            appendLog("Unsupported transcription menu value: \(value)")
            return
        }

        let result = runProcessAndCapture(pythonPath, arguments)
        appendLog("Set transcription model value=\(value), exit=\(result.exitCode): \(result.output)")
        if result.exitCode == 0 {
            runModelTask(["--prepare-current-transcription-model"])
        }
        refreshTranscriptionModelMenu()
        refreshPanel()
    }

    @objc private func selectCorrectionModel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else {
            return
        }
        setCorrectionModelValue(value)
    }

    private func setCorrectionModelValue(_ value: String) {
        let arguments: [String]
        if value.hasPrefix("profile:") {
            let profile = String(value.dropFirst("profile:".count))
            arguments = [configHelperPath, "--set-correction-profile", profile]
        } else if value.hasPrefix("ollama:") {
            let model = String(value.dropFirst("ollama:".count))
            arguments = [configHelperPath, "--set-ollama-correction-model", model]
        } else {
            appendLog("Unsupported correction menu value: \(value)")
            return
        }

        let result = runProcessAndCapture(pythonPath, arguments)
        appendLog("Set correction model value=\(value), exit=\(result.exitCode): \(result.output)")
        if result.exitCode == 0 {
            runModelTask(["--prepare-current-correction-model"])
        }
        refreshCorrectionModelMenu()
        refreshPanel()
    }

    @objc private func warmCurrentTranscriptionModel(_ sender: Any?) {
        runModelTask(["--prepare-current-transcription-model"])
        refreshTranscriptionModelMenu()
        refreshPanel()
    }

    @objc private func warmCurrentCorrectionModel(_ sender: Any?) {
        runModelTask(["--prepare-current-correction-model"])
        refreshCorrectionModelMenu()
        refreshPanel()
    }

    @objc private func unloadCurrentCorrectionModel(_ sender: Any?) {
        runModelTask(["--unload-current-correction-model"])
        refreshCorrectionModelMenu()
        refreshPanel()
    }

    private func unloadOllamaModel(_ model: String) {
        lastAutoPreparedCorrectionModel = model
        runModelTask(["--unload-ollama-model", model]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPanelScanIfNeeded(force: true)
            }
        }
        refreshCorrectionModelMenu()
        refreshPanel()
    }

    private func runModelTask(
        _ arguments: [String],
        completion: ((Int32) -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .utility).async {
            let exitCode = self.runProcessAndWait(
                self.pythonPath,
                [self.configHelperPath] + arguments
            )
            self.appendLog(
                "Model task finished: \(arguments.joined(separator: " ")), "
                + "exit=\(exitCode)"
            )
            completion?(exitCode)
        }
    }

    private func refreshInputDeviceMenu() {
        guard let menu = inputDeviceMenu else {
            return
        }
        menu.removeAllItems()

        let config = readConfig()
        let configured = config["input_device"] as? String
        let devices = readInputDevices()

        let defaultName = devices.first(where: { $0.isDefault })?.name
        let defaultTitle: String
        if let defaultName, !defaultName.isEmpty {
            defaultTitle = i18n("menu.systemDefaultInputNamed", config: config, ["name": defaultName])
        } else {
            defaultTitle = i18n("menu.systemDefaultInput", config: config)
        }
        let defaultItem = actionMenuItem(defaultTitle, #selector(selectInputDevice(_:)))
        defaultItem.representedObject = "__default__"
        defaultItem.state = (configured == nil || configured?.isEmpty == true) ? .on : .off
        menu.addItem(defaultItem)

        if devices.isEmpty {
            let emptyItem = disabledMenuItem(i18n("menu.noMicrophone", config: config))
            menu.addItem(emptyItem)
            return
        }

        menu.addItem(.separator())
        for device in devices {
            let title = device.isDefault
                ? "\(device.name) \(i18n("menu.currentSystemDefault", config: config))"
                : device.name
            let item = actionMenuItem(title, #selector(selectInputDevice(_:)))
            item.representedObject = device.name
            item.state = configured == device.name ? .on : .off
            menu.addItem(item)
        }
    }

    private func readInputDevices() -> [InputDevice] {
        let result = runProcessAndCapture(
            pythonPath,
            [configHelperPath, "--list-input-devices"]
        )
        if result.exitCode != 0 {
            appendLog("Could not list input devices: \(result.output)")
            return []
        }

        guard let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let deviceDicts = dict["devices"] as? [[String: Any]] else {
            appendLog("Could not parse input device list: \(result.output)")
            return []
        }

        return deviceDicts.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else {
                return nil
            }
            return InputDevice(
                name: name,
                isDefault: item["default"] as? Bool ?? false,
                channels: (item["channels"] as? NSNumber)?.intValue,
                index: (item["index"] as? NSNumber)?.intValue
            )
        }
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else {
            return
        }
        setInputDeviceValue(value)
    }

    private func setInputDeviceValue(_ value: String) {
        let exitCode = runProcessAndWait(
            pythonPath,
            [configHelperPath, "--set-input-device", value]
        )
        appendLog("Set input device to \(value), exit=\(exitCode)")
        refreshInputDeviceMenu()
        refreshPanel()
    }

    private func setMaxRecordingMinutes(_ minutes: Double) {
        let bounded = max(1, min(10, minutes))
        let formatted = String(format: "%.1f", bounded)
        let result = runProcessAndCapture(
            pythonPath,
            [configHelperPath, "--set-max-minutes", formatted]
        )
        appendLog("Set max recording minutes to \(formatted), exit=\(result.exitCode): \(result.output)")
        refreshPanel()
    }

    private func setUILanguage(_ language: String) {
        let result = runProcessAndCapture(
            pythonPath,
            [configHelperPath, "--set-ui-language", language]
        )
        appendLog("Set UI language to \(language), exit=\(result.exitCode): \(result.output)")
        if result.exitCode == 0 {
            cachedMaintenance = nil
            transcriptionModelMenu?.removeAllItems()
            correctionModelMenu?.removeAllItems()
            inputDeviceMenu?.removeAllItems()
            updateStatus()
            refreshPanelScanIfNeeded(force: true)
        } else {
            refreshPanel()
        }
    }

    private func readConfig() -> [String: Any] {
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func readConfigBool(_ key: String, defaultValue: Bool) -> Bool {
        let value = readConfig()[key]
        if let boolValue = value as? Bool {
            return boolValue
        }
        return defaultValue
    }

    private func readConfigDouble(_ key: String, defaultValue: Double) -> Double {
        let value = readConfig()[key]
        if let numberValue = value as? NSNumber {
            return numberValue.doubleValue
        }
        return defaultValue
    }

    private func writeConfigBool(_ key: String, value: Bool) -> Bool {
        var config = readConfig()
        if config.isEmpty {
            appendLog("Could not read config: \(configPath)")
            return false
        }
        config[key] = value
        return writeConfig(config)
    }

    private func writeConfig(_ config: [String: Any]) -> Bool {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys]
            )
            var output = data
            output.append(Data("\n".utf8))
            let url = URL(fileURLWithPath: configPath)
            let tempURL = url.deletingLastPathComponent()
                .appendingPathComponent(".config.\(getpid()).tmp")
            try output.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            return true
        } catch {
            appendLog("Could not write config \(configPath): \(error.localizedDescription)")
            return false
        }
    }

    private func stopRecordingIndicator() {
        let url = URL(fileURLWithPath: indicatorPIDPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pidValue = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pidValue > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        if kill(pidValue, SIGTERM) != 0 && errno != ESRCH {
            appendLog("Could not stop recording indicator PID \(pidValue): errno \(errno)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func startRecordingIndicator(parentPID: Int) {
        let executable = "\(root)/bin/codex-voice-recording-indicator"
        guard parentPID > 0,
              FileManager.default.isExecutableFile(atPath: executable) else {
            appendLog("Could not start recording indicator from menu")
            return
        }

        stopRecordingIndicator()

        let fallbackMax = readConfigDouble("max_record_seconds", defaultValue: 300)
        let maxSeconds = readConfigDouble("background_max_record_seconds", defaultValue: fallbackMax)
        let language = CodexVoiceI18n.resolved(config: readConfig())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "--parent-pid",
            "\(parentPID)",
            "--max-seconds",
            "\(maxSeconds)",
            "--language",
            language
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: root)

        do {
            try process.run()
            let pidText = "\(process.processIdentifier)"
            try pidText.write(
                to: URL(fileURLWithPath: indicatorPIDPath),
                atomically: true,
                encoding: .utf8
            )
            appendLog("Started recording indicator from menu: \(pidText)")
        } catch {
            appendLog("Could not start recording indicator from menu: \(error.localizedDescription)")
        }
    }

    private func processPasteRequest() {
        let requestURL = URL(fileURLWithPath: pasteRequestPath)
        guard let data = try? Data(contentsOf: requestURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let request = object as? [String: Any],
              let requestID = request["id"] as? String,
              !requestID.isEmpty else {
            return
        }

        try? FileManager.default.removeItem(at: requestURL)
        let result = pasteClipboardWithCGEvent()
        writePasteResult(id: requestID, ok: result.ok, message: result.message)
    }

    private func pasteClipboardWithCGEvent() -> (ok: Bool, message: String) {
        guard requestAccessibilityPermission(prompt: true) else {
            return (
                false,
                i18n("paste.accessibility")
            )
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return (false, "Could not create keyboard event source.")
        }

        let vKeyCode: CGKeyCode = 0x09
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: vKeyCode,
            keyDown: true
        ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: vKeyCode,
                keyDown: false
              ) else {
            return (false, "Could not create Cmd+V keyboard events.")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(60_000)
        keyUp.post(tap: .cghidEventTap)
        appendLog("Pasted clipboard with native Cmd+V event")
        return (true, "pasted")
    }

    private func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func writePasteResult(id: String, ok: Bool, message: String) {
        let payload: [String: Any] = [
            "id": id,
            "ok": ok,
            "message": message,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            var output = data
            output.append(Data("\n".utf8))
            let resultURL = URL(fileURLWithPath: pasteResultPath)
            let tempURL = resultURL.deletingLastPathComponent()
                .appendingPathComponent(".paste-result.\(getpid()).tmp")
            try output.write(to: tempURL, options: .atomic)
            try? FileManager.default.removeItem(at: resultURL)
            try FileManager.default.moveItem(at: tempURL, to: resultURL)
        } catch {
            appendLog("Could not write paste result: \(error.localizedDescription)")
        }
    }

    private func runProcess(_ executable: String, _ arguments: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: self.root)
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["CODEX_VOICE_HOME"] = self.root
            environment["PYTHONNOUSERSITE"] = "1"
            process.environment = environment
            do {
                try process.run()
            } catch {
                self.appendLog("Could not run \(executable): \(error.localizedDescription)")
            }
        }
    }

    private func runProcessAndWait(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CODEX_VOICE_HOME"] = root
        environment["PYTHONNOUSERSITE"] = "1"
        process.environment = environment

        do {
            try process.run()
            if let timeout {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.5)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    appendLog("Process timed out after \(timeout)s: \(executable) \(arguments.joined(separator: " "))")
                    return 124
                }
            } else {
                process.waitUntilExit()
            }
            return process.terminationStatus
        } catch {
            appendLog("Could not run \(executable): \(error.localizedDescription)")
            return 127
        }
    }

    private func runProcessAndCapture(
        _ executable: String,
        _ arguments: [String]
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CODEX_VOICE_HOME"] = root
        environment["PYTHONNOUSERSITE"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            let output = process.terminationStatus == 0
                ? stdoutText
                : [stdoutText, stderrText].joined(separator: "\n")
            return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (127, "Could not run \(executable): \(error.localizedDescription)")
        }
    }

    private func appendLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        let fileURL = URL(fileURLWithPath: "\(root)/logs/codex-voice-agent.log")
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}

import Cocoa
import Foundation
import ApplicationServices
import AVFoundation

struct VoiceStatus {
    let status: String
    let label: String
    let detail: String
    let pid: Int?
    let updatedAt: String
    let isStale: Bool
}

struct InputDevice {
    let name: String
    let isDefault: Bool
}

struct OllamaModel {
    let name: String
    let capabilities: [String]
    let needsTest: Bool
}

struct ModelTask {
    let status: String
    let scope: String
    let label: String
    let detail: String
    let progress: Double?
    let updatedAt: String
}

struct OllamaScan {
    let available: Bool
    let error: String
    let transcriptionModels: [OllamaModel]
    let correctionModels: [OllamaModel]
}

struct PanelMaintenance {
    let pythonPath: String
    let launchAgentStatus: String
    let ollamaStatus: String
}

final class CodexVoiceAgent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let root: String
    private let statusPath: String
    private let triggerDir: String
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
    private var lastInputProbeResult = "未测试"
    private var isPanelScanInFlight = false
    private var lastPanelScanAt = Date.distantPast
    private var isInputProbeInFlight = false
    private var timer: Timer?
    private var isProcessingTrigger = false

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        root = ProcessInfo.processInfo.environment["CODEX_VOICE_HOME"] ?? "\(home)/CodexVoice"
        statusPath = "\(root)/state/status.json"
        triggerDir = "\(root)/state/triggers"
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

        updateStatus()
        timer = Timer.scheduledTimer(
            withTimeInterval: 0.7,
            repeats: true
        ) { [weak self] _ in
            self?.updateStatus()
            self?.processNextTrigger()
            self?.processPasteRequest()
        }
        processNextTrigger()
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
        controller.onProbeInput = { [weak self] in
            self?.runInputProbeForPanel()
        }
        controller.onSetMaxMinutes = { [weak self] minutes in
            self?.setMaxRecordingMinutes(minutes)
        }
        panelController = controller

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = controller
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

        statusLine?.title = "状态: \(voiceStatus.label)"
        detailLine?.title = detailForMenu(voiceStatus)

        let canControlRecording = voiceStatus.status == "recording" || voiceStatus.status == "submitting"
        let busyAfterRecording = voiceStatus.status == "transcribing"
            || voiceStatus.status == "correcting"
            || voiceStatus.status == "finalizing"
        toggleItem?.title = canControlRecording ? "提交当前录音" : "开始录音"
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
            ollamaStatus: "正在扫描"
        )
        controller.update(
            status: voiceStatus,
            config: config,
            modelTask: task,
            inputDevices: cachedInputDevices,
            transcriptionModels: cachedTranscriptionModels,
            correctionModels: cachedCorrectionModels,
            inputProbeResult: lastInputProbeResult,
            isInputProbeInFlight: isInputProbeInFlight,
            isScanningModels: isPanelScanInFlight,
            maintenance: maintenance
        )
    }

    private func refreshPanelScanIfNeeded(force: Bool) {
        guard popover?.isShown == true || force else {
            return
        }
        if isPanelScanInFlight {
            return
        }
        if !force && Date().timeIntervalSince(lastPanelScanAt) < 3 {
            return
        }

        isPanelScanInFlight = true
        refreshPanel()
        DispatchQueue.global(qos: .utility).async {
            let devices = self.readInputDevices()
            let scan = self.readOllamaScan()
            let launchStatus = self.readLaunchAgentSummary()
            let ollamaStatus: String
            if scan.available {
                ollamaStatus = "可用"
            } else if scan.error.isEmpty {
                ollamaStatus = "不可用"
            } else {
                ollamaStatus = "不可用：\(scan.error)"
            }
            let maintenance = PanelMaintenance(
                pythonPath: self.pythonPath,
                launchAgentStatus: launchStatus,
                ollamaStatus: ollamaStatus
            )
            DispatchQueue.main.async {
                self.cachedInputDevices = devices
                self.cachedTranscriptionModels = scan.transcriptionModels
                self.cachedCorrectionModels = scan.correctionModels
                self.cachedMaintenance = maintenance
                self.lastPanelScanAt = Date()
                self.isPanelScanInFlight = false
                self.refreshPanel()
            }
        }
    }

    private func readStatus() -> VoiceStatus {
        let defaultStatus = VoiceStatus(
            status: "idle",
            label: "空闲",
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
        let label = dict["label"] as? String ?? fallbackLabel(status)
        let detail = dict["detail"] as? String ?? ""
        let pid = dict["pid"] as? Int
        let updatedAt = dict["updated_at"] as? String ?? ""
        let isStale = status != "idle" && statusFileIsStale(url)

        if isStale {
            return VoiceStatus(
                status: "idle",
                label: "空闲",
                detail: "状态文件已过期，可能是上次进程异常退出",
                pid: nil,
                updatedAt: updatedAt,
                isStale: true
            )
        }

        return VoiceStatus(
            status: status,
            label: label,
            detail: detail,
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

    private func fallbackLabel(_ status: String) -> String {
        switch status {
        case "recording": return "正在录音"
        case "submitting": return "正在结束录音"
        case "transcribing": return "正在识别"
        case "correcting": return "正在纠错"
        case "finalizing": return "正在提交文本"
        case "error": return "出错"
        default: return "空闲"
        }
    }

    private func titleForStatus(_ status: String, stale: Bool) -> String {
        if stale {
            return "● CV"
        }
        switch status {
        case "recording":
            return "● REC"
        case "submitting", "transcribing", "correcting", "finalizing":
            return "● CV"
        case "error":
            return "● CV"
        default:
            return "● CV"
        }
    }

    private func colorForStatus(_ status: String, stale: Bool) -> NSColor {
        if stale {
            return .black
        }
        switch status {
        case "recording":
            return .systemGreen
        case "submitting", "transcribing", "correcting", "finalizing":
            return .systemYellow
        case "error":
            return .systemRed
        default:
            return .black
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
        NSApp.terminate(nil)
    }

    @objc private func requestPastePermission(_ sender: Any?) {
        let trusted = requestAccessibilityPermission(prompt: true)
        appendLog("Accessibility permission trusted=\(trusted)")
    }

    @objc private func requestMicrophonePermission(_ sender: Any?) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            appendLog("Microphone permission already authorized")
            runMicrophoneProbe()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.appendLog("Microphone permission granted=\(granted)")
                    self.runMicrophoneProbe()
                }
            }
        case .denied, .restricted:
            appendLog("Microphone permission denied or restricted; opening Microphone privacy settings")
            runProcess(
                "/usr/bin/open",
                ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]
            )
        @unknown default:
            appendLog("Microphone permission status is unknown")
            runMicrophoneProbe()
        }
    }

    private func runMicrophoneProbe() {
        DispatchQueue.global(qos: .utility).async {
            let result = self.runProcessAndCapture(
                self.pythonPath,
                [self.configHelperPath, "--probe-input-device"]
            )
            self.appendLog("Microphone probe exit=\(result.exitCode): \(result.output)")
        }
    }

    private func runInputProbeForPanel() {
        if isInputProbeInFlight {
            return
        }
        isInputProbeInFlight = true
        lastInputProbeResult = "测试中..."
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
        if exitCode != 0 {
            return output.isEmpty ? "测试失败" : "测试失败：\(output)"
        }
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return output.isEmpty ? "测试完成" : output
        }
        let rms = (dict["rms"] as? NSNumber)?.doubleValue ?? 0
        let peak = (dict["peak"] as? NSNumber)?.doubleValue ?? 0
        let device = dict["device"] ?? "system default"
        let overflowed = (dict["overflowed"] as? Bool) == true ? "，有溢出" : ""
        return String(
            format: "设备 %@，RMS %.4f，Peak %.4f%@",
            "\(device)",
            rms,
            peak,
            overflowed
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

        menu.addItem(disabledMenuItem("内置转录模型"))
        let mlxItem = actionMenuItem(
            "MLX Whisper large-v3-turbo（推荐）",
            #selector(selectTranscriptionModel(_:))
        )
        mlxItem.representedObject = "profile:mlx-whisper-turbo"
        mlxItem.state = profile == "mlx-whisper-turbo" ? .on : .off
        menu.addItem(mlxItem)

        let fasterItem = actionMenuItem(
            "faster-whisper large-v3-turbo（兼容）",
            #selector(selectTranscriptionModel(_:))
        )
        fasterItem.representedObject = "profile:faster-whisper-turbo"
        fasterItem.state = profile == "faster-whisper-turbo" ? .on : .off
        menu.addItem(fasterItem)

        menu.addItem(.separator())
        menu.addItem(disabledMenuItem("Ollama 已安装转录模型"))
        let ollamaModels = readOllamaTranscriptionModels()
        if ollamaModels.isEmpty {
            menu.addItem(disabledMenuItem("未检测到 Ollama 转录模型"))
        } else {
            for model in ollamaModels {
                let suffix = model.needsTest ? "（需测试）" : ""
                let item = actionMenuItem(
                    "\(model.name)\(suffix)",
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
        menu.addItem(disabledMenuItem("外接在线 API"))
        menu.addItem(disabledMenuItem("OpenAI API（未启用）"))
        menu.addItem(.separator())
        menu.addItem(actionMenuItem("预热当前转录模型", #selector(warmCurrentTranscriptionModel(_:))))
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

        menu.addItem(disabledMenuItem("内置纠错模型"))
        let ruleItem = actionMenuItem(
            "规则纠错（不使用 LLM）",
            #selector(selectCorrectionModel(_:))
        )
        ruleItem.representedObject = "profile:rule-only"
        ruleItem.state = profile == "rule-only" ? .on : .off
        menu.addItem(ruleItem)

        menu.addItem(.separator())
        menu.addItem(disabledMenuItem("Ollama 已安装纠错模型"))
        let ollamaModels = readOllamaCorrectionModels()
        if ollamaModels.isEmpty {
            menu.addItem(disabledMenuItem("未检测到 Ollama 纠错模型"))
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
        menu.addItem(disabledMenuItem("外接在线 API"))
        menu.addItem(disabledMenuItem("OpenAI API（未启用）"))
        menu.addItem(.separator())
        menu.addItem(actionMenuItem("预热当前纠错模型", #selector(warmCurrentCorrectionModel(_:))))
        menu.addItem(actionMenuItem("从内存卸载当前纠错模型", #selector(unloadCurrentCorrectionModel(_:))))
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

        let detailText = task.detail.isEmpty ? "正在准备模型..." : task.detail
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

        return ModelTask(
            status: dict["status"] as? String ?? "idle",
            scope: dict["scope"] as? String ?? "",
            label: dict["label"] as? String ?? "模型任务",
            detail: dict["detail"] as? String ?? "",
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
                error: result.output,
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
                error: "模型扫描结果不可解析",
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
                return OllamaModel(
                    name: name,
                    capabilities: capabilities,
                    needsTest: item["transcription_needs_test"] as? Bool ?? false
                )
            }
        }

        let available = dict["available"] as? Bool ?? false
        let error = dict["error"] as? String ?? ""
        return OllamaScan(
            available: available,
            error: error,
            transcriptionModels: parseModels("transcription_models"),
            correctionModels: parseModels("correction_models")
        )
    }

    private func readLaunchAgentSummary() -> String {
        let label = "com.codexvoice.agent"
        let result = runProcessAndCapture(
            "/bin/launchctl",
            ["print", "gui/\(getuid())/\(label)"]
        )
        if result.exitCode == 0 {
            return "\(label)：已加载"
        }
        return "\(label)：未加载"
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

    private func runModelTask(_ arguments: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let exitCode = self.runProcessAndWait(
                self.pythonPath,
                [self.configHelperPath] + arguments
            )
            self.appendLog(
                "Model task finished: \(arguments.joined(separator: " ")), "
                + "exit=\(exitCode)"
            )
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
            defaultTitle = "系统默认输入（\(defaultName)）"
        } else {
            defaultTitle = "系统默认输入"
        }
        let defaultItem = actionMenuItem(defaultTitle, #selector(selectInputDevice(_:)))
        defaultItem.representedObject = "__default__"
        defaultItem.state = (configured == nil || configured?.isEmpty == true) ? .on : .off
        menu.addItem(defaultItem)

        if devices.isEmpty {
            let emptyItem = disabledMenuItem("未检测到可用麦克风")
            menu.addItem(emptyItem)
            return
        }

        menu.addItem(.separator())
        for device in devices {
            let title = device.isDefault ? "\(device.name)（当前系统默认）" : device.name
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
                isDefault: item["default"] as? Bool ?? false
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "--parent-pid",
            "\(parentPID)",
            "--max-seconds",
            "\(maxSeconds)"
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
                "Codex Voice Agent needs Accessibility permission to send Cmd+V."
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

    private func processNextTrigger() {
        if isProcessingTrigger {
            return
        }

        let directoryURL = URL(fileURLWithPath: triggerDir)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let triggers = urls
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let trigger = triggers.first,
              let mode = consumeTrigger(trigger) else {
            return
        }

        var arguments = ["--toggle"]
        if mode != "normal" {
            arguments.append(contentsOf: ["--mode", mode])
        }
        ensureMicrophonePermissionThenRun(arguments)
    }

    private func ensureMicrophonePermissionThenRun(_ arguments: [String]) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            runVoiceCommandForTrigger(arguments)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.appendLog("Microphone permission before recording granted=\(granted)")
                    if granted {
                        self.runVoiceCommandForTrigger(arguments)
                    } else {
                        self.isProcessingTrigger = false
                    }
                }
            }
        case .denied, .restricted:
            appendLog("Recording blocked because microphone permission is denied or restricted")
            isProcessingTrigger = false
            runProcess(
                "/usr/bin/open",
                ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]
            )
        @unknown default:
            runVoiceCommandForTrigger(arguments)
        }
    }

    private func consumeTrigger(_ url: URL) -> String? {
        let name = url.lastPathComponent
        let mode: String
        if name.hasPrefix("normal.") {
            mode = "normal"
        } else if name.hasPrefix("copy-only.") {
            mode = "copy-only"
        } else if name.hasPrefix("strict.") {
            mode = "strict"
        } else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        do {
            try FileManager.default.removeItem(at: url)
            appendLog("Processing trigger: \(mode)")
            return mode
        } catch {
            appendLog("Could not delete trigger \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    private func runVoiceCommandForTrigger(_ arguments: [String]) {
        isProcessingTrigger = true
        DispatchQueue.global(qos: .utility).async {
            let exitCode = self.runProcessAndWait(
                self.pythonPath,
                [self.voiceScriptPath] + arguments
            )
            DispatchQueue.main.async {
                self.appendLog("Trigger finished: \(arguments.joined(separator: " ")), exit=\(exitCode)")
                self.isProcessingTrigger = false
                self.processNextTrigger()
            }
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

    private func runProcessAndWait(_ executable: String, _ arguments: [String]) -> Int32 {
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
            process.waitUntilExit()
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

final class CodexVoicePanelController: NSViewController {
    var onToggleRecording: (() -> Void)?
    var onSubmitRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onToggleIndicator: (() -> Void)?
    var onRequestMicrophonePermission: (() -> Void)?
    var onRequestPastePermission: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onOpenTranscripts: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSelectTranscriptionModel: ((String) -> Void)?
    var onSelectCorrectionModel: ((String) -> Void)?
    var onSelectInputDevice: ((String) -> Void)?
    var onWarmTranscriptionModel: (() -> Void)?
    var onWarmCorrectionModel: (() -> Void)?
    var onUnloadCorrectionModel: (() -> Void)?
    var onProbeInput: (() -> Void)?
    var onSetMaxMinutes: ((Double) -> Void)?

    private var currentStatus = VoiceStatus(
        status: "idle",
        label: "空闲",
        detail: "",
        pid: nil,
        updatedAt: "",
        isStale: false
    )
    private var currentConfig: [String: Any] = [:]
    private var currentModelTask: ModelTask?
    private var currentInputDevices: [InputDevice] = []
    private var currentTranscriptionModels: [OllamaModel] = []
    private var currentCorrectionModels: [OllamaModel] = []
    private var currentInputProbeResult = "未测试"
    private var inputProbeInFlight = false
    private var scanningModels = false
    private var currentMaintenance = PanelMaintenance(
        pythonPath: "",
        launchAgentStatus: "com.codexvoice.agent",
        ollamaStatus: "正在扫描"
    )
    private var selectedTab = 0

    private let statusDot = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(labelWithString: "空闲")
    private let durationLabel = NSTextField(labelWithString: "录音上限：5 分钟")
    private let stageLabel = NSTextField(labelWithString: "阶段：空闲")
    private let modelTaskLabel = NSTextField(labelWithString: "模型：空闲")
    private let modelTaskDetailLabel = NSTextField(labelWithString: " ")
    private let modelProgress = NSProgressIndicator()
    private let startButton = NSButton(title: "开始", target: nil, action: nil)
    private let submitButton = NSButton(title: "提交", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let indicatorButton = NSButton(checkboxWithTitle: "浮窗", target: nil, action: nil)
    private let routeLabel = NSTextField(labelWithString: "路线：推荐")
    private let transcriptionSummaryLabel = NSTextField(labelWithString: "转录：")
    private let correctionSummaryLabel = NSTextField(labelWithString: "纠错：")
    private let inputSummaryLabel = NSTextField(labelWithString: "输入：")
    private let tabControl = NSSegmentedControl(
        labels: ["转录", "纠错", "输入", "维护"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tabScrollView = NSScrollView()
    private let tabDocumentView = NSView()
    private let tabStack = NSStackView()
    private let maxMinutesLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        root.addArrangedSubview(makeStatusArea())
        root.addArrangedSubview(makeQuickActions())
        root.addArrangedSubview(makeRouteArea())

        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.selectedSegment = selectedTab
        root.addArrangedSubview(tabControl)

        configureTabScrollView()
        root.addArrangedSubview(tabScrollView)
        tabScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true

        root.addArrangedSubview(makeBottomTools())
        refreshAllViews()
    }

    func update(
        status: VoiceStatus,
        config: [String: Any],
        modelTask: ModelTask?,
        inputDevices: [InputDevice],
        transcriptionModels: [OllamaModel],
        correctionModels: [OllamaModel],
        inputProbeResult: String,
        isInputProbeInFlight: Bool,
        isScanningModels: Bool,
        maintenance: PanelMaintenance
    ) {
        currentStatus = status
        currentConfig = config
        currentModelTask = modelTask
        currentInputDevices = inputDevices
        currentTranscriptionModels = transcriptionModels
        currentCorrectionModels = correctionModels
        currentInputProbeResult = inputProbeResult
        inputProbeInFlight = isInputProbeInFlight
        scanningModels = isScanningModels
        currentMaintenance = maintenance
        if isViewLoaded {
            refreshAllViews()
        }
    }

    private func makeStatusArea() -> NSView {
        let container = verticalStack(spacing: 6)

        let row = horizontalStack(spacing: 8)
        statusDot.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        statusLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        row.addArrangedSubview(statusDot)
        row.addArrangedSubview(statusLabel)
        row.addArrangedSubview(makeFlexibleSpacer())
        row.addArrangedSubview(durationLabel)
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        container.addArrangedSubview(row)

        stageLabel.font = NSFont.systemFont(ofSize: 12)
        stageLabel.textColor = .secondaryLabelColor
        stageLabel.lineBreakMode = .byTruncatingMiddle
        container.addArrangedSubview(stageLabel)

        modelTaskLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modelTaskLabel.lineBreakMode = .byTruncatingMiddle
        container.addArrangedSubview(modelTaskLabel)

        modelTaskDetailLabel.font = NSFont.systemFont(ofSize: 11)
        modelTaskDetailLabel.textColor = .secondaryLabelColor
        modelTaskDetailLabel.lineBreakMode = .byTruncatingMiddle
        container.addArrangedSubview(modelTaskDetailLabel)

        modelProgress.style = .bar
        modelProgress.controlSize = .small
        modelProgress.minValue = 0
        modelProgress.maxValue = 1
        modelProgress.usesThreadedAnimation = true
        container.addArrangedSubview(modelProgress)
        return container
    }

    private func makeQuickActions() -> NSView {
        let row = horizontalStack(spacing: 8)
        startButton.target = self
        startButton.action = #selector(startClicked(_:))
        submitButton.target = self
        submitButton.action = #selector(submitClicked(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        indicatorButton.target = self
        indicatorButton.action = #selector(indicatorClicked(_:))
        for button in [startButton, submitButton, cancelButton, indicatorButton] {
            button.bezelStyle = .rounded
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(button)
        }
        return row
    }

    private func makeRouteArea() -> NSView {
        let stack = verticalStack(spacing: 3)
        for label in [routeLabel, transcriptionSummaryLabel, correctionSummaryLabel, inputSummaryLabel] {
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            stack.addArrangedSubview(label)
        }
        return stack
    }

    private func configureTabScrollView() {
        tabScrollView.hasVerticalScroller = true
        tabScrollView.drawsBackground = false
        tabScrollView.borderType = .noBorder
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabDocumentView.frame = NSRect(x: 0, y: 0, width: 392, height: 260)
        tabScrollView.documentView = tabDocumentView

        tabStack.orientation = .vertical
        tabStack.spacing = 10
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabDocumentView.addSubview(tabStack)
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: tabDocumentView.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: tabDocumentView.trailingAnchor, constant: -8),
            tabStack.topAnchor.constraint(equalTo: tabDocumentView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabDocumentView.bottomAnchor)
        ])
    }

    private func makeBottomTools() -> NSView {
        let stack = horizontalStack(spacing: 6)
        let items: [(String, Selector)] = [
            ("麦克风", #selector(microphoneClicked(_:))),
            ("粘贴", #selector(pasteClicked(_:))),
            ("记录", #selector(transcriptsClicked(_:))),
            ("日志", #selector(logClicked(_:))),
            ("配置", #selector(configClicked(_:)))
        ]
        for item in items {
            let button = NSButton(title: item.0, target: self, action: item.1)
            button.bezelStyle = .rounded
            button.controlSize = .small
            stack.addArrangedSubview(button)
        }
        stack.distribution = .fillEqually
        return stack
    }

    private func refreshAllViews() {
        refreshStatusArea()
        refreshQuickActions()
        refreshRouteArea()
        rebuildCurrentTab()
    }

    private func refreshStatusArea() {
        statusDot.textColor = colorForStatus(currentStatus.status, stale: currentStatus.isStale)
        statusLabel.stringValue = currentStatus.label
        durationLabel.stringValue = durationText()

        let stageDetail = currentStatus.detail.isEmpty ? currentStatus.label : currentStatus.detail
        stageLabel.stringValue = "阶段：\(stageDetail)"

        guard let task = currentModelTask else {
            modelTaskLabel.stringValue = "模型：空闲"
            modelTaskDetailLabel.stringValue = " "
            setProgress(value: 0, indeterminate: false)
            return
        }

        let statusText: String
        switch task.status {
        case "running": statusText = "运行中"
        case "succeeded": statusText = "已完成"
        case "failed": statusText = "失败"
        default: statusText = task.status
        }
        modelTaskLabel.stringValue = "模型：\(statusText) · \(task.label)"
        modelTaskDetailLabel.stringValue = task.detail.isEmpty ? " " : task.detail
        if task.status == "running", task.progress == nil {
            setProgress(value: nil, indeterminate: true)
        } else {
            setProgress(value: task.progress ?? (task.status == "succeeded" ? 1 : 0), indeterminate: false)
        }
    }

    private func refreshQuickActions() {
        let canControlRecording = currentStatus.status == "recording" || currentStatus.status == "submitting"
        let busyAfterRecording = ["transcribing", "correcting", "finalizing"].contains(currentStatus.status)
        startButton.isEnabled = !canControlRecording && !busyAfterRecording
        submitButton.isEnabled = canControlRecording
        cancelButton.isEnabled = canControlRecording
        indicatorButton.state = configBool("recording_indicator", defaultValue: true) ? .on : .off
    }

    private func refreshRouteArea() {
        let setup = stringConfig("setup_profile", defaultValue: "recommended")
        routeLabel.stringValue = setup == "custom" ? "路线：自定义路线" : "路线：推荐路线"
        transcriptionSummaryLabel.stringValue = "转录：\(transcriptionLabel())"
        correctionSummaryLabel.stringValue = "纠错：\(correctionLabel())"
        inputSummaryLabel.stringValue = "输入：\(inputLabel())"
    }

    private func rebuildCurrentTab() {
        tabControl.selectedSegment = selectedTab
        tabStack.arrangedSubviews.forEach { view in
            tabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch selectedTab {
        case 0:
            buildTranscriptionTab()
        case 1:
            buildCorrectionTab()
        case 2:
            buildInputTab()
        default:
            buildMaintenanceTab()
        }

        tabStack.layoutSubtreeIfNeeded()
        let fittingHeight = max(250, tabStack.fittingSize.height)
        tabDocumentView.setFrameSize(NSSize(width: 392, height: fittingHeight))
    }

    private func buildTranscriptionTab() {
        let profile = transcriptionProfile()
        let selectedOllama = stringConfig("ollama_transcription_model", defaultValue: "")

        let builtin = columnStack(title: "内置")
        builtin.addArrangedSubview(choiceButton(
            title: "MLX Whisper large-v3-turbo",
            value: "profile:mlx-whisper-turbo",
            selected: profile == "mlx-whisper-turbo",
            action: #selector(transcriptionChoiceClicked(_:))
        ))
        builtin.addArrangedSubview(choiceButton(
            title: "faster-whisper large-v3-turbo",
            value: "profile:faster-whisper-turbo",
            selected: profile == "faster-whisper-turbo",
            action: #selector(transcriptionChoiceClicked(_:))
        ))

        let ollama = columnStack(title: "Ollama")
        if scanningModels {
            ollama.addArrangedSubview(secondaryText("正在扫描..."))
        } else if currentTranscriptionModels.isEmpty {
            ollama.addArrangedSubview(secondaryText("未检测到转录模型"))
        } else {
            for model in currentTranscriptionModels {
                let suffix = model.needsTest ? "（需测试）" : ""
                ollama.addArrangedSubview(choiceButton(
                    title: "\(model.name)\(suffix)",
                    value: "ollama:\(model.name)",
                    selected: profile == "ollama-transcription" && selectedOllama == model.name,
                    action: #selector(transcriptionChoiceClicked(_:))
                ))
            }
        }

        let external = columnStack(title: "在线 API")
        external.addArrangedSubview(disabledButton("OpenAI API（未启用）"))

        tabStack.addArrangedSubview(columns([builtin, ollama, external]))
        tabStack.addArrangedSubview(actionRow([
            ("预热当前转录模型", #selector(warmTranscriptionClicked(_:)))
        ]))
    }

    private func buildCorrectionTab() {
        let profile = correctionProfile()
        let selectedOllama = stringConfig("ollama_model", defaultValue: "")

        let builtin = columnStack(title: "内置")
        builtin.addArrangedSubview(choiceButton(
            title: "规则纠错（不使用 LLM）",
            value: "profile:rule-only",
            selected: profile == "rule-only",
            action: #selector(correctionChoiceClicked(_:))
        ))

        let ollama = columnStack(title: "Ollama")
        if scanningModels {
            ollama.addArrangedSubview(secondaryText("正在扫描..."))
        } else if currentCorrectionModels.isEmpty {
            ollama.addArrangedSubview(secondaryText("未检测到纠错模型"))
        } else {
            for model in currentCorrectionModels {
                ollama.addArrangedSubview(choiceButton(
                    title: model.name,
                    value: "ollama:\(model.name)",
                    selected: profile == "ollama-correction" && selectedOllama == model.name,
                    action: #selector(correctionChoiceClicked(_:))
                ))
            }
        }

        let external = columnStack(title: "在线 API")
        external.addArrangedSubview(disabledButton("OpenAI API（未启用）"))

        tabStack.addArrangedSubview(columns([builtin, ollama, external]))
        tabStack.addArrangedSubview(actionRow([
            ("预热当前纠错模型", #selector(warmCorrectionClicked(_:))),
            ("从内存卸载", #selector(unloadCorrectionClicked(_:)))
        ]))
    }

    private func buildInputTab() {
        let stack = verticalStack(spacing: 8)
        let configured = currentConfig["input_device"] as? String
        let defaultName = currentInputDevices.first(where: { $0.isDefault })?.name
        let defaultTitle: String
        if let defaultName, !defaultName.isEmpty {
            defaultTitle = "系统默认输入（\(defaultName)）"
        } else {
            defaultTitle = "系统默认输入"
        }
        stack.addArrangedSubview(choiceButton(
            title: defaultTitle,
            value: "__default__",
            selected: configured == nil || configured?.isEmpty == true,
            action: #selector(inputChoiceClicked(_:))
        ))

        if currentInputDevices.isEmpty {
            stack.addArrangedSubview(secondaryText(scanningModels ? "正在扫描输入设备..." : "未检测到可用麦克风"))
        } else {
            for device in currentInputDevices {
                let title = device.isDefault ? "\(device.name)（当前系统默认）" : device.name
                stack.addArrangedSubview(choiceButton(
                    title: title,
                    value: device.name,
                    selected: configured == device.name,
                    action: #selector(inputChoiceClicked(_:))
                ))
            }
        }

        let probeRow = horizontalStack(spacing: 8)
        let probeButton = NSButton(
            title: inputProbeInFlight ? "测试中" : "测试输入",
            target: self,
            action: #selector(probeInputClicked(_:))
        )
        probeButton.bezelStyle = .rounded
        probeButton.isEnabled = !inputProbeInFlight
        probeRow.addArrangedSubview(probeButton)
        let probeLabel = secondaryText(currentInputProbeResult)
        probeLabel.lineBreakMode = .byTruncatingMiddle
        probeRow.addArrangedSubview(probeLabel)
        stack.addArrangedSubview(probeRow)

        let maxRow = horizontalStack(spacing: 8)
        let maxSeconds = configDouble(
            "background_max_record_seconds",
            defaultValue: configDouble("max_record_seconds", defaultValue: 300)
        )
        let minutes = max(1, min(10, round(maxSeconds / 60)))
        maxMinutesLabel.stringValue = "录音上限：\(Int(minutes)) 分钟"
        maxMinutesLabel.font = NSFont.systemFont(ofSize: 12)
        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 10
        stepper.increment = 1
        stepper.doubleValue = minutes
        stepper.target = self
        stepper.action = #selector(maxMinutesChanged(_:))
        maxRow.addArrangedSubview(maxMinutesLabel)
        maxRow.addArrangedSubview(stepper)
        maxRow.addArrangedSubview(makeFlexibleSpacer())
        stack.addArrangedSubview(maxRow)

        tabStack.addArrangedSubview(stack)
    }

    private func buildMaintenanceTab() {
        let stack = verticalStack(spacing: 7)
        stack.addArrangedSubview(infoLine("Conda", currentMaintenance.pythonPath))
        stack.addArrangedSubview(infoLine("LaunchAgent", currentMaintenance.launchAgentStatus))
        stack.addArrangedSubview(infoLine("Ollama", currentMaintenance.ollamaStatus))
        if let task = currentModelTask {
            let detail = task.detail.isEmpty ? task.status : "\(task.status) · \(task.detail)"
            stack.addArrangedSubview(infoLine("模型任务", "\(task.label) · \(detail)"))
        } else {
            stack.addArrangedSubview(infoLine("模型任务", "空闲"))
        }
        stack.addArrangedSubview(secondaryText("当前只有一个 LaunchAgent：com.codexvoice.agent"))
        stack.addArrangedSubview(actionRow([
            ("打开日志", #selector(logClicked(_:))),
            ("打开转录记录", #selector(transcriptsClicked(_:))),
            ("打开配置", #selector(configClicked(_:)))
        ]))
        stack.addArrangedSubview(actionRow([
            ("退出 Agent", #selector(quitClicked(_:)))
        ]))
        tabStack.addArrangedSubview(stack)
    }

    private func columns(_ stacks: [NSStackView]) -> NSView {
        let row = horizontalStack(spacing: 10)
        row.distribution = .fillEqually
        for stack in stacks {
            row.addArrangedSubview(stack)
        }
        return row
    }

    private func columnStack(title: String) -> NSStackView {
        let stack = verticalStack(spacing: 6)
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(label)
        return stack
    }

    private func actionRow(_ items: [(String, Selector)]) -> NSView {
        let row = horizontalStack(spacing: 8)
        for item in items {
            let button = NSButton(title: item.0, target: self, action: item.1)
            button.bezelStyle = .rounded
            button.controlSize = .small
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(makeFlexibleSpacer())
        return row
    }

    private func choiceButton(
        title: String,
        value: String,
        selected: Bool,
        action: Selector
    ) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(value)
        button.state = selected ? .on : .off
        button.toolTip = title
        button.font = NSFont.systemFont(ofSize: 11)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = button.cell as? NSButtonCell {
            cell.lineBreakMode = .byTruncatingMiddle
        }
        return button
    }

    private func disabledButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isEnabled = false
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        return button
    }

    private func infoLine(_ name: String, _ value: String) -> NSView {
        let row = horizontalStack(spacing: 8)
        let nameLabel = NSTextField(labelWithString: "\(name)：")
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
        let valueLabel = secondaryText(value)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func secondaryText(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func horizontalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func setProgress(value: Double?, indeterminate: Bool) {
        if indeterminate {
            modelProgress.isIndeterminate = true
            modelProgress.startAnimation(nil)
            return
        }
        modelProgress.stopAnimation(nil)
        modelProgress.isIndeterminate = false
        if let value {
            modelProgress.doubleValue = max(0, min(1, value))
        } else {
            modelProgress.doubleValue = 0
        }
    }

    private func durationText() -> String {
        let maxSeconds = configDouble(
            "background_max_record_seconds",
            defaultValue: configDouble("max_record_seconds", defaultValue: 300)
        )
        let maxText = formatDuration(maxSeconds)
        if currentStatus.status == "recording" || currentStatus.status == "submitting" {
            let elapsed = elapsedSeconds(from: currentStatus.updatedAt)
            return "录音：\(formatDuration(elapsed)) / \(maxText)"
        }
        return "上限：\(maxText)"
    }

    private func elapsedSeconds(from text: String) -> Double {
        guard let date = parseStatusDate(text) else {
            return 0
        }
        return max(0, Date().timeIntervalSince(date))
    }

    private func parseStatusDate(_ text: String) -> Date? {
        if text.isEmpty {
            return nil
        }
        if let date = ISO8601DateFormatter().date(from: text) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remaining = total % 60
        return String(format: "%d:%02d", minutes, remaining)
    }

    private func colorForStatus(_ status: String, stale: Bool) -> NSColor {
        if stale {
            return .black
        }
        switch status {
        case "recording":
            return .systemGreen
        case "submitting", "transcribing", "correcting", "finalizing":
            return .systemYellow
        case "error":
            return .systemRed
        default:
            return .black
        }
    }

    private func transcriptionProfile() -> String {
        if let profile = currentConfig["transcription_profile"] as? String, !profile.isEmpty {
            return profile
        }
        let backend = stringConfig("whisper_backend", defaultValue: "mlx-whisper")
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

    private func correctionProfile() -> String {
        if let profile = currentConfig["correction_profile"] as? String, !profile.isEmpty {
            return profile
        }
        let backend = stringConfig("correction_backend", defaultValue: "ollama")
        if backend == "ollama" {
            return "ollama-correction"
        }
        if backend == "rule-only" || backend == "none" {
            return "rule-only"
        }
        return backend
    }

    private func transcriptionLabel() -> String {
        switch transcriptionProfile() {
        case "mlx-whisper-turbo":
            return "MLX Whisper large-v3-turbo"
        case "faster-whisper-turbo":
            return "faster-whisper large-v3-turbo"
        case "ollama-transcription":
            let model = stringConfig("ollama_transcription_model", defaultValue: "")
            return model.isEmpty ? "Ollama 转录模型未选择" : "Ollama · \(model)"
        default:
            let backend = stringConfig("whisper_backend", defaultValue: "mlx-whisper")
            let model = stringConfig("whisper_model", defaultValue: "")
            return model.isEmpty ? backend : "\(backend) · \(model)"
        }
    }

    private func correctionLabel() -> String {
        switch correctionProfile() {
        case "rule-only":
            return "规则纠错"
        case "ollama-correction":
            let model = stringConfig("ollama_model", defaultValue: "")
            return model.isEmpty ? "Ollama 纠错模型未选择" : "Ollama · \(model)"
        default:
            return stringConfig("correction_backend", defaultValue: "规则纠错")
        }
    }

    private func inputLabel() -> String {
        if let configured = currentConfig["input_device"] as? String, !configured.isEmpty {
            return configured
        }
        if let defaultName = currentInputDevices.first(where: { $0.isDefault })?.name,
           !defaultName.isEmpty {
            return "系统默认输入（\(defaultName)）"
        }
        return "系统默认输入"
    }

    private func configBool(_ key: String, defaultValue: Bool) -> Bool {
        if let bool = currentConfig[key] as? Bool {
            return bool
        }
        return defaultValue
    }

    private func configDouble(_ key: String, defaultValue: Double) -> Double {
        if let number = currentConfig[key] as? NSNumber {
            return number.doubleValue
        }
        if let value = currentConfig[key] as? Double {
            return value
        }
        return defaultValue
    }

    private func stringConfig(_ key: String, defaultValue: String) -> String {
        if let text = currentConfig[key] as? String, !text.isEmpty {
            return text
        }
        return defaultValue
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectedTab = sender.selectedSegment
        rebuildCurrentTab()
    }

    @objc private func startClicked(_ sender: Any?) {
        onToggleRecording?()
    }

    @objc private func submitClicked(_ sender: Any?) {
        onSubmitRecording?()
    }

    @objc private func cancelClicked(_ sender: Any?) {
        onCancelRecording?()
    }

    @objc private func indicatorClicked(_ sender: Any?) {
        onToggleIndicator?()
    }

    @objc private func transcriptionChoiceClicked(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else {
            return
        }
        onSelectTranscriptionModel?(value)
    }

    @objc private func correctionChoiceClicked(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else {
            return
        }
        onSelectCorrectionModel?(value)
    }

    @objc private func inputChoiceClicked(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else {
            return
        }
        onSelectInputDevice?(value)
    }

    @objc private func warmTranscriptionClicked(_ sender: Any?) {
        onWarmTranscriptionModel?()
    }

    @objc private func warmCorrectionClicked(_ sender: Any?) {
        onWarmCorrectionModel?()
    }

    @objc private func unloadCorrectionClicked(_ sender: Any?) {
        onUnloadCorrectionModel?()
    }

    @objc private func probeInputClicked(_ sender: Any?) {
        onProbeInput?()
    }

    @objc private func maxMinutesChanged(_ sender: NSStepper) {
        maxMinutesLabel.stringValue = "录音上限：\(Int(sender.doubleValue)) 分钟"
        onSetMaxMinutes?(sender.doubleValue)
    }

    @objc private func microphoneClicked(_ sender: Any?) {
        onRequestMicrophonePermission?()
    }

    @objc private func pasteClicked(_ sender: Any?) {
        onRequestPastePermission?()
    }

    @objc private func transcriptsClicked(_ sender: Any?) {
        onOpenTranscripts?()
    }

    @objc private func logClicked(_ sender: Any?) {
        onOpenLog?()
    }

    @objc private func configClicked(_ sender: Any?) {
        onOpenConfig?()
    }

    @objc private func quitClicked(_ sender: Any?) {
        onQuit?()
    }
}

let app = NSApplication.shared
let delegate = CodexVoiceAgent()
app.delegate = delegate
app.run()

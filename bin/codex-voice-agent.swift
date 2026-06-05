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
    let channels: Int?
    let index: Int?
}

struct OllamaModel {
    let name: String
    let capabilities: [String]
    let needsTest: Bool
    let loaded: Bool
    let size: Int64?
    let family: String
    let families: [String]
    let parameterSize: String
    let quantization: String
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
    let status: String
    let error: String
    let baseURL: String
    let configuredCorrectionModel: String
    let configuredCorrectionModelInstalled: Bool
    let configuredCorrectionModelLoaded: Bool
    let transcriptionModels: [OllamaModel]
    let correctionModels: [OllamaModel]
}

struct PanelMaintenance {
    let pythonPath: String
    let launchAgentStatus: String
    let ollamaStatus: String
    let ollamaStatusCode: String
    let ollamaBaseURL: String
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
    private var autoPreparingCorrectionModel = false
    private var lastAutoPreparedCorrectionModel = ""
    private var lastInputProbeResult = "未测试"
    private var isPanelScanInFlight = false
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
        controller.onUnloadOllamaModel = { [weak self] model in
            self?.unloadOllamaModel(model)
        }
        controller.onProbeInput = { [weak self] in
            self?.runInputProbeForPanel()
        }
        controller.onSetMaxMinutes = { [weak self] minutes in
            self?.setMaxRecordingMinutes(minutes)
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
            ollamaStatus: "正在扫描",
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
            inputProbeResult: lastInputProbeResult,
            isInputProbeInFlight: isInputProbeInFlight,
            isScanningModels: isPanelScanInFlight,
            maintenance: maintenance
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
            let devices = self.readInputDevices()
            let scan = self.readOllamaScan()
            let launchStatus = self.readLaunchAgentSummary()
            let ollamaStatus: String
            if scan.available {
                ollamaStatus = scan.baseURL.isEmpty ? "可用" : "可用：\(scan.baseURL)"
            } else if scan.status == "ollama_not_installed" {
                ollamaStatus = "Ollama 未安装"
            } else if scan.status == "service_unavailable" {
                ollamaStatus = scan.error.isEmpty ? "服务未就绪" : "服务未就绪：\(scan.error)"
            } else if scan.error.isEmpty {
                ollamaStatus = "不可用"
            } else {
                ollamaStatus = "不可用：\(scan.error)"
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
                error: "模型扫描结果不可解析",
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
        if autoPreparingCorrectionModel || lastAutoPreparedCorrectionModel == model {
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

private func dragEnclosingHorizontalScrollView(from view: NSView, event: NSEvent) -> Bool {
    guard let scrollView = view.enclosingScrollView,
          let window = view.window else {
        return false
    }

    let startLocation = event.locationInWindow
    let startOrigin = scrollView.contentView.bounds.origin
    var didDrag = false
    var shouldContinue = true

    while shouldContinue {
        guard let nextEvent = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) else {
            break
        }

        switch nextEvent.type {
        case .leftMouseDragged:
            let deltaX = nextEvent.locationInWindow.x - startLocation.x
            if abs(deltaX) > 3 {
                didDrag = true
            }
            if didDrag {
                let documentWidth = scrollView.documentView?.bounds.width ?? 0
                let visibleWidth = scrollView.contentView.bounds.width
                let maxX = max(0, documentWidth - visibleWidth)
                let nextX = min(max(startOrigin.x - deltaX, 0), maxX)
                scrollView.contentView.scroll(to: NSPoint(x: nextX, y: startOrigin.y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        case .leftMouseUp:
            shouldContinue = false
        default:
            break
        }
    }

    return didDrag
}

final class CircleControl: NSControl {
    var fillColor: NSColor {
        didSet {
            needsDisplay = true
        }
    }

    private let diameter: CGFloat

    init(color: NSColor, diameter: CGFloat) {
        fillColor = color
        self.diameter = diameter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        fillColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        if let target, let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}

final class CardCloseButton: NSControl {
    private var pressed = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "卸载模型"
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let diameter = min(bounds.width, bounds.height)
        let rect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        ).insetBy(dx: 1, dy: 1)
        let fill = pressed
            ? NSColor.systemRed
            : NSColor(calibratedRed: 0.95, green: 0.22, blue: 0.20, alpha: 0.82)
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        let inset = rect.width * 0.32
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        pressed = true
        needsDisplay = true
        defer {
            pressed = false
            needsDisplay = true
        }

        guard let window,
              let nextEvent = window.nextEvent(matching: [.leftMouseUp]) else {
            return
        }
        let location = convert(nextEvent.locationInWindow, from: nil)
        guard bounds.contains(location) else {
            return
        }
        if let target, let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}

final class AudioWaveformView: NSView {
    private var levels = Array(repeating: CGFloat(0.08), count: 64)
    private var timer: Timer?
    private var active = false
    private var targetLevel = CGFloat(0.28)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ isActive: Bool, level: CGFloat) {
        active = isActive
        targetLevel = max(0.06, min(1.0, level))
        if active {
            startTimerIfNeeded()
        } else {
            stopTimer()
            levels = levels.map { max(0.04, $0 * 0.72) }
            needsDisplay = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTimer()
        } else if active {
            startTimerIfNeeded()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else {
            return
        }
        let timer = Timer(timeInterval: 0.075, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pulse = CGFloat.random(in: 0.45...1.0)
        let floor = CGFloat.random(in: 0.03...0.13)
        let next = max(floor, min(1.0, targetLevel * pulse + floor))
        levels.removeFirst()
        levels.append(next)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let count = max(1, levels.count)
        let gap = CGFloat(2)
        let barWidth = max(2, (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count))
        let midY = bounds.midY
        let color = active
            ? NSColor(calibratedRed: 0.38, green: 1.0, blue: 0.55, alpha: 0.88)
            : NSColor(calibratedWhite: 0.45, alpha: 0.42)
        color.setFill()

        for (index, level) in levels.enumerated() {
            let height = max(2, min(bounds.height - 2, level * (bounds.height - 2)))
            let x = CGFloat(index) * (barWidth + gap)
            let rect = NSRect(
                x: x,
                y: midY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

final class CardChoiceView: NSControl {
    private enum Metrics {
        static let topPadding: CGFloat = 6
        static let bottomPadding: CGFloat = 6
        static let sidePadding: CGFloat = 12
        static let contentSpacing: CGFloat = 2
        static let titleDetailsSpacing: CGFloat = 4
    }

    private let sourceLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private let unloadButton = CardCloseButton()
    private let loadingOverlay = NSView()
    private let loadingLabel = NSTextField(labelWithString: "正在加载")
    private let loadingDetailLabel = NSTextField(labelWithString: " ")
    private let loadingProgress = NSProgressIndicator()
    private var uniformHeightConstraint: NSLayoutConstraint?
    private(set) var isSelectedCard = false

    init(
        source: String,
        title: String,
        rows: [(String, String)],
        selected: Bool,
        enabled: Bool,
        width: CGFloat
    ) {
        super.init(frame: .zero)
        isSelectedCard = selected
        isEnabled = enabled
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setCardStyle(selected: selected, enabled: enabled)
        toolTip = ([source, title] + rows.map { "\($0.0)：\($0.1)" }).joined(separator: "\n")

        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        contentStack.orientation = .vertical
        contentStack.spacing = Metrics.contentSpacing
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sidePadding),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.sidePadding),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topPadding),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomPadding)
        ])

        sourceLabel.stringValue = source
        sourceLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        sourceLabel.textColor = selected
            ? NSColor(calibratedRed: 0.76, green: 1.0, blue: 0.82, alpha: 1)
            : NSColor(calibratedWhite: enabled ? 0.72 : 0.48, alpha: 1)
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
        contentStack.addArrangedSubview(sourceLabel)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: enabled ? 0.96 : 0.58, alpha: 1)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(Metrics.titleDetailsSpacing, after: titleLabel)

        let gridRows = rows.map { row -> [NSView] in
            let key = NSTextField(labelWithString: row.0)
            key.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            key.textColor = NSColor(calibratedWhite: enabled ? 0.62 : 0.42, alpha: 1)
            key.alignment = .right
            key.widthAnchor.constraint(equalToConstant: 30).isActive = true

            let value = NSTextField(labelWithString: row.1)
            value.font = NSFont.systemFont(ofSize: 9)
            value.textColor = NSColor(calibratedWhite: enabled ? 0.84 : 0.50, alpha: 1)
            value.lineBreakMode = .byTruncatingMiddle
            value.maximumNumberOfLines = 1
            value.widthAnchor.constraint(equalToConstant: width - 70).isActive = true
            return [key, value]
        }

        let gridView = NSGridView(views: gridRows)
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.rowSpacing = 1
        gridView.columnSpacing = 6
        gridView.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
        contentStack.addArrangedSubview(gridView)

        configureUnloadButton()
        configureLoadingOverlay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        if dragEnclosingHorizontalScrollView(from: self, event: event) {
            return
        }
        guard isEnabled else {
            return
        }
        if let target, let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    func naturalHeight() -> CGFloat {
        contentStack.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.arrangedSubviews.reduce(CGFloat.zero) { height, view in
            view.layoutSubtreeIfNeeded()
            return height + view.fittingSize.height
        }
        return ceil(
            contentHeight
                + Metrics.contentSpacing
                + Metrics.titleDetailsSpacing
                + Metrics.topPadding
                + Metrics.bottomPadding
        )
    }

    func applyUniformHeight(_ height: CGFloat) {
        let height = ceil(height)
        if let uniformHeightConstraint {
            uniformHeightConstraint.constant = height
        } else {
            let constraint = heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            uniformHeightConstraint = constraint
        }
    }

    func setLoadingTask(_ task: ModelTask?) {
        guard let task else {
            loadingProgress.stopAnimation(nil)
            loadingOverlay.isHidden = true
            return
        }

        loadingOverlay.isHidden = false
        loadingLabel.stringValue = task.label.isEmpty ? "正在准备模型" : task.label
        loadingDetailLabel.stringValue = task.detail.isEmpty ? "正在加载到内存" : task.detail

        if let progress = task.progress {
            loadingProgress.stopAnimation(nil)
            loadingProgress.isIndeterminate = false
            loadingProgress.minValue = 0
            loadingProgress.maxValue = 1
            loadingProgress.doubleValue = max(0, min(1, progress))
        } else {
            loadingProgress.isIndeterminate = true
            loadingProgress.startAnimation(nil)
        }
    }

    func setUnloadAction(value: String, target: AnyObject?, action: Selector) {
        unloadButton.identifier = NSUserInterfaceItemIdentifier(value)
        unloadButton.target = target
        unloadButton.action = action
        unloadButton.isHidden = false
    }

    private func setCardStyle(selected: Bool, enabled: Bool) {
        let background: NSColor
        let border: NSColor
        if selected {
            background = NSColor(calibratedRed: 0.05, green: 0.62, blue: 0.25, alpha: 0.30)
            border = NSColor(calibratedRed: 0.35, green: 1.0, blue: 0.52, alpha: 0.78)
        } else if enabled {
            background = NSColor(calibratedWhite: 0.035, alpha: 0.94)
            border = NSColor(calibratedWhite: 0.24, alpha: 0.78)
        } else {
            background = NSColor(calibratedWhite: 0.08, alpha: 0.78)
            border = NSColor(calibratedWhite: 0.18, alpha: 0.66)
        }
        layer?.backgroundColor = background.usingColorSpace(.deviceRGB)?.cgColor
        layer?.borderColor = border.usingColorSpace(.deviceRGB)?.cgColor
        layer?.borderWidth = selected ? 1.5 : 1
    }

    private func configureUnloadButton() {
        unloadButton.isHidden = true
        addSubview(unloadButton)
        NSLayoutConstraint.activate([
            unloadButton.widthAnchor.constraint(equalToConstant: 15),
            unloadButton.heightAnchor.constraint(equalToConstant: 15),
            unloadButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            unloadButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }

    private func configureLoadingOverlay() {
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.wantsLayer = true
        loadingOverlay.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.12,
            alpha: 0.82
        ).usingColorSpace(.deviceRGB)?.cgColor
        loadingOverlay.layer?.cornerRadius = 8
        loadingOverlay.isHidden = true
        addSubview(loadingOverlay)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(stack)

        loadingLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        loadingLabel.textColor = .white
        loadingLabel.lineBreakMode = .byTruncatingMiddle
        loadingDetailLabel.font = NSFont.systemFont(ofSize: 9)
        loadingDetailLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        loadingDetailLabel.lineBreakMode = .byTruncatingMiddle

        loadingProgress.style = .bar
        loadingProgress.controlSize = .small
        loadingProgress.widthAnchor.constraint(equalToConstant: 160).isActive = true

        stack.addArrangedSubview(loadingLabel)
        stack.addArrangedSubview(loadingDetailLabel)
        stack.addArrangedSubview(loadingProgress)

        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: loadingOverlay.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: loadingOverlay.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor)
        ])
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        _ = dragEnclosingHorizontalScrollView(from: self, event: event)
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
    var onUnloadOllamaModel: ((String) -> Void)?
    var onProbeInput: (() -> Void)?
    var onSetMaxMinutes: ((Double) -> Void)?
    var onPreferredContentSizeChange: ((NSSize) -> Void)?

    private enum Metrics {
        static let panelWidth: CGFloat = 520
        static let contentWidth: CGFloat = 492
        static let cardSpacing: CGFloat = 10
        static let cardScrollerInset: CGFloat = 10
        static let cardScrollerTopInset: CGFloat = 3
        static let cardScrollerBottomInset: CGFloat = 3
        static let modelCardWidth: CGFloat = 231
        static let inputCardWidth: CGFloat = 231
        static let cardViewportWidth: CGFloat = cardScrollerInset * 2 + cardSpacing + modelCardWidth * 2
        static let tabDocumentWidth: CGFloat = contentWidth
        static let tabInnerWidth: CGFloat = contentWidth
        static let routeLabelWidth: CGFloat = 54
        static let maintenanceLabelWidth: CGFloat = 86
    }

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
        ollamaStatus: "正在扫描",
        ollamaStatusCode: "scanning",
        ollamaBaseURL: ""
    )

    private var transcriptionSignature = ""
    private var correctionSignature = ""
    private var inputSignature = ""

    private var inputTestActive = false
    private var selectedTabIndex = 0
    private var tabContainerHeightConstraint: NSLayoutConstraint?
    private var transcriptionCardScrollerHeightConstraint: NSLayoutConstraint?
    private var correctionCardScrollerHeightConstraint: NSLayoutConstraint?
    private var inputCardScrollerHeightConstraint: NSLayoutConstraint?
    private var rootStack: NSStackView?

    private let statusDot = CircleControl(color: .white, diameter: 9)
    private let statusLabel = NSTextField(labelWithString: "空闲")
    private let durationLabel = NSTextField(labelWithString: "0:00 /")
    private let maxMinutesPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stageLabel = NSTextField(labelWithString: "阶段：空闲")
    private let modelTaskLabel = NSTextField(labelWithString: "模型：空闲")
    private let modelTaskDetailLabel = NSTextField(labelWithString: " ")
    private let modelProgress = NSProgressIndicator()
    private let waveformView = AudioWaveformView()
    private let quitButton = CircleControl(color: .systemRed, diameter: 11)

    private let startButton = NSButton(title: "开始", target: nil, action: nil)
    private let submitButton = NSButton(title: "提交", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let indicatorButton = NSButton(title: "", target: nil, action: nil)

    private let stateValueLabel = NSTextField(labelWithString: "空闲")
    private let transcriptionValueLabel = NSTextField(labelWithString: "")
    private let correctionValueLabel = NSTextField(labelWithString: "")
    private let inputValueLabel = NSTextField(labelWithString: "")

    private let tabContainer = NSView()
    private let tabControl = NSSegmentedControl(
        labels: ["转录模型", "纠错模型", "输入设备"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let transcriptionDocument = NSView()
    private let correctionDocument = NSView()
    private let inputDocument = NSView()

    private let transcriptionContentStack = NSStackView()
    private let correctionContentStack = NSStackView()
    private let inputContentStack = NSStackView()

    private let transcriptionCardsDocument = FlippedDocumentView()
    private let transcriptionCardsStack = NSStackView()
    private let correctionCardsDocument = FlippedDocumentView()
    private let correctionCardsStack = NSStackView()
    private let inputCardsDocument = FlippedDocumentView()
    private let inputCardsStack = NSStackView()

    private let probeButton = NSButton(title: "测试输入", target: nil, action: nil)
    private let probeResultLabel = NSTextField(labelWithString: "未测试")
    private let maxMinutesLabel = NSTextField(labelWithString: "录音上限：5 分钟")
    private let maxMinutesStepper = NSStepper()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 1))
        preferredContentSize = NSSize(width: Metrics.panelWidth, height: 1)

        let root = verticalStack(spacing: 6)
        rootStack = root
        root.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 14)
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor)
        ])

        let statusArea = makeStatusArea()
        root.addArrangedSubview(statusArea)
        root.setCustomSpacing(0, after: statusArea)
        root.addArrangedSubview(separator())
        root.addArrangedSubview(makeQuickActions())
        root.addArrangedSubview(separator())
        root.addArrangedSubview(makeTabView())
        root.addArrangedSubview(separator())
        root.addArrangedSubview(makeRouteArea())

        buildStableTabContent()
        refreshStaticAndDynamicViews()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        inputTestActive = false
        waveformView.setActive(false, level: 0.08)
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
        if status.status != "idle" {
            inputTestActive = false
        }
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
            refreshStaticAndDynamicViews()
        }
    }

    private func makeStatusArea() -> NSView {
        let container = verticalStack(spacing: 0)
        container.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        container.heightAnchor.constraint(equalToConstant: 40).isActive = true
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .vertical)

        let row = horizontalStack(spacing: 8)
        statusDot.target = self
        statusDot.action = #selector(statusDotClicked(_:))
        statusDot.toolTip = "点击测试当前输入，再点停止测试"
        statusDot.widthAnchor.constraint(equalToConstant: 18).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 18).isActive = true
        statusLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.widthAnchor.constraint(equalToConstant: 250).isActive = true
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.alignment = .right
        durationLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true
        maxMinutesPopup.controlSize = .small
        maxMinutesPopup.font = NSFont.systemFont(ofSize: 11)
        maxMinutesPopup.removeAllItems()
        for minute in 1...10 {
            maxMinutesPopup.addItem(withTitle: "\(minute) 分钟")
        }
        maxMinutesPopup.target = self
        maxMinutesPopup.action = #selector(maxMinutesPopupChanged(_:))
        maxMinutesPopup.widthAnchor.constraint(equalToConstant: 74).isActive = true
        quitButton.target = self
        quitButton.action = #selector(quitClicked(_:))
        quitButton.toolTip = "退出 Codex Voice Agent"
        quitButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        quitButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(statusDot)
        row.addArrangedSubview(statusLabel)
        row.addArrangedSubview(makeFlexibleSpacer())
        row.addArrangedSubview(durationLabel)
        row.addArrangedSubview(maxMinutesPopup)
        row.addArrangedSubview(quitButton)
        container.addArrangedSubview(row)

        let waveformSlot = NSView()
        waveformSlot.translatesAutoresizingMaskIntoConstraints = false
        waveformSlot.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        waveformSlot.heightAnchor.constraint(equalToConstant: 16).isActive = true
        waveformSlot.addSubview(waveformView)
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.heightAnchor.constraint(equalToConstant: 10).isActive = true
        waveformView.setContentHuggingPriority(.required, for: .vertical)
        waveformView.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            waveformView.leadingAnchor.constraint(equalTo: waveformSlot.leadingAnchor),
            waveformView.trailingAnchor.constraint(equalTo: waveformSlot.trailingAnchor),
            waveformView.centerYAnchor.constraint(equalTo: waveformSlot.centerYAnchor)
        ])
        container.addArrangedSubview(waveformSlot)
        return container
    }

    private func makeQuickActions() -> NSView {
        let row = horizontalStack(spacing: 6)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        row.setContentHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)

        startButton.target = self
        startButton.action = #selector(startClicked(_:))
        submitButton.target = self
        submitButton.action = #selector(submitClicked(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        indicatorButton.target = self
        indicatorButton.action = #selector(indicatorClicked(_:))

        for button in [startButton, submitButton, cancelButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.widthAnchor.constraint(equalToConstant: 56).isActive = true
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(makeFlexibleSpacer())
        let microphoneButton = compactButton("麦克风授权", #selector(microphoneClicked(_:)), width: 76)
        let accessibilityButton = compactButton("辅助功能授权", #selector(pasteClicked(_:)), width: 92)
        row.addArrangedSubview(microphoneButton)
        row.addArrangedSubview(accessibilityButton)
        configureIndicatorButton()
        row.addArrangedSubview(indicatorButton)
        return row
    }

    private func makeRouteArea() -> NSView {
        let stack = verticalStack(spacing: 4)
        stack.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(routeRow("状态", stateValueLabel))
        stack.addArrangedSubview(routeRow("转录模型", transcriptionValueLabel))
        stack.addArrangedSubview(routeRow("纠错模型", correctionValueLabel))
        stack.addArrangedSubview(routeRow("输入设备", inputValueLabel))
        return stack
    }

    private func makeTabView() -> NSView {
        let container = verticalStack(spacing: 6)
        container.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .vertical)

        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.selectedSegment = 0
        tabControl.controlSize = .regular
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        container.addArrangedSubview(tabControl)

        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        tabContainerHeightConstraint = tabContainer.heightAnchor.constraint(equalToConstant: 1)
        tabContainerHeightConstraint?.isActive = true
        addTabDocument(transcriptionDocument, content: transcriptionContentStack)
        addTabDocument(correctionDocument, content: correctionContentStack)
        addTabDocument(inputDocument, content: inputContentStack)
        showTab(at: 0, updateSize: false)
        container.addArrangedSubview(tabContainer)
        return container
    }

    private func buildStableTabContent() {
        configureContentStack(transcriptionContentStack)
        configureContentStack(correctionContentStack)
        configureContentStack(inputContentStack)

        configureCardStack(transcriptionCardsStack)
        configureCardStack(correctionCardsStack)
        configureCardStack(inputCardsStack)

        transcriptionContentStack.addArrangedSubview(cardScroller(
            document: transcriptionCardsDocument,
            stack: transcriptionCardsStack,
            setHeightConstraint: { self.transcriptionCardScrollerHeightConstraint = $0 }
        ))

        correctionContentStack.addArrangedSubview(cardScroller(
            document: correctionCardsDocument,
            stack: correctionCardsStack,
            setHeightConstraint: { self.correctionCardScrollerHeightConstraint = $0 }
        ))

        inputContentStack.addArrangedSubview(cardScroller(
            document: inputCardsDocument,
            stack: inputCardsStack,
            setHeightConstraint: { self.inputCardScrollerHeightConstraint = $0 }
        ))
    }

    private func refreshStaticAndDynamicViews() {
        refreshStatusArea()
        refreshQuickActions()
        refreshRouteArea()
        refreshDynamicModelSections()
        refreshInputProbeArea()
        resizeVisibleTab()
        updatePreferredContentSize()
    }

    private func refreshStatusArea() {
        let testingInput = currentStatus.status == "idle" && (inputTestActive || inputProbeInFlight)
        statusDot.fillColor = testingInput
            ? .systemGreen
            : colorForStatus(currentStatus.status, stale: currentStatus.isStale)
        setText(statusLabel, testingInput ? "测试输入" : currentStatus.label)
        setText(durationLabel, durationText())
        refreshMaxMinutesPopup()
        waveformView.toolTip = testingInput ? currentInputProbeResult : nil
        waveformView.setActive(
            currentStatus.status == "recording" || testingInput,
            level: testingInput ? probeLevelFromResult() : 0.42
        )

        let stageDetail = currentStatus.detail.isEmpty ? currentStatus.label : currentStatus.detail
        setText(stageLabel, "阶段：\(stageDetail)")

        guard let task = currentModelTask else {
            setText(modelTaskLabel, "模型：空闲")
            setText(modelTaskDetailLabel, " ")
            modelProgress.stopAnimation(nil)
            modelProgress.isHidden = true
            modelProgress.doubleValue = 0
            return
        }

        let statusText: String
        switch task.status {
        case "running": statusText = "运行中"
        case "succeeded": statusText = "已完成"
        case "failed": statusText = "失败"
        default: statusText = task.status
        }
        setText(modelTaskLabel, "模型：\(statusText) · \(task.label)")
        setText(modelTaskDetailLabel, task.detail.isEmpty ? " " : task.detail)
        guard task.status == "running" else {
            modelProgress.stopAnimation(nil)
            modelProgress.isHidden = true
            modelProgress.doubleValue = 0
            return
        }
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
        let indicatorEnabled = configBool("recording_indicator", defaultValue: true)
        indicatorButton.state = indicatorEnabled ? .on : .off
        setIndicatorButtonStyle(enabled: indicatorEnabled)
    }

    private func refreshRouteArea() {
        let stateDetail = currentStatus.detail.isEmpty ? currentStatus.label : "\(currentStatus.label) · \(currentStatus.detail)"
        setText(stateValueLabel, stateDetail)
        setText(transcriptionValueLabel, transcriptionLabel())
        setText(correctionValueLabel, correctionLabel())
        setText(inputValueLabel, inputLabel())
    }

    private func refreshDynamicModelSections() {
        let transcriptionSig = [
            transcriptionProfile(),
            stringConfig("ollama_transcription_model", defaultValue: ""),
            currentTranscriptionModels.isEmpty && scanningModels ? "scanning" : "ready",
            currentTranscriptionModels.map {
                "\($0.name):\($0.needsTest):\($0.parameterSize):\($0.family):\($0.quantization)"
            }.joined(separator: "|")
        ].joined(separator: "||")
        if transcriptionSig != transcriptionSignature {
            transcriptionSignature = transcriptionSig
            rebuildTranscriptionOptions()
            layoutCardGroup(
                document: transcriptionCardsDocument,
                stack: transcriptionCardsStack,
                scrollerHeightConstraint: transcriptionCardScrollerHeightConstraint
            )
            _ = resizeDocument(transcriptionDocument, content: transcriptionContentStack)
        }

        let correctionSig = [
            correctionProfile(),
            stringConfig("ollama_model", defaultValue: ""),
            currentMaintenance.ollamaStatusCode,
            currentMaintenance.ollamaBaseURL,
            currentCorrectionModels.isEmpty && scanningModels ? "scanning" : "ready",
            currentCorrectionModels.map {
                "\($0.name):\($0.loaded):\($0.parameterSize):\($0.family):\($0.quantization)"
            }.joined(separator: "|")
        ].joined(separator: "||")
        if correctionSig != correctionSignature {
            correctionSignature = correctionSig
            rebuildCorrectionOptions()
            layoutCardGroup(
                document: correctionCardsDocument,
                stack: correctionCardsStack,
                scrollerHeightConstraint: correctionCardScrollerHeightConstraint
            )
            _ = resizeDocument(correctionDocument, content: correctionContentStack)
        }

        let inputSig = [
            currentConfig["input_device"] as? String ?? "",
            currentInputDevices.isEmpty && scanningModels ? "scanning" : "ready",
            currentInputDevices.map { "\($0.name):\($0.isDefault):\($0.channels ?? 0)" }.joined(separator: "|")
        ].joined(separator: "||")
        if inputSig != inputSignature {
            inputSignature = inputSig
            rebuildInputOptions()
            layoutCardGroup(
                document: inputCardsDocument,
                stack: inputCardsStack,
                scrollerHeightConstraint: inputCardScrollerHeightConstraint
            )
            _ = resizeDocument(inputDocument, content: inputContentStack)
        }
        refreshCardLoadingOverlays()
    }

    private func rebuildTranscriptionOptions() {
        removeAllArrangedSubviews(from: transcriptionCardsStack)

        let profile = transcriptionProfile()
        let selectedOllama = stringConfig("ollama_transcription_model", defaultValue: "")
        transcriptionCardsStack.addArrangedSubview(cardButton(
            source: "内置",
            title: "MLX Whisper large-v3-turbo",
            parameter: "809M",
            architecture: "Whisper Transformer",
            vendor: "OpenAI / MLX",
            value: "profile:mlx-whisper-turbo",
            selected: profile == "mlx-whisper-turbo",
            action: #selector(transcriptionChoiceClicked(_:))
        ))
        transcriptionCardsStack.addArrangedSubview(cardButton(
            source: "内置",
            title: "faster-whisper large-v3-turbo",
            parameter: "809M",
            architecture: "Whisper Transformer",
            vendor: "OpenAI / CTranslate2",
            value: "profile:faster-whisper-turbo",
            selected: profile == "faster-whisper-turbo",
            action: #selector(transcriptionChoiceClicked(_:))
        ))

        if scanningModels {
            transcriptionCardsStack.addArrangedSubview(statusCard("Ollama", "正在扫描", "参数：-", "架构：-", "厂家：Ollama"))
        } else if currentTranscriptionModels.isEmpty {
            transcriptionCardsStack.addArrangedSubview(statusCard("Ollama", "未检测到转录模型", "参数：-", "架构：-", "厂家：Ollama"))
        } else {
            for model in currentTranscriptionModels {
                let suffix = model.needsTest ? "（需测试）" : ""
                transcriptionCardsStack.addArrangedSubview(cardButton(
                    source: "Ollama",
                    title: "\(model.name)\(suffix)",
                    parameter: parameterText(for: model),
                    architecture: architectureText(for: model),
                    vendor: vendorText(for: model),
                    value: "ollama:\(model.name)",
                    selected: profile == "ollama-transcription" && selectedOllama == model.name,
                    action: #selector(transcriptionChoiceClicked(_:))
                ))
            }
        }
        transcriptionCardsStack.addArrangedSubview(cardButton(
            source: "在线 API",
            title: "OpenAI API（未启用）",
            parameter: "云端",
            architecture: "Audio API",
            vendor: "OpenAI",
            value: "external:openai-transcription",
            selected: false,
            action: #selector(transcriptionChoiceClicked(_:)),
            enabled: false
        ))
    }

    private func rebuildCorrectionOptions() {
        removeAllArrangedSubviews(from: correctionCardsStack)

        let profile = correctionProfile()
        let selectedOllama = stringConfig("ollama_model", defaultValue: "")
        correctionCardsStack.addArrangedSubview(cardButton(
            source: "内置",
            title: "规则纠错（不使用 LLM）",
            parameter: "0",
            architecture: "规则引擎",
            vendor: "Codex Voice",
            value: "profile:rule-only",
            selected: profile == "rule-only",
            action: #selector(correctionChoiceClicked(_:))
        ))

        if scanningModels {
            correctionCardsStack.addArrangedSubview(statusCard("Ollama", "正在扫描", "参数：-", "架构：-", "厂家：Ollama"))
        } else if currentCorrectionModels.isEmpty {
            correctionCardsStack.addArrangedSubview(statusCard(
                "Ollama",
                ollamaEmptyCorrectionTitle(selectedModel: selectedOllama),
                "参数：\(ollamaStatusParameter())",
                "架构：\(currentMaintenance.ollamaStatus)",
                "厂家：Ollama"
            ))
        } else {
            for model in currentCorrectionModels {
                let suffix = model.loaded ? "" : "（待加载）"
                correctionCardsStack.addArrangedSubview(cardButton(
                    source: "Ollama",
                    title: "\(model.name)\(suffix)",
                    parameter: parameterText(for: model),
                    architecture: architectureText(for: model),
                    vendor: vendorText(for: model),
                    value: "ollama:\(model.name)",
                    selected: profile == "ollama-correction" && selectedOllama == model.name,
                    action: #selector(correctionChoiceClicked(_:)),
                    unloadValue: model.loaded ? model.name : nil,
                    unloadAction: #selector(unloadOllamaModelClicked(_:))
                ))
            }
        }
        correctionCardsStack.addArrangedSubview(cardButton(
            source: "在线 API",
            title: "OpenAI API（未启用）",
            parameter: "云端",
            architecture: "Chat API",
            vendor: "OpenAI",
            value: "external:openai-correction",
            selected: false,
            action: #selector(correctionChoiceClicked(_:)),
            enabled: false
        ))
    }

    private func ollamaEmptyCorrectionTitle(selectedModel: String) -> String {
        switch currentMaintenance.ollamaStatusCode {
        case "ollama_not_installed":
            return "未检测到纠错模型"
        case "service_unavailable":
            return "Ollama 服务未就绪"
        case "starting":
            return "正在启动 Ollama"
        default:
            if !selectedModel.isEmpty {
                return "未安装 \(selectedModel)"
            }
            return "无可用纠错模型"
        }
    }

    private func ollamaStatusParameter() -> String {
        currentMaintenance.ollamaBaseURL.isEmpty ? "-" : currentMaintenance.ollamaBaseURL
    }

    private func rebuildInputOptions() {
        removeAllArrangedSubviews(from: inputCardsStack)

        let configured = currentConfig["input_device"] as? String
        let defaultName = currentInputDevices.first(where: { $0.isDefault })?.name
        let defaultTitle: String
        if let defaultName, !defaultName.isEmpty {
            defaultTitle = "系统默认输入（\(defaultName)）"
        } else {
            defaultTitle = "系统默认输入"
        }
        inputCardsStack.addArrangedSubview(cardButton(
            source: "默认",
            title: defaultTitle,
            parameter: "自动",
            architecture: "CoreAudio",
            vendor: "macOS",
            value: "__default__",
            selected: configured == nil || configured?.isEmpty == true,
            action: #selector(inputChoiceClicked(_:)),
            width: Metrics.inputCardWidth
        ))

        if currentInputDevices.isEmpty {
            let title = scanningModels ? "正在扫描输入设备" : "未检测到可用麦克风"
            inputCardsStack.addArrangedSubview(statusCard(
                "输入",
                title,
                "参数：-",
                "架构：CoreAudio",
                "厂家：macOS",
                width: Metrics.inputCardWidth
            ))
        } else {
            for device in currentInputDevices {
                let title = device.isDefault ? "\(device.name)（当前系统默认）" : device.name
                let channels = device.channels.map { "\($0) ch" } ?? "未知"
                inputCardsStack.addArrangedSubview(cardButton(
                    source: "麦克风",
                    title: title,
                    parameter: channels,
                    architecture: "CoreAudio 输入",
                    vendor: device.isDefault ? "macOS 默认" : "音频设备",
                    value: device.name,
                    selected: configured == device.name,
                    action: #selector(inputChoiceClicked(_:)),
                    width: Metrics.inputCardWidth
                ))
            }
        }
    }

    private func refreshInputProbeArea() {
        probeButton.title = inputProbeInFlight ? "测试中" : "测试输入"
        probeButton.isEnabled = !inputProbeInFlight
        setText(probeResultLabel, currentInputProbeResult)

        let minutes = currentMaxRecordingMinutes()
        setText(maxMinutesLabel, "录音上限：\(Int(minutes)) 分钟")
        if maxMinutesStepper.doubleValue != minutes {
            maxMinutesStepper.doubleValue = minutes
        }

        if inputTestActive && !inputProbeInFlight && currentStatus.status == "idle" {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.inputTestActive,
                      !self.inputProbeInFlight,
                      self.currentStatus.status == "idle" else {
                    return
                }
                self.onProbeInput?()
            }
        }
    }

    private func refreshMaxMinutesPopup() {
        let minutes = currentMaxRecordingMinutes()
        let index = max(0, min(9, Int(minutes) - 1))
        if maxMinutesPopup.indexOfSelectedItem != index {
            maxMinutesPopup.selectItem(at: index)
        }
    }

    private func currentMaxRecordingMinutes() -> Double {
        let maxSeconds = configDouble(
            "background_max_record_seconds",
            defaultValue: configDouble("max_record_seconds", defaultValue: 300)
        )
        return max(1, min(10, round(maxSeconds / 60)))
    }

    private func probeLevelFromResult() -> CGFloat {
        let pattern = #"RMS\s+([0-9.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: currentInputProbeResult,
                range: NSRange(currentInputProbeResult.startIndex..., in: currentInputProbeResult)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: currentInputProbeResult),
              let value = Double(currentInputProbeResult[range]) else {
            return 0.32
        }
        return CGFloat(max(0.12, min(1.0, value * 18)))
    }

    private func refreshCardLoadingOverlays() {
        let runningTask = currentModelTask?.status == "running" ? currentModelTask : nil
        updateLoadingOverlay(
            in: transcriptionCardsStack,
            task: runningTask?.scope == "transcription" ? runningTask : nil
        )
        updateLoadingOverlay(
            in: correctionCardsStack,
            task: runningTask?.scope == "correction" ? runningTask : nil
        )
        updateLoadingOverlay(in: inputCardsStack, task: nil)
    }

    private func updateLoadingOverlay(in stack: NSStackView, task: ModelTask?) {
        for view in stack.arrangedSubviews {
            guard let card = view as? CardChoiceView else {
                continue
            }
            card.setLoadingTask(card.isSelectedCard ? task : nil)
        }
    }

    private func addTabDocument(_ document: NSView, content: NSStackView) {
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        tabContainer.addSubview(document)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            document.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            document.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor)
        ])
    }

    private func showTab(at index: Int, updateSize: Bool = true) {
        selectedTabIndex = index
        let documents = [transcriptionDocument, correctionDocument, inputDocument]
        for (documentIndex, document) in documents.enumerated() {
            document.isHidden = documentIndex != index
        }
        if updateSize {
            resizeVisibleTab()
            updatePreferredContentSize()
        }
    }

    private func resizeVisibleTab() {
        let selected: (document: NSView, content: NSStackView)
        switch selectedTabIndex {
        case 1:
            selected = (correctionDocument, correctionContentStack)
        case 2:
            selected = (inputDocument, inputContentStack)
        default:
            selected = (transcriptionDocument, transcriptionContentStack)
        }

        let height = resizeDocument(selected.document, content: selected.content)
        if abs((tabContainerHeightConstraint?.constant ?? 0) - height) > 0.5 {
            tabContainerHeightConstraint?.constant = height
        }
    }

    private func configureContentStack(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Metrics.tabInnerWidth).isActive = true
    }

    private func configureCardStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.spacing = Metrics.cardSpacing
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func cardScroller(
        document: NSView,
        stack: NSStackView,
        setHeightConstraint: (NSLayoutConstraint) -> Void
    ) -> NSView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: Metrics.cardViewportWidth).isActive = true
        let heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 1)
        heightConstraint.isActive = true
        setHeightConstraint(heightConstraint)

        document.frame = NSRect(x: 0, y: 0, width: Metrics.cardViewportWidth, height: 1)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Metrics.cardScrollerInset),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Metrics.cardScrollerTopInset),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: document.bottomAnchor,
                constant: -Metrics.cardScrollerBottomInset
            )
        ])
        scrollView.documentView = document
        return scrollView
    }

    private func cardButton(
        source: String,
        title: String,
        parameter: String,
        architecture: String,
        vendor: String,
        value: String,
        selected: Bool,
        action: Selector,
        enabled: Bool = true,
        unloadValue: String? = nil,
        unloadAction: Selector? = nil,
        width: CGFloat = Metrics.modelCardWidth
    ) -> NSView {
        let card = CardChoiceView(
            source: source,
            title: title,
            rows: [
                ("参数", parameter),
                ("架构", architecture),
                ("厂家", vendor)
            ],
            selected: selected,
            enabled: enabled,
            width: width
        )
        card.identifier = NSUserInterfaceItemIdentifier(value)
        if enabled {
            card.target = self
            card.action = action
        }
        if let unloadValue, let unloadAction {
            card.setUnloadAction(value: unloadValue, target: self, action: unloadAction)
        }
        return card
    }

    private func statusCard(
        _ source: String,
        _ title: String,
        _ parameterLine: String,
        _ architectureLine: String,
        _ vendorLine: String,
        width: CGFloat = Metrics.modelCardWidth
    ) -> NSView {
        return CardChoiceView(
            source: source,
            title: title,
            rows: [
                ("参数", parameterLine.replacingOccurrences(of: "参数：", with: "")),
                ("架构", architectureLine.replacingOccurrences(of: "架构：", with: "")),
                ("厂家", vendorLine.replacingOccurrences(of: "厂家：", with: ""))
            ],
            selected: false,
            enabled: false,
            width: width
        )
    }

    private func layoutCardGroup(
        document: NSView,
        stack: NSStackView,
        scrollerHeightConstraint: NSLayoutConstraint?
    ) {
        let cardHeight = uniformCardHeight(for: stack)
        let scrollerHeight = ceil(
            cardHeight
                + Metrics.cardScrollerTopInset
                + Metrics.cardScrollerBottomInset
        )
        scrollerHeightConstraint?.constant = max(1, scrollerHeight)
        stack.layoutSubtreeIfNeeded()
        let width = max(Metrics.tabInnerWidth, stack.fittingSize.width + Metrics.cardScrollerInset * 2)
        if abs(document.frame.width - width) > 1
            || abs(document.frame.height - scrollerHeight) > 1 {
            document.setFrameSize(NSSize(width: width, height: max(1, scrollerHeight)))
        }
    }

    private func uniformCardHeight(for stack: NSStackView) -> CGFloat {
        let cards = stack.arrangedSubviews.compactMap { $0 as? CardChoiceView }
        let height = cards.map { $0.naturalHeight() }.max() ?? 1
        let uniformHeight = max(1, ceil(height))
        for card in cards {
            card.applyUniformHeight(uniformHeight)
        }
        return uniformHeight
    }

    private func parameterText(for model: OllamaModel) -> String {
        if !model.parameterSize.isEmpty {
            return model.parameterSize
        }
        return "未知"
    }

    private func architectureText(for model: OllamaModel) -> String {
        let base: String
        if !model.family.isEmpty {
            base = model.family
        } else if let first = model.families.first, !first.isEmpty {
            base = first
        } else {
            base = inferredArchitecture(from: model.name)
        }
        if model.quantization.isEmpty {
            return base
        }
        return "\(base) · \(model.quantization)"
    }

    private func vendorText(for model: OllamaModel) -> String {
        let text = ([model.name, model.family] + model.families).joined(separator: " ").lowercased()
        if text.contains("qwen") { return "Alibaba / Qwen" }
        if text.contains("gemma") { return "Google" }
        if text.contains("llama") { return "Meta" }
        if text.contains("mistral") { return "Mistral AI" }
        if text.contains("deepseek") { return "DeepSeek" }
        if text.contains("phi") { return "Microsoft" }
        if text.contains("whisper") { return "OpenAI / 社区" }
        if text.contains("yi") { return "01.AI" }
        if text.contains("baichuan") { return "Baichuan" }
        return "Ollama"
    }

    private func inferredArchitecture(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("gemma") { return "Gemma" }
        if lower.contains("llama") { return "Llama" }
        if lower.contains("mistral") { return "Mistral" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("whisper") { return "Whisper" }
        if lower.contains("asr") || lower.contains("speech") { return "Audio" }
        return "LLM"
    }

    private func makeProbeRow() -> NSView {
        let row = horizontalStack(spacing: 8)
        row.widthAnchor.constraint(equalToConstant: Metrics.tabInnerWidth).isActive = true
        probeButton.target = self
        probeButton.action = #selector(probeInputClicked(_:))
        probeButton.bezelStyle = .rounded
        probeButton.controlSize = .small
        probeButton.widthAnchor.constraint(equalToConstant: 78).isActive = true
        probeResultLabel.font = NSFont.systemFont(ofSize: 11)
        probeResultLabel.textColor = .secondaryLabelColor
        probeResultLabel.lineBreakMode = .byTruncatingMiddle
        probeResultLabel.widthAnchor.constraint(
            equalToConstant: Metrics.tabInnerWidth - 78 - 8
        ).isActive = true
        row.addArrangedSubview(probeButton)
        row.addArrangedSubview(probeResultLabel)
        return row
    }

    private func makeMaxRecordingRow() -> NSView {
        let row = horizontalStack(spacing: 8)
        row.widthAnchor.constraint(equalToConstant: Metrics.tabInnerWidth).isActive = true
        maxMinutesLabel.font = NSFont.systemFont(ofSize: 12)
        maxMinutesLabel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        maxMinutesStepper.minValue = 1
        maxMinutesStepper.maxValue = 10
        maxMinutesStepper.increment = 1
        maxMinutesStepper.target = self
        maxMinutesStepper.action = #selector(maxMinutesChanged(_:))
        row.addArrangedSubview(maxMinutesLabel)
        row.addArrangedSubview(maxMinutesStepper)
        row.addArrangedSubview(makeFlexibleSpacer())
        return row
    }

    private func routeRow(_ name: String, _ valueLabel: NSTextField) -> NSView {
        let row = horizontalStack(spacing: 3)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        let nameLabel = NSTextField(labelWithString: "\(name)：")
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.font = NSFont.systemFont(ofSize: 12)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.contentWidth - 80).isActive = true
        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func infoLine(_ name: String, _ valueLabel: NSTextField) -> NSView {
        let row = horizontalStack(spacing: 8)
        row.widthAnchor.constraint(equalToConstant: Metrics.tabInnerWidth).isActive = true
        let nameLabel = NSTextField(labelWithString: "\(name)：")
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.widthAnchor.constraint(equalToConstant: Metrics.maintenanceLabelWidth).isActive = true
        valueLabel.font = NSFont.systemFont(ofSize: 11)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.widthAnchor.constraint(
            equalToConstant: Metrics.tabInnerWidth - Metrics.maintenanceLabelWidth - 8
        ).isActive = true
        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func actionRow(_ items: [(String, Selector)]) -> NSView {
        let row = horizontalStack(spacing: 8)
        row.widthAnchor.constraint(equalToConstant: Metrics.tabInnerWidth).isActive = true
        for item in items {
            let button = NSButton(title: item.0, target: self, action: item.1)
            button.bezelStyle = .rounded
            button.controlSize = .small
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(makeFlexibleSpacer())
        return row
    }

    private func compactButton(_ title: String, _ action: Selector, width: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private func configureIndicatorButton() {
        indicatorButton.target = self
        indicatorButton.action = #selector(indicatorClicked(_:))
        indicatorButton.bezelStyle = .rounded
        indicatorButton.controlSize = .small
        indicatorButton.imagePosition = .imageOnly
        indicatorButton.toolTip = "显示或隐藏录音浮窗"
        if #available(macOS 11.0, *) {
            indicatorButton.image = NSImage(
                systemSymbolName: "macwindow",
                accessibilityDescription: "浮窗"
            ) ?? NSImage(
                systemSymbolName: "rectangle",
                accessibilityDescription: "浮窗"
            )
        } else {
            indicatorButton.title = "□"
            indicatorButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        }
        indicatorButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        indicatorButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        indicatorButton.wantsLayer = true
        indicatorButton.layer?.cornerRadius = 6
        setIndicatorButtonStyle(enabled: configBool("recording_indicator", defaultValue: true))
    }

    private func setIndicatorButtonStyle(enabled: Bool) {
        indicatorButton.contentTintColor = enabled ? .systemGreen : .labelColor
        indicatorButton.layer?.backgroundColor = enabled
            ? NSColor.systemGreen.withAlphaComponent(0.16).usingColorSpace(.deviceRGB)?.cgColor
            : NSColor.clear.cgColor
        indicatorButton.layer?.borderWidth = enabled ? 1 : 0
        indicatorButton.layer?.borderColor = enabled
            ? NSColor.systemGreen.withAlphaComponent(0.55).usingColorSpace(.deviceRGB)?.cgColor
            : NSColor.clear.cgColor
    }

    private func secondaryText(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.tabInnerWidth).isActive = true
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

    private func separator(width: CGFloat = Metrics.contentWidth) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.setContentHuggingPriority(.required, for: .vertical)
        line.setContentCompressionResistancePriority(.required, for: .vertical)
        return line
    }

    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func updatePreferredContentSize() {
        guard isViewLoaded, let rootStack else {
            return
        }

        view.layoutSubtreeIfNeeded()
        rootStack.layoutSubtreeIfNeeded()
        let fittingHeight = max(1, ceil(rootStack.fittingSize.height))
        let nextSize = NSSize(width: Metrics.panelWidth, height: fittingHeight)
        guard abs(preferredContentSize.width - nextSize.width) > 0.5
            || abs(preferredContentSize.height - nextSize.height) > 0.5 else {
            return
        }

        preferredContentSize = nextSize
        view.setFrameSize(nextSize)
        onPreferredContentSizeChange?(nextSize)
    }

    @discardableResult
    private func resizeDocument(_ document: NSView, content: NSStackView) -> CGFloat {
        content.layoutSubtreeIfNeeded()
        let height = max(1, ceil(content.fittingSize.height))
        if abs(document.frame.height - height) > 1 {
            document.setFrameSize(NSSize(width: Metrics.tabDocumentWidth, height: height))
        }
        return height
    }

    private func removeAllArrangedSubviews(from stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func setText(_ label: NSTextField, _ text: String) {
        if label.stringValue != text {
            label.stringValue = text
        }
    }

    private func setProgress(value: Double?, indeterminate: Bool) {
        modelProgress.isHidden = false
        if indeterminate {
            if !modelProgress.isIndeterminate {
                modelProgress.isIndeterminate = true
            }
            modelProgress.startAnimation(nil)
            return
        }
        modelProgress.stopAnimation(nil)
        if modelProgress.isIndeterminate {
            modelProgress.isIndeterminate = false
        }
        modelProgress.doubleValue = max(0, min(1, value ?? 0))
    }

    private func durationText() -> String {
        if currentStatus.status == "recording" || currentStatus.status == "submitting" {
            let elapsed = elapsedSeconds(from: currentStatus.updatedAt)
            return "\(formatDuration(elapsed)) /"
        }
        return "0:00 /"
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
        let index = max(0, min(sender.selectedSegment, 2))
        showTab(at: index)
    }

    @objc private func statusDotClicked(_ sender: Any?) {
        guard currentStatus.status == "idle" else {
            return
        }
        inputTestActive.toggle()
        if inputTestActive {
            onProbeInput?()
        }
        refreshStatusArea()
        refreshInputProbeArea()
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

    @objc private func transcriptionChoiceClicked(_ sender: NSControl) {
        guard let value = sender.identifier?.rawValue else {
            return
        }
        onSelectTranscriptionModel?(value)
    }

    @objc private func correctionChoiceClicked(_ sender: NSControl) {
        guard let value = sender.identifier?.rawValue else {
            return
        }
        onSelectCorrectionModel?(value)
    }

    @objc private func inputChoiceClicked(_ sender: NSControl) {
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

    @objc private func unloadOllamaModelClicked(_ sender: NSControl) {
        guard let model = sender.identifier?.rawValue, !model.isEmpty else {
            return
        }
        onUnloadOllamaModel?(model)
    }

    @objc private func probeInputClicked(_ sender: Any?) {
        onProbeInput?()
    }

    @objc private func maxMinutesChanged(_ sender: NSStepper) {
        setText(maxMinutesLabel, "录音上限：\(Int(sender.doubleValue)) 分钟")
        onSetMaxMinutes?(sender.doubleValue)
    }

    @objc private func maxMinutesPopupChanged(_ sender: NSPopUpButton) {
        let minutes = Double(max(1, sender.indexOfSelectedItem + 1))
        onSetMaxMinutes?(minutes)
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

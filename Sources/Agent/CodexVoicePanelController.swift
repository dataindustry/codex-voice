import Cocoa
import Foundation
import ApplicationServices
import AVFoundation

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
    var onSetNativeHotkey: ((NativeHotkey) -> Void)?
    var onClearNativeHotkey: (() -> Void)?
    var onResetNativeHotkey: (() -> Void)?
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
    private var currentNativeHotkeyStatus = "未注册"
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
    private let settingsButton = NSButton(title: "", target: nil, action: nil)
    private let settingsOverlay = EventBlockingVisualEffectView()
    private let settingsCloseButton = NSButton(title: "", target: nil, action: nil)
    private let quitButton = CircleControl(color: .systemRed, diameter: 11)

    private let startButton = NSButton(title: "开始", target: nil, action: nil)
    private let submitButton = NSButton(title: "提交", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let indicatorButton = NSButton(title: "", target: nil, action: nil)
    private let hotkeyValueLabel = NSTextField(labelWithString: "⌥Space")
    private let recordHotkeyButton = NSButton(title: "录制", target: nil, action: nil)
    private let clearHotkeyButton = NSButton(title: "清除", target: nil, action: nil)
    private let resetHotkeyButton = NSButton(title: "默认", target: nil, action: nil)

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
    private var isRecordingHotkey = false
    private var hotkeyMonitor: Any?
    private var hotkeyRecordingModifier: String?
    private var hotkeyRecordingModifierIsDown = false
    private var hotkeyRecordingLastTapTime: TimeInterval = 0
    private var settingsOverlayVisible = false

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

        configureSettingsOverlay()
        buildStableTabContent()
        refreshStaticAndDynamicViews()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        inputTestActive = false
        stopHotkeyRecording()
        hideSettingsOverlay()
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
        maintenance: PanelMaintenance,
        nativeHotkeyStatus: String
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
        currentNativeHotkeyStatus = nativeHotkeyStatus
        if isViewLoaded {
            refreshStaticAndDynamicViews()
        }
    }

    private func makeStatusArea() -> NSView {
        let container = verticalStack(spacing: 0)
        container.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        container.heightAnchor.constraint(equalToConstant: 48).isActive = true
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
        configureSettingsButton()
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
        row.addArrangedSubview(settingsButton)
        row.addArrangedSubview(quitButton)
        container.addArrangedSubview(row)

        let waveformSlot = NSView()
        waveformSlot.translatesAutoresizingMaskIntoConstraints = false
        waveformSlot.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        waveformSlot.heightAnchor.constraint(equalToConstant: 24).isActive = true
        waveformSlot.addSubview(waveformView)
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.heightAnchor.constraint(equalToConstant: 18).isActive = true
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
        configureIndicatorButton()
        row.addArrangedSubview(indicatorButton)
        return row
    }

    private func makePermissionSettingsRow() -> NSView {
        let row = horizontalStack(spacing: 8)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        let microphoneButton = compactButton("麦克风授权", #selector(microphoneClicked(_:)), width: 84)
        let accessibilityButton = compactButton("辅助功能授权", #selector(pasteClicked(_:)), width: 98)
        row.addArrangedSubview(microphoneButton)
        row.addArrangedSubview(accessibilityButton)
        row.addArrangedSubview(makeFlexibleSpacer())
        return row
    }

    private func makeHotkeyRow() -> NSView {
        let row = horizontalStack(spacing: 6)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        row.setContentHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)

        let nameLabel = NSTextField(labelWithString: "快捷键：")
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.widthAnchor.constraint(equalToConstant: Metrics.routeLabelWidth).isActive = true

        hotkeyValueLabel.font = NSFont.systemFont(ofSize: 12)
        hotkeyValueLabel.lineBreakMode = .byTruncatingMiddle
        hotkeyValueLabel.widthAnchor.constraint(equalToConstant: 244).isActive = true

        configureHotkeyButton(recordHotkeyButton, action: #selector(recordHotkeyClicked(_:)), width: 52)
        configureHotkeyButton(clearHotkeyButton, action: #selector(clearHotkeyClicked(_:)), width: 52)
        configureHotkeyButton(resetHotkeyButton, action: #selector(resetHotkeyClicked(_:)), width: 52)

        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(hotkeyValueLabel)
        row.addArrangedSubview(makeFlexibleSpacer())
        row.addArrangedSubview(recordHotkeyButton)
        row.addArrangedSubview(clearHotkeyButton)
        row.addArrangedSubview(resetHotkeyButton)
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
        refreshHotkeyArea()
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

    private func refreshHotkeyArea() {
        recordHotkeyButton.title = isRecordingHotkey ? "取消" : "录制"
        let enabled = configBool("native_hotkey_enabled", defaultValue: true)
        clearHotkeyButton.isEnabled = enabled && !isRecordingHotkey
        resetHotkeyButton.isEnabled = !isRecordingHotkey

        guard !isRecordingHotkey else {
            hotkeyValueLabel.textColor = .systemYellow
            setText(hotkeyValueLabel, "按组合键")
            return
        }

        hotkeyValueLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
        let hotkey = NativeHotkey.from(config: currentConfig)
        let base = enabled ? hotkey.displayName : "已关闭"
        let status = currentNativeHotkeyStatus.isEmpty ? "" : " · \(currentNativeHotkeyStatus)"
        setText(hotkeyValueLabel, "\(base)\(status)")
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

    private func configureSettingsButton() {
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked(_:))
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.toolTip = "设置"
        settingsButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        if #available(macOS 11.0, *) {
            settingsButton.image = NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: "设置"
            )
            settingsButton.contentTintColor = .secondaryLabelColor
        } else {
            settingsButton.title = "⚙"
            settingsButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        }
    }

    private func configureSettingsOverlay() {
        settingsOverlay.translatesAutoresizingMaskIntoConstraints = false
        settingsOverlay.blendingMode = .withinWindow
        settingsOverlay.material = .hudWindow
        settingsOverlay.state = .active
        settingsOverlay.isHidden = true
        view.addSubview(settingsOverlay)

        let stack = verticalStack(spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        settingsOverlay.addSubview(stack)

        NSLayoutConstraint.activate([
            settingsOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            settingsOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            settingsOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: settingsOverlay.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: settingsOverlay.trailingAnchor),
            stack.topAnchor.constraint(equalTo: settingsOverlay.topAnchor)
        ])

        stack.addArrangedSubview(makeSettingsHeader())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(settingsSectionLabel("权限"))
        stack.addArrangedSubview(makePermissionSettingsRow())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(settingsSectionLabel("快捷键"))
        stack.addArrangedSubview(makeHotkeyRow())
    }

    private func makeSettingsHeader() -> NSView {
        let row = horizontalStack(spacing: 8)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true

        let title = NSTextField(labelWithString: "设置")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        row.addArrangedSubview(title)
        row.addArrangedSubview(makeFlexibleSpacer())

        settingsCloseButton.target = self
        settingsCloseButton.action = #selector(settingsCloseClicked(_:))
        settingsCloseButton.isBordered = false
        settingsCloseButton.imagePosition = .imageOnly
        settingsCloseButton.toolTip = "关闭设置"
        settingsCloseButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        settingsCloseButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        if #available(macOS 11.0, *) {
            settingsCloseButton.image = NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: "关闭设置"
            )
            settingsCloseButton.contentTintColor = .secondaryLabelColor
        } else {
            settingsCloseButton.title = "×"
            settingsCloseButton.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        }
        row.addArrangedSubview(settingsCloseButton)
        return row
    }

    private func settingsSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        return label
    }

    private func configureHotkeyButton(_ button: NSButton, action: Selector, width: CGFloat) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
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

    private func showSettingsOverlay() {
        guard !settingsOverlayVisible else {
            return
        }
        settingsOverlayVisible = true
        refreshHotkeyArea()
        settingsOverlay.alphaValue = 1
        settingsOverlay.isHidden = false
    }

    private func hideSettingsOverlay() {
        guard settingsOverlayVisible || !settingsOverlay.isHidden else {
            return
        }
        settingsOverlayVisible = false
        stopHotkeyRecording()
        settingsOverlay.isHidden = true
        settingsOverlay.alphaValue = 1
    }

    private func startHotkeyRecording() {
        guard !isRecordingHotkey else {
            return
        }
        isRecordingHotkey = true
        hotkeyRecordingModifier = nil
        hotkeyRecordingModifierIsDown = false
        hotkeyRecordingLastTapTime = 0
        refreshHotkeyArea()
        view.window?.makeFirstResponder(view)
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.isRecordingHotkey else {
                return event
            }
            self.captureHotkeyEvent(event)
            return nil
        }
    }

    private func stopHotkeyRecording() {
        isRecordingHotkey = false
        hotkeyRecordingModifier = nil
        hotkeyRecordingModifierIsDown = false
        hotkeyRecordingLastTapTime = 0
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            self.hotkeyMonitor = nil
        }
        refreshHotkeyArea()
    }

    private func captureHotkeyEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            captureModifierHotkeyEvent(event)
            return
        }
        if event.keyCode == 53 {
            stopHotkeyRecording()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            stopHotkeyRecording()
            onClearNativeHotkey?()
            return
        }
        guard let hotkey = NativeHotkey.from(event: event) else {
            hotkeyValueLabel.textColor = .systemRed
            setText(hotkeyValueLabel, "请按组合键")
            return
        }
        if let status = NativeHotkeyConflictChecker.publicAPIStatus(for: hotkey),
           status != noErr {
            hotkeyValueLabel.textColor = .systemRed
            setText(hotkeyValueLabel, "快捷键不可用或已被占用")
            return
        }
        stopHotkeyRecording()
        onSetNativeHotkey?(hotkey)
    }

    private func captureModifierHotkeyEvent(_ event: NSEvent) {
        guard let modifier = NativeHotkey.modifierName(forKeyCode: event.keyCode) else {
            return
        }
        guard NativeHotkey.onlyModifier(modifier, isActiveIn: event.modifierFlags) else {
            hotkeyRecordingModifier = nil
            hotkeyRecordingModifierIsDown = false
            hotkeyRecordingLastTapTime = 0
            return
        }

        let isDown = NativeHotkey.modifierIsPressed(modifier, in: event.modifierFlags)
        if isDown && !hotkeyRecordingModifierIsDown {
            let now = event.timestamp
            if hotkeyRecordingModifier == modifier
                && hotkeyRecordingLastTapTime > 0
                && now - hotkeyRecordingLastTapTime <= 0.45,
               let hotkey = NativeHotkey.doubleModifier(modifier) {
                stopHotkeyRecording()
                onSetNativeHotkey?(hotkey)
            } else {
                hotkeyRecordingModifier = modifier
                hotkeyRecordingLastTapTime = now
                hotkeyValueLabel.textColor = .systemYellow
                setText(hotkeyValueLabel, "再按一次 \(NativeHotkey.displayModifier(modifier))")
            }
            hotkeyRecordingModifierIsDown = true
        } else if !isDown {
            hotkeyRecordingModifierIsDown = false
        }
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

    @objc private func settingsClicked(_ sender: Any?) {
        showSettingsOverlay()
    }

    @objc private func settingsCloseClicked(_ sender: Any?) {
        hideSettingsOverlay()
    }

    @objc private func recordHotkeyClicked(_ sender: Any?) {
        if isRecordingHotkey {
            stopHotkeyRecording()
        } else {
            startHotkeyRecording()
        }
    }

    @objc private func clearHotkeyClicked(_ sender: Any?) {
        stopHotkeyRecording()
        onClearNativeHotkey?()
    }

    @objc private func resetHotkeyClicked(_ sender: Any?) {
        stopHotkeyRecording()
        onResetNativeHotkey?()
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

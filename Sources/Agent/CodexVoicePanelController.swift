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
    var onUnloadLocalModel: ((String) -> Void)?
    var onProbeInput: (() -> Void)?
    var onSetMaxMinutes: ((Double) -> Void)?
    var onSetNativeHotkey: ((NativeHotkey) -> Void)?
    var onClearNativeHotkey: (() -> Void)?
    var onResetNativeHotkey: (() -> Void)?
    var onSetUILanguage: ((String) -> Void)?
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
        labelKey: "status.idle",
        label: "",
        detailKey: "",
        detailArgs: [:],
        detail: "",
        pid: nil,
        updatedAt: "",
        isStale: false
    )
    private var currentConfig: [String: Any] = [:]
    private var currentModelTask: ModelTask?
    private var currentInputDevices: [InputDevice] = []
    private var currentDirectASRModels: [LocalModel] = []
    private var currentTranscriptionModels: [LocalModel] = []
    private var currentCorrectionModels: [LocalModel] = []
    private var currentInputProbeResult = ""
    private var inputProbeInFlight = false
    private var scanningModels = false
    private var currentNativeHotkeyStatus = "unregistered"
    private var currentMaintenance = PanelMaintenance(
        pythonPath: "",
        launchAgentStatus: "com.codexvoice.agent",
        modelServiceStatus: "",
        modelServiceStatusCode: "scanning",
        modelServiceSocket: ""
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
    private let statusLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "0:00 /")
    private let maxMinutesPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stageLabel = NSTextField(labelWithString: "")
    private let modelTaskLabel = NSTextField(labelWithString: "")
    private let modelTaskDetailLabel = NSTextField(labelWithString: " ")
    private let modelProgress = NSProgressIndicator()
    private let waveformView = AudioWaveformView()
    private let settingsButton = NSButton(title: "", target: nil, action: nil)
    private let settingsOverlay = EventBlockingVisualEffectView()
    private let settingsCloseButton = NSButton(title: "", target: nil, action: nil)
    private let quitButton = CircleControl(color: .systemRed, diameter: 11)

    private let startButton = NSButton(title: "", target: nil, action: nil)
    private let submitButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let indicatorButton = NSButton(title: "", target: nil, action: nil)
    private let hotkeyNameLabel = NSTextField(labelWithString: "")
    private let hotkeyValueLabel = NSTextField(labelWithString: "")
    private let recordHotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let clearHotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let resetHotkeyButton = NSButton(title: "", target: nil, action: nil)

    private let stateNameLabel = NSTextField(labelWithString: "")
    private let transcriptionNameLabel = NSTextField(labelWithString: "")
    private let correctionNameLabel = NSTextField(labelWithString: "")
    private let inputNameLabel = NSTextField(labelWithString: "")
    private let stateValueLabel = NSTextField(labelWithString: "")
    private let transcriptionValueLabel = NSTextField(labelWithString: "")
    private let correctionValueLabel = NSTextField(labelWithString: "")
    private let inputValueLabel = NSTextField(labelWithString: "")

    private let tabContainer = NSView()
    private let tabControl = NSSegmentedControl(
        labels: ["", "", ""],
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

    private let probeButton = NSButton(title: "", target: nil, action: nil)
    private let probeResultLabel = NSTextField(labelWithString: "")
    private let maxMinutesLabel = NSTextField(labelWithString: "")
    private let maxMinutesStepper = NSStepper()
    private let settingsTitleLabel = NSTextField(labelWithString: "")
    private let permissionsSectionLabel = NSTextField(labelWithString: "")
    private let languageSectionLabel = NSTextField(labelWithString: "")
    private let hotkeySectionLabel = NSTextField(labelWithString: "")
    private let languageNameLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphonePermissionButton = NSButton(title: "", target: nil, action: nil)
    private let accessibilityPermissionButton = NSButton(title: "", target: nil, action: nil)
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
        directASRModels: [LocalModel],
        transcriptionModels: [LocalModel],
        correctionModels: [LocalModel],
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
        currentDirectASRModels = directASRModels
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
        maxMinutesPopup.target = self
        maxMinutesPopup.action = #selector(maxMinutesPopupChanged(_:))
        maxMinutesPopup.widthAnchor.constraint(equalToConstant: 74).isActive = true
        configureSettingsButton()
        quitButton.target = self
        quitButton.action = #selector(quitClicked(_:))
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
            configureAdaptiveTextButton(button, minWidth: 56)
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
        configureCompactButton(
            microphonePermissionButton,
            action: #selector(microphoneClicked(_:)),
            width: 112
        )
        configureCompactButton(
            accessibilityPermissionButton,
            action: #selector(pasteClicked(_:)),
            width: 132
        )
        row.addArrangedSubview(microphonePermissionButton)
        row.addArrangedSubview(accessibilityPermissionButton)
        row.addArrangedSubview(makeFlexibleSpacer())
        return row
    }

    private func makeLanguageSettingsRow() -> NSView {
        let row = horizontalStack(spacing: 8)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true

        languageNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        languageNameLabel.textColor = .secondaryLabelColor
        languageNameLabel.widthAnchor.constraint(equalToConstant: Metrics.routeLabelWidth).isActive = true

        languagePopup.controlSize = .small
        languagePopup.font = NSFont.systemFont(ofSize: 11)
        languagePopup.target = self
        languagePopup.action = #selector(languagePopupChanged(_:))
        languagePopup.widthAnchor.constraint(equalToConstant: 188).isActive = true

        row.addArrangedSubview(languageNameLabel)
        row.addArrangedSubview(languagePopup)
        row.addArrangedSubview(makeFlexibleSpacer())
        return row
    }

    private func makeHotkeyRow() -> NSView {
        let row = horizontalStack(spacing: 6)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        row.setContentHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)

        hotkeyNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hotkeyNameLabel.textColor = .secondaryLabelColor
        hotkeyNameLabel.widthAnchor.constraint(equalToConstant: Metrics.routeLabelWidth).isActive = true

        hotkeyValueLabel.font = NSFont.systemFont(ofSize: 12)
        hotkeyValueLabel.lineBreakMode = .byTruncatingMiddle
        hotkeyValueLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 244).isActive = true
        hotkeyValueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hotkeyValueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureHotkeyButton(recordHotkeyButton, action: #selector(recordHotkeyClicked(_:)), width: 52)
        configureHotkeyButton(clearHotkeyButton, action: #selector(clearHotkeyClicked(_:)), width: 52)
        configureHotkeyButton(resetHotkeyButton, action: #selector(resetHotkeyClicked(_:)), width: 52)

        row.addArrangedSubview(hotkeyNameLabel)
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
        stack.addArrangedSubview(routeRow(stateNameLabel, stateValueLabel))
        stack.addArrangedSubview(routeRow(transcriptionNameLabel, transcriptionValueLabel))
        stack.addArrangedSubview(routeRow(correctionNameLabel, correctionValueLabel))
        stack.addArrangedSubview(routeRow(inputNameLabel, inputValueLabel))
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
        refreshLocalization()
        refreshStatusArea()
        refreshQuickActions()
        refreshHotkeyArea()
        refreshRouteArea()
        refreshDynamicModelSections()
        refreshInputProbeArea()
        resizeVisibleTab()
        updatePreferredContentSize()
    }

    private func refreshLocalization() {
        startButton.title = t("panel.start")
        submitButton.title = t("panel.submit")
        cancelButton.title = t("panel.cancel")
        clearHotkeyButton.title = t("panel.clear")
        resetHotkeyButton.title = t("panel.default")
        microphonePermissionButton.title = t("panel.microphonePermission")
        accessibilityPermissionButton.title = t("panel.accessibilityPermission")
        settingsTitleLabel.stringValue = t("panel.settings")
        permissionsSectionLabel.stringValue = t("panel.permissions")
        languageSectionLabel.stringValue = t("panel.languageSection")
        hotkeySectionLabel.stringValue = t("panel.hotkey")
        languageNameLabel.stringValue = t("panel.language")
        hotkeyNameLabel.stringValue = t("panel.hotkey")
        stateNameLabel.stringValue = "\(t("panel.route.status")):"
        transcriptionNameLabel.stringValue = "\(t("panel.route.transcription")):"
        correctionNameLabel.stringValue = "\(t("panel.route.correction")):"
        inputNameLabel.stringValue = "\(t("panel.route.input")):"
        statusDot.toolTip = t("panel.inputTestTooltip")
        quitButton.toolTip = t("panel.quitTooltip")
        settingsButton.toolTip = t("panel.settings")
        settingsCloseButton.toolTip = t("panel.closeSettings")
        indicatorButton.toolTip = t("panel.floatingIndicatorTooltip")
        tabControl.setLabel(t("panel.tab.transcription"), forSegment: 0)
        tabControl.setLabel(t("panel.tab.correction"), forSegment: 1)
        tabControl.setLabel(t("panel.tab.input"), forSegment: 2)
        tabControl.setEnabled(true, forSegment: 1)
        refreshLanguagePopup()
        refreshMaxMinutesPopupItems()
    }

    private func refreshLanguagePopup() {
        let configured = CodexVoiceI18n.normalize(currentConfig["ui_language"])
        let previousTarget = languagePopup.target
        let previousAction = languagePopup.action
        languagePopup.target = nil
        languagePopup.action = nil
        languagePopup.removeAllItems()
        for language in CodexVoiceI18n.supportedLanguages {
            languagePopup.addItem(withTitle: CodexVoiceI18n.languageLabel(language, config: currentConfig))
            languagePopup.lastItem?.representedObject = language
        }
        if let index = languagePopup.itemArray.firstIndex(where: { item in
            (item.representedObject as? String) == configured
        }) {
            languagePopup.selectItem(at: index)
        }
        languagePopup.target = previousTarget
        languagePopup.action = previousAction
    }

    private func refreshMaxMinutesPopupItems() {
        let selectedIndex = max(0, min(9, Int(currentMaxRecordingMinutes()) - 1))
        let previousTarget = maxMinutesPopup.target
        let previousAction = maxMinutesPopup.action
        maxMinutesPopup.target = nil
        maxMinutesPopup.action = nil
        maxMinutesPopup.removeAllItems()
        for minute in 1...10 {
            maxMinutesPopup.addItem(withTitle: t("panel.minutes", ["minutes": "\(minute)"]))
        }
        maxMinutesPopup.selectItem(at: selectedIndex)
        maxMinutesPopup.target = previousTarget
        maxMinutesPopup.action = previousAction
    }

    private func refreshStatusArea() {
        let testingInput = currentStatus.status == "idle" && (inputTestActive || inputProbeInFlight)
        statusDot.fillColor = testingInput
            ? .systemGreen
            : colorForStatus(currentStatus.status, stale: currentStatus.isStale)
        setText(statusLabel, testingInput ? t("panel.testInput") : localizedStatusLabel(currentStatus))
        setText(durationLabel, durationText())
        refreshMaxMinutesPopup()
        waveformView.toolTip = testingInput ? currentInputProbeResult : nil
        waveformView.setActive(
            currentStatus.status == "recording" || testingInput,
            level: testingInput ? probeLevelFromResult() : 0.42
        )

        let stageDetail = localizedStatusDetail(currentStatus)
        setText(stageLabel, t("panel.stage", ["value": stageDetail]))

        guard let task = currentModelTask else {
            setText(modelTaskLabel, t("panel.modelIdle"))
            setText(modelTaskDetailLabel, " ")
            modelProgress.stopAnimation(nil)
            modelProgress.isHidden = true
            modelProgress.doubleValue = 0
            return
        }

        let statusText: String
        switch task.status {
        case "running": statusText = t("panel.modelRunning")
        case "succeeded": statusText = t("panel.modelSucceeded")
        case "failed": statusText = t("panel.modelFailed")
        default: statusText = task.status
        }
        let taskLabel = CodexVoiceI18n.modelTaskText(
            label: task.label,
            key: task.labelKey,
            args: task.labelArgs,
            config: currentConfig
        )
        let taskDetail = CodexVoiceI18n.modelTaskText(
            label: task.detail,
            key: task.detailKey,
            args: task.detailArgs,
            config: currentConfig
        )
        setText(modelTaskLabel, t("panel.model", ["status": statusText, "label": taskLabel]))
        setText(modelTaskDetailLabel, taskDetail.isEmpty ? " " : taskDetail)
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
        recordHotkeyButton.title = isRecordingHotkey ? t("panel.cancel") : t("panel.record")
        let enabled = configBool("native_hotkey_enabled", defaultValue: true)
        clearHotkeyButton.isEnabled = enabled && !isRecordingHotkey
        resetHotkeyButton.isEnabled = !isRecordingHotkey

        guard !isRecordingHotkey else {
            hotkeyValueLabel.textColor = .systemYellow
            setText(hotkeyValueLabel, t("panel.pressHotkey"))
            return
        }

        hotkeyValueLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
        let hotkey = NativeHotkey.from(config: currentConfig)
        let base = enabled ? hotkey.displayName : t("panel.hotkeyOff")
        let localizedStatus = localizedNativeHotkeyStatus(currentNativeHotkeyStatus)
        let status = localizedStatus.isEmpty ? "" : " · \(localizedStatus)"
        setText(hotkeyValueLabel, "\(base)\(status)")
    }

    private func refreshRouteArea() {
        let label = localizedStatusLabel(currentStatus)
        let detail = localizedStatusDetail(currentStatus)
        let stateDetail = detail == label ? label : "\(label) · \(detail)"
        setText(stateValueLabel, stateDetail)
        setText(transcriptionValueLabel, transcriptionLabel())
        setText(correctionValueLabel, correctionLabel())
        setText(inputValueLabel, inputLabel())
    }

    private func refreshDynamicModelSections() {
        let languageSignature = CodexVoiceI18n.resolved(config: currentConfig)
        let route = processingRoute()
        let directSelection = stringConfig("direct_asr_model", defaultValue: "")
        let transcriptionSelection = stringConfig("transcription_model", defaultValue: "")
        let primaryModels = primaryModelRows()
        let transcriptionSig = [
            languageSignature,
            route,
            directSelection,
            transcriptionSelection,
            primaryModels.isEmpty && scanningModels ? "scanning" : "ready",
            primaryModels.map {
                "\($0.prefix):\($0.model.id):\($0.model.installed):\($0.model.loaded):\($0.model.parameterSize):\($0.model.architecture):\($0.model.quantization)"
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
            languageSignature,
            route,
            configBool("correction_enabled", defaultValue: false) ? "enabled" : "disabled",
            stringConfig("correction_model", defaultValue: ""),
            currentMaintenance.modelServiceStatusCode,
            currentMaintenance.modelServiceSocket,
            currentCorrectionModels.isEmpty && scanningModels ? "scanning" : "ready",
            currentCorrectionModels.map {
                "\($0.id):\($0.installed):\($0.loaded):\($0.parameterSize):\($0.architecture):\($0.quantization)"
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
            languageSignature,
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

        let route = processingRoute()
        let models = primaryModelRows()
        let directSelection = stringConfig("direct_asr_model", defaultValue: "")
        let transcriptionSelection = stringConfig("transcription_model", defaultValue: "")
        if scanningModels {
            transcriptionCardsStack.addArrangedSubview(statusCard(
                t("card.localModel"),
                t("card.scanning"),
                "-",
                "-",
                "-"
            ))
        } else if models.isEmpty {
            transcriptionCardsStack.addArrangedSubview(statusCard(
                t("card.localModel"),
                t("card.noTranscription"),
                "-",
                currentMaintenance.modelServiceStatus,
                "-"
            ))
        } else {
            for item in models {
                let model = item.model
                let title = model.installed
                    ? model.name
                    : t("card.notInstalled", ["model": model.name])
                let selected = item.prefix == "direct"
                    ? route == "direct_asr" && directSelection == model.id
                    : route == "two_stage" && transcriptionSelection == model.id
                transcriptionCardsStack.addArrangedSubview(cardButton(
                    source: t("card.localModel"),
                    title: title,
                    modelType: localizedModelType(model.modelType),
                    parameter: parameterText(for: model),
                    architecture: architectureText(for: model),
                    vendor: vendorText(for: model),
                    value: "\(item.prefix):\(model.id)",
                    selected: selected,
                    action: #selector(transcriptionChoiceClicked(_:)),
                    enabled: true,
                    modelID: model.id,
                    unloadValue: model.loaded ? model.id : nil,
                    unloadAction: #selector(unloadLocalModelClicked(_:))
                ))
            }
        }
    }

    private func rebuildCorrectionOptions() {
        removeAllArrangedSubviews(from: correctionCardsStack)

        let enabled = configBool("correction_enabled", defaultValue: false)
        let selected = stringConfig("correction_model", defaultValue: "")
        if scanningModels {
            correctionCardsStack.addArrangedSubview(statusCard(
                t("card.localModel"),
                t("card.scanning"),
                "-",
                "-",
                "-"
            ))
        } else if currentCorrectionModels.isEmpty {
            correctionCardsStack.addArrangedSubview(statusCard(
                t("card.localModel"),
                t("card.noCorrection"),
                "-",
                currentMaintenance.modelServiceStatus,
                "-"
            ))
        } else {
            for model in currentCorrectionModels {
                let title = model.installed
                    ? model.name
                    : t("card.notInstalled", ["model": model.name])
                correctionCardsStack.addArrangedSubview(cardButton(
                    source: t("card.localModel"),
                    title: title,
                    modelType: localizedModelType(model.modelType),
                    parameter: parameterText(for: model),
                    architecture: architectureText(for: model),
                    vendor: vendorText(for: model),
                    value: "correction:\(model.id)",
                    selected: enabled && selected == model.id,
                    action: #selector(correctionChoiceClicked(_:)),
                    enabled: true,
                    modelID: model.id,
                    unloadValue: model.loaded ? model.id : nil,
                    unloadAction: #selector(unloadLocalModelClicked(_:))
                ))
            }
        }
    }

    private func rebuildInputOptions() {
        removeAllArrangedSubviews(from: inputCardsStack)

        let configured = currentConfig["input_device"] as? String
        let defaultName = currentInputDevices.first(where: { $0.isDefault })?.name
        let defaultTitle: String
        if let defaultName, !defaultName.isEmpty {
            defaultTitle = t("card.systemDefaultInputNamed", ["name": defaultName])
        } else {
            defaultTitle = t("card.systemDefaultInput")
        }
        inputCardsStack.addArrangedSubview(cardButton(
            source: t("card.default"),
            title: defaultTitle,
            modelType: t("card.input"),
            parameter: t("card.auto"),
            architecture: t("card.coreAudio"),
            vendor: t("card.macOS"),
            value: "__default__",
            selected: configured == nil || configured?.isEmpty == true,
            action: #selector(inputChoiceClicked(_:)),
            width: Metrics.inputCardWidth
        ))

        if currentInputDevices.isEmpty {
            let title = scanningModels ? t("card.scanningInput") : t("card.noMicrophone")
            inputCardsStack.addArrangedSubview(statusCard(
                t("card.input"),
                title,
                "-",
                t("card.coreAudio"),
                t("card.macOS"),
                width: Metrics.inputCardWidth
            ))
        } else {
            for device in currentInputDevices {
                let title = device.isDefault
                    ? "\(device.name) \(t("menu.currentSystemDefault"))"
                    : device.name
                let channels = device.channels.map { "\($0) ch" } ?? t("card.unknown")
                inputCardsStack.addArrangedSubview(cardButton(
                    source: t("card.microphone"),
                    title: title,
                    modelType: t("card.microphone"),
                    parameter: channels,
                    architecture: t("card.coreAudioInput"),
                    vendor: device.isDefault ? t("card.macOSDefault") : t("card.audioDevice"),
                    value: device.name,
                    selected: configured == device.name,
                    action: #selector(inputChoiceClicked(_:)),
                    width: Metrics.inputCardWidth
                ))
            }
        }
    }

    private func refreshInputProbeArea() {
        probeButton.title = inputProbeInFlight ? t("panel.testing") : t("panel.testInput")
        probeButton.isEnabled = !inputProbeInFlight
        setText(
            probeResultLabel,
            currentInputProbeResult.isEmpty ? t("panel.notTested") : currentInputProbeResult
        )

        let minutes = currentMaxRecordingMinutes()
        setText(maxMinutesLabel, t("panel.maxMinutes", ["minutes": "\(Int(minutes))"]))
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
        let runningTask = currentModelTask?.status == "running"
            && ["download", "load"].contains(currentModelTask?.phase ?? "")
            ? currentModelTask
            : nil
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
            let matchingTask = task?.modelID == card.modelID ? task : nil
            card.setLoadingTask(matchingTask, config: currentConfig)
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
        modelType: String? = nil,
        parameter: String,
        architecture: String,
        vendor: String,
        value: String,
        selected: Bool,
        action: Selector,
        enabled: Bool = true,
        modelID: String? = nil,
        unloadValue: String? = nil,
        unloadAction: Selector? = nil,
        width: CGFloat = Metrics.modelCardWidth
    ) -> NSView {
        var rows: [(String, String)] = []
        if let modelType {
            rows.append((t("card.type"), modelType))
        }
        rows.append(contentsOf: [
            (t("card.parameter"), parameter),
            (t("card.architecture"), architecture),
            (t("card.vendor"), vendor)
        ])
        let card = CardChoiceView(
            source: source,
            title: title,
            rows: rows,
            selected: selected,
            enabled: enabled,
            width: width
        )
        card.identifier = NSUserInterfaceItemIdentifier(value)
        if let modelID {
            card.setModelID(modelID)
        }
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
        _ parameter: String,
        _ architecture: String,
        _ vendor: String,
        width: CGFloat = Metrics.modelCardWidth
    ) -> NSView {
        return CardChoiceView(
            source: source,
            title: title,
            rows: [
                (t("card.type"), source),
                (t("card.parameter"), parameter),
                (t("card.architecture"), architecture),
                (t("card.vendor"), vendor)
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

    private func parameterText(for model: LocalModel) -> String {
        if !model.parameterSize.isEmpty {
            return model.parameterSize
        }
        return t("card.unknown")
    }

    private func architectureText(for model: LocalModel) -> String {
        let base = model.architecture.isEmpty
            ? inferredArchitecture(from: model.name)
            : model.architecture
        if model.quantization.isEmpty {
            return base
        }
        return "\(base) · \(model.quantization)"
    }

    private func vendorText(for model: LocalModel) -> String {
        model.vendor.isEmpty ? t("card.unknown") : model.vendor
    }

    private func localizedModelType(_ type: String) -> String {
        switch type {
        case "direct_asr":
            return t("card.type.transcription")
        case "transcription":
            return t("card.type.transcription")
        case "text_correction":
            return t("card.type.textCorrection")
        default:
            return type.isEmpty ? t("card.unknown") : type
        }
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

    private func routeRow(_ nameLabel: NSTextField, _ valueLabel: NSTextField) -> NSView {
        let row = horizontalStack(spacing: 3)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
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
        let nameLabel = NSTextField(labelWithString: "\(name):")
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
        configureCompactButton(button, action: action, width: width)
        return button
    }

    private func configureCompactButton(_ button: NSButton, action: Selector, width: CGFloat) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func configureSettingsButton() {
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked(_:))
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        if #available(macOS 11.0, *) {
            settingsButton.image = NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: "Settings"
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
        stack.addArrangedSubview(configureSettingsSectionLabel(languageSectionLabel))
        stack.addArrangedSubview(makeLanguageSettingsRow())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(configureSettingsSectionLabel(permissionsSectionLabel))
        stack.addArrangedSubview(makePermissionSettingsRow())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(configureSettingsSectionLabel(hotkeySectionLabel))
        stack.addArrangedSubview(makeHotkeyRow())
    }

    private func makeSettingsHeader() -> NSView {
        let row = horizontalStack(spacing: 8)
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true

        settingsTitleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        settingsTitleLabel.textColor = .labelColor
        row.addArrangedSubview(settingsTitleLabel)
        row.addArrangedSubview(makeFlexibleSpacer())

        settingsCloseButton.target = self
        settingsCloseButton.action = #selector(settingsCloseClicked(_:))
        settingsCloseButton.isBordered = false
        settingsCloseButton.imagePosition = .imageOnly
        settingsCloseButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        settingsCloseButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        if #available(macOS 11.0, *) {
            settingsCloseButton.image = NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: "Close settings"
            )
            settingsCloseButton.contentTintColor = .secondaryLabelColor
        } else {
            settingsCloseButton.title = "×"
            settingsCloseButton.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        }
        row.addArrangedSubview(settingsCloseButton)
        return row
    }

    private func configureSettingsSectionLabel(_ label: NSTextField) -> NSTextField {
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        return label
    }

    private func configureHotkeyButton(_ button: NSButton, action: Selector, width: CGFloat) {
        button.target = self
        button.action = action
        configureAdaptiveTextButton(button, minWidth: width, fontSize: 11)
    }

    private func configureAdaptiveTextButton(
        _ button: NSButton,
        minWidth: CGFloat,
        fontSize: CGFloat? = nil
    ) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        if let fontSize {
            button.font = NSFont.systemFont(ofSize: fontSize)
        }
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureIndicatorButton() {
        indicatorButton.target = self
        indicatorButton.action = #selector(indicatorClicked(_:))
        indicatorButton.bezelStyle = .rounded
        indicatorButton.controlSize = .small
        indicatorButton.imagePosition = .imageOnly
        if #available(macOS 11.0, *) {
            indicatorButton.image = NSImage(
                systemSymbolName: "macwindow",
                accessibilityDescription: "Recording indicator"
            ) ?? NSImage(
                systemSymbolName: "rectangle",
                accessibilityDescription: "Recording indicator"
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

    private func t(_ key: String, _ args: [String: String] = [:]) -> String {
        CodexVoiceI18n.text(key, config: currentConfig, args)
    }

    private func localizedStatusLabel(_ status: VoiceStatus) -> String {
        let key = status.labelKey.isEmpty ? "status.\(status.status)" : status.labelKey
        return CodexVoiceI18n.text(key, config: currentConfig)
    }

    private func localizedStatusDetail(_ status: VoiceStatus) -> String {
        if !status.detailKey.isEmpty {
            return CodexVoiceI18n.text(status.detailKey, config: currentConfig, status.detailArgs)
        }
        if !status.detail.isEmpty {
            return status.detail
        }
        return localizedStatusLabel(status)
    }

    private func localizedNativeHotkeyStatus(_ status: String) -> String {
        if status.isEmpty || status == "unregistered" {
            return ""
        }
        if status == "registered" {
            return t("panel.hotkeyRegistered")
        }
        if status == "disabled" {
            return t("panel.hotkeyDisabled")
        }
        if status == "unavailable" || status == "rejected" {
            return t("panel.hotkeyUnavailable")
        }
        if status.hasPrefix("conflict:") {
            return t("panel.hotkeyMaybeConflict", ["status": String(status.dropFirst("conflict:".count))])
        }
        return status
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

    private func processingRoute() -> String {
        stringConfig("processing_route", defaultValue: "direct_asr")
    }

    private func transcriptionLabel() -> String {
        let direct = processingRoute() == "direct_asr"
        let modelID = direct
            ? stringConfig("direct_asr_model", defaultValue: "")
            : stringConfig("transcription_model", defaultValue: "")
        let models = direct ? currentDirectASRModels : currentTranscriptionModels
        return models.first(where: { $0.id == modelID })?.name
            ?? (modelID.isEmpty ? t("card.noTranscription") : modelID)
    }

    private func primaryModelRows() -> [(prefix: String, model: LocalModel)] {
        currentDirectASRModels.map { (prefix: "direct", model: $0) }
            + currentTranscriptionModels.map { (prefix: "transcription", model: $0) }
    }

    private func correctionLabel() -> String {
        if !configBool("correction_enabled", defaultValue: false) {
            return t("label.correctionNotUsed")
        }
        let modelID = stringConfig("correction_model", defaultValue: "")
        return currentCorrectionModels.first(where: { $0.id == modelID })?.name
            ?? (modelID.isEmpty ? t("card.noCorrection") : modelID)
    }

    private func inputLabel() -> String {
        if let configured = currentConfig["input_device"] as? String, !configured.isEmpty {
            return configured
        }
        if let defaultName = currentInputDevices.first(where: { $0.isDefault })?.name,
           !defaultName.isEmpty {
            return t("label.systemDefaultInputNamed", ["name": defaultName])
        }
        return t("label.systemDefaultInput")
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
            setText(hotkeyValueLabel, t("panel.pressCombination"))
            return
        }
        if let status = NativeHotkeyConflictChecker.publicAPIStatus(for: hotkey),
           status != noErr {
            hotkeyValueLabel.textColor = .systemRed
            setText(hotkeyValueLabel, t("panel.hotkeyRejected"))
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
                setText(
                    hotkeyValueLabel,
                    t("panel.pressAgain", ["key": NativeHotkey.displayModifier(modifier)])
                )
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

    @objc private func unloadLocalModelClicked(_ sender: NSControl) {
        guard let model = sender.identifier?.rawValue, !model.isEmpty else {
            return
        }
        onUnloadLocalModel?(model)
    }

    @objc private func probeInputClicked(_ sender: Any?) {
        onProbeInput?()
    }

    @objc private func maxMinutesChanged(_ sender: NSStepper) {
        setText(maxMinutesLabel, t("panel.maxMinutes", ["minutes": "\(Int(sender.doubleValue))"]))
        onSetMaxMinutes?(sender.doubleValue)
    }

    @objc private func maxMinutesPopupChanged(_ sender: NSPopUpButton) {
        let minutes = Double(max(1, sender.indexOfSelectedItem + 1))
        onSetMaxMinutes?(minutes)
    }

    @objc private func languagePopupChanged(_ sender: NSPopUpButton) {
        guard let language = sender.selectedItem?.representedObject as? String else {
            return
        }
        onSetUILanguage?(language)
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

import Cocoa
import Foundation
import ApplicationServices
import AVFoundation

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
            let documentWidth = scrollView.documentView?.bounds.width ?? 0
            let visibleWidth = scrollView.contentView.bounds.width
            let maxX = max(0, documentWidth - visibleWidth)
            guard maxX > 0 else {
                continue
            }
            if abs(deltaX) > 3 {
                didDrag = true
            }
            if didDrag {
                let nextX = min(max(startOrigin.x - deltaX, 0), maxX)
                scrollView.contentView.scroll(to: NSPoint(x: nextX, y: startOrigin.y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        case .leftMouseUp:
            if didDrag {
                snapHorizontalScrollView(scrollView)
            }
            shouldContinue = false
        default:
            break
        }
    }

    return didDrag
}

private func snapHorizontalScrollView(_ scrollView: NSScrollView) {
    guard let documentView = scrollView.documentView else {
        return
    }
    documentView.layoutSubtreeIfNeeded()
    let visibleWidth = scrollView.contentView.bounds.width
    let maxX = max(0, documentView.bounds.width - visibleWidth)
    guard maxX > 0 else {
        return
    }

    let current = scrollView.contentView.bounds.origin
    let step = max(1, horizontalPageStep(for: scrollView))
    let rawPage = floor((current.x + step * 0.5) / step)
    let targetX = min(max(rawPage * step, 0), maxX)
    animateHorizontalScrollView(scrollView, to: NSPoint(x: targetX, y: current.y))
}

private func horizontalPageStep(for scrollView: NSScrollView) -> CGFloat {
    guard let documentView = scrollView.documentView,
          let stack = documentView.subviews.compactMap({ $0 as? NSStackView }).first,
          let firstCard = stack.arrangedSubviews.first else {
        return scrollView.contentView.bounds.width
    }
    stack.layoutSubtreeIfNeeded()
    firstCard.layoutSubtreeIfNeeded()
    let cardWidth = max(firstCard.bounds.width, firstCard.fittingSize.width)
    return cardWidth + stack.spacing
}

private func animateHorizontalScrollView(_ scrollView: NSScrollView, to origin: NSPoint) {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.allowsImplicitAnimation = true
        scrollView.contentView.animator().setBoundsOrigin(origin)
    } completionHandler: {
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
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

final class EventBlockingVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden,
              alphaValue > 0.01,
              bounds.contains(point) else {
            return nil
        }
        return super.hitTest(point) ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

final class AudioWaveformView: NSView {
    private static let levelCount = 36
    private var levels = Array(
        repeating: CGFloat(0.08),
        count: AudioWaveformView.levelCount
    )
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
    private let loadingOverlay = NSVisualEffectView()
    private let loadingLabel = NSTextField(labelWithString: "")
    private let loadingDetailLabel = NSTextField(labelWithString: " ")
    private let loadingProgress = NSProgressIndicator()
    private var uniformHeightConstraint: NSLayoutConstraint?
    private(set) var isSelectedCard = false
    private(set) var modelID: String?

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

    func setLoadingTask(_ task: ModelTask?, config: [String: Any]) {
        guard let task else {
            loadingProgress.stopAnimation(nil)
            loadingOverlay.isHidden = true
            return
        }

        loadingOverlay.isHidden = false
        loadingLabel.stringValue = task.label.isEmpty
            ? CodexVoiceI18n.text("menu.modelPreparing", config: config)
            : task.label
        loadingDetailLabel.isHidden = task.detail.isEmpty
        loadingDetailLabel.stringValue = task.detail

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

    func setModelID(_ modelID: String) {
        self.modelID = modelID
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
        loadingOverlay.material = .hudWindow
        loadingOverlay.blendingMode = .withinWindow
        loadingOverlay.state = .active
        loadingOverlay.wantsLayer = true
        loadingOverlay.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.08,
            alpha: 0.28
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

        loadingProgress.translatesAutoresizingMaskIntoConstraints = false
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

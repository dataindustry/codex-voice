import Cocoa
import Foundation

final class RecordingIndicator: NSObject, NSApplicationDelegate {
    private let parentPID: pid_t
    private let maxSeconds: TimeInterval
    private let startedAt = Date()

    private var window: NSPanel?
    private var dot: NSView?
    private var timerLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    init(parentPID: pid_t, maxSeconds: TimeInterval) {
        self.parentPID = parentPID
        self.maxSeconds = maxSeconds
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        installSignalHandlers()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func buildWindow() {
        let width: CGFloat = 310
        let height: CGFloat = 104
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = max(screen.minX + 20, screen.maxX - width - 28)
        let y = screen.maxY - height - 28

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        panel.contentView = content

        let dotView = NSView(frame: NSRect(x: 17, y: 73, width: 12, height: 12))
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 6
        content.addSubview(dotView)
        dot = dotView

        let title = label(
            text: "REC  正在录音",
            frame: NSRect(x: 39, y: 65, width: 240, height: 28),
            font: .boldSystemFont(ofSize: 16),
            color: .white
        )
        content.addSubview(title)

        let timerText = label(
            text: "00:00 / 05:00",
            frame: NSRect(x: 14, y: 31, width: 260, height: 28),
            font: .monospacedDigitSystemFont(ofSize: 20, weight: .bold),
            color: NSColor(calibratedWhite: 0.95, alpha: 1)
        )
        content.addSubview(timerText)
        timerLabel = timerText

        let hint = label(
            text: "再按一次快捷键结束并转写",
            frame: NSRect(x: 14, y: 12, width: 280, height: 20),
            font: .systemFont(ofSize: 12),
            color: NSColor(calibratedWhite: 0.73, alpha: 1)
        )
        content.addSubview(hint)
        hintLabel = hint

        panel.orderFrontRegardless()
        window = panel
    }

    private func label(
        text: String,
        frame: NSRect,
        font: NSFont,
        color: NSColor
    ) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.stringValue = text
        field.font = font
        field.textColor = color
        field.backgroundColor = .clear
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byClipping
        return field
    }

    private func refresh() {
        guard processAlive(parentPID) else {
            NSApp.terminate(nil)
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        timerLabel?.stringValue = "\(formatSeconds(elapsed)) / \(formatSeconds(maxSeconds))"

        let remaining = max(0, maxSeconds - elapsed)
        if remaining <= 30 {
            hintLabel?.stringValue = "即将达到 5 分钟上限"
            hintLabel?.textColor = NSColor.systemYellow
        } else {
            hintLabel?.stringValue = "再按一次快捷键结束并转写"
            hintLabel?.textColor = NSColor(calibratedWhite: 0.73, alpha: 1)
        }

        let blinkOn = Int(elapsed * 2) % 2 == 0
        dot?.layer?.backgroundColor = (blinkOn ? NSColor.systemRed : NSColor(calibratedRed: 0.48, green: 0.12, blue: 0.10, alpha: 1)).cgColor
        window?.orderFrontRegardless()
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func processAlive(_ pid: pid_t) -> Bool {
        if pid <= 0 {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

func argumentValue(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
        return nil
    }
    return args[index + 1]
}

let parentPID = pid_t(Int32(argumentValue(after: "--parent-pid") ?? "0") ?? 0)
let maxSeconds = TimeInterval(Double(argumentValue(after: "--max-seconds") ?? "300") ?? 300)

let app = NSApplication.shared
let delegate = RecordingIndicator(parentPID: parentPID, maxSeconds: maxSeconds)
app.delegate = delegate
app.run()

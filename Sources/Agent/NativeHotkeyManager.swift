import Cocoa
import Carbon
import Foundation

enum NativeHotkeyKind: String {
    case keyCombination = "key_combination"
    case doubleModifier = "double_modifier"
}

struct NativeHotkey: Equatable {
    static let defaultHotkey = NativeHotkey(
        keyCode: 49,
        key: "space",
        modifiers: ["option"]
    )

    let keyCode: UInt32
    let key: String
    let modifiers: [String]
    let kind: NativeHotkeyKind
    let modifier: String?
    let tapCount: Int

    init(
        keyCode: UInt32,
        key: String,
        modifiers: [String],
        kind: NativeHotkeyKind = .keyCombination,
        modifier: String? = nil,
        tapCount: Int = 2
    ) {
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
        self.kind = kind
        self.modifier = modifier
        self.tapCount = tapCount
    }

    var configValue: [String: Any] {
        var value: [String: Any] = [
            "kind": kind.rawValue,
            "key_code": NSNumber(value: keyCode),
            "key": key,
            "modifiers": modifiers
        ]
        if kind == .doubleModifier {
            value["modifier"] = modifier ?? key
            value["tap_count"] = NSNumber(value: tapCount)
        }
        return value
    }

    var displayName: String {
        if kind == .doubleModifier {
            return "Double \(NativeHotkey.displayModifier(modifier ?? key))"
        }
        let prefix = NativeHotkey.modifierSymbols
            .filter { modifiers.contains($0.name) }
            .map(\.symbol)
            .joined()
        return "\(prefix)\(NativeHotkey.displayKey(key))"
    }

    var requiresPublicAPIConflictCheck: Bool {
        kind == .keyCombination
    }

    static func from(config: [String: Any]) -> NativeHotkey {
        guard let value = config["native_hotkey"] as? [String: Any] else {
            return defaultHotkey
        }

        if value["kind"] as? String == NativeHotkeyKind.doubleModifier.rawValue {
            let modifier = normalizedModifier(value["modifier"] as? String) ?? "control"
            let tapCount = (value["tap_count"] as? NSNumber)?.intValue
                ?? (value["tap_count"] as? Int)
                ?? 2
            return NativeHotkey(
                keyCode: UInt32(keyCode(forModifier: modifier)),
                key: modifier,
                modifiers: [],
                kind: .doubleModifier,
                modifier: modifier,
                tapCount: max(2, tapCount)
            )
        }

        let keyCode: UInt32
        if let number = value["key_code"] as? NSNumber {
            keyCode = number.uint32Value
        } else if let intValue = value["key_code"] as? Int {
            keyCode = UInt32(max(0, intValue))
        } else {
            keyCode = defaultHotkey.keyCode
        }
        let key = (value["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultHotkey.key
        let modifiers = (value["modifiers"] as? [String])?.compactMap(normalizedModifier)
        return NativeHotkey(
            keyCode: keyCode,
            key: key,
            modifiers: modifiers?.isEmpty == false ? modifiers! : defaultHotkey.modifiers
        )
    }

    static func from(event: NSEvent) -> NativeHotkey? {
        guard event.type == .keyDown else {
            return nil
        }
        let modifiers = modifierNames(from: event.modifierFlags)
        guard !modifiers.isEmpty else {
            return nil
        }
        guard let key = keyName(from: event), !key.isEmpty else {
            return nil
        }
        return NativeHotkey(
            keyCode: UInt32(event.keyCode),
            key: key,
            modifiers: modifiers
        )
    }

    static func doubleModifier(_ modifier: String) -> NativeHotkey? {
        guard let modifier = normalizedModifier(modifier) else {
            return nil
        }
        return NativeHotkey(
            keyCode: UInt32(keyCode(forModifier: modifier)),
            key: modifier,
            modifiers: [],
            kind: .doubleModifier,
            modifier: modifier,
            tapCount: 2
        )
    }

    func matchesKeyDown(_ event: NSEvent) -> Bool {
        guard kind == .keyCombination,
              event.type == .keyDown,
              !event.isARepeat,
              UInt32(event.keyCode) == keyCode else {
            return false
        }
        return Set(NativeHotkey.modifierNames(from: event.modifierFlags)) == Set(modifiers)
    }

    static func modifierName(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 59, 62:
            return "control"
        case 58, 61:
            return "option"
        case 56, 60:
            return "shift"
        case 54, 55:
            return "command"
        default:
            return nil
        }
    }

    static func modifierIsPressed(_ modifier: String, in flags: NSEvent.ModifierFlags) -> Bool {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        switch modifier {
        case "control":
            return normalized.contains(.control)
        case "option":
            return normalized.contains(.option)
        case "shift":
            return normalized.contains(.shift)
        case "command":
            return normalized.contains(.command)
        default:
            return false
        }
    }

    static func onlyModifier(_ modifier: String, isActiveIn flags: NSEvent.ModifierFlags) -> Bool {
        let active = Set(modifierNames(from: flags))
        return active.isEmpty || active == [modifier]
    }

    static func displayModifier(_ modifier: String) -> String {
        switch modifier {
        case "control":
            return "Ctrl"
        case "option":
            return "Option"
        case "shift":
            return "Shift"
        case "command":
            return "Command"
        default:
            return modifier
        }
    }

    static func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        var names: [String] = []
        if normalized.contains(.control) {
            names.append("control")
        }
        if normalized.contains(.option) {
            names.append("option")
        }
        if normalized.contains(.shift) {
            names.append("shift")
        }
        if normalized.contains(.command) {
            names.append("command")
        }
        return names
    }

    private static let modifierSymbols: [(name: String, symbol: String)] = [
        ("control", "⌃"),
        ("option", "⌥"),
        ("shift", "⇧"),
        ("command", "⌘")
    ]

    private static func normalizedModifier(_ value: String?) -> String? {
        let normalized = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == "ctrl" {
            return "control"
        }
        if modifierSymbols.contains(where: { $0.name == normalized }) {
            return normalized
        }
        return nil
    }

    private static func keyCode(forModifier modifier: String) -> UInt16 {
        switch modifier {
        case "control":
            return 59
        case "option":
            return 58
        case "shift":
            return 56
        case "command":
            return 55
        default:
            return 59
        }
    }

    private static func keyName(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 36:
            return "return"
        case 48:
            return "tab"
        case 49:
            return "space"
        case 51:
            return "delete"
        case 53:
            return "escape"
        default:
            let text = (event.charactersIgnoringModifiers ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                return nil
            }
            return text.lowercased()
        }
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "space":
            return "Space"
        case "return":
            return "Return"
        case "tab":
            return "Tab"
        case "delete":
            return "Delete"
        case "escape":
            return "Esc"
        default:
            return key.uppercased()
        }
    }
}

final class NativeHotkeyManager {
    private static let doubleTapInterval: TimeInterval = 0.45
    private static let doubleTapCooldown: TimeInterval = 0.75

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hotkey: NativeHotkey?
    private var modifierIsDown = false
    private var waitsForModifierRelease = false
    private var lastModifierTapTime: TimeInterval = 0
    private var lastFireTime: TimeInterval = 0
    private var onPress: (() -> Void)?

    deinit {
        unregister()
    }

    func register(_ hotkey: NativeHotkey, onPress: @escaping () -> Void) -> OSStatus {
        unregister()
        self.hotkey = hotkey
        self.onPress = onPress

        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        return noErr
    }

    func unregister() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        hotkey = nil
        onPress = nil
        modifierIsDown = false
        waitsForModifierRelease = false
        lastModifierTapTime = 0
        lastFireTime = 0
    }

    private func handle(_ event: NSEvent) {
        guard let hotkey else {
            return
        }
        switch hotkey.kind {
        case .keyCombination:
            if hotkey.matchesKeyDown(event) {
                fire()
            }
        case .doubleModifier:
            handleDoubleModifier(event, hotkey: hotkey)
        }
    }

    private func handleDoubleModifier(_ event: NSEvent, hotkey: NativeHotkey) {
        guard event.type == .flagsChanged,
              let targetModifier = hotkey.modifier ?? Optional(hotkey.key),
              NativeHotkey.modifierName(forKeyCode: event.keyCode) == targetModifier else {
            return
        }
        guard NativeHotkey.onlyModifier(targetModifier, isActiveIn: event.modifierFlags) else {
            modifierIsDown = false
            lastModifierTapTime = 0
            return
        }

        let now = event.timestamp
        let isDown = NativeHotkey.modifierIsPressed(targetModifier, in: event.modifierFlags)
        if !isDown {
            modifierIsDown = false
            if waitsForModifierRelease {
                waitsForModifierRelease = false
            }
            return
        }
        if waitsForModifierRelease || now - lastFireTime < NativeHotkeyManager.doubleTapCooldown {
            modifierIsDown = true
            return
        }
        if isDown && !modifierIsDown {
            if lastModifierTapTime > 0
                && now - lastModifierTapTime <= NativeHotkeyManager.doubleTapInterval {
                lastModifierTapTime = 0
                lastFireTime = now
                waitsForModifierRelease = true
                fire()
            } else {
                lastModifierTapTime = now
            }
            modifierIsDown = true
        }
    }

    private func fire() {
        DispatchQueue.main.async { [weak self] in
            self?.onPress?()
        }
    }
}

enum NativeHotkeyConflictChecker {
    private static let signature: OSType = 0x43564854

    static func publicAPIStatus(for hotkey: NativeHotkey) -> OSStatus? {
        guard hotkey.requiresPublicAPIConflictCheck else {
            return nil
        }

        let hotKeyID = EventHotKeyID(
            signature: NativeHotkeyConflictChecker.signature,
            id: 1
        )
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            carbonModifiers(from: hotkey.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref {
            UnregisterEventHotKey(ref)
        }
        return status
    }

    private static func carbonModifiers(from modifiers: [String]) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains("control") {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains("option") {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains("shift") {
            flags |= UInt32(shiftKey)
        }
        if modifiers.contains("command") {
            flags |= UInt32(cmdKey)
        }
        return flags
    }
}

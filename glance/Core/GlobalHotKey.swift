//
//  GlobalHotKey.swift
//  glance
//
//  Global hotkey shortcut model and Carbon RegisterEventHotKey wrapper.
//  Registers system-wide shortcuts even when glance runs as a background accessory app.
//

import AppKit
import Carbon
import Foundation

nonisolated struct HotKeyShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    /// Default global toggle shortcut: ⌃⌥⌘F.
    static let defaultToggleFaceUnlock = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_F),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    enum KeyDownAction: Equatable {
        case cancel
        case clear
        case assign(HotKeyShortcut)
        case ignore
    }

    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyLabel(for: keyCode)
        return result
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func modifierFlags(from carbonModifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    static func classify(keyDownEvent event: NSEvent) -> KeyDownAction {
        classify(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
    }

    static func classify(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> KeyDownAction {
        let rawCode = UInt32(keyCode)
        let relevantFlags = modifierFlags.intersection([.command, .control, .option, .shift])

        if relevantFlags.isEmpty {
            if rawCode == UInt32(kVK_Escape) { return .cancel }
            if rawCode == UInt32(kVK_Delete) || rawCode == UInt32(kVK_ForwardDelete) { return .clear }
        }

        let hasPrimaryModifier = !relevantFlags.isDisjoint(with: [.command, .control, .option])
        guard hasPrimaryModifier, !isModifierOnlyKeyCode(rawCode) else {
            return .ignore
        }

        return .assign(
            HotKeyShortcut(
                keyCode: rawCode,
                carbonModifiers: carbonModifiers(from: relevantFlags)
            ))
    }

    private static func isModifierOnlyKeyCode(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control,
            kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl, kVK_Function:
            return true
        default:
            return false
        }
    }

    private static let keyLabels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".",
        kVK_ANSI_Grave: "`", kVK_ISO_Section: "§",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Help",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_Keypad0: "KP0", kVK_ANSI_Keypad1: "KP1",
        kVK_ANSI_Keypad2: "KP2", kVK_ANSI_Keypad3: "KP3",
        kVK_ANSI_Keypad4: "KP4", kVK_ANSI_Keypad5: "KP5",
        kVK_ANSI_Keypad6: "KP6", kVK_ANSI_Keypad7: "KP7",
        kVK_ANSI_Keypad8: "KP8", kVK_ANSI_Keypad9: "KP9",
        kVK_ANSI_KeypadDecimal: "KP.", kVK_ANSI_KeypadMultiply: "KP*",
        kVK_ANSI_KeypadPlus: "KP+", kVK_ANSI_KeypadClear: "⌧",
        kVK_ANSI_KeypadDivide: "KP/", kVK_ANSI_KeypadEnter: "⌤",
        kVK_ANSI_KeypadMinus: "KP-", kVK_ANSI_KeypadEquals: "KP="
    ]

    static func keyLabel(for keyCode: UInt32) -> String {
        keyLabels[Int(keyCode)] ?? "Key(\(keyCode))"
    }
}

@MainActor
final class GlobalHotKey {
    var onHotKey: (() -> Void)?

    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private var registeredShortcut: HotKeyShortcut?

    private nonisolated static let hotKeySignature: OSType = 0x474C_4E43  // 'GLNC'
    private nonisolated static let hotKeyIDValue: UInt32 = 1

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers `shortcut` exclusively for this process. Returns `false` if Carbon
    /// refuses registration (e.g. an existing exclusive shortcut conflict).
    @discardableResult
    func register(_ shortcut: HotKeyShortcut) -> Bool {
        if registeredShortcut == shortcut, hotKeyRef != nil {
            return true
        }
        unregisterHotKeyOnly()

        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            var installedHandler: EventHandlerRef?
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                Self.eventHandlerCallback,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &installedHandler
            )
            guard status == noErr, let installedHandler else {
                return false
            }
            handlerRef = installedHandler
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyIDValue
        )
        var registeredRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registeredRef
        )
        guard status == noErr, let registeredRef else {
            unregister()
            return false
        }

        hotKeyRef = registeredRef
        registeredShortcut = shortcut
        return true
    }

    func unregister() {
        unregisterHotKeyOnly()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func unregisterHotKeyOnly() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredShortcut = nil
    }

    private nonisolated static let eventHandlerCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
            hotKeyID.signature == GlobalHotKey.hotKeySignature,
            hotKeyID.id == GlobalHotKey.hotKeyIDValue
        else {
            return OSStatus(eventNotHandledErr)
        }

        let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor [weak owner] in
            guard let owner, owner.hotKeyRef != nil else { return }
            owner.onHotKey?()
        }
        return noErr
    }
}

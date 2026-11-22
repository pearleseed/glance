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

        let hasPrimaryModifier = !relevantFlags.intersection([.command, .control, .option]).isEmpty
        guard hasPrimaryModifier, !isModifierOnlyKeyCode(rawCode) else {
            return .ignore
        }

        return .assign(HotKeyShortcut(
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

    static func keyLabel(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Grave: return "`"
        case kVK_ISO_Section: return "§"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Help: return "Help"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_ANSI_Keypad0: return "KP0"
        case kVK_ANSI_Keypad1: return "KP1"
        case kVK_ANSI_Keypad2: return "KP2"
        case kVK_ANSI_Keypad3: return "KP3"
        case kVK_ANSI_Keypad4: return "KP4"
        case kVK_ANSI_Keypad5: return "KP5"
        case kVK_ANSI_Keypad6: return "KP6"
        case kVK_ANSI_Keypad7: return "KP7"
        case kVK_ANSI_Keypad8: return "KP8"
        case kVK_ANSI_Keypad9: return "KP9"
        case kVK_ANSI_KeypadDecimal: return "KP."
        case kVK_ANSI_KeypadMultiply: return "KP*"
        case kVK_ANSI_KeypadPlus: return "KP+"
        case kVK_ANSI_KeypadClear: return "⌧"
        case kVK_ANSI_KeypadDivide: return "KP/"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_ANSI_KeypadMinus: return "KP-"
        case kVK_ANSI_KeypadEquals: return "KP="
        default: return "Key(\(keyCode))"
        }
    }
}

@MainActor
final class GlobalHotKey {
    var onHotKey: (() -> Void)?

    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private var registeredShortcut: HotKeyShortcut?

    private nonisolated static let hotKeySignature: OSType = 0x474C4E43 // 'GLNC'
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

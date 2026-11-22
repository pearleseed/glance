//
//  DisplayContext.swift
//  glance
//
//  Classifies the active display topology so settings can choose which setups allow Face Unlock.
//

import AppKit

enum DisplayContext {
    case builtInOnly
    case builtInAndExternal
    case externalOnly

    static func current() -> DisplayContext {
        let screens = NSScreen.screens
        let hasBuiltIn = screens.contains { $0.isBuiltIn }
        let hasExternal = screens.contains { !$0.isBuiltIn }
        if hasBuiltIn {
            return hasExternal ? .builtInAndExternal : .builtInOnly
        }
        return hasExternal ? .externalOnly : .builtInOnly
    }
}

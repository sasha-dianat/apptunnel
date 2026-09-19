// Menu.swift — the application menu.
//
// The windows are borderless, drawn from scratch, so it was tempting to skip
// the menu bar entirely. That was a bug: on macOS an app with no NSMainMenu has
// no key-equivalent table, so Command-Q, Command-W, Command-M and Command-H all
// do nothing. There is no fallback. The only way out of the app was the little
// painted X in the title bar, and a user who reached for Command-Q concluded
// the app had hung.
//
// A menu also makes the app look alive when it is frontmost: without one, the
// menu bar shows only the Apple menu, which reads as a half-crashed process.
//
// Nothing here is decorative. Every item is a standard responder-chain action,
// so the system handles the shortcuts exactly as it does for any other app.

import AppKit

enum AppMenu {
    /// Items are built and appended explicitly rather than through
    /// addItem(withTitle:action:keyEquivalent:), whose Swift return is an
    /// Optional - the convenience form cannot set a modifier mask without an
    /// unwrap, and silently discards its result everywhere else.
    private static func item(_ title: String,
                             _ action: Selector?,
                             _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { it.keyEquivalentModifierMask = mods }
        return it
    }

    static func install(appName: String = "AppTunnel") {
        let main = NSMenu()

        // ---- application menu ------------------------------------------------
        // The first submenu is always the app menu, whatever its title; macOS
        // substitutes the process name in the bar.
        let appItem = NSMenuItem()
        let appSub = NSMenu(title: appName)

        appSub.addItem(item("About \(appName)",
                            #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appSub.addItem(.separator())
        appSub.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        appSub.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
                            "h", [.command, .option]))
        appSub.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appSub.addItem(.separator())

        // The one the user actually asked for. terminate: travels the responder
        // chain to NSApp, so it works from any window, including the log panels.
        appSub.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))

        appItem.submenu = appSub
        main.addItem(appItem)

        // ---- window menu -----------------------------------------------------
        let winItem = NSMenuItem()
        let winSub = NSMenu(title: "Window")

        winSub.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        // Both windows override performClose: the main one quits (matching the
        // painted X), the log panels just close.
        winSub.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        winSub.addItem(.separator())
        winSub.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))

        winItem.submenu = winSub
        main.addItem(winItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = winSub
    }

    /// A flat, greppable dump of what is actually bound, for the regression
    /// suite. Source greps cannot tell you whether the menu was installed, only
    /// that the code exists; this reads the live NSMenu back.
    static func describe() -> String {
        var out: [String] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let sub = top.submenu else { continue }
            for it in sub.items where !it.isSeparatorItem {
                var mods: [String] = []
                let m = it.keyEquivalentModifierMask
                if m.contains(.command) { mods.append("cmd") }
                if m.contains(.option)  { mods.append("opt") }
                if m.contains(.shift)   { mods.append("shift") }
                if m.contains(.control) { mods.append("ctrl") }
                // The modifier mask is meaningless without a key, and printing
                // it anyway ("cmd+-") reads as a binding that does not exist.
                let shortcut = it.keyEquivalent.isEmpty
                    ? "-"
                    : (mods + [it.keyEquivalent]).joined(separator: "+")
                let sel = it.action.map { NSStringFromSelector($0) } ?? "-"
                out.append("\(sub.title)\t\(it.title)\t\(shortcut)\t\(sel)")
            }
        }
        return out.joined(separator: "\n")
    }
}

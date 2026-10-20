import AppKit

// YA-28: a menu-bar app still needs a main menu. AppKit routes Cmd+C, Cmd+V,
// Cmd+Z, Cmd+Q and Cmd+W through it, so without one the text fields in the
// control window and popover ignore the standard shortcuts. The bar itself
// only shows while the control window is open.
@MainActor
enum MainMenuBuilder {
    /// `target` receives the two app-specific actions (Settings, Quit). Every
    /// other item goes to the first responder, like any Mac app.
    static func make(target: AnyObject, openSettings: Selector, quit: Selector) -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenu = NSMenu(title: "YappYapp")
        appMenu.addItem(
            withTitle: L10n.tr("About YappYapp"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: L10n.tr("Setup…"), action: openSettings, keyEquivalent: ",")
        settingsItem.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("Hide YappYapp"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: L10n.tr("Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: L10n.tr("Quit YappYapp"), action: quit, keyEquivalent: "q")
        quitItem.target = target
        addSubmenu(appMenu, to: mainMenu)

        let editMenu = NSMenu(title: L10n.tr("Edit"))
        editMenu.addItem(withTitle: L10n.tr("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.tr("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.tr("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.tr("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.tr("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.tr("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        let windowMenu = NSMenu(title: L10n.tr("Window"))
        windowMenu.addItem(withTitle: L10n.tr("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L10n.tr("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        addSubmenu(windowMenu, to: mainMenu)

        return mainMenu
    }

    private static func addSubmenu(_ submenu: NSMenu, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        mainMenu.addItem(item)
    }
}

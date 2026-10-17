import AppKit

/// Native responder-chain actions for both regular windows and nonactivating panels.
enum TextEditingMenu {
    static let menu: NSMenu = {
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // Nil targets let AppKit validate and dispatch to the current editor.
        return menu
    }()

    static func performKeyEquivalent(with event: NSEvent, in window: NSWindow) -> Bool {
        // The companion can be key while another application still owns the menu
        // bar. Route only editing commands, and only while a text editor has focus.
        guard window.isKeyWindow, window.firstResponder is NSTextView else { return false }
        return menu.performKeyEquivalent(with: event)
    }
}

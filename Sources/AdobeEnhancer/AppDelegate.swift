import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let controller = ConversionController()
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        // Load podcast.adobe.com now so the first conversion doesn't pay for it
        // (and so an expired session surfaces before the user drops a file).
        controller.prepareSession()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.teardown()
    }

    /// The hidden Adobe window would otherwise keep the app alive forever, so
    /// quitting is tied to the main window instead of the window count.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        controller.reset()
        controller.start(files: filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    private func buildWindow() {
        let hosting = NSHostingView(rootView: ContentView(controller: controller))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Enhance"
        window.contentView = hosting
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Actions

    @objc func pasteFile(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            NSSound.beep()
            return
        }
        controller.reset()
        controller.start(files: urls)
    }

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose audio or video"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        controller.reset()
        controller.start(files: panel.urls)
    }

    @objc func cancelJob(_ sender: Any?) {
        controller.cancel()
    }

    @objc func toggleAdobeWindow(_ sender: NSMenuItem) {
        controller.toggleBrowserVisibility()
        sender.state = Settings.showBrowser ? .on : .off
    }

    @objc func showLog(_ sender: Any?) {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc func showSupportFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
    }

    // MARK: - Menus

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Enhance", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Enhance", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Enhance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(to: fileMenu, "Open…", #selector(openFile(_:)), "o")
        add(to: fileMenu, "Cancel Conversion", #selector(cancelJob(_:)), ".")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add(to: editMenu, "Paste", #selector(pasteFile(_:)), "v")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let debugItem = NSMenuItem()
        let debugMenu = NSMenu(title: "Debug")
        let toggle = add(to: debugMenu, "Show Adobe Window", #selector(toggleAdobeWindow(_:)), "")
        toggle.state = Settings.showBrowser ? .on : .off
        debugMenu.addItem(.separator())
        add(to: debugMenu, "Open Log", #selector(showLog(_:)), "")
        add(to: debugMenu, "Open Support Folder", #selector(showSupportFolder(_:)), "")
        debugItem.submenu = debugMenu
        mainMenu.addItem(debugItem)

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }
}

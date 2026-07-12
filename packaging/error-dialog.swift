// Beyond All Reason — error dialog.
//
// One native window used for BOTH launcher (download) failures and engine
// fatals, so users always get a readable, copy-pastable error instead of the
// app just vanishing. Shows:
//   • a prominent, selectable key message (Copy Error button)
//   • a SEPARATE scrollable log of what happened THIS run (Copy Full Log)
//   • Quit
//
// Usage:
//   error-dialog --title T --message M [--logfile PATH]
// The message may also be passed on stdin (for very long text); --logfile is
// read once at open. Exits 0 when dismissed.
import AppKit

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

let title = arg("--title") ?? "BAR Launcher"
var message = arg("--message") ?? ""
if message.isEmpty {
    message = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
let logPath = arg("--logfile")
var logText = ""
if let p = logPath, let d = FileManager.default.contents(atPath: p),
   let s = String(data: d, encoding: .utf8) {
    // keep the tail — this-run logs can be large; the end holds the failure
    let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
    logText = lines.suffix(600).joined(separator: "\n")
}

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
    var logView: NSTextView!

    func applicationDidFinishLaunching(_ n: Notification) {
        win.title = title
        win.center()
        win.isReleasedWhenClosed = false
        let cv = win.contentView!

        let head = NSTextField(labelWithString: "Beyond All Reason could not continue")
        head.font = .systemFont(ofSize: 14, weight: .bold)
        head.frame = NSRect(x: 20, y: 424, width: 580, height: 22)
        cv.addSubview(head)

        // key message — selectable so it can be copied by hand too
        let msg = NSTextField(wrappingLabelWithString: message)
        msg.isSelectable = true
        msg.font = .systemFont(ofSize: 12)
        msg.frame = NSRect(x: 20, y: 300, width: 580, height: 116)
        cv.addSubview(msg)

        let logLabel = NSTextField(labelWithString: "Details from this session (paste this into a bug report):")
        logLabel.font = .systemFont(ofSize: 11)
        logLabel.textColor = .secondaryLabelColor
        logLabel.frame = NSRect(x: 20, y: 274, width: 580, height: 16)
        cv.addSubview(logLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 56, width: 580, height: 210))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView = NSTextView(frame: scroll.bounds)
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.string = logText.isEmpty ? "(no log available)" : logText
        logView.autoresizingMask = [.width]
        scroll.documentView = logView
        cv.addSubview(scroll)
        DispatchQueue.main.async { self.logView.scrollToEndOfDocument(nil) }

        // grouped bottom-right (macOS convention): [Copy Error][Copy Full Log][Quit]
        addButton(cv, "Copy Error",    x: 236, #selector(copyErr))
        addButton(cv, "Copy Full Log", x: 356, #selector(copyLog))
        let q = addButton(cv, "Quit",  x: 486, #selector(quit))
        q.keyEquivalent = "\r"
        q.keyEquivalentModifierMask = []

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func addButton(_ cv: NSView, _ t: String, x: CGFloat, _ sel: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: sel)
        b.bezelStyle = .rounded
        b.frame = NSRect(x: x, y: 14, width: 110, height: 30)
        cv.addSubview(b); return b
    }
    func setClipboard(_ s: String) { let p = NSPasteboard.general; p.clearContents(); p.setString(s, forType: .string) }
    @objc func copyErr() { setClipboard(message) }
    @objc func copyLog() { setClipboard(logView.string) }
    @objc func quit()    { NSApp.terminate(nil) }
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let c = Controller()
app.delegate = c
c.win.delegate = c
app.run()

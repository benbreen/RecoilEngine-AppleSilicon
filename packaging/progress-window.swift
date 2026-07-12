// Beyond All Reason — first-run progress window.
//
// A tiny AppKit helper the launcher shows immediately on first run, so the
// one-time lobby download has a real window instead of a silently bouncing
// dock icon. Launched as a child of the .app launcher; reads a line protocol
// on stdin and updates the UI:
//
//   S <text>   set the status line (what is happening right now)
//   D <text>   set the secondary detail line (host, bytes, tag, …)
//   P <int>    determinate progress, 0..100
//   I          indeterminate (pulsing) — unknown-duration step
//   E <text>   error: show <text> in red, stop, reveal a Quit button
//   EOF        success (if no error was shown) → window closes
//
// On error the window stays up until the user clicks Quit (EOF does not close
// it once in the error state), so the classified failure reason is readable.
import AppKit

final class ProgressController: NSObject, NSApplicationDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 168),
        styleMask: [.titled], backing: .buffered, defer: false)
    let status = NSTextField(labelWithString: "Preparing Beyond All Reason…")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let quit = NSButton(title: "Quit", target: nil, action: nil)
    var inError = false

    func applicationDidFinishLaunching(_ n: Notification) {
        window.title = "BAR Launcher"
        window.center()
        window.isReleasedWhenClosed = false

        status.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        status.frame = NSRect(x: 20, y: 118, width: 440, height: 22)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 20, y: 92, width: 440, height: 18)
        detail.lineBreakMode = .byTruncatingMiddle

        bar.frame = NSRect(x: 20, y: 58, width: 440, height: 20)
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)

        quit.frame = NSRect(x: 380, y: 16, width: 80, height: 28)
        quit.bezelStyle = .rounded
        quit.target = self
        quit.action = #selector(doQuit)
        quit.isHidden = true

        let cv = window.contentView!
        cv.addSubview(status); cv.addSubview(detail); cv.addSubview(bar); cv.addSubview(quit)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        readStdin()
    }

    @objc func doQuit() { NSApp.terminate(nil) }

    func readStdin() {
        let fh = FileHandle.standardInput
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = Data()
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }              // EOF
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0a) {
                    let line = String(data: buf[..<nl], encoding: .utf8) ?? ""
                    buf.removeSubrange(...nl)
                    DispatchQueue.main.async { self.handle(line) }
                }
            }
            DispatchQueue.main.async {
                if !self.inError { NSApp.terminate(nil) }  // success closes; error stays
            }
        }
    }

    func handle(_ line: String) {
        guard let tag = line.first else { return }
        let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch tag {
        case "S": status.stringValue = rest
        case "D": detail.stringValue = rest
        case "P":
            if let v = Int(rest) {
                bar.isIndeterminate = false
                bar.minValue = 0; bar.maxValue = 100
                bar.doubleValue = Double(max(0, min(100, v)))
            }
        case "I":
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        case "E":
            inError = true
            bar.isIndeterminate = false
            bar.stopAnimation(nil)
            bar.isHidden = true
            status.stringValue = "Setup could not complete"
            status.textColor = .systemRed
            detail.stringValue = rest
            detail.textColor = .labelColor
            detail.frame = NSRect(x: 20, y: 52, width: 440, height: 54)
            detail.maximumNumberOfLines = 3
            detail.lineBreakMode = .byWordWrapping
            quit.isHidden = false
        default: break
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no second dock icon; window still shows
let c = ProgressController()
app.delegate = c
app.run()

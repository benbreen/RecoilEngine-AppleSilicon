// message-check — remote "message of the day" / kill-switch for the BAR
// launcher. On launch the helper fetches a small JSON config (hosted in the
// messages repo), decides which messages apply to THIS launcher version, and
// shows them oldest-first. A message can inform (continue) or block (quit) —
// e.g. suppress a known-bad build and point users at an upgrade.
//
// Idiomatic choices:
//   • Compiled, not shell/python: user Macs have neither python3 nor jq, and
//     Swift gives URLSession + Codable + NSAttributedString(HTML) (clickable
//     links, bold/italic/colour) + NSAlert's native suppression checkbox.
//   • FAIL-OPEN: any fetch/parse error → exit 0 (continue). Our config host
//     going down must never brick a launch.
//   • The config is JSONC — full-line `//` comments are stripped before
//     parsing, so the hosted file can be self-documenting.
//
// Usage:
//   message-check --config-url <url|file://> --app-version <ver>
//                 --seen-file <path> [--timeout <sec>] [--dry-run]
// Exit: 0 = continue launching, 2 = a message's chosen action quits the app.
// --dry-run: evaluate + print decisions and act as if each message's DEFAULT
//            button were pressed (no windows, no URLs opened) — for tests.
import AppKit

func arg(_ n: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: n), i + 1 < a.count { return a[i + 1] }
    return nil
}
let dryRun = CommandLine.arguments.contains("--dry-run")

// test hook: `message-check --sanitize` reads HTML on stdin, prints the
// sanitized HTML (sanitizeHTML is defined below; top-level Swift resolves it).
if CommandLine.arguments.contains("--sanitize") {
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print(sanitizeHTML(input))
    exit(0)
}

guard let cfgURLStr = arg("--config-url"),
      let appVer = arg("--app-version"),
      let url = URL(string: cfgURLStr) else { exit(0) }
// Only https for network fetches (file:// allowed for local tests). Refuse
// http/other so the config can never be pulled over an unauthenticated /
// downgradable channel.
if !url.isFileURL && url.scheme?.lowercased() != "https" { exit(0) }
let seenPath = arg("--seen-file")
let timeout = Double(arg("--timeout") ?? "4") ?? 4
let maxConfigBytes = 8 * 1024 * 1024   // 8 MB — generous (a real config is KB)
// The config is hosted on GitHub's raw CDN; require that host (and only allow
// redirects that stay on it), so the connection can only ever be to GitHub.
let allowedHostSuffix = "githubusercontent.com"

// Block any redirect that leaves GitHub's raw CDN (defence against a redirect
// to an attacker host); redirects that stay on githubusercontent.com are fine.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest req: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let host = req.url?.host?.lowercased() ?? ""
        completionHandler(host.hasSuffix(allowedHostSuffix) ? req : nil)
    }
}

// ---- fetch (fail-open) ----
// NEVER cache between runs: a fixed-id message's content/config can change, so
// every launch must see the current config. An ephemeral session persists no
// cache; the request also ignores any local cache. TLS is validated by default
// (system trust, hostname, expiry) and pinned to >= TLS 1.2; the host is pinned
// to GitHub's raw CDN; off-CDN redirects are blocked; an oversized body is
// rejected (by Content-Length and actual size) to bound memory.
func fetchConfig() -> Data? {
    if url.isFileURL {
        guard let d = try? Data(contentsOf: url), d.count <= maxConfigBytes else { return nil }
        return d
    }
    guard let host = url.host?.lowercased(), host.hasSuffix(allowedHostSuffix) else { return nil }
    var out: Data?
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                         timeoutInterval: timeout)
    req.setValue("recoil-apple-launcher", forHTTPHeaderField: "User-Agent")
    req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    let cfg = URLSessionConfiguration.ephemeral
    cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
    let session = URLSession(configuration: cfg, delegate: RedirectGuard(), delegateQueue: nil)
    session.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let fh = http.url?.host?.lowercased(), fh.hasSuffix(allowedHostSuffix),
           http.expectedContentLength <= Int64(maxConfigBytes),
           let d = data, d.count <= maxConfigBytes {
            out = d
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return out
}

// Best-effort HTML hardening before the (WebKit-backed) NSAttributedString
// import. It never executes JavaScript, but it CAN fetch external resources
// (<img>, CSS url()) — so strip script/style, event-handler attributes,
// external-resource + embedding tags, and dangerous URL schemes, leaving the
// formatting subset (b/i/strong/em/span-colour/a-href/p/br) we actually use.
func sanitizeHTML(_ html: String) -> String {
    var s = html
    func strip(_ pattern: String) {
        s = s.replacingOccurrences(of: pattern, with: "",
                                   options: [.regularExpression, .caseInsensitive])
    }
    for tag in ["script", "style", "iframe", "object", "embed", "applet", "video", "audio", "svg"] {
        strip("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>")
        strip("<\(tag)\\b[^>]*/?>")
    }
    for tag in ["img", "link", "meta", "base", "source", "track", "input", "form", "canvas"] {
        strip("<\(tag)\\b[^>]*>"); strip("</\(tag)\\s*>")
    }
    strip("\\son\\w+\\s*=\\s*\"[^\"]*\"")          // onclick=, onload=, …
    strip("\\son\\w+\\s*=\\s*'[^']*'")
    strip("(href|src)\\s*=\\s*\"\\s*(javascript|data|vbscript):[^\"]*\"")
    strip("(href|src)\\s*=\\s*'\\s*(javascript|data|vbscript):[^']*'")
    return s
}

// strip full-line `//` comments (never touches https:// inside values)
func stripComments(_ d: Data) -> Data {
    guard let s = String(data: d, encoding: .utf8) else { return d }
    let kept = s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    return Data(kept.joined(separator: "\n").utf8)
}

// ---- model ----
// body may be a single string OR an array of lines (joined) — the latter keeps
// multi-line HTML readable in the source files.
struct FlexibleText: Decodable {
    let value: String
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([String].self) { value = a.joined() }
        else { value = "" }
    }
}
struct Button: Decodable {
    let label: String
    let action: String          // "continue" | "quit" | "open-url"
    let url: String?            // open-url
    let then: String?           // open-url follow-up: "continue"(default) | "quit"
    let isDefault: Bool?
    enum CodingKeys: String, CodingKey { case label, action, url, then, isDefault = "default" }
}
struct Target: Decodable {
    let op: String            // all|eq|ne|lt|le|gt|ge|range
    let version: String?      // for eq/ne/lt/le/gt/ge
    let min: String?          // for range
    let max: String?          // for range
    let minInclusive: Bool?   // range lower bound inclusive (default true)
    let maxInclusive: Bool?   // range upper bound inclusive (default true)
}
struct Message: Decodable {
    let id: String
    let date: String?
    let target: Target
    let title: String
    let body: FlexibleText       // HTML fragment (string or [lines])
    let suppressible: Bool?     // adds "Don't show again" checkbox
    let suppressDefault: Bool?  // checkbox initial state (default true)
    let frequency: String?      // non-suppressible: "once"(default) | "always"
    let buttons: [Button]?
}
struct Config: Decodable { let schema: Int; let messages: [Message] }

// ---- dotted-numeric version compare (0.11 > 0.2, matching the port scheme) ----
func vcmp(_ a: String, _ b: String) -> Int {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}
func matches(_ t: Target, _ v: String) -> Bool {
    func c(_ f: (Int) -> Bool) -> Bool { t.version.map { f(vcmp(v, $0)) } ?? false }
    switch t.op {
    case "all": return true
    case "eq": return c { $0 == 0 };  case "ne": return c { $0 != 0 }
    case "lt": return c { $0 < 0 };   case "le": return c { $0 <= 0 }
    case "gt": return c { $0 > 0 };   case "ge": return c { $0 >= 0 }
    case "range":
        guard let lo = t.min, let hi = t.max else { return false }
        let loOK = (t.minInclusive ?? true) ? vcmp(v, lo) >= 0 : vcmp(v, lo) > 0
        let hiOK = (t.maxInclusive ?? true) ? vcmp(v, hi) <= 0 : vcmp(v, hi) < 0
        return loOK && hiOK
    default: return false
    }
}
func effectiveQuit(_ b: Button) -> Bool {
    b.action == "quit" || (b.action == "open-url" && (b.then ?? "continue") == "quit")
}

// ---- seen (suppressed) ids ----
var seen = Set<String>()
if let p = seenPath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
    seen = Set(s.split(separator: "\n").map(String.init))
}
func persistSeen() {
    guard let p = seenPath else { return }
    try? seen.sorted().joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)
}

// ---- load config (fail-open) ----
guard let raw = fetchConfig() else { exit(0) }
guard let cfg = try? JSONDecoder().decode(Config.self, from: stripComments(raw)),
      cfg.schema == 1 else {
    FileHandle.standardError.write(Data("message-check: config parse failed — continuing\n".utf8))
    exit(0)
}

// oldest -> newest, stable for equal/absent dates
let messages = cfg.messages.enumerated().sorted {
    let d0 = $0.element.date ?? "", d1 = $1.element.date ?? ""
    return d0 != d1 ? d0 < d1 : $0.offset < $1.offset
}.map { $0.element }

// BAR app icon (Contents/Resources/AppIcon.icns) for the alert instead of the
// generic executable/folder icon. BAR_ICON_PATH overrides (tests/standalone).
func barIcon() -> NSImage? {
    if let p = ProcessInfo.processInfo.environment["BAR_ICON_PATH"],
       let i = NSImage(contentsOfFile: p) { return i }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let icns = exe.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/AppIcon.icns")
    return NSImage(contentsOf: icns)
}
// Map unstyled / near-black body text to the dynamic label colour so it is
// legible in BOTH light and dark; explicit accent colours (our spans) stay.
func adaptForAppearance(_ a: NSAttributedString) -> NSAttributedString {
    let m = NSMutableAttributedString(attributedString: a)
    m.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: m.length)) { val, range, _ in
        let c = val as? NSColor
        let isDefault = (c == nil) || ((c?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) < 0.25)
        if isDefault { m.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
    }
    return m
}

// Custom message panel — full layout control (centred icon+title header, no
// dead space), native light/dark via the window material + label colours, and
// trivial "stay" (an open-url/stay button just doesn't close the window).
final class MessageDialog: NSObject {
    let m: Message, buttons: [Button], defaultIdx: Int, suppressible: Bool, suppressDefaultOn: Bool
    let icon: NSImage?
    var window: NSPanel!
    var suppressBox: NSButton?
    var resultIdx = 0
    init(_ m: Message, _ buttons: [Button], _ defaultIdx: Int,
         _ suppressible: Bool, _ suppressDefaultOn: Bool, _ icon: NSImage?) {
        self.m = m; self.buttons = buttons; self.defaultIdx = defaultIdx
        self.suppressible = suppressible; self.suppressDefaultOn = suppressDefaultOn; self.icon = icon
    }
    @objc func clicked(_ sender: NSButton) {
        let b = buttons[sender.tag]
        if b.action == "open-url", let u = b.url, let ou = URL(string: u) {
            NSWorkspace.shared.open(ou)
            if (b.then ?? "continue") == "stay" { return }   // keep the window up
        }
        resultIdx = sender.tag
        NSApp.stopModal()
    }
    func run() -> (Int, Bool) {
        let bodyWidth: CGFloat = 400, pad: CGFloat = 24

        // header: icon on the LEFT, title to its right (aligns with the body's
        // left edge below — one clean left axis, native + scannable).
        let title = NSTextField(labelWithString: m.title)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byWordWrapping; title.maximumNumberOfLines = 3
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)   // fill remaining width
        var headerViews: [NSView] = []
        if let icon = icon {
            let iv = NSImageView(); iv.image = icon; iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 51).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 51).isActive = true
            headerViews.append(iv)
        }
        headerViews.append(title)
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal; header.spacing = 12; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: bodyWidth).isActive = true  // span the column; title wraps within it

        // body (rich, sanitized, appearance-adaptive)
        let attr = (try? NSAttributedString(
            data: Data(sanitizeHTML(m.body.value).utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)) ?? NSAttributedString(string: sanitizeHTML(m.body.value))
        // A properly scrollable text view: the view resizes to the full content
        // height and the scroll view clips it to a capped region, so LONG
        // messages scroll instead of pushing the buttons off-screen.
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: bodyWidth, height: 10))
        tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
        tv.textContainerInset = .zero; tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: bodyWidth, height: 0)
        tv.maxSize = NSSize(width: bodyWidth, height: .greatestFiniteMagnitude)
        tv.textContainer?.containerSize = NSSize(width: bodyWidth, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        // trim trailing whitespace and zero the last paragraph's bottom margin
        // so the body hugs its content (no dead space before the checkbox).
        let body = NSMutableAttributedString(attributedString: adaptForAppearance(attr))
        let wsn = CharacterSet.whitespacesAndNewlines
        while body.length > 0, let sc = body.string.unicodeScalars.last, wsn.contains(sc) {
            body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
        }
        if body.length > 0 {
            let last = (body.string as NSString).paragraphRange(for: NSRange(location: body.length - 1, length: 1))
            let ps = (body.attribute(.paragraphStyle, at: last.location, effectiveRange: nil)
                        as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            ps.paragraphSpacing = 0
            body.addAttribute(.paragraphStyle, value: ps, range: last)
        }
        tv.textStorage?.setAttributedString(body)
        // Measure the attributed string directly — NSTextView glyph layout is
        // lazy and usedRect() under-reports tall bodies before display.
        let contentH = ceil(body.boundingRect(
            with: NSSize(width: bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        tv.frame = NSRect(x: 0, y: 0, width: bodyWidth, height: max(contentH, 18))
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let bodyCap: CGFloat = 340
        let bodyH = min(max(contentH, 18), bodyCap)
        let scroll = NSScrollView(); scroll.documentView = tv; scroll.drawsBackground = false
        scroll.hasVerticalScroller = contentH > bodyCap; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: bodyWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: bodyH).isActive = true

        // buttons — full width, stacked (labels can be long); default is accented
        let btns: [NSButton] = buttons.enumerated().map { (i, b) in
            let nb = NSButton(title: b.label, target: self, action: #selector(clicked(_:)))
            nb.tag = i; nb.bezelStyle = .rounded; nb.controlSize = .large
            nb.translatesAutoresizingMaskIntoConstraints = false
            nb.widthAnchor.constraint(equalToConstant: bodyWidth).isActive = true
            if i == defaultIdx { nb.keyEquivalent = "\r" }   // Return + accent highlight
            return nb
        }
        let btnStack = NSStackView(views: btns)
        btnStack.orientation = .vertical; btnStack.spacing = 8; btnStack.alignment = .centerX

        let main = NSStackView(); main.orientation = .vertical; main.alignment = .leading; main.spacing = 18
        main.translatesAutoresizingMaskIntoConstraints = false
        main.addArrangedSubview(header)
        main.addArrangedSubview(scroll)
        if suppressible {
            let cb = NSButton(checkboxWithTitle: "Don't show this message again", target: nil, action: nil)
            cb.state = suppressDefaultOn ? .on : .off
            suppressBox = cb
            let wrap = NSStackView(views: [cb]); wrap.orientation = .horizontal; wrap.alignment = .leading
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.widthAnchor.constraint(equalToConstant: bodyWidth).isActive = true
            main.addArrangedSubview(wrap)
        }
        main.addArrangedSubview(btnStack)

        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: bodyWidth + 2*pad, height: 200),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        let content = window.contentView!
        content.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            main.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            main.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
        ])
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.runModal(for: window)
        let supp = suppressBox?.state == .on
        window.orderOut(nil)
        return (resultIdx, supp)
    }
}

let app = NSApplication.shared
if !dryRun { app.setActivationPolicy(.regular) }
var mustQuit = false

for m in messages {
    guard matches(m.target, appVer) else { continue }
    // Server control wins: a currently-forced ("always") message ignores any
    // prior suppression, so flipping a message from suppressible to forced
    // re-shows it to users who had suppressed it. Only "once"/suppressible
    // messages honour the seen set.
    let alwaysShow = (m.frequency ?? "once") == "always"
    if !alwaysShow && seen.contains(m.id) { continue }
    let buttons = (m.buttons?.isEmpty == false) ? m.buttons!
        : [Button(label: "OK", action: "continue", url: nil, then: nil, isDefault: true)]
    let defaultIdx = buttons.firstIndex(where: { $0.isDefault == true }) ?? 0
    let suppressible = m.suppressible ?? false
    let suppressDefaultOn = m.suppressDefault ?? true

    let clicked: Button
    let suppressChecked: Bool
    if dryRun {
        clicked = buttons[defaultIdx]
        suppressChecked = suppressible && suppressDefaultOn
        let btnDesc = buttons.map { "\($0.label)[\($0.action)\($0.isDefault == true ? "*" : "")]" }.joined(separator: " ")
        let tgt = m.target.op == "range"
            ? "range:\(m.target.min ?? "?")-\(m.target.max ?? "?")"
            : "\(m.target.op)\(m.target.version.map { ":" + $0 } ?? "")"
        print("SHOW id=\(m.id) target=\(tgt) suppressible=\(suppressible) buttons={ \(btnDesc) } default=\(clicked.label)")
    } else {
        // custom panel (handles url-open incl. "stay" internally)
        let (idx, supp) = MessageDialog(m, buttons, defaultIdx, suppressible, suppressDefaultOn, barIcon()).run()
        clicked = buttons[idx]
        suppressChecked = supp
    }

    let eq = effectiveQuit(clicked)
    // suppression: suppressible messages honour the checkbox; others use
    // frequency (once = auto-suppress). Never suppress on a quit action, so a
    // kill-switch always re-shows.
    var markSeen = false
    if suppressible { markSeen = suppressChecked && !eq }
    else if (m.frequency ?? "once") == "once" { markSeen = !eq }
    if markSeen { seen.insert(m.id); persistSeen() }
    if dryRun { print("ACTION id=\(m.id) button=\(clicked.label) action=\(clicked.action) quit=\(eq) markSeen=\(markSeen)") }
    if eq { mustQuit = true; break }
}

exit(mustQuit ? 2 : 0)

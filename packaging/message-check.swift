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

guard let cfgURLStr = arg("--config-url"),
      let appVer = arg("--app-version"),
      let url = URL(string: cfgURLStr) else { exit(0) }
let seenPath = arg("--seen-file")
let timeout = Double(arg("--timeout") ?? "4") ?? 4

// ---- fetch (fail-open) ----
// NEVER cache between runs: a fixed-id message's content/config can change, so
// every launch must see the current config. An ephemeral session persists no
// cache; the request also ignores any local cache.
func fetchConfig() -> Data? {
    if url.isFileURL { return try? Data(contentsOf: url) }
    var out: Data?
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                         timeoutInterval: timeout)
    req.setValue("recoil-apple-launcher", forHTTPHeaderField: "User-Agent")
    req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    let session = URLSession(configuration: .ephemeral)
    session.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 { out = data }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return out
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
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = m.title
        alert.alertStyle = buttons.contains(where: { effectiveQuit($0) }) && buttons.allSatisfy({ $0.action != "continue" }) ? .critical : .informational
        // rich body via selectable NSTextView (clickable links, bold/italic/colour)
        let attr = (try? NSAttributedString(
            data: Data(m.body.value.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)) ?? NSAttributedString(string: m.body.value)
        let width: CGFloat = 380
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
        tv.textContainerInset = .zero; tv.textContainer?.lineFragmentPadding = 0
        tv.textStorage?.setAttributedString(attr)
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 60
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(max(used, 18), 320)))
        scroll.documentView = tv; scroll.drawsBackground = false; scroll.hasVerticalScroller = used > 320
        alert.accessoryView = scroll
        for b in buttons { alert.addButton(withTitle: b.label) }
        // config-specified default responds to Return; clear the rest
        for (i, nsBtn) in alert.buttons.enumerated() { nsBtn.keyEquivalent = (i == defaultIdx) ? "\r" : "" }
        if suppressible {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show this message again"
            alert.suppressionButton?.state = suppressDefaultOn ? .on : .off
        }
        // force the panel in front of every other app (activate() alone races)
        let win = alert.window
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        app.activate(ignoringOtherApps: true)
        let ret = alert.runModal()
        let idx = max(0, min(ret.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue, buttons.count - 1))
        clicked = buttons[idx]
        suppressChecked = suppressible && (alert.suppressionButton?.state == .on)
        if clicked.action == "open-url", let u = clicked.url, let ou = URL(string: u) {
            NSWorkspace.shared.open(ou)
        }
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

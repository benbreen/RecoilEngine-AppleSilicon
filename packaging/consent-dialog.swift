// Recoil Engine — user dialogs for the BAR launcher.
//
// Two modes:
//   (default)        first-run consent, shown once before anything downloads:
//                    the launcher is about to fetch a game (Beyond All Reason)
//                    from a third-party content network and the user must opt
//                    in. "Quit" is the default (Return) so the safe choice is
//                    the effortless one.
//                    Usage: consent-dialog --server <host>
//                    Exit: 0 = "Accept Risk and Run", 1 = "Quit"/closed.
//   --notice <text>  informational notice (e.g. online play disabled), single
//                    OK button. Exit: always 0.
import AppKit

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

let alert = NSAlert()
alert.messageText = "Recoil Engine"

if let notice = arg("--notice") {
    alert.informativeText = notice
    alert.alertStyle = .informational
    // right-aligned signature below the message (true bottom-right, not
    // spaces). NSAlert lays the accessory across its full text column (~500pt
    // wide for this message), so a full-width right-aligned label sits at the
    // right edge; .width autoresizing keeps it flush if the alert resizes.
    let sig = NSTextField(labelWithString: "— Ben")
    sig.alignment = .right
    sig.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    sig.textColor = .secondaryLabelColor
    sig.frame = NSRect(x: 0, y: 0, width: 500, height: 18)
    sig.autoresizingMask = [.width]
    alert.accessoryView = sig
    alert.addButton(withTitle: "OK")
    _ = alert.runModal()
    exit(0)
}

let server = arg("--server") ?? "the BAR content network"
alert.informativeText =
    "Do you wish to download and run the game Beyond All Reason from \(server)?\n\n" +
    "Beyond All Reason is third-party content. It is not hosted, vetted, or " +
    "endorsed by the maintainer of Recoil Engine for macOS, who accepts no " +
    "responsibility for it or for any damage it may cause. Download and run " +
    "this game AT YOUR OWN RISK!\n\n" +
    "If you continue, future updates for the game may download and run " +
    "automatically."
alert.alertStyle = .warning
// first button = default (Return). Quit is the safe default.
alert.addButton(withTitle: "Quit")
alert.addButton(withTitle: "Accept Risk and Run")

let response = alert.runModal()
exit(response == .alertSecondButtonReturn ? 0 : 1)

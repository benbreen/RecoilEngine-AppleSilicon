#!/usr/bin/env python3
"""Write the .DS_Store that styles the release DMG (icon view, background
picture, icon positions) directly onto the mounted read-write volume.

Replaces Finder AppleScript styling: no Automation permission, works headless
on any build box. Uses the vendored pure-python ds_store + mac_alias
(packaging/vendor/, same technique as create-dmg/appdmg).

Geometry contract with packaging/dmg-background.png (1320x840 @144dpi =
660x420 logical): window content must match the image exactly or Finder
paints white below it; icon positions must sit on the arrow's endpoints.

Usage: dmg-layout.py <mounted-volume-path> <app-basename>
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))
from ds_store import DSStore          # noqa: E402
from mac_alias import Alias           # noqa: E402

TITLEBAR = 28          # window bounds include the title bar
BG_W, BG_H = 660, 420  # logical size of dmg-background.png
APP_POS = (165, 195)
APPLICATIONS_POS = (495, 195)


def main() -> None:
    vol, app_name = sys.argv[1], sys.argv[2]
    bg = os.path.join(vol, ".background", "background.png")
    if not os.path.isfile(bg):
        sys.exit(f"FATAL: {bg} missing")

    icvp = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": Alias.for_file(bg).to_bytes(),
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "arrangeBy": "none",
        "gridOffsetX": 0.0, "gridSpacing": 100.0,
        "iconSize": 128.0, "textSize": 13.0,
        "labelOnBottom": True, "showIconPreview": True, "showItemInfo": False,
    }
    bwsp = {
        "WindowBounds": f"{{{{200, 140}}, {{{BG_W}, {BG_H + TITLEBAR}}}}}",
        "ShowStatusBar": False, "ShowToolbar": False, "ShowPathbar": False,
        "ShowSidebar": False, "ContainerShowSidebar": False, "SidebarWidth": 0,
        "ShowTabView": False, "PreviewPaneVisibility": False,
    }

    ds_path = os.path.join(vol, ".DS_Store")
    if os.path.exists(ds_path):
        os.remove(ds_path)
    with DSStore.open(ds_path, "w+") as d:
        d["."]["vSrn"] = ("long", 1)
        d["."]["bwsp"] = bwsp
        d["."]["icvp"] = icvp
        d[app_name]["Iloc"] = APP_POS
        d["Applications"]["Iloc"] = APPLICATIONS_POS
    print(f"dmg layout written: {ds_path}")


if __name__ == "__main__":
    main()

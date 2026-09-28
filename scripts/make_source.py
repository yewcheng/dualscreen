#!/usr/bin/env python3
"""Write the AltStore/SideStore source document.

SideStore polls this JSON and offers an Update when the version it lists is
newer than what is installed, so publishing a build is just committing this
file alongside a GitHub release.

Usage: make_source.py <version> <size-bytes> <iso-date> <download-url>
"""

import json
import sys

DESCRIPTION = (
    "Renders a window manager on a USB-C/HDMI display while the iPad acts as "
    "the control surface: launcher, pointer pad, snapping and per-app input. "
    "Includes web, notes, calculator, PDF, files, dashboard and clock windows."
)


ICON_URL = "https://raw.githubusercontent.com/yewcheng/dualscreen/main/icon.png"


def main() -> None:
    version, size, date, url = sys.argv[1:5]
    app = {
        "name": "DualScreen",
        "bundleIdentifier": "com.dualscreen.workspace",
        "developerName": "yewcheng",
        "subtitle": "Turn an HDMI monitor into a real workspace",
        "localizedDescription": DESCRIPTION,
        # Required: SideStore refuses the whole source without it.
        "iconURL": ICON_URL,
        "tintColor": "1E2438",
        "category": "utilities",
        "screenshotURLs": [],
        "versions": [
            {
                "version": version,
                "date": date,
                "localizedDescription": "Automated build.",
                "downloadURL": url,
                "size": int(size),
                "minOSVersion": "16.0",
            }
        ],
        # Older clients read these flat fields instead of `versions`.
        "version": version,
        "versionDate": date,
        "versionDescription": "Automated build.",
        "downloadURL": url,
        "size": int(size),
    }
    source = {
        "name": "DualScreen",
        "identifier": "com.dualscreen.source",
        "subtitle": "Second-screen workspace for iPad",
        "iconURL": ICON_URL,
        "apps": [app],
        "news": [],
    }
    print(json.dumps(source, indent=2))


if __name__ == "__main__":
    main()

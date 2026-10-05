# DualScreen v0.3

An iPadOS app that turns a USB-C → HDMI monitor into a second workspace: the
monitor shows a window manager with Web, Notes, Calculator, PDF, Files, Dashboard
and Clock windows; the iPad becomes the control surface (launcher, trackpad,
keyboard, snapping, live preview).

## What is and is not possible

iPadOS gives third-party apps one external-display scene role:
`UIWindowSceneSessionRoleExternalDisplayNonInteractive`. Read the last word —
**that scene receives no touch, pointer or keyboard events**. So the monitor is
an output canvas and every input arrives from the iPad. The architecture here is
built around that, not fighting it.

Stage Manager (Apple's own extended desktop) needs an M1 iPad. An iPad 10 will
only ever *mirror* at the system level — but this scene API is separate from the
system compositor and works on A-series iPads. When this app is frontmost with a
display attached, the mirror is replaced by the workspace scene.

What no third-party app can do: put Safari on the monitor and Notes on the iPad.
There is no API to host another app's UI. That remains impossible, by design.

## Layout

```
Sources/
  AppDelegate.swift        scene routing — external vs controller
  SceneDelegates.swift     the two UIWindowSceneDelegates
  Model/
    AppKind.swift          the six built-in apps
    WindowModel.swift      one window; frame normalised 0…1 to the display
    Workspace.swift        shared state, window management, persistence
  Views/
    WorkspaceView.swift    what the monitor draws (output only)
    WindowChrome.swift     title bar + border
    ControllerView.swift   the iPad UI

    DocumentPicker.swift   security-scoped file access
  Apps/
    AppContentView.swift   app bodies
    WebApp.swift           WKWebView hosting + the iPad-side driver
project.yml                XcodeGen spec — the .xcodeproj is generated, not committed
.github/workflows/build.yml
```

Both scenes share `Workspace.shared` in one process, so there is no IPC — the
controller mutates, the monitor re-renders.

## Building without a Mac

`.github/workflows/build.yml` runs on GitHub's `macos-14` runners. Push, and it:

1. generates the Xcode project with XcodeGen,
2. builds for the iPad 10 simulator, launches the app, screenshots it, and fails
   the job if the process died — a real smoke test, not just a compile,
3. builds unsigned for device and uploads `DualScreen-unsigned.ipa`.

Free minutes: unlimited on public repos; private repos bill macOS minutes at 10×,
so keep the repo public unless you have a reason not to.

The simulator cannot emulate an external display (Xcode dropped that), so CI
proves the code compiles and runs. The HDMI behaviour must be checked on the iPad.

## Installing on the iPad from Windows

CI produces an *unsigned* ipa. Sign it on your Windows machine:

1. Install **Sideloadly** (sideloadly.io) — no Mac involved.
2. Download the `DualScreen-unsigned-ipa` artifact from the Actions run and unzip it.
3. Plug the iPad in, drag `DualScreen-unsigned.ipa` into Sideloadly, sign in with
   your Apple ID, Start.
4. On the iPad: Settings → General → VPN & Device Management → trust your Apple ID.

Free Apple ID: the app expires after **7 days** — re-run Sideloadly to refresh.
A $99/yr Apple Developer account extends that to a year and removes the 3-app limit.

## The v0.3 test protocol

This is the question the whole project hinges on. With the app installed:

1. Open DualScreen on the iPad with nothing plugged in. The banner should read
   "No external display" and the preview should show the workspace miniature.
2. Open a Notes and a Calculator window; confirm they appear in the preview.
3. Connect USB-C → HDMI.
   - **Pass:** the monitor stops mirroring and shows the dark workspace with the
     same two windows and a bottom status bar.
   - **Fail:** the monitor keeps mirroring the iPad UI.
4. Drag on the iPad trackpad — the window should move on the monitor, and the
   iPad's own screen should keep showing the controller, not the workspace.
5. Type in the Notes panel; text appears on the monitor.
6. Unplug. The app should stay alive on the iPad with no crash; plug back in and
   the same windows should return.

Step 3 is the gate. If it passes, v0.4 (richer window manager) and v0.5 (more
apps) are ordinary app development.

## Web windows

A `web` window is a WKWebView that renders on the monitor. Since that scene gets
no touches, the controller supplies them: the pad maps 1:1 onto the window, a tap
becomes a synthetic click through `document.elementFromPoint`, a drag scrolls
`contentOffset` directly, and the text field types into whatever the last click
focused. Bookmarked: Croissant TCG (over the tailnet) and Carousell.

This is a remote control for a page, not Safari. Hover, long-press, pinch-zoom,
text selection and drag-and-drop inside the page are not wired up, and sites that
depend on real pointer events may not respond to a synthetic click.

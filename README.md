<p align="center">
  <img src="chrome-extension/icons/icon-128.png" width="128" alt="App Icon" />
</p>

<h1 align="center">PsychAudio</h1>

<p align="center">
  Deterministic hardware media key routing for macOS, eliminating play/pause race conditions between Apple Music, Spotify, VLC, IINA, and Google Chrome.
</p>

---

## Overview

On macOS, pressing the hardware Play/Pause media key often leads to unpredictable behavior: the system daemon (`mediaremoted`) guesses which application should receive the event, frequently triggering the wrong media player or launching Apple Music when a user intends to resume a paused Spotify track, video in VLC or IINA, or a tab in Google Chrome.

**PsychAudio** solves this through a lightweight, unified architecture:

1. **Native Menu Bar Daemon (Swift)**: Runs as an accessory app in the macOS menu bar. Using a low-level HID event tap (`CGEventTap`), it intercepts and consumes hardware Play/Pause key presses (`NX_KEYTYPE_PLAY`) before macOS daemons can misroute them. It tracks the active and paused playback state across Apple Music, Spotify, VLC, IINA, and Google Chrome tabs, deterministically routing the key press to the source that was playing or most recently paused.
2. **Chrome Extension (Manifest V3)**: Bridges Chrome tab audio states (`audible: true/false`) to the native daemon over a strictly local WebSocket server and executes targeted play/pause toggles inside the active media tab.

---

## Multi-App Support

PsychAudio v1.2.0 unifies media arbitration across your primary media players:

* **Apple Music**: State tracked via `DistributedNotificationCenter` (`com.apple.Music.playerInfo`). Controlled via AppleScript (`tell application "Music" to playpause`).
* **Spotify**: State tracked via `DistributedNotificationCenter` (`com.spotify.client.PlaybackStateChanged`). Controlled via AppleScript (`tell application "Spotify" to playpause`).
* **VLC**: Process state and window activity tracked via `NSWorkspace`. Controlled via AppleScript (`tell application "VLC" to play`).
* **IINA**: Process state and window activity tracked via `NSWorkspace`. Controlled via AppleScript (`tell application "IINA" to playpause`).
* **Google Chrome**: Tab-level audio emission tracked in real time over local WebSocket (`ws://127.0.0.1:49281`). Injects targeted play/pause toggles directly into the audible or paused tab.

---

## Setup Instructions

### 1. Build and Install the Native Application

1. Open Terminal in the repository root and run the build script:
   ```bash
   ./build.sh
   ```
2. Copy the resulting application bundle to your `/Applications` directory:
   ```bash
   cp -R dist/PsychAudio.app /Applications/
   ```
3. Launch the application:
   ```bash
   open /Applications/PsychAudio.app
   ```
   An ear icon will appear in the macOS menu bar.

### 2. Grant macOS Permissions

* **Accessibility**: Required for the low-level HID event tap to intercept physical keyboard media keys.
  * Open **System Settings > Privacy & Security > Accessibility**.
  * Ensure **PsychAudio** is toggled **ON**.
* **Automation**: Required for AppleScript to control playback in media applications.
  * When PsychAudio first routes a command to an application (Music, Spotify, VLC, or IINA), macOS will display an authorization prompt. Click **Allow** (or verify under **System Settings > Privacy & Security > Automation > PsychAudio**).

### 3. Install the Chrome Extension

1. Open Google Chrome and navigate to:
   ```
   chrome://extensions
   ```
2. Enable **Developer mode** using the toggle in the upper-right corner.
3. Click the **Load unpacked** button in the upper-left toolbar.
4. In the file picker, select the `chrome-extension` directory from this repository.
5. The **PsychAudio** extension is now active and will automatically connect to the local daemon.

---

## Privacy & Security

* **Strictly Local**: The daemon binds its WebSocket server exclusively to `127.0.0.1` on port `49281`. It rejects any non-loopback connections.
* **No Telemetry**: Neither the native daemon nor the Chrome extension transmits analytics, metrics, or personal data. No external servers or cloud services are involved.

---

## License

This project is licensed under the [MIT License](LICENSE).

<p align="center">
  <img src="chrome-extension/icons/icon-128.png" width="128" alt="App Icon" />
</p>

<h1 align="center">PsychAudio</h1>

<p align="center">
  Deterministic hardware media key routing for macOS, eliminating play/pause race conditions between Apple Music and Google Chrome.
</p>

---

## Overview

On macOS, pressing the hardware Play/Pause media key often leads to unpredictable behavior: the system daemon (`mediaremoted`) guesses which application should receive the event, frequently triggering Apple Music when a user intends to resume a paused YouTube video or podcast in Google Chrome, or vice versa.

**PsychAudio** solves this through a lightweight, two-part architecture:

1. **Native Menu Bar Daemon (Swift)**: Runs as an accessory app in the macOS menu bar. It establishes a low-level HID event tap to intercept and consume hardware Play/Pause key presses before system daemons can guess. It tracks the playback state of Apple Music and active Chrome tabs, deterministically routing the key press to the source that was playing or most recently paused.
2. **Chrome Extension (Manifest V3)**: Bridges Chrome tab audio states (`audible: true/false`) to the native daemon over a strictly local WebSocket server and executes targeted play/pause toggles inside the active media tab.

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

* **Accessibility**: Required for the low-level HID event tap to intercept hardware media keys.
  * Open **System Settings > Privacy & Security > Accessibility**.
  * Ensure **PsychAudio** is toggled **ON**.
* **Automation**: Required for AppleScript to control Apple Music playback.
  * When PsychAudio first routes a command to Apple Music, macOS will display an authorization prompt. Click **Allow** (or verify under **System Settings > Privacy & Security > Automation > PsychAudio > Music**).

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

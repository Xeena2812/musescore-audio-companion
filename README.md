# MuseScore Audio Companion

A MuseScore 4 plugin that plays an external audio file in sync with score playback. Useful for following along with a recording while reading the score — rehearsal tracks, backing tracks, reference recordings, and so on.

## Features

- Load an audio file (MP3, WAV, OGG, FLAC) per score
- Play/Pause/Stop/Rewind drives both MuseScore and the audio simultaneously
- ±3 s / ±10 s skip buttons and a seekable progress bar
- Configurable ms-level delay offset so the audio and score stay in sync
- Volume control
- Remembers which audio file belongs to each score

## Requirements

- **MuseScore Studio 4**
- **VLC media player** (native install; on Linux `sudo dnf install vlc` / `sudo apt install vlc`)
- A one-time install of the **`audiocompanion://` URL handler** (below), so the plugin can start and stop VLC itself

## Installation

**1. Copy the plugin**

```bash
cp AudioCompanion.qml ~/Documents/MuseScore4/Plugins/
```

**2. Register the VLC launcher (once per machine, no admin rights)**

MuseScore plugins cannot spawn processes (and Flatpak/Snap sandboxes forbid it anyway), so the plugin opens `audiocompanion://start` / `audiocompanion://stop` and your OS hands those to a small launcher script that runs VLC with its HTTP interface on `127.0.0.1:9091`.

| OS | Run | What it changes | Tested |
|---|---|---|---|
| Linux | `install/install-linux.sh` | copies launcher to `~/.local/share/audio-companion/`, writes `~/.local/share/applications/audiocompanion.desktop`, registers it via `update-desktop-database` + `xdg-mime default` | **Yes** (Fedora, Flatpak MuseScore; host and sandbox via the OpenURI portal) |
| Windows | `powershell -ExecutionPolicy Bypass -File install\install-windows.ps1` | copies launcher to `%LOCALAPPDATA%\AudioCompanion\`, writes `HKCU\Software\Classes\audiocompanion` | **No - untested** |
| macOS | `install/install-macos.sh` | builds `~/Applications/AudioCompanionHandler.app` (osacompile applet with `CFBundleURLTypes`), registers it with Launch Services | **No - untested** |

Each installer has an uninstall option (`--uninstall` / `-Uninstall`). Verify with `xdg-open audiocompanion://start` (Linux), `Start-Process audiocompanion://start` (Windows) or `open audiocompanion://start` (macOS): VLC should appear on port 9091.

Snap MuseScore on Linux uses the same Linux installer (snaps reach the host handler through the same desktop portal); this is expected to work but is untested.

**3. Enable the plugin in MuseScore**

Plugins → Manage Plugins → find *Audio Companion* → check the box → Close

## Usage

**1. Open the plugin**

Plugins → Audio Companion

If VLC isn't running the plugin starts it automatically (status shows *Starting VLC…*). If it stays unreachable, the handler isn't installed - run the installer above, then press **Retry**. When the plugin closes it stops the VLC it started; a VLC you launched yourself on port 9091 is left running. Only the VLC on port 9091 is ever stopped, never other VLC windows.

Port and password are fixed (`9091` / `musescore`) in the plugin and the launchers.

**2. Load an audio file**

Click **Load Audio…** and select your file. The plugin remembers your choice per score.

**3. Play**

Press ▶ — both the score and the audio start together. Use the **Offset** spinner to adjust sync in milliseconds (positive = audio starts after the score, negative = audio starts before).

## Why VLC?

MuseScore 4 installed via snap does not have a working GStreamer backend for Qt's built-in `QMediaPlayer`. The plugin works around this by talking to VLC's HTTP remote-control API instead of playing audio directly.

## License

MIT

## QtMultimedia probe (experimental)

`AudioCompanionProbe.qml` is a separate throwaway plugin (not part of the real plugin) that checks whether Qt's own `MediaPlayer` could replace VLC. Copy it to the Plugins folder, enable it, open it, pick a long audio file, press **Run probe**: it plays, seeks to several positions and prints seek latency/error and 8 s playback drift on screen.

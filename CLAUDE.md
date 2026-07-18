# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A MuseScore 4 plugin (QML) that plays back an external audio file synchronized with score playback. The plugin owns the transport: its Play/Pause/Stop controls drive both MuseScore's internal playback engine and an external audio file simultaneously.

**Planned features:** audio file loading (mp3/wav/ogg/flac), configurable ms delay offset relative to measure 1 (positive or negative), volume control, and seek-on-cursor-move in edit mode via `onScoreStateChanged` + `selectionChanged`.

## Environment

- **MuseScore Studio**, installed via **Flatpak** (`org.musescore.MuseScore`) on **Fedora**. Version drifts as Flatpak auto-updates it (was 4.6.3, now 4.7.4) — check the newest log's startup line rather than trusting a remembered version number.
- Plugin install path: `~/Documents/MuseScore4/Plugins/` (unchanged under Flatpak — the app has `filesystems=home`, i.e. full real-`$HOME` access, not sandboxed to `~/.var/app/...`)
- Logs: `~/.var/app/org.musescore.MuseScore/data/MuseScore/MuseScore4/logs/` (newest file by `ls -t`). There's also a stale, unrelated `~/.local/share/MuseScore/MuseScore4/` left over from a prior native/snap install — ignore it.
- Qt 6 (MU4.4+ uses Qt 6)
- No Plugin Creator in MU4 — edit files externally, then reload via **Plugins → Manage Plugins → Reload**
- **QtMultimedia objects instantiate** in the Flatpak sandbox but `QMediaPlayer` requires a GStreamer backend to actually play audio. Required system packages (install once): `sudo apt install libqt6multimedia6 gstreamer1.0-qt6`. Codec plugins `gstreamer1.0-plugins-good` and `gstreamer1.0-libav` cover MP3/FLAC/OGG/WAV and are already installed on the dev machine.
- **Port 9090 is claimed by Cockpit** (`cockpit.socket`, enabled by default on Fedora) — this is why the VLC HTTP bridge uses port **9091**, not VLC's traditional default. If VLC's status endpoint ever needs to move again, verify the new port is free first (`ss -tln`) — 9090 silently answers with Cockpit's login page (`200 OK`, but not VLC's XML), which looks like "connected but broken," not "connection refused."
- `console.log(...)` calls in plugin QML/JS do **not** appear in the MuseScore log file — don't rely on it for debugging; use on-screen state (Text elements bound to debug properties) instead.
- To test networking, filesystem access, or run a command in the *exact* sandbox MuseScore executes in: `flatpak run --command=bash org.musescore.MuseScore -c '<command>'` (or `--command=curl` directly). No `qml`/`qmlscene` binary exists inside that sandbox, so standalone QML/JS test harnesses aren't possible this way.

## Development Workflow

There is no build step. Edit `.qml` files in this repo, **copy to the MuseScore plugins folder**, then get MuseScore to pick up the change:

```bash
cp ~/Projects/musescore-audio-companion/AudioCompanion.qml ~/Documents/MuseScore4/Plugins/
```

Simply re-running the plugin from the menu re-executes `onRun` but does **not** re-parse the QML. In principle disable + re-enable (`Plugins → Manage Plugins → uncheck → check → Close`) should be enough for structural/UI changes — but on the current Flatpak/Fedora dev setup this has proven **unreliable**: changes sometimes don't take effect until MuseScore is **fully quit and relaunched**. If a reload doesn't seem to be taking effect (stale behavior, old UI), restart the whole app before assuming the change is wrong.

To check logs after a crash or QML error:
```bash
tail -f ~/.var/app/org.musescore.MuseScore/data/MuseScore/MuseScore4/logs/MuseScore*.log
```

QtMultimedia is confirmed working in the Flatpak sandbox (tested via probe plugin).

## MU4 QML Rules (always follow)

- `import MuseScore` — no version number
- `import QtQuick` — no version number
- Never use `Qt.quit()` — use `quit()` instead
- Score modifications must be wrapped in `curScore.startCmd()` / `curScore.endCmd()`
- **Do not use `QtQuick.Dialogs`** — broken in MU4.4+
- **`pluginType: "dock"` is broken in MU4** due to the UI rewrite — use `"dialog"` only
- For file pickers, use `Qt.labs.platform.FileDialog` loaded via `Qt.createQmlObject` (dynamic import), so the plugin still loads if the module is absent from the snap. Connect signals imperatively with `.onAccepted.connect(...)`
- **Do not `import Qt.labs.settings`** — Settings is integrated into the MuseScore module

## Architecture

The plugin is a single QML component tree. Key responsibilities:

| Concern | Mechanism |
|---|---|
| MuseScore playback control | `cmd("play")`, `cmd("stop")` via the MuseScore plugin API |
| Audio file playback | `QtMultimedia.MediaPlayer` + `AudioOutput` (Qt 6 API) |
| Sync on play | Start both engines together; use the ms delay offset to schedule the audio start via a `Timer` |
| Seek on cursor move | `onScoreStateChanged` → read `curScore.selection` tick → convert tick→ms → `mediaPlayer.position = ms` |
| Delay offset | Stored in `Settings`; applied at play-start: positive = audio starts after score, negative = audio starts before score |
| Persistent settings | `Settings` (built into MuseScore module) — do not import separately |

### Tick → milliseconds conversion

MuseScore exposes tempo via `curScore.tempo(tick)` (returns BPS). Convert a tick position to ms by integrating tempo changes across the score's tempo map. There is no single built-in call for this; it must be computed from the score's segment list.

## Snap Sandbox Constraints

The snap confines file access. The audio file path must come from a user-initiated file picker (not a hardcoded path). If `QtQuick.Dialogs` is unavailable, implement a path input field as a fallback.

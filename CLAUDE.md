# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A MuseScore 4 plugin (QML) that plays back an external audio file synchronized with score playback. The plugin owns the transport: its Play/Pause/Stop controls drive both MuseScore's internal playback engine and an external audio file simultaneously.

**Planned features:** audio file loading (mp3/wav/ogg/flac), configurable ms delay offset relative to measure 1 (positive or negative), volume control, and seek-on-cursor-move in edit mode via `onScoreStateChanged` + `selectionChanged`.

## Environment

- **MuseScore Studio 4.6.5** on Ubuntu, installed via **snap**
- Plugin install path: `~/Documents/MuseScore4/Plugins/audio-companion/`
- Logs: `~/snap/musescore/current/.local/share/MuseScore/MuseScore4/logs/`
- Qt 6 (MU4.4+ uses Qt 6)
- No Plugin Creator in MU4 — edit files externally, then reload via **Plugins → Manage Plugins → Reload**
- **QtMultimedia is confirmed available** in the snap sandbox — `MediaPlayer`, `AudioOutput`, and `.position` seek all work

## Development Workflow

There is no build step. Edit `.qml` files in this repo, **copy to the MuseScore plugins folder**, then disable + re-enable the plugin in MuseScore for changes to take effect:

```bash
cp ~/Projects/musescore-audio-companion/AudioCompanion.qml ~/Documents/MuseScore4/Plugins/
```

```
Plugins → Manage Plugins → uncheck → check → Close, then run again
```

Simply re-running the plugin from the menu re-executes `onRun` but does **not** re-parse the QML — disable/re-enable is required for any structural or UI changes.

To check logs after a crash or QML error:
```bash
tail -f ~/snap/musescore/current/.local/share/MuseScore/MuseScore4/logs/MuseScore*.log
```

QtMultimedia is confirmed working in the snap sandbox (tested via probe plugin).

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

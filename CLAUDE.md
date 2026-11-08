# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A MuseScore 4 plugin (QML) that plays back an external audio file synchronized with score playback. The plugin owns the transport: its Play/Pause/Stop controls drive both MuseScore's internal playback engine and an external audio file simultaneously.

**Shipped (v1.4.0):** file loading, ms delay offset with nudges, volume/mute, speed (Audio mode), A–B loop (Audio mode), recent files, per-score settings, keyboard shortcuts, **Follow cursor** (selection → audio seek, Both mode). **Not feasible on 4.7.4:** live drift correction (no playback position in the plugin API). **Tried and dropped:** a "Move to cursor" button (audio position → score selection) selected the wrong note and was removed; revisit if wanted. See "Score position API" below.

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

## Audio engines

Default engine is Qt Multimedia (`MediaPlayer`, created dynamically in `_initQtPlayer()`); VLC is the fallback, used when QtMultimedia can't be created or raises `errorOccurred` (`_qtFailed()`). The `vlc*` functions and `vlcConnected/vlcState/vlcPosition/vlcLength` are the engine-neutral API and dispatch on `useQt`. Probe results (Flatpak, ffmpeg+GStreamer backends present): seeks exact, start ~100 ms, playback resumes ~100-150 ms late after a seek-while-playing (not compensated), rate accurate, drift within ±50 ms/60 s, audible latency unmeasured. `AudioCompanionProbe*.qml` are throwaway probes.

## VLC fallback auto-start (URL-scheme handler)

QML plugins can't spawn processes, so `_tryLaunchVlc()` calls `Qt.openUrlExternally("audiocompanion://start")` and `Component.onDestruction` calls `audiocompanion://stop` (only if the plugin launched VLC). A per-OS handler in `install/` (Linux `.desktop` + `xdg-mime`, Windows HKCU registry + PowerShell, macOS osacompile applet) runs the launcher script, which is idempotent and only touches the VLC bound to port 9091. Verified on Linux: works from the host and from inside the Flatpak sandbox (OpenURI portal, no prompt observed). Windows/macOS installers are untested. The launcher honors `AUDIOCOMPANION_PORT` for testing on a temp port — never kill the user's GUI VLC. `Qt.openUrlExternally` gives no failure signal when no handler exists, so the plugin relies on the status ping timing out and shows the "run the installer" banner.

## Development Workflow

There is no build step. Edit `.qml` files in this repo, **copy to the MuseScore plugins folder**, then get MuseScore to pick up the change:

```bash
scripts/deploy-plugin.sh   # or: cp AudioCompanion.qml ~/Documents/MuseScore4/Plugins/
```

The git hooks `post-merge`/`post-checkout`/`post-rewrite` (installed per clone by `scripts/install-git-hooks.sh`; hooks aren't versioned) run `deploy-plugin.sh` automatically. It deploys from the **main checkout only** (never a linked worktree) and skips if the file is unchanged. When testing a worktree branch, `cp` the worktree's `AudioCompanion.qml` into the Plugins folder yourself, and don't run the deploy script from the main checkout, or you will silently be back on `main`'s version. `AUDIO_COMPANION_PLUGIN_DIR` overrides the destination.

Simply re-running the plugin from the menu re-executes `onRun` but does **not** re-parse the QML. In principle disable + re-enable (`Plugins → Manage Plugins → uncheck → check → Close`) should be enough for structural/UI changes — but on the current Flatpak/Fedora dev setup this has proven **unreliable**: changes sometimes don't take effect until MuseScore is **fully quit and relaunched**. If a reload doesn't seem to be taking effect (stale behavior, old UI), restart the whole app before assuming the change is wrong.

To check logs after a crash or QML error:
```bash
tail -f ~/.var/app/org.musescore.MuseScore/data/MuseScore/MuseScore4/logs/MuseScore*.log
```

Lint before deploying (catches syntax errors that otherwise only show up when MuseScore loads the plugin). The binary is `qmllint-qt6`; the `MuseScore` import can't be resolved, so silence that noise:
```bash
qmllint-qt6 --unqualified disable --import disable AudioCompanion.qml
```
Expected leftover: `themeHolder` "not found on type QQuickItem" warnings (intentional dynamic ancestor lookup in `PBtn`/`PSlider`); anything else is real.

QtMultimedia is confirmed working in the Flatpak sandbox (tested via probe plugin).

The UI follows MuseScore's theme by reading `ui/application/currentThemeCode` from `MuseScore4.ini` (polled every 2 s; plugin API has no theme access — `api.theme` is extensions-only). Accent colour follows the theme default, not a user-customised one (planned).

## MU4 QML Rules (always follow)

- `import MuseScore` — no version number
- `import QtQuick` — no version number
- Never use `Qt.quit()` — use `quit()` instead
- Score modifications must be wrapped in `curScore.startCmd()` / `curScore.endCmd()`
- **Do not use `QtQuick.Dialogs`** — broken in MU4.4+
- **`pluginType: "dock"` is broken in MU4** — confirmed on 4.7.4: it opens the same plain dialog. Use `"dialog"` only. Plugin dialogs are **fixed-size**: they ignore later `width`/`height` changes and can't be resized, so the window uses a fixed `height` with the footer pinned to the bottom. Upstream dockable plugins (PR musescore/MuseScore#35277) aren't released yet; tracked in repo issue #1.
- Reusable styled controls (`PBtn`, `PSlider`) are **inline `component`s** inside `AudioCompanion.qml`. Don't add extra `.qml` files to the Plugins folder: MuseScore scans that folder and would list each file as a plugin.
- For file pickers, use `Qt.labs.platform.FileDialog` loaded via `Qt.createQmlObject` (dynamic import), so the plugin still loads if the module is absent from the snap. Connect signals imperatively with `.onAccepted.connect(...)`
- **Do not `import Qt.labs.settings`** — Settings is integrated into the MuseScore module

## Score position API (probed on MuseScore 4.7.4)

Verified with a throwaway probe plugin (not kept in the repo):

- **Never enumerate** plugin API objects: `for..in` over `curScore` and `n in cursor` both SIGSEGV MuseScore. Read named properties directly.
- 480 ticks per quarter. `curScore.lastSegment.tick` is the end; `curScore.duration` is seconds. There is **no `curScore.tempo(tick)`** and no tick→time function (`cursor.time` is a method of unknown meaning). `cursor.tempo` exists (quarter notes/s).
- Tempo map: walk `curScore.newCursor()` from `Cursor.SCORE_START` with `next()`, read `cursor.segment.annotations`, keep `type === Element.TEMPO_TEXT`; `.tempo` is quarter notes per second. Gradual changes and repeats are not represented (the plugin compares the result with `curScore.duration` and warns).
- Selection tick: if `selection.isRange` use `selection.startSegment.tick` (a whole measure gives the measure start); otherwise walk `selection.elements[0].parent` up to the element named `"Segment"` and use its `.tick` (`Measure.tick` is a Fraction object, unusable). Single-note selections report `isRange=false`, `startSegment=null`.
- Moving the selection works with `cursor.rewindToTick(t)` then `curScore.selection.select(cursor.element)`. `selection.selectRange(...)` returned false when called without `selection.clear()` first and with a 1-tick range; the mcp-musescore plugin calls `clear()` then `selectRange(start, start+duration, staff, staff+1)`.
- **No live playback position**: during `cmd("play")` the cursor and selection stay fixed, and no play-position property exists. Hence no drift correction.
- **`onScoreStateChanged` did not fire** in a probe plugin on selection changes or `cmd("next-measure")`, so Follow polls the selection every 200 ms instead (only in Both mode, when nothing is playing).
- Offset convention: audio time = score time − `offsetMs` (positive offset = audio starts later); tick 0 keeps the lead-in path used by `transportPlay`.
- `cmd("play")` is a toggle; pausing is tracked with `_scorePaused` so the ▶/⏸ button flips back and Resume re-toggles. If the cursor moved while paused, Resume does stop + `transportPlay()` so score and audio restart together from the cursor.

## Architecture

The plugin is a single QML component tree. Key responsibilities:

| Concern | Mechanism |
|---|---|
| MuseScore playback control | `cmd("play")`, `cmd("stop")` via the MuseScore plugin API |
| Audio file playback | `QtMultimedia.MediaPlayer` + `AudioOutput` (Qt 6 API) |
| Sync on play | Start both engines together; use the ms delay offset to schedule the audio start via a `Timer` |
| Follow cursor (Both mode) | A 200 ms `Timer` polls the selection (`onScoreStateChanged` doesn't fire — see "Score position API"): `_selectionTick()` → `_tickToMs()` → `_seekAudioToTick()`. Only runs while Follow is on and nothing is playing |
| Delay offset | Stored in `Settings`; audio time = score time − offset (positive = audio starts after score, negative = before) |
| Persistent settings | `Settings` (built into MuseScore module) — do not import separately; Follow, offset and the audio file are remembered per score |

### Tick → milliseconds conversion

There is no `curScore.tempo(tick)` and no built-in tick→time call. `_buildTempoMap()` collects the score's tempo texts and `_tickToMs()` / `_msToTick()` integrate across them; gradual tempo changes and repeats aren't modelled, so the plugin compares the total with `curScore.duration` and warns (amber info line) on mismatch. Details in "Score position API".

## File access

The audio file path must come from a user-initiated file picker (not a hardcoded path); a recent-files list is kept. Under Flatpak the app has full `$HOME` access, so the sandbox rarely blocks reads, but keep the picker flow so the plugin still works on confined installs (snap).

## Repository layout

- `AudioCompanion.qml` — the whole plugin (the only file deployed to the Plugins folder).
- `AudioCompanionProbe*.qml` — throwaway probes, not deployed; don't copy them into the Plugins folder.
- `install/` — per-OS `audiocompanion://` URL-handler installers and VLC launchers (fallback engine only).
- `scripts/` — `deploy-plugin.sh`, `install-git-hooks.sh`.
- `docs/agents/` — config for the agent skills below. `.agents/skills/` holds the skill files, `.claude/skills/*` are symlinks into it, `skills-lock.json` pins versions. `.claude/settings.local.json` and `.claude/worktrees/` are machine-local and gitignored.
- Versioning: the `version:` property at the top of `AudioCompanion.qml` is the single source; use the `release` skill to bump, commit and tag.

## Setting up a new machine

1. Clone, then `scripts/install-git-hooks.sh` (hooks aren't versioned).
2. Install MuseScore 4 and the Qt Multimedia + GStreamer packages (see Environment), plus `gh auth login`.
3. `scripts/deploy-plugin.sh`, fully restart MuseScore, enable the plugin in Manage Plugins.
4. Optional, VLC fallback only: run the OS installer in `install/` (and install VLC).
5. Auto-memory lives outside the repo (`~/.claude/projects/<path-derived-dir>/memory/`) — copy it over manually if wanted.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`Xeena2812/musescore-audio-companion`, via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

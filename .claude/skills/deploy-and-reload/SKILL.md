---
name: deploy-and-reload
description: Sync plugin files to the MuseScore Plugins folder and tail the newest log to check for errors after a change
disable-model-invocation: true
---

# Deploy and reload

Runs the manual test cycle documented in CLAUDE.md's "Development Workflow" section:

1. Run `scripts/deploy-plugin.sh` to copy `AudioCompanion.qml` into
   `~/Documents/MuseScore4/Plugins/` (no-op if already in sync — the git post-merge/checkout/rewrite
   hooks usually already handle this, so this step is mostly a safety net). The script deploys
   from the main checkout only; from a worktree, `cp` the worktree's `AudioCompanion.qml` yourself.
2. Remind the user how to get MuseScore to pick up the change:
   - Structural/UI changes: **Plugins → Manage Plugins → uncheck → check → Close**. If that
     doesn't visibly take effect, **fully quit and relaunch MuseScore** — reload via the menu has
     proven unreliable on this Flatpak/Fedora setup.
   - Re-running the plugin from the menu alone does **not** re-parse the QML.
3. Find the newest log file and tail it for errors:
   ```bash
   ls -t ~/.var/app/org.musescore.MuseScore/data/MuseScore/MuseScore4/logs/*.log | head -1 | xargs tail -n 60
   ```
   Ignore `~/.local/share/MuseScore/MuseScore4/` — that's a stale leftover from a prior
   native/snap install, not the active Flatpak instance.
4. Report back: whether the copy was needed, and whether the log shows QML parse errors or is clean.

Do not use `console.log` output as a signal — it does not appear in the MuseScore log file
(per CLAUDE.md). Rely on the log tail and on-screen state instead.

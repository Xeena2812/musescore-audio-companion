---
name: release
description: Cut a versioned release of the plugin — bump version, update README if needed, commit and tag following this repo's convention
disable-model-invocation: true
---

# Release

Cuts a release following the convention established in this repo's git history.

## Convention (as established by git log, kept consistent by this skill)

- **Single source of truth for the version**: the `version: "X.Y.Z"` property near the top of
  `AudioCompanion.qml` (also shown live in the UI status bar as `vX.Y.Z — ...`). Bump it there —
  there is no separate CHANGELOG or version file.
- **Commit subject**: `vX.Y.Z: <imperative summary of the user-visible change>`
  (e.g. `v1.2.2: fix VLC connect — port 9090 collided with Cockpit, not a real hang`).
  Non-version housekeeping commits (e.g. README-only) may omit the version prefix.
- **Commit body**: prose explaining what changed and *why* — for bug fixes, include root-cause
  narrative if one was found, not just the symptom. Mention any incidental cleanup bundled in
  (e.g. "also strips the temporary debug UI added during investigation").
- **Trailer**: `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>` (adjust model name to
  whichever model is doing the work).
- **Tag**: a lightweight `vX.Y.Z` git tag on the release commit. **Note**: only `v1.0.0` exists
  today — every release since drifted from this. This skill re-establishes tagging going forward;
  if the user wants the missing historical tags backfilled too, ask before doing it (rewrites
  nothing, but touches multiple points in history).

## Steps

1. Confirm the target version number and a one-line summary of the change with the user if not
   already obvious from conversation context.
2. Bump `version: "X.Y.Z"` in `AudioCompanion.qml`.
3. Check whether `README.md`'s **Features** list or **Requirements** section needs updating to
   reflect the change (e.g. a new feature, a new dependency). Update if so.
4. Stage the changed files, commit following the subject/body/trailer convention above.
5. Tag the commit: `git tag vX.Y.Z`.
6. Run `git log -1` and `git tag -l` to confirm, and report both to the user.

Do not push commits or tags unless the user explicitly asks — this only commits and tags locally.

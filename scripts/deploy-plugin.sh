#!/bin/sh
# Copies AudioCompanion.qml into the MuseScore plugins folder.
# Called by the .githooks post-merge / post-checkout / post-rewrite hooks (see
# scripts/install-git-hooks.sh); only deploys from the main checkout, never
# from a linked worktree.
top=$(git rev-parse --show-toplevel) || exit 0
[ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ] || exit 0
DST="${AUDIO_COMPANION_PLUGIN_DIR:-$HOME/Documents/MuseScore4/Plugins}"
cmp -s "$top/AudioCompanion.qml" "$DST/AudioCompanion.qml" && exit 0
cp "$top/AudioCompanion.qml" "$DST/AudioCompanion.qml" \
  && echo "Deployed AudioCompanion.qml to $DST - fully restart MuseScore."

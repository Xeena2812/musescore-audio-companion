#!/bin/sh
# Points git at the versioned hooks in .githooks/ (post-merge, post-checkout, post-rewrite
# deploy the plugin). core.hooksPath is local config, so run this once per clone.
set -e
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
echo "core.hooksPath set to .githooks"

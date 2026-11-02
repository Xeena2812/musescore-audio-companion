#!/bin/sh
# Installs git hooks that deploy the plugin after pull/merge/checkout/rebase.
# Hooks point at the main checkout. Hooks are not versioned, so run this once per clone.
set -e
hooks="$(git rev-parse --git-common-dir)/hooks"
top=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
for h in post-merge post-checkout post-rewrite; do
    printf '#!/bin/sh\nexec "%s/scripts/deploy-plugin.sh"\n' "$top" > "$hooks/$h"
    chmod +x "$hooks/$h"
done
echo "Installed post-merge, post-checkout, post-rewrite hooks in $hooks"

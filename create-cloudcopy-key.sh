#!/usr/bin/env bash
#
# create-cloudcopy-key.sh — Create a MINIMAL-permission vast.ai API key (cloud copy only).
#
# Run this LOCALLY (with your admin/primary key configured) BEFORE training, then upload the
# printed scoped key to the instance for the auto cloud-sync cron. Even if the instance leaks
# the key, it can ONLY trigger cloud copy — not destroy instances or spend credits.
#
# WHY a custom script: `vastai create api-key --raw` does not emit clean JSON in some CLI
# versions, and the cloud-copy permission endpoint name is non-obvious. This hits the REST API
# directly with the validated permission set.
#
# USAGE:
#   ./create-cloudcopy-key.sh                  # print the scoped key to stdout
#   VAST_API_KEY=$(./create-cloudcopy-key.sh)  # capture into env, then: ... ./setup-vast.sh cloudsync
#   ./create-cloudcopy-key.sh --set-env-var    # also set vast ACCOUNT env-var VAST_API_KEY
#                                              # (auto-injected into FUTURE instances; still prints)
#
# The admin/primary key is read from ~/.config/vastai/vast_api_key (or $VAST_ADMIN_KEY).
# Prefer env vars over copying a key file onto rented instances.
set -euo pipefail

NAME="${KEY_NAME:-faceswap-cc}"
ADMIN_KEY="${VAST_ADMIN_KEY:-$(cat "$HOME/.config/vastai/vast_api_key" 2>/dev/null || true)}"
[ -n "$ADMIN_KEY" ] || { echo "ERROR: no admin key (set VAST_ADMIN_KEY or run 'vastai set api-key')" >&2; exit 1; }

# Minimal permission: instance_write limited to the rclone/cloud-copy POST endpoint.
PERMS='{"api":{"instance_write":{"api.commands.rclone":{"POST":{}}}}}'

resp="$(curl -s -X POST "https://console.vast.ai/api/v0/auth/apikeys/" \
  -H "Authorization: Bearer $ADMIN_KEY" -H "Content-Type: application/json" \
  -d "{\"name\":\"$NAME\",\"permissions\":$PERMS}")"

scoped="$(printf '%s' "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['key']) if d.get('success') else sys.exit('create failed: '+str(d))")"

if [ "${1:-}" = "--set-env-var" ]; then
  # Set as a vast.ai account env-var -> auto-injected into future instances' environment.
  vastai create env-var VAST_API_KEY "$scoped" >&2
  echo "Set vast account env-var VAST_API_KEY (injected into new instances)." >&2
fi
printf '%s\n' "$scoped"

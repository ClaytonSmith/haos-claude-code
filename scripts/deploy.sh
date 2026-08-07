#!/usr/bin/env bash
# Install/update this add-on on a Home Assistant instance over the REST API.
#
# Usage:
#   export HA_URL=http://192.168.1.50:8123
#   read -rs HA_TOKEN && export HA_TOKEN     # paste a long-lived access token
#   ./scripts/deploy.sh
#
# HA_TOKEN is read from the environment and never written to disk or logged.
# Create one at: Home Assistant -> your profile -> Security -> Long-lived access
# tokens. It is admin-equivalent, so revoke it there when you are done.
set -euo pipefail

REPO_URL="https://github.com/ClaytonSmith/haos-claude-code"
SLUG_SUFFIX="_claude_code"

: "${HA_URL:?set HA_URL, e.g. http://192.168.1.50:8123}"
: "${HA_TOKEN:?set HA_TOKEN to a Home Assistant long-lived access token}"
HA_URL="${HA_URL%/}"

api() {
    # api <METHOD> <path> [json-body]
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS -X "${method}" -H "Authorization: Bearer ${HA_TOKEN}"
                -H "Content-Type: application/json" "${HA_URL}/api/hassio${path}")
    [[ -n "${body}" ]] && args+=(-d "${body}")
    curl "${args[@]}"
}

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

step "Checking connectivity to ${HA_URL}"
api GET /supervisor/info | jq -e '.result == "ok"' >/dev/null \
    || die "could not reach the Supervisor API. Check HA_URL, the token, and that this is HAOS (not a bare Core container)."
echo "ok"

step "Registering the add-on repository"
if api GET /store/repositories | jq -e --arg u "${REPO_URL}" '.data[]? | select(.source == $u)' >/dev/null 2>&1; then
    echo "already registered"
else
    api POST /store/repositories "$(jq -nc --arg r "${REPO_URL}" '{repository: $r}')" \
        | jq -e '.result == "ok"' >/dev/null \
        || die "failed to add the repository"
    echo "added"
fi

step "Reloading the add-on store"
api POST /store/reload >/dev/null || true
sleep 3

step "Locating the add-on"
SLUG="$(api GET /store/addons | jq -r --arg s "${SLUG_SUFFIX}" \
    '.data.addons[]? | select(.slug | endswith($s)) | .slug' | head -1)"
[[ -n "${SLUG}" ]] || die "add-on not found in the store. Give the reload a moment and re-run."
echo "slug: ${SLUG}"

INSTALLED="$(api GET "/addons/${SLUG}/info" | jq -r '.data.version // "null"')"
if [[ "${INSTALLED}" == "null" ]]; then
    step "Installing (pulling the image — this takes a few minutes)"
    api POST "/addons/${SLUG}/install" | jq -e '.result == "ok"' >/dev/null \
        || die "install failed; check Settings -> System -> Logs -> Supervisor"
else
    step "Already installed (${INSTALLED}) — updating if a newer version exists"
    api POST "/addons/${SLUG}/update" >/dev/null 2>&1 || echo "already current"
fi

# Non-secret options only. Real secrets belong in the .env on the HA box, at
# /addon_configs/${SLUG}/.env — see claude-code/DOCS.md.
if [[ -n "${GIT_USER_NAME:-}${GIT_USER_EMAIL:-}" ]]; then
    step "Applying git identity options"
    api POST "/addons/${SLUG}/options" "$(jq -nc \
        --arg n "${GIT_USER_NAME:-}" --arg e "${GIT_USER_EMAIL:-}" \
        '{options: {git_user_name: $n, git_user_email: $e}}')" >/dev/null
fi

step "Starting the add-on"
api POST "/addons/${SLUG}/start" >/dev/null 2>&1 || true
sleep 5
api GET "/addons/${SLUG}/info" | jq -r '"state: \(.data.state)  version: \(.data.version)"'

cat <<EOF

Done. Next:
  1. Open Home Assistant -> sidebar -> Claude Code
  2. Run: claude     (sign in interactively — this cannot be scripted)
  3. Optional: drop secrets in /addon_configs/${SLUG}/.env and restart the add-on

Revoke the long-lived token now if this was a one-off:
  ${HA_URL}/profile/security
EOF

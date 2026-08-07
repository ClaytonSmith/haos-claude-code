#!/usr/bin/env bash
# Install/update this add-on on a Home Assistant instance over the REST API.
#
# If you can SSH into the box, `ha` is simpler and needs no token — see README.
# This script is for driving the install remotely.
#
# Usage:
#   export HA_URL=http://192.168.1.50:8123
#   read -rs HA_TOKEN && export HA_TOKEN     # long-lived access token
#   ./scripts/deploy.sh [--diagnose]
#
# Supervisor renamed "addons" to "apps" in 2026.07 and kept the old routes as v1
# aliases, so every call below tries both spellings rather than assuming either.
set -euo pipefail

REPO_URL="https://github.com/ClaytonSmith/haos-claude-code"
SLUG_SUFFIX="_claude_code"
DIAGNOSE="${1:-}"

: "${HA_URL:?set HA_URL, e.g. http://192.168.1.50:8123}"
: "${HA_TOKEN:?set HA_TOKEN to a Home Assistant long-lived access token}"
HA_URL="${HA_URL%/}"

api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS -X "${method}" -H "Authorization: Bearer ${HA_TOKEN}"
                -H "Content-Type: application/json" "${HA_URL}/api/hassio${path}")
    [[ -n "${body}" ]] && args+=(-d "${body}")
    curl "${args[@]}" 2>/dev/null
}

# POST the first path that reports success; return 1 if none do.
post_first_ok() {
    local body="${1}"; shift
    local path
    for path in "$@"; do
        if api POST "${path}" "${body}" | jq -e '.result == "ok"' >/dev/null 2>&1; then
            echo "    via ${path}" >&2
            return 0
        fi
    done
    return 1
}

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

step "Checking connectivity to ${HA_URL}"
api GET /supervisor/info | jq -e '.result == "ok"' >/dev/null \
    || die "cannot reach the Supervisor API — check HA_URL, the token, and that this is HAOS."
echo "ok"

if [[ "${DIAGNOSE}" == "--diagnose" ]]; then
    step "Registered repositories"
    api GET /store/repositories | jq -r '(.data // [])[]? | "  \(.slug // "?")  \(.source // .url // "?")"'
    step "Store entries matching 'claude' (both API generations)"
    for p in /store/apps /store/addons; do
        echo "  ${p}:"
        api GET "${p}" | jq -r '((.data.apps // .data.addons // .data // []) | select(type=="array"))[]?
            | select((.slug // "") | test("claude"))
            | "    slug=\(.slug)  version=\(.version // "?")  installed=\(.installed // false)"' 2>/dev/null \
            || echo "    (no usable response)"
    done
    exit 0
fi

step "Registering the add-on repository"
if post_first_ok "$(jq -nc --arg r "${REPO_URL}" '{repository: $r}')" /store/repositories; then
    echo "registered"
else
    echo "already registered (or the endpoint rejected a duplicate) — continuing"
fi

step "Reloading the add-on store"
post_first_ok "" /store/reload /addons/reload >/dev/null || echo "reload endpoint not found — continuing"
sleep 5

step "Locating the add-on"
SLUG=""
for p in /store/apps /store/addons; do
    SLUG="$(api GET "${p}" | jq -r --arg s "${SLUG_SUFFIX}" \
        '((.data.apps // .data.addons // .data // []) | select(type=="array"))[]?
         | select((.slug // "") | endswith($s)) | .slug' 2>/dev/null | head -1)"
    [[ -n "${SLUG}" ]] && { echo "found via ${p}"; break; }
done
[[ -n "${SLUG}" ]] || die "add-on not in the store. Run: $0 --diagnose"
echo "slug: ${SLUG}"

step "Installing (pulls the image — a few minutes)"
post_first_ok "" "/store/apps/${SLUG}/install" "/store/addons/${SLUG}/install" "/addons/${SLUG}/install" \
    || echo "already installed, or install returned non-ok — continuing"

if [[ -n "${GIT_USER_NAME:-}${GIT_USER_EMAIL:-}" ]]; then
    step "Applying git identity"
    post_first_ok "$(jq -nc --arg n "${GIT_USER_NAME:-}" --arg e "${GIT_USER_EMAIL:-}" \
        '{options: {git_user_name: $n, git_user_email: $e}}')" \
        "/apps/${SLUG}/options" "/addons/${SLUG}/options" >/dev/null || echo "could not set options"
fi

step "Starting"
post_first_ok "" "/apps/${SLUG}/start" "/addons/${SLUG}/start" >/dev/null || echo "start returned non-ok"
sleep 5
for p in "/apps/${SLUG}/info" "/addons/${SLUG}/info"; do
    api GET "${p}" | jq -e '.data' >/dev/null 2>&1 \
        && { api GET "${p}" | jq -r '"state: \(.data.state)  version: \(.data.version)"'; break; }
done

cat <<EOF

Next:
  1. Home Assistant -> sidebar -> Claude Code
  2. Run: claude          (interactive sign-in; cannot be scripted)
  3. Secrets: /app_configs/${SLUG}/.env  then restart the add-on

Revoke the token if this was a one-off: ${HA_URL}/profile/security
EOF

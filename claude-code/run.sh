#!/usr/bin/env bash
# Entrypoint for the Claude Code add-on.
#
# /data is the add-on's persistent volume, so HOME lives there: Claude Code's
# credentials, shell history, and any git checkouts survive restarts and image
# updates. Everything baked into the image itself does not.
set -euo pipefail

OPTIONS_FILE="/data/options.json"
export HOME="${HOME:-/data/home}"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

opt() {
    # opt <jq-path> [default] — read an add-on option, tolerating a missing file.
    local value
    [[ -f "${OPTIONS_FILE}" ]] || { printf '%s' "${2:-}"; return; }
    value="$(jq -r "${1} // empty" "${OPTIONS_FILE}" 2>/dev/null || true)"
    printf '%s' "${value:-${2:-}}"
}

mkdir -p "${HOME}" "${HOME}/.ssh" /data/workspace
chmod 700 "${HOME}/.ssh"

# --- shell environment -------------------------------------------------------
if [[ ! -f "${HOME}/.bashrc" ]]; then
    cat > "${HOME}/.bashrc" <<'EOF'
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export EDITOR=nano
alias ll='ls -alF'
alias ha='cd /homeassistant'
# /data/workspace persists; git checkouts belong here, not in / or /tmp.
cd "${HOME}" 2>/dev/null || true
EOF
fi
# `bash -l` reads .bash_profile, not .bashrc — bridge the two.
[[ -f "${HOME}/.bash_profile" ]] || echo '[[ -f ~/.bashrc ]] && . ~/.bashrc' > "${HOME}/.bash_profile"

# --- secrets -----------------------------------------------------------------
# Runtime secrets must never be baked into the image: it is published publicly to
# GHCR, and GitHub Actions secrets only exist on the build runner. Two runtime
# paths instead, both outside the image and outside git:
#
#   1. <app config dir>/.env — KEY=value lines, edited over SSH / Samba.
#      Host path: /app_configs/<slug>/.env (/addon_configs on Supervisor <2026.07)
#   2. Add-on options — Supervisor stores them in /data/options.json.
#
# Options are read after this block, so an explicitly-set option wins over .env.
APP_CONFIG_DIR="/app_config"
[[ -d "${APP_CONFIG_DIR}" ]] || APP_CONFIG_DIR="/addon_config"
export APP_CONFIG_DIR
ENV_FILE="${APP_CONFIG_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    log "Sourcing ${ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}" || log "WARNING: ${ENV_FILE} returned non-zero."
    set +a
fi

# Supervisor injects SUPERVISOR_TOKEN because config.yaml sets
# homeassistant_api: true. It is scoped to this add-on and rotates on its own, so
# there is no long-lived token to mint, store, or leak.
if [[ -n "${SUPERVISOR_TOKEN:-}" ]]; then
    export HA_URL="${HA_URL:-http://supervisor/core}"
    export HA_TOKEN="${HA_TOKEN:-${SUPERVISOR_TOKEN}}"
    log "Home Assistant API available at \${HA_URL} with \${HA_TOKEN}."
fi

# --- options -----------------------------------------------------------------
git_name="$(opt '.git_user_name')"
git_email="$(opt '.git_user_email')"
[[ -n "${git_name}" ]] && git config --global user.name "${git_name}"
[[ -n "${git_email}" ]] && git config --global user.email "${git_email}"
git config --global --add safe.directory '*'

api_key="$(opt '.anthropic_api_key')"
if [[ -n "${api_key}" ]]; then
    export ANTHROPIC_API_KEY="${api_key}"
    log "ANTHROPIC_API_KEY set from add-on options (API billing)."
fi

mapfile -t extra_packages < <(
    [[ -f "${OPTIONS_FILE}" ]] && jq -r '.extra_packages[]? // empty' "${OPTIONS_FILE}" 2>/dev/null || true
)
if [[ ${#extra_packages[@]} -gt 0 ]]; then
    log "Installing extra packages: ${extra_packages[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq \
        && apt-get install -y --no-install-recommends "${extra_packages[@]}" \
        || log "WARNING: extra package install failed; continuing."
fi

# --- user hook ---------------------------------------------------------------
# post-start.sh in the app config dir (host: /app_configs/<slug>/post-start.sh)
# lets you extend the container without rebuilding the image.
HOOK="${APP_CONFIG_DIR}/post-start.sh"
if [[ -x "${HOOK}" ]]; then
    log "Running ${HOOK}"
    "${HOOK}" || log "WARNING: post-start hook exited non-zero; continuing."
elif [[ -f "${HOOK}" ]]; then
    log "Found ${HOOK} but it is not executable — skipping (chmod +x it)."
fi

# --- first-run hint ----------------------------------------------------------
if [[ ! -e "${CLAUDE_CONFIG_DIR}/.credentials.json" && -z "${api_key:-}" ]]; then
    cat > "${HOME}/.motd" <<'EOF'

  Claude Code is installed but not signed in yet.

    claude          then follow the sign-in prompt and paste the code back

  Handy paths:
    /homeassistant  your Home Assistant config (read-write — be careful)
    /share          shared with other add-ons
    /data/workspace persistent scratch space for git checkouts

EOF
    grep -q '.motd' "${HOME}/.bashrc" 2>/dev/null \
        || echo '[[ -f ~/.motd ]] && cat ~/.motd' >> "${HOME}/.bashrc"
fi

log "Starting web terminal on port 7681"
cd "${HOME}"

# tmux keeps the session alive across browser reloads, so a long Claude Code run
# is not killed by closing the tab.
exec ttyd \
    --port 7681 \
    --writable \
    --client-option fontSize=14 \
    --client-option 'theme={"background":"#1e1e2e"}' \
    tmux new -A -s claude bash -l

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

# --- workspace repo ----------------------------------------------------------
# Check the add-on's own source out *inside* the container. Without this, the
# CLAUDE.md that addresses the agent living here exists only on the machine that
# built the image — the one reader it is written for never sees it. Cloning it
# also means the manifest, run.sh, and Dockerfile are readable and editable from
# the session that runs on top of them.
WORKDIR="${HOME}"
repo_url="$(opt '.workspace_repo')"
if [[ -n "${repo_url}" ]]; then
    repo_dir="/data/workspace/$(basename "${repo_url}" .git)"
    if [[ -d "${repo_dir}/.git" ]]; then
        # --ff-only so a restart can never discard work in progress: if the agent
        # has local commits, or the branch diverged, this fails and leaves it be.
        git -C "${repo_dir}" fetch --quiet --all 2>/dev/null || log "  fetch failed; using the checkout as-is."
        if git -C "${repo_dir}" pull --ff-only --quiet 2>/dev/null; then
            log "Updated ${repo_dir}"
        else
            log "${repo_dir} is not fast-forwardable (local work?) — left untouched."
        fi
    elif git clone --quiet "${repo_url}" "${repo_dir}" 2>/dev/null; then
        log "Cloned ${repo_url} -> ${repo_dir}"
    else
        log "WARNING: could not clone ${repo_url}; continuing without it."
    fi
    [[ -d "${repo_dir}" ]] && WORKDIR="${repo_dir}"
fi

# The Remote Control bridge keys its resume pointer on a slug of the working
# directory, so WORKDIR is not cosmetic: start one boot in a different directory
# and the pointer is not found, a fresh environment is registered, and every
# prior session reports `environment_deleted` in the web UI. The fallback to
# $HOME above is exactly that hazard, so remember the directory that worked and
# prefer it over the fallback on every later boot.
STICKY="/data/.workspace_dir"
if [[ "${WORKDIR}" == "${HOME}" && -s "${STICKY}" ]] && [[ -d "$(cat "${STICKY}")" ]]; then
    WORKDIR="$(cat "${STICKY}")"
    log "Workspace repo unavailable — reusing last known workdir ${WORKDIR} (keeps the resume pointer findable)."
fi
printf '%s' "${WORKDIR}" > "${STICKY}"

if [[ -n "${repo_url}" ]]; then

    # Starting the shell in the repo makes CLAUDE.md load as project context, but
    # only while the cwd stays there — `cd /homeassistant` and it silently drops
    # out. The stance it describes ("you are running inside this container; an
    # update ends your session") is true of the whole container, not one
    # directory, so link it in as user-level memory too. Belt and braces.
    if [[ -f "${repo_dir}/CLAUDE.md" ]]; then
        mkdir -p "${CLAUDE_CONFIG_DIR}"
        if [[ ! -e "${CLAUDE_CONFIG_DIR}/CLAUDE.md" || -L "${CLAUDE_CONFIG_DIR}/CLAUDE.md" ]]; then
            # Symlink, not a copy, so `git pull` keeps it current.
            ln -sfn "${repo_dir}/CLAUDE.md" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
            log "Linked CLAUDE.md into ${CLAUDE_CONFIG_DIR} (loads regardless of cwd)"
        else
            log "${CLAUDE_CONFIG_DIR}/CLAUDE.md is a real file — left alone."
        fi
    fi
fi

# The shell starts here. Written every boot and sourced last, so it wins over the
# .bashrc above — which is only generated once and would otherwise pin an old path.
printf 'cd %q 2>/dev/null || true\n' "${WORKDIR}" > "${HOME}/.workspace_cd"
grep -q 'workspace_cd' "${HOME}/.bashrc" 2>/dev/null \
    || echo '[[ -f ~/.workspace_cd ]] && . ~/.workspace_cd' >> "${HOME}/.bashrc"

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

# --- house-dispatch ----------------------------------------------------------
# Lets the rest of the house hand work to a Claude session over HTTP: HA
# automations, cron, and sibling add-ons all reach it, so a service does not need
# an Anthropic API key of its own to get an LLM answer.
#
# It binds inside the container only. config.yaml maps no port for it on purpose,
# so it is reachable at http://1dedd3a9-claude-code:8097 on the add-on network and
# NOT from the LAN — it runs `claude` as root, and an open port would be remote
# code execution on a flat network. Callers send a profile NAME, never a prompt.
if [[ "$(opt '.dispatch_enabled' 'true')" == "true" && -f /opt/dispatch/dispatchd.py ]]; then
    # setsid so it survives independently of the terminal ttyd owns.
    setsid python3 /opt/dispatch/dispatchd.py >> /data/dispatch.log 2>&1 &
    log "Started house-dispatch on :8097 (log: /data/dispatch.log)"
fi

# --- session autostart -------------------------------------------------------
# tmux runs this instead of a bare login shell, so the add-on comes up already
# hosting a Remote Control session reachable from claude.ai/code and the mobile
# app. Two deliberate choices:
#
#   - the command is NOT exec'd, so if it exits or fails you land in a shell
#     rather than staring at a dead panel with no way to debug it;
#   - the command is read from a file at runtime, not baked into this script, so
#     no quoting from an add-on option can break the entrypoint.
printf '%s' "$(opt '.autostart_command')" > "${HOME}/.autostart_command"
cat > "${HOME}/.start-session" <<'START'
#!/usr/bin/env bash
# Generated by run.sh on every start — edits here are overwritten.
[[ -f ~/.workspace_cd ]] && . ~/.workspace_cd
cmd="$(cat ~/.autostart_command 2>/dev/null)"

# Supervise, do not run-once. The bridge is what makes claude.ai/code sessions
# resumable, and its resume pointer goes stale 4h after it stops writing — so a
# bridge that dies at 02:00 and waits for a human to notice takes every live
# session with it. Restart it instead. A run that survived a minute is treated as
# healthy and restarts immediately; repeated instant exits are a real fault (bad
# flag, no credentials) that a retry loop would only hide, so back off and give
# up rather than spin. Ctrl-C is a person asking for a shell — honour it.
attempt=0
trap 'printf "\n  Interrupted — dropping to a shell.\n\n"; cmd=""' INT
while [[ -n "${cmd}" ]]; do
    printf '\n  Starting: %s\n  in: %s\n  (Ctrl-b d detaches and leaves it running)\n\n' "${cmd}" "${PWD}"
    started="${SECONDS}"
    eval "${cmd}" || true
    [[ -z "${cmd}" ]] && break                      # trap fired during the run
    if (( SECONDS - started >= 60 )); then
        attempt=0                                   # it ran; whatever killed it was transient
    elif (( ++attempt >= 5 )); then
        printf '\n  Exited immediately %s times — not restarting. Dropping to a shell.\n\n' "${attempt}"
        break
    fi
    delay=$(( attempt * 5 ))
    printf '\n  Exited after %ss — restarting in %ss (attempt %s/5, Ctrl-C for a shell).\n\n' \
        "$(( SECONDS - started ))" "${delay}" "${attempt}"
    sleep "${delay}"
done
trap - INT
exec bash -l
START
chmod +x "${HOME}/.start-session"

# The bridge treats its resume pointer as stale after 4h, measured on the file's
# mtime. A running bridge rewrites it hourly, so the clock effectively starts the
# moment the container dies — down overnight means every session is unrecoverable
# even though the backend still holds the environment. Touch it here so the TTL
# runs from *boot* instead. If the backend really has reaped the environment the
# bridge just registers a fresh one, which is what would have happened anyway.
POINTER="${CLAUDE_CONFIG_DIR}/projects/${WORKDIR//\//-}/bridge-pointer.json"
if [[ -f "${POINTER}" ]]; then
    touch "${POINTER}"
    log "Refreshed resume pointer $(basename "$(dirname "${POINTER}")")/bridge-pointer.json"
fi

log "Starting web terminal on port 7681 in ${WORKDIR}"
cd "${WORKDIR}"

# ttyd spawns its command once per *browser connection* — that is what --max-clients
# and --exit-no-conn are counting. So handing the session to ttyd means nothing runs
# until someone opens the panel, and an autostarted Remote Control session would
# never appear in claude.ai/code unattended. Start it detached at boot instead; ttyd
# then only ever attaches to a session that is already up.
if tmux has-session -t claude 2>/dev/null; then
    log "tmux session 'claude' already running — attaching."
else
    tmux new-session -d -s claude "${HOME}/.start-session"
    log "Started detached tmux session 'claude' running: $(cat "${HOME}/.autostart_command")"
fi

# On stop, Docker signals PID 1 (tini) only, and tini's only child is ttyd. The
# tmux server and the `claude remote-control` bridge beneath it were reparented to
# PID 1 when tmux daemonised, so they never see SIGTERM — they are SIGKILLed when
# the grace period expires, and every live session dies mid-write. Forward the
# signal by hand so the bridge runs its own shutdown, which stops its sessions
# cleanly and deliberately skips the environment deregister so claude.ai/code can
# reattach on the next boot. Docker's grace is 10s, so this must finish inside it.
shutdown() {
    local bridge
    bridge="$(pgrep -f 'claude remote-control' | head -n1 || true)"
    if [[ -n "${bridge}" ]]; then
        log "Forwarding SIGTERM to claude remote-control (pid ${bridge})"
        kill -TERM "${bridge}" 2>/dev/null || true
        for _ in $(seq 1 8); do
            kill -0 "${bridge}" 2>/dev/null || break
            sleep 1
        done
    fi
    kill -TERM "${ttyd_pid}" 2>/dev/null || true
}
trap shutdown TERM INT

# tmux keeps the session alive across browser reloads, so a long Claude Code run
# is not killed by closing the tab. No command here on purpose — the session was
# already started above, and this must only ever attach to it.
# Backgrounded rather than exec'd so the trap above still has a shell to run in.
ttyd \
    --port 7681 \
    --writable \
    --client-option fontSize=14 \
    --client-option 'theme={"background":"#1e1e2e"}' \
    tmux new -A -s claude &
ttyd_pid=$!
wait "${ttyd_pid}" || true

# Claude Code

An Ubuntu 24.04 dev container running Claude Code, with a terminal in the
Home Assistant sidebar.

## First run

Start the add-on, open **Claude Code** from the sidebar, and run:

```bash
claude
```

Follow the sign-in prompt — it prints a URL, you authenticate in a browser, and
paste the code back into the terminal. Credentials are stored in
`/data/home/.claude`, which persists across restarts and add-on updates.

If you would rather bill against an API key than a Claude subscription, set the
**Anthropic API key** option instead and skip the sign-in.

## Options

### `extra_packages`

A list of apt packages installed on every start:

```yaml
extra_packages:
  - postgresql-client
  - ffmpeg
```

Convenient, but it re-downloads on each boot. For anything permanent, add it to
the Dockerfile in the repo and bump the add-on version.

### `git_user_name` / `git_user_email`

Written to the container's global git config so commits from here are attributed
correctly.

### `anthropic_api_key`

Optional. Exported as `ANTHROPIC_API_KEY`. Leave empty to use subscription
sign-in.

### `workspace_repo`

A git URL cloned into `/data/workspace` on every start, and used as the shell's
working directory. Defaults to this add-on's own source.

That default is the point, not a convenience: a `CLAUDE.md` in this repo is
written *for the agent running in this container*, and unless the repo is checked
out in here, the one reader it addresses never sees it. Cloning it also puts
`config.yaml`, `run.sh`, and the `Dockerfile` within reach of the session running
on top of them.

On restart the checkout is updated with `git pull --ff-only`, which **cannot**
discard work: if there are local commits or the branch has diverged, the pull
fails and the checkout is left exactly as it was. Set the option to `""` to skip
cloning and start in `$HOME`.

## Secrets and environment variables

The image is published publicly to GHCR, so **nothing secret can live in it**.
GitHub Actions secrets don't help either — they only exist on the build runner.
Runtime secrets come from one of three places:

### 1. The Home Assistant API — no token needed

The add-on sets `homeassistant_api: true`, so Supervisor injects a scoped,
auto-rotating `SUPERVISOR_TOKEN`. The entrypoint re-exports it as:

```bash
HA_URL=http://supervisor/core
HA_TOKEN=<supervisor token>
```

So this works out of the box, with no long-lived token to mint or store:

```bash
curl -sH "Authorization: Bearer ${HA_TOKEN}" "${HA_URL}/api/states" | jq '.[0]'
```

Prefer this over a long-lived access token. If you specifically need one (for an
external service, say), put it in the `.env` below.

The same token also reaches **Supervisor** itself, because the add-on sets
`hassio_api: true` and `hassio_role: manager`:

```bash
curl -sH "Authorization: Bearer ${SUPERVISOR_TOKEN}" http://supervisor/store | jq '.data.addons | length'
```

That is what makes the container able to install and manage add-ons — including
building new ones and updating itself. `manager` is the lowest role whose
allowlist covers `/store.*` and `/addons/<slug>/...`; it also covers `/host/...`
and `/os/...`, so it can reboot the machine. Treat it with the seriousness that
implies.

Note this is Supervisor's own listener on the add-on network, **not** the
`/api/hassio/...` proxy on the Core port — that one is 401-blocked in HA 2026.7
no matter what token you present.

> Updating this add-on replaces the container you are running in, ending the
> session with no warning. For anything substantial, build a separate add-on
> instead of modifying this image.

### 2. `/app_config/.env` — for everything else

Create a `.env` in the add-on's config dir and it is sourced into the environment
on every start. Host path, via the Samba or File Editor add-on:

```
/app_configs/<slug>/.env
```

```bash
OPENAI_API_KEY=...
TAILSCALE_AUTHKEY=...
GH_TOKEN=...
```

It lives on the HA data volume — outside the image, outside git, and it survives
add-on updates.

### 3. Add-on options

`anthropic_api_key` is stored by Supervisor in `/data/options.json` and exported
as `ANTHROPIC_API_KEY`. Options are applied *after* `.env`, so an option that is
explicitly set wins.

### `autostart_command`

Run inside the tmux session on every start, from the `workspace_repo` checkout.
Defaults to:

```
claude remote-control --name haos
```

That hosts a Remote Control session you can drive from **claude.ai/code** or the
Claude mobile app, so the add-on is useful without opening the sidebar terminal
at all.

`--name` is pinned rather than left to default. The default name is derived from
the hostname, which here is the slug-based `1dedd3a9-claude-code` and changes if
the add-on is ever reinstalled under a different repository slug — you would get a
new entry in claude.ai/code instead of the same one reconnecting.

If the command exits or fails, you drop to an interactive shell rather than a dead
panel, and the reason is printed. Set the option to `""` to boot straight to a
shell.

Note the session inherits Claude Code's **default** permission mode. This
container holds `hassio_role: manager`, so think hard before adding
`--permission-mode bypassPermissions` here — that combination is an unattended
agent with host reboot rights.

## First run

Sign-in is interactive and cannot be scripted, so run `claude` once from the
sidebar terminal before relying on autostart. Credentials persist in
`/data/home/.claude`, so this is a one-time step that survives updates.

## Paths

| Path              | Notes                                                     |
| ----------------- | --------------------------------------------------------- |
| `/data/home`      | `HOME`. Persistent.                                        |
| `/data/workspace` | Persistent git checkouts. `workspace_repo` lands here.      |
| `/local_apps`     | The host's local add-on dir. Build sibling containers here. |
| `/homeassistant`  | Home Assistant config, **read-write**.                     |
| `/share`          | Shared with other add-ons.                                 |
| `/app_config`   | This add-on's config dir. Put `post-start.sh` here.        |
| `/ssl`            | Certificates, read-only.                                   |

Anything written elsewhere is lost when the add-on updates.

## The `post-start.sh` hook

An executable script at `/app_config/post-start.sh` runs on every start,
before the terminal comes up. From the Samba or File Editor add-on the host path
is `/app_configs/<slug>/post-start.sh`. Use it to clone repos,
install a language toolchain, or restore dotfiles without rebuilding the image.

Remember to `chmod +x` it — a non-executable hook is skipped with a log line.

## tmux

The terminal runs inside a tmux session named `claude`. Close the tab and
reconnect and you land back in the same session with your agent still running.
`Ctrl-b d` detaches; `tmux ls` lists sessions.

## Security

The add-on runs as root with read-write access to your Home Assistant config.
Use the sidebar panel (authenticated by Home Assistant) rather than the optional
`7681/tcp` port, which is not authenticated. Be deliberate about letting an agent
run unattended against your live configuration.

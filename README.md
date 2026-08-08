# Home Assistant add-on: Claude Code

An Ubuntu 24.04 dev container running [Claude Code][claude-code], installed as a
Home Assistant add-on with a terminal in the sidebar.

Home Assistant OS won't let you `docker run` an arbitrary container — the
Supervisor owns Docker. Add-ons *are* containers though, and nothing requires
them to use Home Assistant's Alpine base images. This repo builds a plain Ubuntu
image on GitHub Actions, publishes it to GHCR, and ships an add-on manifest that
points Supervisor at the published image, so your HA box pulls instead of builds.

## Install

### Over SSH (simplest — no token needed)

```bash
ha store repositories add https://github.com/ClaytonSmith/haos-claude-code
ha store reload
ha store apps | grep -i claude          # note the slug, e.g. a1b2c3d4_claude_code
ha apps install <slug>
ha apps start <slug>
```

`ha apps` is the current command; `ha addons` still works as an alias.

### Or in the UI

**Settings → Add-ons → Add-on Store → ⋮ → Repositories**, add
`https://github.com/ClaytonSmith/haos-claude-code`, refresh, then install and
start **Claude Code**.

### Or remotely

Drive Supervisor over its **WebSocket** `supervisor/api` route:
`POST /store/repositories` → `POST /store/reload` → `POST /store/addons/<slug>/install`
→ `POST /addons/<slug>/start`.

Do **not** reach for the `/api/hassio/...` REST proxy. It returns 401 on every
path in HA 2026.7 regardless of token, and a 401 there has an *empty body*, so a
`curl … | jq -e '.result == "ok"'` health check passes while every write
silently does nothing. That failure mode cost a full session before it was found.

Two more things that are easy to get wrong: `/store/apps` does not exist —
the 2026.07 addons → apps rename hit the `ha` CLI and the `map:` type, not the
REST paths, so it is still `/store/addons`. And `supervisor/api` raises
`unknown_error` with an empty message for any endpoint returning a non-JSON body
(`install`, `start`, `logs`) *even on success*; always read the state back with
`/addons/<slug>/info` rather than trusting the exception.

Either way, finish by opening **Claude Code** in the sidebar and running
`claude` once to sign in — that step is interactive and cannot be scripted.

After that it starts `claude remote-control --name haos` on every boot, in the
`workspace_repo` checkout, so you can drive it from **claude.ai/code** or the
mobile app without opening the sidebar at all. The `autostart_command` option
changes or disables it; if it exits you get a shell rather than a dead panel.

## What's in the image

Ubuntu 24.04 with Claude Code, Node 22, Python 3 + `uv`, `git`, `gh`, `ripgrep`,
`fd`, `jq`, `tmux`, `build-essential`, and the usual editors. `ttyd` serves the
terminal; `tmux` keeps your session alive across browser reloads, so closing the
tab doesn't kill a running agent.

## Mounted paths

| Path              | What it is                                                    |
| ----------------- | ------------------------------------------------------------- |
| `/data/home`      | `HOME`. Persistent — auth tokens, shell history, config.       |
| `/data/workspace` | Persistent checkouts. `workspace_repo` is cloned here on boot. |
| `/local_apps`     | The host's local add-on dir — build sibling containers here.   |
| `/homeassistant`  | Your Home Assistant config, **read-write**.                    |
| `/share`          | Shared with other add-ons, read-write.                         |
| `/app_config`   | This add-on's own config dir; drop a `post-start.sh` here.     |
| `/ssl`            | Certificates, read-only.                                       |

Everything outside `/data`, `/share`, and the mapped config dirs lives in the
image and is replaced on every add-on update.

## Secrets

The published image is public, and GitHub Actions secrets only exist on the build
runner — so no secret is ever baked in. At runtime:

- **Home Assistant API**: nothing to configure. `homeassistant_api: true` makes
  Supervisor inject a scoped, self-rotating token, re-exported as `HA_URL` and
  `HA_TOKEN`. Prefer this over minting a long-lived access token.
- **Everything else**: a `.env` at `/app_configs/<slug>/.env` is sourced
  on every start. Off the image, off git, survives updates.
- **`anthropic_api_key`**: an add-on option, stored in `/data/options.json` and
  exported as `ANTHROPIC_API_KEY`.

See [`claude-code/DOCS.md`](claude-code/DOCS.md) for details.

## Extending it

Three options, in increasing order of permanence:

- **`extra_packages`** in the add-on options — apt packages installed on each
  start. Convenient, but re-runs every boot.
- **`post-start.sh`** — drop an executable script at
  `/app_configs/<slug>/post-start.sh` (reachable via the Samba or File
  Editor add-on). Runs before the terminal starts.
- **Edit the Dockerfile here** and bump `version` in `claude-code/config.yaml`.
  Pushing to `main` builds and publishes both architectures; Home Assistant then
  offers the add-on update in the UI.

## Releasing a new image

The workflow tags images with the `version` field from `claude-code/config.yaml`,
and Supervisor pulls `image:version` — so **bumping that version is what makes an
update visible in Home Assistant**. Push to `main` with a changed version and the
add-on shows an update once the build finishes.

> **If you are Claude, running inside this container, read this twice.**
> Applying that update replaces the container you are executing in. Sessions do
> not survive it — the work stops mid-thought, with no chance to save state or
> report back. Editing this repo is editing your own floor.
>
> `/data/home` and `/data/workspace` persist, so credentials and checkouts come
> back; the *session* does not. Two consequences worth internalising:
>
> - Batch changes to this image. Land one version bump, not five.
> - For anything non-trivial, build it as its **own** add-on under `/local_apps`
>   rather than baking it in here. A sibling container can be rebuilt and
>   restarted as often as you like without ending the session doing the work.
>   `hassio_role: manager` exists precisely so you can do that unassisted.

## Security notes

This is a root shell with read-write access to your Home Assistant config, on
your LAN, running an agent. Reasonable precautions:

- Access it through the **Ingress sidebar panel**, which is behind Home Assistant
  authentication. The direct `7681/tcp` port mapping is disabled by default
  because it is *not* authenticated.
- Think twice before `--dangerously-skip-permissions` on a box that runs your
  house.
- `boot: manual` by default, so it isn't running unless you want it to be.

[claude-code]: https://claude.com/claude-code

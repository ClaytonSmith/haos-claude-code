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

`scripts/deploy.sh` drives the whole thing over the REST API from another
machine — see the header comment. `--diagnose` prints what Supervisor actually
sees, which is the fastest way to debug a store that looks empty.

Either way, finish by opening **Claude Code** in the sidebar and running
`claude` to sign in.

## What's in the image

Ubuntu 24.04 with Claude Code, Node 22, Python 3 + `uv`, `git`, `gh`, `ripgrep`,
`fd`, `jq`, `tmux`, `build-essential`, and the usual editors. `ttyd` serves the
terminal; `tmux` keeps your session alive across browser reloads, so closing the
tab doesn't kill a running agent.

## Mounted paths

| Path              | What it is                                                    |
| ----------------- | ------------------------------------------------------------- |
| `/data/home`      | `HOME`. Persistent — auth tokens, shell history, config.       |
| `/data/workspace` | Persistent scratch space. Put git checkouts here.              |
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

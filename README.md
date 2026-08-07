# Home Assistant add-on: Claude Code

An Ubuntu 24.04 dev container running [Claude Code][claude-code], installed as a
Home Assistant add-on with a terminal in the sidebar.

Home Assistant OS won't let you `docker run` an arbitrary container — the
Supervisor owns Docker. Add-ons *are* containers though, and nothing requires
them to use Home Assistant's Alpine base images. This repo builds a plain Ubuntu
image on GitHub Actions, publishes it to GHCR, and ships an add-on manifest that
points Supervisor at the published image, so your HA box pulls instead of builds.

## Install

1. **Settings → Add-ons → Add-on Store → ⋮ → Repositories**, and add:

   ```
   https://github.com/ClaytonSmith/haos-claude-code
   ```

2. Refresh the store, open **Claude Code**, and click **Install**. Supervisor
   pulls `ghcr.io/claytonsmith/haos-claude-code-{arch}` matching your hardware.
3. **Start** the add-on, then open **Claude Code** in the sidebar.
4. Run `claude` in the terminal and follow the sign-in prompt.

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
| `/addon_config`   | This add-on's own config dir; drop a `post-start.sh` here.     |
| `/ssl`            | Certificates, read-only.                                       |

Everything outside `/data`, `/share`, and the mapped config dirs lives in the
image and is replaced on every add-on update.

## Extending it

Three options, in increasing order of permanence:

- **`extra_packages`** in the add-on options — apt packages installed on each
  start. Convenient, but re-runs every boot.
- **`post-start.sh`** — drop an executable script at
  `/addon_configs/*_claude_code/post-start.sh` (reachable via the Samba or File
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

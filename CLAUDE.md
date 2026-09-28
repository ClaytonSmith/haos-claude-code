You are in a Home Assistant OS add-on: an Ubuntu container that builds, deploys
and runs the house's services.

This repository defines that container. An add-on update replaces it: running
commands are killed and the turn in flight is lost, though the session resumes
afterwards. Build anything non-trivial as its own sibling add-on instead of
changing this one.

## Start here

**Run `house-brief` at the start of every session.** It prints live state on
one page: platform, network, add-ons, what each service is for and whether it
is healthy, areas and key entities, backups, the inbox. If it contradicts a
document, trust `house-brief`.

Tools, on `PATH` and versioned in `/data/workspace/haos-infra/tools/` (`~/bin`
holds symlinks, so an edit to the checkout is live at once):

- `hactl` (`hactl --help`) — Home Assistant and Supervisor APIs, registries,
  add-on management, the git server, the network, HTTPS routes, MQTT,
  screenshots.
- `ha-ws <command> ['<json>']` — one-shot HA websocket calls, for what REST
  lacks (backup config, registries, Lovelace).

## Documentation

Docs state what is true now and what to watch out for: no history, no dates, no
decision records. When something changes, rewrite the doc; never append to it.

| Kind of fact | Its one home |
|---|---|
| How a service works, and its constraints | `README.md` in its checkout; read it before changing the service |
| How to use a tool | the tool's `--help` |
| Live state | `house-brief` |
| Preferences and cross-cutting traps | memory, indexed in `~/.claude/projects/-data-workspace-haos-claude-code/memory/MEMORY.md` |

## Infrastructure

Everything is self-hosted on this box. Nothing is published to the internet.

| What | Where | Notes |
|---|---|---|
| Forgejo | `http://192.168.1.102:3000` | git server and OCI registry, private |
| Builder | `http://192.168.1.102:8100` | builds images with `buildah`, no Docker socket |
| Checkouts | `/data/workspace/<repo>` | several add-ons live inside `haos-infra/` |
| Add-on source | `/local_apps/<slug>` | what Supervisor builds |
| HA config | `/homeassistant` | a git working tree; read its README before editing |
| Credentials | `~/.config/haos/*.env` | 0600. Never echo a token, or output that may contain one |

```bash
hactl repos                          # what exists
hactl newrepo <name> [desc]          # create a private repo
hactl install <slug>                 # first install of a new local add-on
hactl deploy <slug>                  # workspace -> /local_apps -> rebuild -> tail
hactl build <repo> [ref] [tag]       # commit -> image -> registry
hactl route add <name> <host:port>   # HTTPS name for a service
```

- Use `hactl deploy`, never a bare `hactl rebuild`. `/local_apps/<slug>` and
  the checkout are separate copies, and a forgotten copy fails silently.
- Bump `version:` in `config.yaml` whenever `options:` or `schema:` change;
  `rebuild` does not re-read the manifest.
- An add-on either builds locally from `/local_apps` or pulls
  `image: 127.0.0.1:3000/claude/<name>`. `/data/workspace/haos-infra/README.md`
  explains the registry addressing, the builder, and the health contract every
  service implements.
- This repository is public. Keep personal detail and anything secret out of
  it.

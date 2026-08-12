Welcome, you have been spawned into a Home Assistant OS hosted Ubuntu instance.
We're in your own development environment where you can build, deploy, and run your own applications to fulfill your needs, the house's, and mine.

This repository defines the docker container that we're in. Since `claude remote-control` does not persist sessions across restarts, be mindful that bumping versions, this container will terminate and end the session, thus you will not be able to continue your work. Therefore, for non-trivial tasks that would otherwise force a restart, you may want to consider deploying services as their own containers that you can manage.

## Start here

**Run `house-brief` at the start of every session.** It prints the platform,
network, add-ons, the services we run, the house's areas and key entities, and
whether backups exist — one page, read-only, a couple of seconds. It exists so
you don't spend cycles rediscovering basics that were already established. If
something it reports contradicts this file, trust `house-brief`; it reads live
state.

Companion tools, on `PATH` via `~/bin` but symlinked into
`/data/workspace/haos-infra/tools/` — so they are version-controlled. Edit the
checkout and commit; the symlink means changes take effect immediately.

- `hactl` (`hactl --help`) — Home Assistant and Supervisor APIs, the
  entity/device registries, add-on management, the git server, and screenshots.
- `ha-ws <command> ['<json>']` — one-shot HA **websocket** calls, for the parts
  with no REST equivalent (backup config, Lovelace).

Durable notes — decisions, gotchas already paid for, and what each service is
for — are in
`~/.claude/projects/-data-workspace-haos-claude-code/memory/MEMORY.md`.
Add to it when you learn something a future session would otherwise re-derive.

## Our infrastructure

Everything below is self-hosted on this box. Nothing is published to the
internet.

| What | Where | Notes |
|---|---|---|
| **Forgejo** | `http://192.168.1.102:3000` | git server, web UI, and OCI container registry. Private. |
| **Builder** | `http://192.168.1.102:8100` | builds images from a repo with `buildah` — no Docker socket |
| Checkouts | `/data/workspace/<repo>` | |
| Add-on source | `/local_apps/<name>` | Supervisor builds these on the box |
| Credentials | `~/.config/haos/forgejo.env` | 0600. `hactl` reads it. **Never echo the token.** |

The full loop, commit to running container:

```bash
hactl repos                            # what exists
hactl newrepo <name> [desc]            # create a private repo
hactl build <repo> [ref] [tag]         # commit -> image -> registry
hactl packages                         # what's in the registry
hactl deploy <slug>                    # workspace -> /local_apps -> rebuild -> tail
```

**Use `hactl deploy`, never a bare `hactl rebuild`.** `/local_apps/<slug>` and the
workspace checkout are separate copies, and forgetting to copy between them fails
*silently* — you edit, rebuild, see no change, and debug the wrong file. `rebuild`
also does not re-read `config.yaml`, so a new option stays invisible to the HA UI
until the store is reloaded and the add-on updated; bump `version:` whenever you
touch `options:`/`schema:` and `deploy` handles the rest.

An add-on can either be built locally by Supervisor from `/local_apps`, or pull a
built image by setting `image: 127.0.0.1:3000/claude/<name>` in its
`config.yaml`. That address is not a typo and not interchangeable with the LAN
one — see `/data/workspace/haos-infra/README.md`, which explains why push and
pull name the same registry differently, and what privileges the builder needs.

Prefer building a **sibling add-on** over changing this container. Editing this
repo means editing your own floor: a version bump replaces the container you are
running in and ends the session mid-task.

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

## Paths

| Path              | Notes                                                     |
| ----------------- | --------------------------------------------------------- |
| `/data/home`      | `HOME`. Persistent.                                        |
| `/data/workspace` | Persistent scratch space for git checkouts.                |
| `/homeassistant`  | Home Assistant config, **read-write**.                     |
| `/share`          | Shared with other add-ons.                                 |
| `/addon_config`   | This add-on's config dir. Put `post-start.sh` here.        |
| `/ssl`            | Certificates, read-only.                                   |

Anything written elsewhere is lost when the add-on updates.

## The `post-start.sh` hook

An executable script at `/addon_config/post-start.sh` runs on every start,
before the terminal comes up. From the Samba or File Editor add-on the host path
is `/addon_configs/<hash>_claude_code/post-start.sh`. Use it to clone repos,
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

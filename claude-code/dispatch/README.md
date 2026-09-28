# house-dispatch

Lets house services hand work to a Claude Code session over HTTP.

    POST http://1dedd3a9-claude-code:8097/dispatch
    Authorization: Bearer <token from ~/.config/haos/dispatch.env>
    {"profile": "nutrition", "input": "chicken burrito bowl with guac"}

It runs in the `claude-code` add-on because the `claude` binary and its
credentials live there. It uses the subscription login in `$CLAUDE_CONFIG_DIR`;
no API key is involved.

## Profiles

Callers send a profile name and input, never a prompt. Each profile fixes the
system prompt, model, tools and turn limit on the server.

| Profile | Model | Tools | Turns | For |
|---|---|---|---|---|
| `nutrition` | Haiku 4.5 | none | 1 | meal → itemised calories and macros |
| `exercise` | Haiku 4.5 | none | 1 | workout → activities with Compendium MET values |
| `logentry` | Haiku 4.5 | none | 1 | free text → food and exercise sections in one reply |
| `morning-brief` | Sonnet 5 | WebSearch, WebFetch | 12 | the display's morning brief |
| `local-events` | Haiku 4.5 | WebSearch, WebFetch | 12 | local events for the interests feed |
| `interest-news` | Haiku 4.5 | WebSearch, WebFetch | 12 | news for a batch of interests |
| `house-task` | session default | all | 30 | open-ended investigation |

- A profile with a tool list gets exactly those tools; everything else is
  denied.
- `house-task` has full tooling and bypasses permission prompts. Keep it off
  any automatic path.
- Responses report the profile's pinned model and `api_equiv_usd`.

## Security

- The process runs `claude` as root with the house's credentials. Accepting
  prompts or tool lists from callers would be remote code execution.
- `config.yaml` maps no host port for 8097. Siblings reach it over the add-on
  network; the LAN cannot. Do not add a `ports:` mapping for it.
- The token reaches callers as an add-on option. Supervisor echoes options in
  validation errors, so it can land in logs. Rotate it with
  `python3 /opt/dispatch/dispatchd.py --rotate-token`, then update every
  caller.

## Cost

- Nothing is billed per call. `api_equiv_usd` is what the tokens would cost at
  API rates; the `anthropic_api_key` add-on option is the only switch to API
  billing.
- Calls spend the subscription quota that interactive sessions use.
- Each call is a cold process: about 15–30 s and 18k tokens whatever the
  question, with no cache reuse. `--setting-sources ''` and
  `--disallowed-tools` do not reduce it.
- Concurrency is capped at 2.

Callers must therefore:

- run asynchronously, never blocking a user on a dispatch;
- cache repeated inputs on their side;
- treat a rate limit as a normal outcome and back off, because a failed
  dispatch has already spent its quota.

## Operating it

```bash
curl -s http://localhost:8097/health     # profiles and free slots
tail -f /data/dispatch.log               # one line per call
./restart-dev.sh                         # run the workspace copy instead of the baked one
```

- The add-on starts the copy baked into the image at `/opt/dispatch` when
  `dispatch_enabled` is true. A changed or new profile goes live with an image
  release.
- `restart-dev.sh` replaces the running daemon with the workspace copy until
  the container restarts.
- Never `pkill -f dispatchd.py`; the calling shell matches too.
  `restart-dev.sh` uses a pidfile.
- `claude-code/.dockerignore` denies everything by default. A new `COPY` in the
  Dockerfile needs its own `!` line.

## Implementation notes

- `child_env()` strips `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and related
  variables, or the child believes it continues the parent session.
- `extract_json()` tolerates fenced replies and several concatenated objects,
  and returns a list. A profile may supply a `merge` function.
- `exercise` asks for MET and duration, never calories; the caller computes
  energy.

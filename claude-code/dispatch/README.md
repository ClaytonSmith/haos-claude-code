# house-dispatch

Lets the rest of the house hand work to a real Claude Code session over HTTP.

    POST http://1dedd3a9-claude-code:8097/dispatch
    Authorization: Bearer <token from ~/.config/haos/dispatch.env>
    {"profile": "nutrition", "input": "chicken burrito bowl with guac"}

It runs here, in the `claude-code` add-on, because this is where the `claude`
binary and its OAuth credentials live. **No Anthropic API key is involved** — it
reuses the subscription credentials already in `$CLAUDE_CONFIG_DIR`.

## Callers send a profile name, never a prompt

This is the whole security model, and it is not negotiable.

The process runs `claude` **as root with the house's credentials**. An endpoint
accepting arbitrary prompts and tool lists would be remote code execution, on a
flat LAN with no internal segmentation. So profiles are defined server-side —
system prompt, model, tool allowlist and turn limit all fixed — and a caller can
only pick one by name and supply input. A caller cannot widen its own privileges.

It also binds **inside the container only**: `config.yaml` deliberately maps no
host port for 8097. Siblings reach it on the add-on network; the LAN cannot reach
it at all. If you ever add a `ports:` mapping for it, you have turned it into an
RCE surface — don't.

| Profile | Model | Tools | For |
|---|---|---|---|
| `nutrition` | Haiku 4.5 | none | meal description → itemised calories and macros |
| `exercise` | Haiku 4.5 | none | workout description → activities with Compendium MET values |
| `house-task` | session default | all | "something looks wrong, go and investigate" |

`house-task` is the one privileged profile: full house context, full tooling,
`bypassPermissions`, 30 turns. Slow and expensive by design. Never put it on a
hot path.

## What it consumes

**It does not cost money per call.** This box authenticates with a Claude
**subscription** — `~/.claude/.credentials.json` shows `subscriptionType: max`,
`rateLimitTier: default_claude_max_5x`, and there is no `ANTHROPIC_API_KEY`. The
`total_cost_usd` field in the `claude -p` envelope is what the same tokens *would
have* cost at API rates; nothing is billed. The add-on option
`anthropic_api_key` is the only thing that switches this box to API billing, and
it is unset. Our response field is named `api_equiv_usd` to stop anyone reading
it as a bill.

**The real budget is subscription quota**, and the thing to understand is that
house-dispatch draws from **the same pool as Clayton's own interactive
sessions**. A chatty automation does not produce an invoice; it eats headroom
from the person trying to work, and can push the account into a rate limit.

That makes the measured overhead matter as much as it would have if it were
money. Measured 2026-08-13 across several runs:

- Each `claude -p` is a **cold process**. ~11–18k tokens of tool schemas and
  system prompt are rebuilt every invocation, and `cache_read` is **always 0**.
- So ~**15–30 s** and ~18k tokens of quota to answer a 20-token question.
- Slimming it down made it **worse**. `--setting-sources ''` drops CLAUDE.md but
  also drops what little cache reuse existed; `--disallowed-tools` does not
  remove tool definitions from the prompt. Both were tried.

The overhead is structural, not a tuning problem. Design around it:

- **Callers should be async.** The `health` add-on stores the raw text and
  returns immediately, resolving afterwards — nothing waits on a dispatch.
- **Cache on the caller's side.** Repeat inputs should never reach here. This is
  quota preservation, not penny-pinching.
- **Rate limits are an expected failure mode**, not an exception. A caller must
  tolerate a dispatch failing and retry later; `health` leaves the entry
  `pending` and the raw text intact.
- Concurrency is capped at 2. This box has 4 cores and is also running the house.

If quota contention ever becomes the problem, putting a key in
`~/.config/haos/anthropic.env` and adding an API-backed path behind the same
profile interface would **decouple the house's automated calls from the human's
subscription** — that isolation is the argument for it, not price. The profile
boundary means no caller changes.

## Operating it

```bash
curl -s http://localhost:8097/health                  # profiles + free slots
tail -f /data/dispatch.log                            # it logs one line per call
python3 /opt/dispatch/dispatchd.py --rotate-token     # then update every caller
./restart-dev.sh                                      # iterate without a rebuild
```

Set `dispatch_enabled: false` in the add-on options to turn it off.

**Never `pkill -f dispatchd.py`.** The calling shell's own command line contains
that string, so pkill kills the shell you typed it in. `restart-dev.sh` uses a
pidfile for exactly this reason.

Rotating the token is a first-class operation because it reaches callers as an
add-on *option*, and Supervisor echoes the whole options object back in
validation errors — so it lands in logs and transcripts more easily than you
would like. After rotating, every caller must be updated by hand.

## Gotchas already paid for

**Strip the session environment.** `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and
friends mark the parent as an agent session in progress; inherited, the child
believes it is a continuation of its parent. `child_env()` removes them.

**Parse generously.** The prompts say "no markdown fence" and the model fences
the reply about half the time anyway. It also sometimes emits several
concatenated top-level objects instead of one containing a list — which is how
the first `exercise` prompt broke, because it asked for a single activity and
"ran 5 miles, then lifted" is obviously two. `extract_json()` returns a list, and
a profile may supply a `merge` function.

**Ask for the right thing.** `exercise` deliberately does *not* ask for calories.
It returns a MET value and duration; the caller computes energy. That is
reproducible, auditable, and self-corrects as body weight changes — where a
model-supplied calorie figure is unfalsifiable.

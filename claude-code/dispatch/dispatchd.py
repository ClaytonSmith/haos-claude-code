#!/usr/bin/env python3
"""house-dispatch — hand work to a real Claude Code session over HTTP.

Runs INSIDE the claude-code add-on, because that is where the `claude` binary and
its credentials live. Listens on the internal add-on network only (no `ports:`
mapping in config.yaml), so siblings reach it as
`http://1dedd3a9-claude-code:8097` and the LAN cannot reach it at all.

Callers pass a PROFILE NAME plus input, never a prompt and never a tool list.
That is the whole security model: this process runs `claude` as root with the
house's credentials, so an endpoint taking arbitrary prompts would be remote code
execution on a flat LAN. Profiles turn it into a fixed set of functions.

Stdlib only — no venv to keep alive across image rebuilds.
"""

import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("DISPATCH_PORT", "8097"))
CRED_FILE = os.path.expanduser("~/.config/haos/dispatch.env")

# `claude -p` is a cold process every time: it rebuilds ~11-18k tokens of tool
# schemas and system prompt on each run and never reads from cache (measured
# 2026-08-13 — cache_read was 0 across every invocation). So each call is slow
# and non-trivially priced, and running many at once buys nothing but memory
# pressure on a 4-core box that is also running the house.
MAX_CONCURRENT = 2
_slots = threading.Semaphore(MAX_CONCURRENT)

NUTRITION_PROMPT = """\
You are a nutrition estimator. Given a free-text meal description, break it into
individual food items, state the portion you assumed, and estimate each item.

Rules:
- Itemise. Never return only a total; a single-number guess cannot be audited or
  corrected, and per-item estimates are measurably more accurate.
- Assume typical real-world portions. Restaurant servings run larger than home
  ones; say so in `assumptions` when it matters.
- If the description names a chain restaurant dish, use that chain's actual menu
  nutrition where you know it.
- confidence: "high" for packaged/measured food, "medium" for ordinary described
  meals, "low" when the portion is genuinely unknowable.
- If the text does not describe food at all, do NOT ask for clarification and do
  NOT reply in prose. Return the same object with an empty `items`, all totals 0,
  confidence "low", and `assumptions` saying it did not look like food. Anything
  else is a parse failure that gets retried, which wastes far more than a wrong
  guess would.

Reply with ONLY a JSON object. No prose, no markdown fence:
{"items":[{"name":str,"portion":str,"kcal":int,"protein_g":int,"carb_g":int,"fat_g":int}],
 "kcal":int,"protein_g":int,"carb_g":int,"fat_g":int,
 "confidence":"high"|"medium"|"low","assumptions":str}
"""

EXERCISE_PROMPT = """\
You are an exercise classifier. Given a free-text description of a workout,
break it into activities and classify each.

Do NOT estimate calories. Return a MET value from the Compendium of Physical
Activities; the caller computes energy from MET, body weight and duration, which
is reproducible and self-corrects as weight changes.

- One entry per distinct activity. "Ran, then lifted" is two entries. A single
  activity is a list of one.
- duration_min: minutes of actual activity. If the text gives distance and pace
  but no time, derive it. If nothing implies a duration, use 0 and say so in
  `assumptions`.
- met: the Compendium value for the stated intensity, not the generic one.
  Running 6 mph is 9.8; running 8 mph is 11.8. Pick deliberately.
- For strength training, use 3.5 (light/moderate) to 6.0 (vigorous, short rest).
- If the text does not describe exercise at all, do NOT ask for clarification and
  do NOT reply in prose. Return an empty `activities` list, confidence "low", and
  `assumptions` saying it did not look like exercise. Anything else is a parse
  failure that gets retried, which wastes far more than a wrong guess would.

Reply with ONLY a JSON object — a single object, not a sequence of them. No
prose, no markdown fence:
{"activities":[{"activity":str,"met":float,"duration_min":int,
  "intensity":"light"|"moderate"|"vigorous","distance_mi":float|null}],
 "confidence":"high"|"medium"|"low","assumptions":str}
"""

def _merge_activities(objs):
    """Fold bare per-activity objects back into the documented shape.

    Seen in testing: "ran 5 miles, then lifted" came back as two top-level
    objects instead of one with a two-item `activities` list.
    """
    acts, notes = [], []
    for o in objs:
        acts.extend(o.get("activities") or [
            {k: o.get(k) for k in
             ("activity", "met", "duration_min", "intensity", "distance_mi")}
        ])
        if o.get("assumptions"):
            notes.append(o["assumptions"])
    ranked = ["high", "medium", "low"]
    worst = max((ranked.index(o.get("confidence", "low")) for o in objs), default=2)
    return {"activities": acts, "confidence": ranked[worst],
            "assumptions": " ".join(notes)}


# model/tools/turns are fixed per profile so a caller cannot widen them.
PROFILES = {
    "nutrition": {
        "system": NUTRITION_PROMPT,
        "model": "claude-haiku-4-5-20251001",
        "max_turns": 1,
        "tools": False,
        "json": True,
        "timeout": 120,
    },
    "exercise": {
        "system": EXERCISE_PROMPT,
        "model": "claude-haiku-4-5-20251001",
        "max_turns": 1,
        "tools": False,
        "json": True,
        "timeout": 120,
        "merge": _merge_activities,
    },
    # The one privileged profile: full house context and tooling, for "something
    # looks wrong, go and investigate". Slow and expensive by design; not for
    # anything on a hot path.
    "house-task": {
        "system": None,
        "model": None,
        "max_turns": 30,
        "tools": True,
        "json": False,
        "timeout": 900,
        "cwd": "/data/workspace/haos-claude-code",
    },
}


def load_token(rotate=False):
    """Read the shared secret, minting one on first run or when rotating.

    Rotating is a first-class operation because the token reaches callers as an
    add-on option, and Supervisor echoes the whole options object back in
    validation errors — so it lands in logs and transcripts more easily than you
    would like. Every caller must be updated after a rotation; `hactl` cannot do
    that for you.
    """
    os.makedirs(os.path.dirname(CRED_FILE), exist_ok=True)
    if os.path.exists(CRED_FILE) and not rotate:
        for line in open(CRED_FILE):
            if line.startswith("DISPATCH_TOKEN="):
                return line.split("=", 1)[1].strip()
    token = secrets.token_urlsafe(32)
    keep = []
    if os.path.exists(CRED_FILE):
        keep = [l for l in open(CRED_FILE) if not l.startswith("DISPATCH_TOKEN=")]
    with open(CRED_FILE, "w") as f:
        f.writelines(keep)
        f.write(f"DISPATCH_TOKEN={token}\n")
    os.chmod(CRED_FILE, 0o600)
    log(f"{'rotated' if rotate else 'minted'} the dispatch token in {CRED_FILE}")
    return token


TOKEN = None


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def child_env():
    """A clean environment for the child `claude`.

    The session variables below mark this process as an agent session already in
    progress. Inherited, they make the child believe it is a continuation of its
    own parent rather than a fresh run.
    """
    env = dict(os.environ)
    for var in (
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_SESSION_ACCESS_TOKEN",
        "CLAUDE_PID",
        "CLAUDE_CODE_WORKER_EPOCH",
    ):
        env.pop(var, None)
    return env


_FENCE = re.compile(r"```(?:json)?\s*(.*?)\s*```", re.S)


def extract_json(text):
    """Pull JSON objects out of a model reply, returning a list of them.

    Two things make this more than `json.loads`. The prompts say "no markdown
    fence" and the model fences it anyway about half the time. And it sometimes
    emits several concatenated objects rather than one object containing a list
    — which is why the caller gets a list and decides what that means. Retrying
    costs ~15s and ~$0.04, so parsing generously is worth the code.
    """
    if not text:
        return []
    m = _FENCE.search(text)
    if m:
        text = m.group(1)
    text = text.strip()
    start = text.find("{")
    if start < 0:
        return []
    decoder = json.JSONDecoder()
    out, idx = [], start
    while idx < len(text):
        try:
            obj, end = decoder.raw_decode(text, idx)
        except json.JSONDecodeError:
            break
        out.append(obj)
        idx = end
        while idx < len(text) and text[idx] in " \t\r\n,":
            idx += 1
    return out


def run_profile(name, user_input):
    """Run one dispatch. Returns a result dict; never raises."""
    prof = PROFILES[name]
    cmd = ["claude", "-p", user_input, "--output-format", "json",
           "--no-session-persistence", "--max-turns", str(prof["max_turns"])]
    if prof["model"]:
        cmd += ["--model", prof["model"]]
    if prof["system"]:
        cmd += ["--system-prompt", prof["system"],
                "--exclude-dynamic-system-prompt-sections",
                # Skip user/project CLAUDE.md: a nutrition estimate has no use
                # for the house brief, and loading it is pure token cost.
                "--setting-sources", "", "--strict-mcp-config"]
    if not prof["tools"]:
        cmd += ["--disallowed-tools", "Bash,Read,Write,Edit,Glob,Grep,WebSearch,"
                "WebFetch,Task,TodoWrite,NotebookEdit"]
    else:
        cmd += ["--permission-mode", "bypassPermissions"]

    started = time.time()
    with _slots:
        waited = time.time() - started
        if waited > 1:
            log(f"{name}: waited {waited:.0f}s for a slot")
        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True, env=child_env(),
                cwd=prof.get("cwd", "/tmp"), timeout=prof["timeout"],
                stdin=subprocess.DEVNULL,
            )
        except subprocess.TimeoutExpired:
            log(f"{name}: TIMEOUT after {prof['timeout']}s")
            return {"ok": False, "error": f"timeout after {prof['timeout']}s"}

    if proc.returncode != 0:
        log(f"{name}: exit {proc.returncode}: {proc.stderr[:300]}")
        return {"ok": False, "error": f"claude exited {proc.returncode}",
                "stderr": proc.stderr[-2000:]}

    try:
        envelope = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "error": "unparseable envelope",
                "stdout": proc.stdout[-2000:]}

    if envelope.get("is_error"):
        return {"ok": False, "error": envelope.get("result", "claude reported an error")}

    text = envelope.get("result", "")
    out = {
        "ok": True,
        "profile": name,
        # Which model actually answered, not which one we asked for — worth
        # recording alongside an estimate so a later re-run is comparable.
        "model": next(iter(envelope.get("modelUsage") or {}), None),
        # NOT money. This box authenticates with a Claude **subscription**
        # (subscriptionType: max), so nothing here is billed per token; the CLI
        # reports what the same tokens would have cost at API rates. Kept because
        # it is a good proxy for quota consumption — named so nobody reads it as
        # a bill. See README.md, "What it consumes".
        "api_equiv_usd": envelope.get("total_cost_usd"),
        "duration_ms": envelope.get("duration_ms"),
        "session_id": envelope.get("session_id"),
    }
    if prof["json"]:
        objs = extract_json(text)
        if not objs:
            log(f"{name}: reply was not JSON: {text[:200]}")
            return {"ok": False, "error": "model did not return JSON", "raw": text[:2000]}
        if len(objs) > 1:
            merge = prof.get("merge")
            if not merge:
                log(f"{name}: {len(objs)} objects returned, using the first")
                objs = objs[:1]
            else:
                log(f"{name}: merged {len(objs)} objects")
                objs = [merge(objs)]
        out["data"] = objs[0]
    else:
        out["text"] = text
    log(f"{name}: ok in {out['duration_ms']}ms, "
        f"~{out['api_equiv_usd'] or 0:.4f} api-equiv")
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "house-dispatch/1.0"

    def log_message(self, *a):
        pass  # we do our own, on one line

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        got = self.headers.get("Authorization", "")
        if got.startswith("Bearer ") and secrets.compare_digest(got[7:], TOKEN):
            return True
        self._send(401, {"ok": False, "error": "bad or missing bearer token"})
        return False

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True, "profiles": sorted(PROFILES),
                             "free_slots": _slots._value})
            return
        self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if self.path != "/dispatch":
            self._send(404, {"ok": False, "error": "not found"})
            return
        if not self._authed():
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n))
        except (ValueError, json.JSONDecodeError):
            self._send(400, {"ok": False, "error": "body must be JSON"})
            return

        profile = req.get("profile")
        user_input = (req.get("input") or "").strip()
        if profile not in PROFILES:
            self._send(400, {"ok": False,
                             "error": f"unknown profile; have {sorted(PROFILES)}"})
            return
        if not user_input:
            self._send(400, {"ok": False, "error": "input is required"})
            return
        if len(user_input) > 4000:
            self._send(400, {"ok": False, "error": "input too long (max 4000)"})
            return

        log(f"{profile}: {user_input[:80]!r}")
        self._send(200, run_profile(profile, user_input))


def main():
    global TOKEN
    if "--rotate-token" in sys.argv:
        load_token(rotate=True)
        print("Token rotated. Update every caller, then restart the dispatcher.")
        return 0
    TOKEN = load_token()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log(f"house-dispatch listening on :{PORT}, profiles={sorted(PROFILES)}")
    log(f"token in {CRED_FILE} (chmod 600)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")


if __name__ == "__main__":
    sys.exit(main())

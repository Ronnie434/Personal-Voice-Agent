#!/usr/bin/env python3
"""A stand-in for the `claude` CLI that speaks the same stream-json protocol.

What it does depends on the request text:
  "tool ..."   says a sentence, uses a tool, then answers
  "slow ..."   says a sentence, then waits to be interrupted
  "die ..."    exits without answering
  otherwise    answers "You said: <request>"
  "authdie ..." exits as a signed-out Claude does
Its arguments and environment variable names are written to FAKE_CLAUDE_LOG
(by the warm, stream-json process only, not by sign-in checks).

Sign-in: FAKE_CLAUDE_AUTH names a file holding "ok" (the default when it is
missing), "expired" (signed in, but every request fails the way an OAuth
session that can't be refreshed does) or "signed_out". `auth status`, one-off
`-p` requests and the warm process all follow it. `auth login` appends a line
to FAKE_CLAUDE_LOGINS, waits FAKE_CLAUDE_LOGIN_SECS (default 0.5; "never" to
wait for ever, as if the user never finishes) and then writes "ok".
"""
import json
import os
import select
import sys
import time

AUTH_FILE = os.environ.get("FAKE_CLAUDE_AUTH")
EXPIRED = "Failed to authenticate: OAuth session expired and could not be refreshed"


def auth_state():
    try:
        with open(AUTH_FILE) as f:
            return f.read().strip() or "ok"
    except (TypeError, OSError):
        return "ok"


if "--version" in sys.argv:
    print("9.9.9 (fake)")
    sys.exit(0)

if sys.argv[1:3] == ["auth", "status"]:
    print(json.dumps({"loggedIn": auth_state() != "signed_out", "authMethod": "claude.ai"}))
    sys.exit(0)

if sys.argv[1:3] == ["auth", "login"]:
    print("Opening browser to sign in…", flush=True)
    logins = os.environ.get("FAKE_CLAUDE_LOGINS")
    if logins:
        with open(logins, "a") as f:
            f.write(f"{time.time()}\n")
    wait = os.environ.get("FAKE_CLAUDE_LOGIN_SECS", "0.5")
    time.sleep(3600 if wait == "never" else float(wait))
    with open(AUTH_FILE, "w") as f:
        f.write("ok")
    print("Login successful.")
    sys.exit(0)

if "-p" in sys.argv and "--input-format" not in sys.argv:  # a one-off request
    if auth_state() != "ok":
        print(json.dumps({"type": "result", "is_error": True, "result": EXPIRED}))
        sys.exit(1)
    print(json.dumps({"type": "result", "is_error": False, "result": "OK"}))
    sys.exit(0)

log = os.environ.get("FAKE_CLAUDE_LOG")
if log:
    with open(log, "w") as f:
        json.dump({"argv": sys.argv[1:], "env": sorted(os.environ), "cwd": os.getcwd(),
                   "path": os.environ.get("PATH", "")}, f)


def send(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def text(words):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": words}]}}


def result(words, **extra):
    return {"type": "result", "result": words, "num_turns": 1, "is_error": False, **extra}


send({"type": "system", "subtype": "init"})
turns = 0
for line in sys.stdin:
    message = json.loads(line)
    if message.get("type") == "control_request":
        send(result("", interrupted=True))
        continue
    turns += 1
    said = message["message"]["content"].split("\n\n(Voice system note")[0]
    if auth_state() != "ok":
        send(result(EXPIRED, is_error=True))
        continue
    if said.startswith("authdie"):
        sys.stderr.write("Not logged in · Please run /login\n")
        sys.exit(1)
    if said.startswith("die"):
        sys.stderr.write("fatal: not signed in. api_key=sk-ant-secret123456789\n")
        sys.exit(3)
    if said.startswith("tool"):
        send(text("Let me check that."))
        send({"type": "assistant", "parent_tool_use_id": "sub1",
              "message": {"content": [{"type": "text", "text": "sub-agent chatter"},
                                      {"type": "tool_use", "name": "Bash", "input": {}}]}})
        send({"type": "assistant",
              "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {}}]}})
        send(text("**All good**, see [the page](https://example.com)."))
        send(result("**All good**, see [the page](https://example.com)."))
    elif said.startswith("slow"):
        send(text("Working on it."))
        send({"type": "assistant",
              "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {}}]}})
        # Wait for the interrupt (or stdin closing).
        select.select([sys.stdin], [], [], 30)
    else:
        send(text(f"You said: {said}"))
        send(result(f"You said: {said} (turn {turns})"))

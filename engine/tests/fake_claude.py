#!/usr/bin/env python3
"""A stand-in for the `claude` CLI that speaks the same stream-json protocol.

What it does depends on the request text:
  "tool ..."   says a sentence, uses a tool, then answers
  "slow ..."   says a sentence, then waits to be interrupted
  "die ..."    exits without answering
  otherwise    answers "You said: <request>"
Its arguments and environment variable names are written to FAKE_CLAUDE_LOG.
"""
import json
import os
import select
import sys

log = os.environ.get("FAKE_CLAUDE_LOG")
if log:
    with open(log, "w") as f:
        json.dump({"argv": sys.argv[1:], "env": sorted(os.environ), "cwd": os.getcwd(),
                   "path": os.environ.get("PATH", "")}, f)

if "--version" in sys.argv:
    print("9.9.9 (fake)")
    sys.exit(0)


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

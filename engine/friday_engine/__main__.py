"""Start the engine.

    uv run agent.py                    voice, from a checkout (reads .env)
    uv run agent.py --text "..."       ask the brain a typed question, print the reply
    uv run agent.py --devices          list microphones and speakers as JSON
    python -m friday_engine            the same, as started by the desktop app

The desktop app sets FRIDAY_SOCKET and FRIDAY_TOKEN; the engine then takes its
settings from the app and reports to it. FRIDAY_NO_AUDIO=1 runs the brain and
the app link with no microphone or speaker.
"""

import argparse
import asyncio
import json
import os
import sys


def main():
    parser = argparse.ArgumentParser(description="Friday's engine")
    parser.add_argument(
        "--text",
        action="append",
        help="send a typed request to the brain and print the reply (repeatable)",
    )
    parser.add_argument("--debug", action="store_true", help="log every transcript and frame")
    parser.add_argument("--devices", action="store_true", help="list audio devices and exit")
    args = parser.parse_args()

    from loguru import logger

    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if args.debug else "INFO")

    # Settings from the app have to be in place before config.py is imported.
    sock = None
    path, token = os.getenv("FRIDAY_SOCKET"), os.environ.pop("FRIDAY_TOKEN", "")
    if path:
        from . import ipc

        sock, settings = ipc.handshake(path, token)
        ipc.apply_settings(settings)

    if args.devices:
        from . import voice

        print(json.dumps(voice.list_devices(), indent=2))
        return

    from . import agent
    from .ipc import hub

    async def run():
        if sock is not None:
            await hub.attach(sock)
        hub.emit("state", state="starting", conversation=False)
        try:
            if args.text:
                await agent.run_text(args.text)
            elif os.getenv("FRIDAY_NO_AUDIO") == "1":
                await agent.run_headless()
            else:
                await agent.run_voice()
        finally:
            await hub.close()

    asyncio.run(run())


if __name__ == "__main__":
    main()

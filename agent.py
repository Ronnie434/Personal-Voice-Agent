"""Dev entry point: `uv run agent.py` runs the engine straight from this checkout."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "engine"))

from friday_engine.__main__ import main

if __name__ == "__main__":
    main()

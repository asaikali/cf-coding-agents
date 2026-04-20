"""Debug the SDK->CLI handshake with maximum verbosity + --bare flag."""
import asyncio
import os
from pathlib import Path

import claude_agent_sdk
from claude_agent_sdk import ClaudeAgentOptions, query

BUNDLED = str(Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude")


async def main() -> None:
    opts = ClaudeAgentOptions(
        allowed_tools=["Bash"],
        cli_path=BUNDLED,
        extra_args={"bare": None, "debug-to-stderr": None},
    )
    async for m in query(prompt="say hello in one short sentence", options=opts):
        print("MSG:", m, flush=True)


asyncio.run(main())

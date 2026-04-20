"""Minimal Cloud Foundry task entrypoint that runs a Claude Agent SDK query.

Invoked by the manifest's task process. Reads the prompt from argv[1], falling
back to a trivial hello prompt. Prints every message streamed back from the
agent to stdout so it shows up in `cf logs agent-py --recent`.

The SDK picks up ANTHROPIC_API_KEY from the environment. That env var is
populated by .profile.d/vcap.sh which parses it out of VCAP_SERVICES.
"""

import asyncio
import sys

from claude_agent_sdk import ClaudeAgentOptions, query


async def main() -> None:
    prompt = sys.argv[1] if len(sys.argv) > 1 else "Say hello in one short sentence."
    options = ClaudeAgentOptions(allowed_tools=["Read", "Glob", "Grep"])
    async for message in query(prompt=prompt, options=options):
        print(message, flush=True)


if __name__ == "__main__":
    asyncio.run(main())

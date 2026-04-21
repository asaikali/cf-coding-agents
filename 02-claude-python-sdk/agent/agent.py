"""Minimal Cloud Foundry task entrypoint that runs a Claude Agent SDK query.

Invoked by the manifest's task process. Reads the prompt from argv[1], falling
back to a trivial hello prompt. Prints every message streamed back from the
agent to stdout so it shows up in `cf logs agent-sdk --recent`.

The SDK picks up ANTHROPIC_API_KEY from the environment. That env var is
populated by .profile.d/vcap.sh which parses it out of VCAP_SERVICES.
"""

import asyncio
import logging
import sys

from claude_agent_sdk import ClaudeAgentOptions, query

# Surface every SDK-internal debug line on stderr so we can correlate the
# Python side with the CLI subprocess output. Especially useful during init
# debugging — message_parser.py logs "Skipping unknown message type" when
# the CLI writes something the SDK doesn't recognise. force=True overrides
# any existing handler config so this takes effect even after SDK imports.
logging.basicConfig(
    level=logging.DEBUG,
    format="[py] %(name)s %(levelname)s: %(message)s",
    stream=sys.stderr,
    force=True,
)
logging.getLogger("agent").info("python logging is live")

# The SDK's default CLI discovery looks at shutil.which("claude") and a set of
# common install paths (npm global, ~/.local/bin, etc.) — none of which exist
# in the CF droplet. We've also observed that the linux-x64 binary bundled in
# the claude_agent_sdk wheel hangs at initialize in the CF container. Use the
# standalone Claude Code binary we ship alongside the app instead; it's the
# same version but a different build pipeline (downloads.claude.ai release).
BUNDLED_CLI = "./bin/claude"


async def main() -> None:
    prompt = sys.argv[1] if len(sys.argv) > 1 else "Say hello in one short sentence."
    options = ClaudeAgentOptions(
        allowed_tools=["Read", "Glob", "Grep"],
        cli_path=BUNDLED_CLI,
        # setting_sources=[] skips ~/.claude/* discovery (MCP registry, skills,
        # managed settings, plugin sync). permission_mode bypasses the
        # interactive permission prompts that have no UI in a CF task. Both
        # are the SDK doc's CI/headless recipe; without them the CLI's
        # initialize control request never completes and query() times out.
        setting_sources=[],
        permission_mode="bypassPermissions",
        # debug-to-stderr + the stderr callback stream the CLI's debug lines
        # inline with the Python output so we can see what the binary is
        # doing while the SDK waits for its initialize response.
        extra_args={"debug-to-stderr": None},
        stderr=lambda line: print(f"[cli] {line}", file=sys.stderr, flush=True),
    )
    async for message in query(prompt=prompt, options=options):
        print(message, flush=True)


if __name__ == "__main__":
    asyncio.run(main())

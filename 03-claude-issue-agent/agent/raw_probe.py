"""Spawn the bundled claude directly (bypassing the SDK) and see if we can
read/write on its stdio in streaming mode."""
import asyncio
import json
from pathlib import Path

import claude_agent_sdk

BUNDLED = str(Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude")


async def main() -> None:
    proc = await asyncio.create_subprocess_exec(
        BUNDLED,
        "--output-format", "stream-json",
        "--verbose",
        "--system-prompt", "",
        "--allowedTools", "Bash",
        "--input-format", "stream-json",
        "--bare",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    print("PID:", proc.pid, flush=True)

    # Send a minimal user message on stdin, then close stdin.
    msg = {"type": "user", "message": {"role": "user", "content": "say hi"}}
    proc.stdin.write((json.dumps(msg) + "\n").encode())
    await proc.stdin.drain()

    # Read up to 60 seconds of stdout.
    try:
        line_count = 0
        while True:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=60)
            if not line:
                print("STDOUT EOF", flush=True)
                break
            line_count += 1
            print("STDOUT:", line.decode(errors="replace").rstrip(), flush=True)
            if line_count >= 10:
                print("STOPPING after 10 lines", flush=True)
                break
    except asyncio.TimeoutError:
        print("STDOUT READ TIMEOUT after 60s", flush=True)

    proc.stdin.close()
    try:
        await asyncio.wait_for(proc.wait(), timeout=10)
    except asyncio.TimeoutError:
        proc.terminate()
    print("EXIT:", proc.returncode, flush=True)


asyncio.run(main())

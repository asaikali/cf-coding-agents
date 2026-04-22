/**
 * End-to-end smoke test for the droplet — TypeScript twin of
 * 03-claude-issue-agent/agent/smoke_test.py.
 *
 * Drives the SDK through a strict verification sequence: clone the target
 * repo, compile it, boot the app, curl it, shut it down. Proves every link
 * in the chain — git HTTPS auth, JDK, Maven wrapper, Spring Boot startup,
 * local HTTP — plus the TS SDK wiring itself. Pure verification; no file
 * edits, no fixes.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    process.stderr.write(`error: ${name} must be set in the environment\n`);
    process.exit(2);
  }
  return value;
}

function buildPrompt(repo: string): string {
  return `
You are verifying that a Cloud Foundry task container can clone, compile,
and run a Spring Boot application. Execute the following steps exactly.
Do not edit any files. Do not attempt to fix errors — if a step fails,
print a clear failure message and stop.

1. Clone the target repo into ./work (PWD-relative; avoids /tmp quota):
     gh repo clone ${repo} ./work
2. cd ./work
3. Compile the project. This proves JDK + Maven wrapper are working:
     ./mvnw compile -q
4. Launch the app in the background, redirecting output to a log file:
     nohup ./mvnw spring-boot:run > boot.log 2>&1 &
     echo $! > app.pid
5. Wait for startup by polling boot.log for the line
   "Started PetClinicApplication". Poll every 3 seconds for up to
   120 seconds. If it does not appear within 120 seconds, print the
   last 30 lines of boot.log and stop with a clear failure message.
6. Once the banner is present, curl the app once and print the first
   ~10 lines of the response:
     curl -si http://localhost:8080/ | head -n 10
   A 200 response proves the app is live.
7. Stop the app cleanly:
     kill $(cat app.pid) || true
8. Print the literal line on its own:
     VERIFIED: clone + compile + run + curl all passed

Success criterion: step 8 prints. Anything else is failure.
`;
}

async function main(): Promise<void> {
  const repo = requireEnv("TARGET_REPO");

  for await (const message of query({
    prompt: buildPrompt(repo),
    options: {
      allowedTools: ["Bash", "Read", "Glob", "Grep"],
      settingSources: [],
      permissionMode: "bypassPermissions",
      extraArgs: { "debug-to-stderr": null },
      stderr: (line: string) =>
        process.stderr.write(`[cli] ${line}\n`),
    },
  })) {
    console.log(JSON.stringify(message));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

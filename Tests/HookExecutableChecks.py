"""Exercise the shipped helper, including real pipe EOF, in an isolated macOS home."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

helper = Path(os.environ["HOOK_HELPER_PATH"]) if "HOOK_HELPER_PATH" in os.environ else (Path(__file__).resolve().parents[1] /
          "dist/While AI Works.app/Contents/Resources/while-ai-works-hook")
with tempfile.TemporaryDirectory(prefix="while-hook-check-") as directory:
    environment = dict(os.environ, CFFIXED_USER_HOME=directory)
    root = Path(directory) / "Library/Application Support/While AI Works/Hooks"
    session = "isolated-test-session"
    filename = hashlib.sha256(session.encode()).hexdigest() + ".json"
    for provider in ["qoder", "workbuddy"]:
        for event, working in [("UserPromptSubmit", True), ("PreToolUse", True), ("PostToolUse", True), ("Stop", False)]:
            payload = json.dumps({"session_id": session, "hook_event_name": event,
                                  "generation_id": event if provider == "workbuddy" else "stable-turn",
                                  "prompt": "PRIVATE_PROMPT", "tool_input": "PRIVATE_TOOL"}).encode()
            process = subprocess.Popen([str(helper), provider], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
            process.stdin.write(payload[:20])
            process.stdin.flush()
            time.sleep(0.02)
            output, error = process.communicate(payload[20:], timeout=4)
            assert process.returncode == 0 and not output and not error
            text = (root / provider / filename).read_text()
            assert json.loads(text)["working"] == working and "PRIVATE_" not in text
        for payload in [b"not json", b"", b"x" * 1_048_577]:
            result = subprocess.run([str(helper), provider], input=payload, capture_output=True,
                                    timeout=4, env=environment)
            assert result.returncode == 0 and not result.stdout and not result.stderr
    print("HookExecutableChecks: both shipped providers, split pipes/EOF, privacy, malformed/empty/oversized inputs passed")

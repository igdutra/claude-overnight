#!/usr/bin/env python3
"""Pull the final assistant text out of a stream-json transcript.

The rendered feed is for watching; this is for parsing. Verdict lines
(TESTS:, QA-VERDICT:, REVIEW-BUG:, SPEC-PR:) live in the assistant's final
message, which stream-json splits across events.

Usage: extract-result.py <stream.jsonl>
"""

import json
import sys

streamPath = sys.argv[1]
resultText = ""
assistantText = []

try:
    handle = open(streamPath, errors="replace")
except OSError:
    sys.exit(0)

with handle:
    for line in handle:
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue

        if event.get("type") == "result":
            resultText = event.get("result") or ""
        elif event.get("type") == "assistant":
            for block in event.get("message", {}).get("content", []):
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text", "").strip()
                    if text:
                        assistantText.append(text)

# The result event carries the final message; the accumulated assistant text is
# the fallback for a run that ended without one (killed, crashed, out of turns).
print(resultText if resultText.strip() else "\n".join(assistantText))

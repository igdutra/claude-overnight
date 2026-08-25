#!/usr/bin/env python3
"""Turn claude's stream-json into a readable live feed.

`claude -p --output-format stream-json --verbose` emits newline-delimited JSON:
one event per tool call, per assistant message, per result. Raw, it is
unreadable. This renders it as running commentary you can actually watch.

The point is knowing what is happening while it happens. A log you read
afterwards tells you what went wrong; a live feed tells you whether to
intervene now.

Usage:
    claude -p ... --output-format stream-json --verbose | render-stream.py [label]

Reads stdin and writes the rendering to stdout. It does not pass the raw stream
through — tee it to a file separately if you want one.
"""

import json
import sys
import time

label = sys.argv[1] if len(sys.argv) > 1 else ""
prefix = "[%s] " % label if label else ""

DIM, BOLD, RESET = "\033[2m", "\033[1m", "\033[0m"
BLUE, GREEN, RED, YELLOW = "\033[34m", "\033[32m", "\033[31m", "\033[33m"

startedAt = time.time()


def elapsed():
    seconds = int(time.time() - startedAt)
    return "%dm%02ds" % (seconds // 60, seconds % 60)


def emit(marker, color, text):
    print("%s%s%7s%s %s%s%s %s" % (DIM, prefix, elapsed(), RESET, color, marker, RESET, text),
          flush=True)


def condense(value, limit=100):
    """One line, bounded width — tool inputs are often whole file bodies."""
    text = " ".join(str(value).split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def describeTool(name, toolInput):
    """Say what the tool is actually doing, not just that a tool ran."""
    if not isinstance(toolInput, dict):
        return name
    if name == "Bash":
        return condense(toolInput.get("command", ""))
    if name in ("Read", "Edit", "Write", "NotebookEdit"):
        return "%s %s" % (name, condense(toolInput.get("file_path", ""), 80))
    if name in ("Grep", "Glob"):
        return "%s %s" % (name, condense(toolInput.get("pattern", ""), 60))
    if name == "Skill":
        return "/%s %s" % (toolInput.get("skill", "?"), condense(toolInput.get("args", ""), 40))
    if name == "Task":
        return "subagent: %s" % condense(toolInput.get("description", ""), 60)
    if name == "TodoWrite":
        todos = toolInput.get("todos", [])
        active = next((item.get("content") for item in todos
                       if isinstance(item, dict) and item.get("status") == "in_progress"), None)
        return "plan: %s" % condense(active, 70) if active else "plan (%d items)" % len(todos)
    return "%s %s" % (name, condense(toolInput, 70))


toolCount = 0
pendingTools = {}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue

    eventType = event.get("type")
    subtype = event.get("subtype")

    if eventType == "system" and subtype == "init":
        emit("▸", BOLD, "session started  %s%s%s" % (DIM, str(event.get("session_id", ""))[:8], RESET))

    elif eventType == "system" and subtype == "api_retry":
        emit("⏳", YELLOW, "retry %s/%s — %s" % (
            event.get("attempt", "?"), event.get("max_retries", "?"), event.get("error", "")))

    elif eventType == "assistant":
        for block in event.get("message", {}).get("content", []):
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                toolCount += 1
                name = block.get("name", "?")
                pendingTools[block.get("id")] = name
                emit("→", BLUE, describeTool(name, block.get("input")))
            elif block.get("type") == "text":
                text = block.get("text", "").strip()
                if text:
                    # The model's own narration is the most informative thing in
                    # the stream, so it gets more room than tool noise.
                    emit("•", "", condense(text, 240))

    elif eventType == "user":
        for block in event.get("message", {}).get("content", []):
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            name = pendingTools.pop(block.get("tool_use_id"), "tool")
            if block.get("is_error"):
                emit("✗", RED, "%s failed: %s" % (name, condense(block.get("content"), 160)))

    elif eventType == "rate_limit_event":
        status = (event.get("rate_limit") or {}).get("status")
        if status and status != "allowed":
            emit("⏳", YELLOW, "rate limit: %s" % status)

    elif eventType == "result":
        failed = event.get("is_error") or subtype != "success"
        marker, color = ("✗", RED) if failed else ("✓", GREEN)
        parts = ["%s turns" % event.get("num_turns", "?"),
                 "%d tool calls" % toolCount,
                 "%.0fs" % (event.get("duration_ms", 0) / 1000.0)]
        cost = event.get("total_cost_usd")
        if cost:
            parts.append("$%.2f" % cost)
        emit(marker, color, "%s%s%s — %s" % (BOLD, subtype or "done", RESET, ", ".join(parts)))

#!/usr/bin/env python3
"""Pull the final assistant text — and the run's health — out of a transcript.

The rendered feed is for watching; this is for parsing. Verdict lines
(TESTS:, QA-VERDICT:, REVIEW-BUG:, SPEC-PR:) live in the assistant's final
message, which stream-json splits across events.

Two modes:

    extract-result.py <stream.jsonl>            the final text, for verdicts
    extract-result.py --health <stream.jsonl>   JSON: did the phase actually run

The health mode exists because a phase can return successfully-shaped output
having done nothing at all. A session limit ends the turn with the banner as
the assistant's only text, and the run of 2026-08-25 drove twelve such phases
in a row and reported every one green. Distinguishing "said nothing because
there was nothing to say" from "said nothing because it never ran" is not
possible from the text alone, so it is read from the stream's structure:
whether the result carried is_error, whether any tool was called, and whether
the text matches a known exhaustion banner.

No single one of those is sufficient. In that night's streams, six phases hit
the limit and only four carried is_error — qa-2 and review-2 came back with
the same banner and is_error false. The flag and the banner are both checked
because either alone misses cases the other catches.
"""

import json
import re
import sys

# The banners a session-limit or usage-exhaustion turn comes back with. Matched
# case-insensitively against the phase's whole text, which for a limited turn is
# the banner and nothing else.
EXHAUSTION_PATTERNS = [
    r"you've hit your (session|usage) limit",
    r"you have hit your (session|usage) limit",
    r"claude usage limit reached",
    r"resets? \d{1,2}(:\d{2})?\s*(am|pm)",
    r"rate.?limit(ed|ing)? ",
    r"upgrade to (increase|raise) your usage limit",
]

# When the banner names a reset time, carry it into the report — the operator's
# first question in the morning is when they can start again.
RESET_PATTERN = re.compile(
    r"resets?\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm)?(?:\s*\([^)]+\))?)", re.IGNORECASE
)


def readStream(streamPath):
    """Yield each parsed event; unparseable lines are skipped, not fatal."""
    try:
        handle = open(streamPath, errors="replace")
    except OSError:
        return

    with handle:
        for line in handle:
            try:
                yield json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue


def analyse(streamPath):
    resultText = ""
    assistantText = []
    isError = False
    subtype = ""
    toolCallCount = 0
    sawResultEvent = False

    for event in readStream(streamPath):
        eventType = event.get("type")

        if eventType == "result":
            sawResultEvent = True
            resultText = event.get("result") or ""
            isError = bool(event.get("is_error"))
            subtype = event.get("subtype") or ""

        elif eventType == "assistant":
            for block in event.get("message", {}).get("content", []):
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    text = block.get("text", "").strip()
                    if text:
                        assistantText.append(text)
                elif block.get("type") == "tool_use":
                    toolCallCount += 1

    # The result event carries the final message; accumulated assistant text is
    # the fallback for a run that ended without one (killed, crashed, out of
    # turns).
    finalText = resultText if resultText.strip() else "\n".join(assistantText)

    exhausted = any(
        re.search(pattern, finalText, re.IGNORECASE) for pattern in EXHAUSTION_PATTERNS
    )

    resetsAt = ""
    if exhausted:
        match = RESET_PATTERN.search(finalText)
        if match:
            resetsAt = match.group(1).strip()

    return {
        "text": finalText,
        "is_error": isError,
        "subtype": subtype,
        "tool_calls": toolCallCount,
        "saw_result": sawResultEvent,
        "exhausted": exhausted,
        "resets_at": resetsAt,
        # Empty output is not proof of failure on its own, but combined with no
        # tool calls it means the phase produced nothing and touched nothing.
        "silent": not finalText.strip() and toolCallCount == 0,
    }


def main():
    arguments = sys.argv[1:]
    healthMode = False

    if arguments and arguments[0] == "--health":
        healthMode = True
        arguments = arguments[1:]

    if not arguments:
        sys.exit(0)

    health = analyse(arguments[0])

    if healthMode:
        print(json.dumps({key: value for key, value in health.items() if key != "text"}))
    else:
        print(health["text"])


if __name__ == "__main__":
    main()

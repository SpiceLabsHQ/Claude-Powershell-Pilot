#!/usr/bin/env python3
"""
Parse a Claude Code JSONL chat history file into a clean, LLM-readable transcript.

Usage:
  python parse.py <file.jsonl> [options]

Options:
  --head N          Show first N conversation turns
  --tail N          Show last N conversation turns
  --no-thinking     Omit <thinking> blocks
  --no-tools        Omit tool calls and results entirely
  --compact-tools   Show tool calls/results as one-line summaries (default)
  --full-tools      Show full tool call inputs and results
  --stats           Print statistics only (turn counts, tool usage)
  --search PATTERN  Show only turns containing PATTERN (case-insensitive)
"""

import json
import sys
import argparse
import re
from typing import Iterator


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("file", help="Path to .jsonl chat history file")
    p.add_argument("--head", type=int, metavar="N", help="Show first N turns")
    p.add_argument("--tail", type=int, metavar="N", help="Show last N turns")
    p.add_argument("--no-thinking", action="store_true", help="Omit thinking blocks")
    p.add_argument("--no-tools", action="store_true", help="Omit tool calls and results")
    p.add_argument("--compact-tools", action="store_true", default=True, help="One-line tool summaries (default)")
    p.add_argument("--full-tools", action="store_true", help="Show full tool inputs and results")
    p.add_argument("--stats", action="store_true", help="Print statistics only")
    p.add_argument("--search", metavar="PATTERN", help="Show only turns containing pattern")
    return p.parse_args()


def stream_records(path: str) -> Iterator[dict]:
    """Stream JSONL records line by line — handles files of any size."""
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError as e:
                print(f"  [WARN] Line {lineno}: invalid JSON — {e}", file=sys.stderr)


def truncate(text: str, max_chars: int = 300) -> str:
    text = str(text).strip()
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + f"… [{len(text) - max_chars} more chars]"


def format_tool_use(item: dict, full: bool) -> str:
    name = item.get("name", "?")
    inp = item.get("input", {})
    tool_id = item.get("id", "")[:8]

    if full:
        inp_str = json.dumps(inp, indent=2) if isinstance(inp, dict) else str(inp)
        return f"  [tool_use:{tool_id}] {name}\n    input: {inp_str}"

    # Compact: show the most useful identifying info per tool type
    if name in ("Read", "Write", "Edit"):
        path = inp.get("file_path", inp.get("path", ""))
        extra = ""
        if name == "Edit":
            extra = f" (replace {'all' if inp.get('replace_all') else 'once'})"
        elif name == "Read":
            offset = inp.get("offset")
            limit = inp.get("limit")
            if offset or limit:
                extra = f" [lines {offset or 0}–{(offset or 0)+(limit or '?')}]"
        return f"  → {name}({path}){extra}"
    elif name == "Bash":
        cmd = inp.get("command", "")
        desc = inp.get("description", "")
        label = desc if desc else truncate(cmd, 80)
        bg = " [background]" if inp.get("run_in_background") else ""
        return f"  → Bash: {label}{bg}"
    elif name == "Grep":
        pattern = inp.get("pattern", "")
        path = inp.get("path", "")
        return f"  → Grep({truncate(pattern, 50)}) in {path or '.'}"
    elif name == "Glob":
        return f"  → Glob({inp.get('pattern', '')})"
    elif name == "Agent":
        return f"  → Agent({inp.get('subagent_type', '?')}): {truncate(inp.get('prompt', ''), 80)}"
    elif name in ("TaskCreate", "TaskUpdate", "TaskGet", "TaskList"):
        subject = inp.get("subject", inp.get("taskId", ""))
        status = inp.get("status", "")
        return f"  → {name}({subject}{': '+status if status else ''})"
    else:
        inp_preview = truncate(json.dumps(inp), 100) if inp else ""
        return f"  → {name}({inp_preview})"


def format_tool_result(item: dict, tool_map: dict, full: bool) -> str:
    tool_id = item.get("tool_use_id", "")[:8]
    tool_name = tool_map.get(item.get("tool_use_id", ""), "?")
    content = item.get("content", "")

    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict):
                t = c.get("type", "")
                if t == "text":
                    parts.append(c.get("text", ""))
                elif t == "tool_reference":
                    parts.append(f"[tool_reference: {c.get('tool_use_id','')[:8]}]")
                else:
                    parts.append(f"[{t}]")
            else:
                parts.append(str(c))
        content = "\n".join(parts)
    elif isinstance(content, dict):
        content = json.dumps(content)

    content = str(content).strip()

    if full:
        return f"  [tool_result:{tool_id}] ← {tool_name}\n    {content}"

    return f"  ← {tool_name}: {truncate(content, 200)}"


def format_user_turn(record: dict, tool_map: dict, args) -> str:
    msg = record.get("message", {})
    content = msg.get("content", "")
    ts = record.get("timestamp", "")[:19].replace("T", " ")

    lines = [f"\n{'='*60}", f"USER  [{ts}]"]

    if isinstance(content, str):
        lines.append(content.strip())
    elif isinstance(content, list):
        text_parts = []
        tool_results = []
        for item in content:
            if not isinstance(item, dict):
                text_parts.append(str(item))
                continue
            t = item.get("type", "")
            if t == "tool_result":
                if not args.no_tools:
                    tool_results.append(format_tool_result(item, tool_map, args.full_tools))
            elif t == "text":
                text_parts.append(item.get("text", "").strip())
            else:
                text_parts.append(f"[{t}]")
        if text_parts:
            lines.append("\n".join(text_parts))
        if tool_results:
            lines.append("\nTool results:")
            lines.extend(tool_results)

    return "\n".join(lines)


def format_assistant_turn(record: dict, args) -> tuple[str, dict]:
    """Returns (formatted_text, tool_id_to_name_map)."""
    msg = record.get("message", {})
    content = msg.get("content", [])
    model = msg.get("model", "")
    ts = record.get("timestamp", "")[:19].replace("T", " ")
    usage = msg.get("usage", {})

    tool_map = {}
    lines = [f"\n{'='*60}", f"ASSISTANT  [{ts}]  model={model}"]

    if usage:
        in_tok = usage.get("input_tokens", 0)
        out_tok = usage.get("output_tokens", 0)
        cache_read = usage.get("cache_read_input_tokens", 0)
        lines.append(f"tokens: {in_tok} in / {out_tok} out" + (f" / {cache_read} cache_read" if cache_read else ""))

    if isinstance(content, list):
        for item in content:
            if not isinstance(item, dict):
                lines.append(str(item))
                continue
            t = item.get("type", "")
            if t == "thinking":
                if not args.no_thinking:
                    thinking = item.get("thinking", "").strip()
                    lines.append(f"\n<thinking>\n{truncate(thinking, 500)}\n</thinking>")
            elif t == "text":
                text = item.get("text", "").strip()
                if text:
                    lines.append(f"\n{text}")
            elif t == "tool_use":
                if not args.no_tools:
                    lines.append(format_tool_use(item, args.full_tools))
                # Always track tool names for matching results
                tool_map[item.get("id", "")] = item.get("name", "?")
    elif isinstance(content, str):
        lines.append(content)

    return "\n".join(lines), tool_map


def collect_turns(path: str, args) -> list[dict]:
    """Collect all user/assistant turns, resolving tool IDs."""
    turns = []  # list of (record, kind) where kind is 'user' | 'assistant'
    pending_tool_map = {}  # carry tool_id->name from assistant to next user

    for record in stream_records(path):
        rtype = record.get("type")
        if rtype == "assistant":
            turns.append(("assistant", record, {}))
        elif rtype == "user":
            msg = record.get("message", {})
            content = msg.get("content", "")
            # Skip pure-system tool result messages with no text (intermediate plumbing)
            has_text = False
            if isinstance(content, str):
                has_text = bool(content.strip())
            elif isinstance(content, list):
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "text":
                        has_text = True
                    elif isinstance(content, list) and not isinstance(item, dict):
                        has_text = True
                # Tool results also count as content worth showing
                has_tool_result = any(
                    isinstance(i, dict) and i.get("type") == "tool_result"
                    for i in content
                )
                has_text = has_text or has_tool_result
            if has_text:
                turns.append(("user", record, {}))

    return turns


def compute_stats(path: str) -> dict:
    stats = {
        "total_lines": 0,
        "user_turns": 0,
        "assistant_turns": 0,
        "tool_calls": {},
        "total_input_tokens": 0,
        "total_output_tokens": 0,
        "thinking_blocks": 0,
        "text_blocks": 0,
    }
    for record in stream_records(path):
        stats["total_lines"] += 1
        rtype = record.get("type")
        if rtype == "user":
            stats["user_turns"] += 1
        elif rtype == "assistant":
            stats["assistant_turns"] += 1
            msg = record.get("message", {})
            usage = msg.get("usage", {})
            stats["total_input_tokens"] += usage.get("input_tokens", 0)
            stats["total_output_tokens"] += usage.get("output_tokens", 0)
            for item in msg.get("content", []):
                if isinstance(item, dict):
                    t = item.get("type", "")
                    if t == "tool_use":
                        name = item.get("name", "?")
                        stats["tool_calls"][name] = stats["tool_calls"].get(name, 0) + 1
                    elif t == "thinking":
                        stats["thinking_blocks"] += 1
                    elif t == "text":
                        stats["text_blocks"] += 1
    return stats


def main():
    args = parse_args()
    if args.full_tools:
        args.compact_tools = False

    path = args.file

    if args.stats:
        s = compute_stats(path)
        print(f"File: {path}")
        print(f"Total records: {s['total_lines']}")
        print(f"User turns: {s['user_turns']}")
        print(f"Assistant turns: {s['assistant_turns']}")
        print(f"Thinking blocks: {s['thinking_blocks']}")
        print(f"Text blocks: {s['text_blocks']}")
        print(f"Total input tokens: {s['total_input_tokens']:,}")
        print(f"Total output tokens: {s['total_output_tokens']:,}")
        if s["tool_calls"]:
            print("\nTool call counts:")
            for name, count in sorted(s["tool_calls"].items(), key=lambda x: -x[1]):
                print(f"  {name}: {count}")
        return

    # Build turns
    turns = collect_turns(path, args)

    # Apply head/tail slicing
    if args.head and args.tail:
        print("[WARN] --head and --tail both set; --tail takes precedence", file=sys.stderr)
    if args.tail:
        turns = turns[-args.tail:]
    elif args.head:
        turns = turns[:args.head]

    # Resolve tool maps: pass tool_map from each assistant turn to the next user turn
    # We need to do a two-pass to link tool_use IDs → names for tool_result display
    all_tool_map = {}  # global tool_id → name map built from assistant messages

    # First pass: collect all tool IDs
    for kind, record, _ in turns:
        if kind == "assistant":
            msg = record.get("message", {})
            for item in msg.get("content", []):
                if isinstance(item, dict) and item.get("type") == "tool_use":
                    all_tool_map[item.get("id", "")] = item.get("name", "?")

    # Render turns
    output_parts = []
    search_pat = re.compile(args.search, re.IGNORECASE) if args.search else None

    for kind, record, _ in turns:
        if kind == "assistant":
            text, _ = format_assistant_turn(record, args)
        else:
            text = format_user_turn(record, all_tool_map, args)

        if search_pat and not search_pat.search(text):
            continue
        output_parts.append(text)

    if not output_parts:
        print("(no turns matched)")
        return

    # Print header
    print(f"# Chat transcript: {path}")
    print(f"# Turns shown: {len(output_parts)} of {len(turns)} total")
    if args.no_thinking:
        print("# (thinking blocks hidden)")
    if args.no_tools:
        print("# (tool calls/results hidden)")
    print()
    print("\n".join(output_parts))
    print(f"\n{'='*60}")
    print(f"# End of transcript")


if __name__ == "__main__":
    main()

---
name: parse-chat
description: >
  Use when the user wants to read, review, inspect, search, or understand a Claude Code
  JSONL chat history file. Handles files of any size via streaming. Renders a clean
  turn-by-turn transcript with tool calls, results, token usage, and metadata.
disable-model-invocation: false
allowed-tools:
  - Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/parse.py *)
---

# parse-chat

You are an expert at reading Claude Code `.jsonl` chat history files. These files live at:

```text
~/.claude/projects/<project-path>/<chat-uuid>.jsonl
```

Each line is one JSON record. Record types:

| type                   | meaning                                           |
| :--------------------- | :------------------------------------------------ |
| `user`                 | A human turn (text, tool results, or both)        |
| `assistant`            | A Claude turn (text, thinking, tool calls)        |
| `system`               | Hook / system event metadata                      |
| `last-prompt`          | Final rendered prompt sent to the model           |
| `file-history-snapshot`| Snapshot of tracked file state (not conversation) |

## How to parse any chat file

Use the bundled parser. It streams line-by-line so it handles files of any size:

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/parse.py <path-to.jsonl> [options]
```

**Options:**

| flag               | effect                                             |
| :----------------- | :------------------------------------------------- |
| `--stats`          | Turn counts, tool usage, token totals (no output)  |
| `--tail N`         | Show the last N turns (default: all)               |
| `--head N`         | Show the first N turns                             |
| `--no-thinking`    | Omit `<thinking>` blocks                           |
| `--no-tools`       | Omit all tool calls and results                    |
| `--full-tools`     | Show complete tool inputs and result payloads      |
| `--search PATTERN` | Show only turns matching a regex (case-insensitive)|

## Strategy for large files

1. **Always run `--stats` first.** It scans the full file in one pass and gives you turn counts, token totals, and which tools were used — without loading everything into context.
2. **Use `--tail N` to read recent context.** Most debugging questions are about the end of the conversation. Start with `--tail 10 --no-thinking`.
3. **Use `--search` to find relevant turns.** If you're looking for a specific error message, file path, or decision, search for it rather than reading the whole file.
4. **Use `--head N` for the opening context.** The first 2–4 turns usually establish what the user was trying to accomplish.
5. **Expand only when needed.** Use `--full-tools` only if you need to inspect exact tool inputs/outputs for debugging.

## JSONL record structure (reference)

```text
user record:
  uuid, parentUuid, timestamp, sessionId, gitBranch
  message.role = "user"
  message.content = string  |  [{type:"tool_result", tool_use_id, content}, ...]

assistant record:
  uuid, parentUuid, timestamp, sessionId
  message.model, message.usage (input_tokens, output_tokens, cache_read_input_tokens)
  message.content = [
    {type:"thinking", thinking: "..."},
    {type:"text", text: "..."},
    {type:"tool_use", id, name, input: {...}},
    ...
  ]
```

Tool calls (`tool_use`) are in **assistant** turns.
Tool results (`tool_result`) are in the following **user** turn, matched by `tool_use_id`.

## Locating chat files

Chat files are stored by project path. The project path is the working directory with `/` replaced by `-`:

```text
~/.claude/projects/-Users-ryan-Developer-MyProject/<uuid>.jsonl
```

To list all chats for the current project:

```bash
ls -lt ~/.claude/projects/$(pwd | sed 's|/|-|g' | sed 's|^-||')/*.jsonl
```

To find a chat by UUID when you know part of it:

```bash
ls ~/.claude/projects/**/<partial-uuid>*.jsonl
```

# Claude Powershell Pilot

[![CI](https://github.com/SpiceLabsHQ/Claude-Powershell-Pilot/actions/workflows/ci.yml/badge.svg)](https://github.com/SpiceLabsHQ/Claude-Powershell-Pilot/actions/workflows/ci.yml)
[![Version](https://img.shields.io/github/v/release/SpiceLabsHQ/Claude-Powershell-Pilot?label=version)](https://github.com/SpiceLabsHQ/Claude-Powershell-Pilot/releases/latest)
[![License](https://img.shields.io/github/license/SpiceLabsHQ/Claude-Powershell-Pilot)](LICENSE)

A Claude Code plugin and Claude Desktop skill package for PowerShell automation.

## Structure

```text
.
├── .claude-plugin/
│   └── plugin.json       # Claude Code plugin manifest
├── skills/
│   └── <skill-name>/
│       └── SKILL.md      # Skill prompt (identical format on both platforms)
├── .releaserc.json       # semantic-release config
└── .github/workflows/
    └── ci.yml            # Validate → release pipeline
```

## Installation

### Claude Code

```bash
claude plugin install github:SpiceLabsHQ/Claude-Powershell-Pilot
```

### Claude Desktop

Download the `.zip` for your skill from the [latest release](../../releases/latest), extract it, and place the skill directory in your Claude Desktop skills folder.

## Development

Commit using [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix                       | Version bump |
| ---------------------------- | ------------ |
| `feat:`                      | minor        |
| `fix:`, `perf:`, `refactor:` | patch        |
| `BREAKING CHANGE` footer     | major        |
| `docs:`, `chore:`, `ci:`     | no release   |

CI validates all skills and releases automatically on every push to `main` that contains a release-worthy commit.

## Adding a Skill

1. Create `skills/<skill-name>/SKILL.md`
2. Add YAML frontmatter with at minimum a `description:` field
3. Commit with `feat: add <skill-name> skill`

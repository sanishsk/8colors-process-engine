# 8colors-process-engine

Portable Claude Code process engine. Three agents + three slash commands that
force brief-before-code, async OSS scouting, and weekly retro discipline into
any project.

## What's in the box (v0.1.0)

**Agents:**
- `brief-writer` (Sonnet) — writes 1-page briefs with alternatives + market check
- `researcher` (Haiku) — scouts OSS/MCP options async
- `ceo` (Opus) — weekly retro + next-week plan

**Commands:**
- `/brainstorm [topic]` — capture brainstorm → brief
- `/lock-backlog [phase]` — lock a phase backlog
- `/weekly-retro` — Friday retro + planning

**Doctrine:**
- OSS-first search order (5 rules, non-negotiable)
- Weekly rhythm (Mon brainstorm, Fri retro)
- Agent invocation rules per slot type

## Install

```bash
git clone https://github.com/sanishsk/8colors-process-engine.git
cd 8colors-process-engine
./scripts/install.sh /path/to/your-project
```

Restart Claude Code in the target project. Agents and commands will load.

## Roadmap

- v0.1 (current) — 3 new agents, 3 commands, templates, docs
- v0.2 — extract 14 existing 8CStudio agents (architect, code-reviewer, security-reviewer, etc.)
- v0.3 — `.process-engine.yaml` parameterization, `upgrade.sh`, `eject.sh`
- v0.4 — `hooks/` directory (pre-commit hooks generalized)
- v1.0 — Plugin marketplace publication

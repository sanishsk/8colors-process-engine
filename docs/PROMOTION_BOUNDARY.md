# Promotion boundary — what goes in the engine, what stays in the project

> Doctrine, 2026-09-05. Written after four promotions in one day landed on
> four different sides of this line, and after an adopter built a local
> wrapper around an engine hook because the engine had no way to express the
> thing they needed. Extends CONTRIBUTING's **value bar**, which decides
> whether a change is worth making at all; this decides *where it lives*.
>
> Read the value bar first. A change that fails V1–V4 does not get promoted
> anywhere, and no amount of correct layering rescues it.

---

## The test

> **Does it need to know something about *this* project to be correct?**

Not *"is it stack-specific"*. That is the mistake this doc exists to stop.
Swift snapshot-testing *doctrine* is stack-specific and belongs in the
engine, because it is true of every Swift project that will ever adopt it.
What cannot move is anything whose **correctness** depends on this codebase.

## Three layers, not two

Most of the engine's defects this year came from treating this as binary.

### Layer 1 — Engine: mechanism and judgment

Byte-identical across projects. Agents, gates, hooks, tools, doctrine docs.

If the next project's copy of the file would be the same file, it belongs
here.

### Layer 2 — Engine mechanism + project config

**The layer that gets forgotten, and the expensive one.** The engine owns
the rule; the project supplies its vocabulary.

```yaml
claude_md:      { warn_bytes: 30000, fail_bytes: 45000 }
security_gate:  { exempt_paths: '^ios/.*Session[A-Za-z]*\.swift$' }
review_gate:    { exempt_paths: '^(docs/|CLAUDE\.md$)' }
```

Every one of those knobs was added in v0.53.1–v0.55.0 *after* an adopter hit
the missing layer. Before them the values were hardcoded, and the adopter's
only recourse was a local wrapper that re-implemented the gate with a filter
in front. **A wrapper around an engine component is the symptom of a missing
layer-2 knob** — when you see one, the fix is a config key in the engine, not
a better wrapper.

Two rules for this layer, both learned the hard way:

- **Both halves of a dual-mode component must read the same config.**
  `claude-md-size` runs git-side and Claude-side; its thresholds were only
  settable through an env var on the pre-commit entry line, which the
  Claude-side launcher never sees. The two modes returned **opposite
  verdicts on the same file**. If a component has two entry points, the
  config lives where both can read it — `.process-engine.yaml`, not an env
  prefix in one caller.
- **Adopter config ADDS to the engine default; it does not replace it.**
  `security_gate.exempt_paths` is unioned with the engine's own exemptions.
  Replacing would mean declaring one exemption silently re-exposes
  everything the engine already knew to exclude.

### Layer 3 — Project: what the engine cannot know

Design tokens, snapshot baselines, test fixtures, the Swift package wiring,
domain vocabulary. Not a consolation prize — most code is correctly here.

## The split that catches people out

**A feature is routinely split across layers. The code stays; the lesson
promotes.**

`swift-snapshot-testing` adoption, worked through:

| Part | Layer | Why |
|---|---|---|
| Package pin, test target, scheme split | **Project** | No cross-project abstraction exists; the engine does not own a project's tests |
| The baselines | **Project** | PNGs of *your* screens |
| "Catches regressions, **not first builds**" | **Engine** | True of every Swift project that adopts it — and the caveat that cost the adopter two shipped bugs with no baseline to diff against |
| "An auto-recorded baseline locks a bug in as expected" | **Engine** | Same |
| "A different simulator gives false failures from font hinting" | **Engine** | Same |

Zero lines of code promoted. Three paragraphs of doctrine did, into
`docs/TESTING_TOPOLOGY.md`. **That is a successful promotion**, not a failed
one — the next Swift adopter does not rediscover any of it.

Ask the two questions separately:

1. Can the **code** be shared? Usually no.
2. Can the **lesson** be shared? Almost always yes.

Answering only the first is how the same caveat gets rediscovered five times.

## Agents specifically

**Do not add an agent per stack, per project, or per surface.** A
`swift-design-critic` would duplicate `design-critic`'s rubric, scoring and
reference-lock logic, and the two would drift — a rubric bug would then need
fixing twice. CONTRIBUTING's value bar already rejects "a new agent
overlapping an existing one": extend the existing agent's prompt.

The engine has one agent per *job*, not per *technology*.

**How a project gives a shared agent its own knowledge** — three ways, in
order of preference:

1. **Invocation context.** Pass the project's token file, config or spec as
   an argument. Nothing to maintain, nothing to drift.
2. **Layer-2 config.** A `.process-engine.yaml` key the agent reads.
3. **A project-local agent file.** `pe install` symlinks engine agents and
   **skips real files** — a `.md` you write into `.claude/agents/` is left
   alone by every future install:

   ```bash
   [ -L "$link" ] || continue      # skip real files (customizations)
   ```

   Use this for genuinely project-specific jobs (a docs agent that knows your
   layout), never to fork a shared agent.

## Which way to err

The costs are not symmetric, so the defaults are not either.

| Mistake | Cost |
|---|---|
| Wrongly **project-scoped** | Every project rediscovers it. Cheap once, expensive over five, and **silent** — nobody notices the rediscovery |
| Wrongly **engine-scoped** | The engine carries one project's assumption and breaks the next adopter. Louder, and worse |

So, matching CONTRIBUTING's "when in doubt it stays local":

> **Default the code to the project. Default the lesson to the engine.**

Promote code only when a second project would want the *identical file*.
`measure_screenshot.py` earned that by being written project-agnostic from
the start — its own docstring said it was meant for promotion, and it needed
one docstring edit to move.

## Expect the engine's gates to fire on promoted code

`measure_screenshot.py` had shipped and passed review in its home project.
The engine's size gate rejected it on arrival — `cmd_rules` at 55 lines
against `max_function_lines=50`, which has no escape hatch. It was split.

That is the boundary working. A project's standards are its own; code
crossing into the engine meets the engine's. **Budget for a round of
adjustment on any promotion**, and do not bypass a gate to land one.

## Checklist

Before proposing a promotion:

- [ ] It clears CONTRIBUTING's value bar (V1–V4) with evidence attached
- [ ] The file would be **identical** in the next project — or it is a
      lesson, not code
- [ ] It names no project's paths, section numbers or domain vocabulary
- [ ] Anything project-varying is a **layer-2 config key**, defaulting to
      today's behaviour so no adopter's gate moves on upgrade
- [ ] If dual-mode: both entry points read that config
- [ ] If it adds config: adopter values **add to** engine defaults
- [ ] It extends an existing agent rather than adding an overlapping one
- [ ] `pe install` actually delivers it — a convention that lives only in
      prose is not a convention
- [ ] Its test runs in CI rather than skipping

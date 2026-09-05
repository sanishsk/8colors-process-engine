# Design tooling plan — measured numbers, then a designer-grade spec

> Plan, 2026-09-05. Selects from the nine-item research at
> `docs/research/design-tooling.md` (commissioned the same day in Origyn) the
> items that shorten the design review loop, sequences them, and names the
> two decisions that are the operator's. Research is not repeated here.
>
> Operator's bar, verbatim: *"we should also receive the font size,
> placement, buttons, colors, gradients and all the possible design
> attributes a designer will think of ... it should work as a UI/UX design
> expert."*

---

## The problem this solves, in one incident

Origyn shipped a 22pt feed title against Hevy's 17pt and corrected it twice
in one day (D3a). Nobody measured; `design-critic` and the operator both
*judged* the size from a screenshot. Every review round on that title was a
round that a ruler would have made unnecessary.

That is the loop to shorten: **a number that was reasoned about instead of
measured costs a review round each time it is wrong.** The rest of the plan
follows from asking what else in a design review is currently judgment that
could be measurement — and, separately, what is judgment that should be
*labelled* as such so nobody builds on it as if it were measured.

## What is being selected against

Two filters, applied to all nine research items:

1. **Does it shorten the review loop?** Fewer rounds, or a round caught
   before review (a snapshot), or a spec produced *before* code so the first
   review is against a target rather than a guess.
2. **Does it fix a control that exists only in prose?** The research found
   the engine documents `docs/design/reference/` as where reference shots
   live and `pe install` never creates it — so Origyn's are in
   `docs/reference/hevy/` and nothing objected. Same shape as every defect
   fixed this week: a documented convention with no mechanism behind it.

Rejected outright, agreeing with the research: the Figma Dev-Mode MCP (every
tool takes a Figma node; there is no Figma file for a competitor's app —
zero fit, not partial) and every other MCP surveyed (they expose live
files/APIs; a flat PNG has nothing to expose).

---

## Tier 1 — this week, engine, each under an hour

| # | Item | Where | Loop effect | Effort |
|---|---|---|---|---|
| E1 | **`screenshot-measure.py`** — point-sample colour, pixel distance, horizontal-rule scan, image size. Pillow, no ML. Plus the `install.sh` copy loop that delivers `templates/tools/` → `docs/templates/tools/` (copy-once, adopter edits survive) | `templates/tools/screenshot-measure.py`, `scripts/install.sh` | Kills the D3a class: the number is measured on the first pass | ~1 hr incl. a `find_rules` self-check against a synthetic image with a known hairline |
| E2 | **One sentence in `design-critic` Step 4** — *"If `docs/templates/tools/screenshot-measure.py` exists, use it via Bash for exact colour/distance/rule values before citing drift; do not estimate what you can measure."* No new tools, no new mode: `design-critic` already declares `Bash` and `Read` (which reads images) | `agents/design-critic.md` | The existing gate cites measurements instead of impressions | 5 min |
| E3 | **`install.sh` scaffolds `docs/design/reference/`** and drops the reference README template into it — the convention the engine documents and never creates | `scripts/install.sh` + test | The tooling keys off a path that now exists on every adopter | 15 min |
| E4 | **The engine installs itself** — `pe install .` so its Claude-side hooks (`pre-commit-envelope-check`, `session-cost-warn`, `ponytail-preflight`, …) fire on engine sessions and a review envelope is required before an engine commit. Found today: no `.claude/settings.json` in this repo, no envelope ever recorded. Every "mandatory" in the engine is currently mandatory for adopters only | repo root | The engine's own review loop gets the gates it ships | 10 min — **decision needed, see below** |

E1 + E2 are the whole fix for the incident above. E3 and E4 are the
"convention in prose only" fixes; E4 is not from the research — it fell out
of checking why 38 engine files trip the security regex without consequence.

## Tier 2 — next, engine, half a day

| # | Item | Where | Loop effect | Effort |
|---|---|---|---|---|
| E5 | **Measurement primitives** — grow E1: `sample-grid` (N colour samples over a region, for gradient stops and line-height baselines), `scale-factor` (resolution → device profile lookup), and **structured output**: DTCG tokens with `$extensions.com.8colors.provenance.confidence` pre-set to `measured` or `derived`, never anything else | same file, ~150–250 lines | The agent stops copying numbers off stdout by hand; the JSON is the input to E7 | 3–4 hrs |
| E6 | **`docs/design/spec-taxonomy.md`** — the eight-category attribute taxonomy (typography, colour, shape, layout, components, hierarchy, motion, content) and the four-label confidence protocol (`measured` / `derived` / `inferred` / `unknown`, **per sub-value**), lifted from research Q6–Q8 with their DTCG / Apple HIG / Material 3 / WCAG grounding | new doc | Gives E7 a contract to cite rather than inline | 2–3 hrs, mostly done |

## Tier 3 — engine, one day, gated on Tier 1 having proved out

| # | Item | Where | Loop effect | Effort |
|---|---|---|---|---|
| E7 | **`design-critic` EXTRACTION mode** — a third mode beside FLOOR and CEILING. Explicit trigger on a bare reference image, **no diff required**. Emits the E6 spec (an artefact), not a PASS/WARN/FAIL envelope. Resolves every value against the adopter's token file(s) passed as context and reports `mapped_token: MATCH / near-miss (delta) / none`. Hard rule: may add a judgment-labelled value beside a measured one; may **never** overwrite a measured value or upgrade its own `inferred` to `measured` | `agents/design-critic.md` new section; contract decision vs `agents/_gate-contract.md` | The spec exists **before** the SwiftUI does, so the first review is against a target | ~1 day |

This is the operator's actual ask. It is genuinely a mode, not a sentence:
its trigger (an image, not a staged diff), its inputs (script JSON + token
files), and its output (a spec, not a verdict) are all different from what
`design-critic` does today. It is still not a new agent — vision-reading,
design judgment and the taxonomy belong with the one agent that owns design.

**Why it is gated.** Roughly two-thirds of "what a designer would think of"
is judgment, not extraction: font family, weight, easing, pressed/disabled
states, anything behind a scroll. A spec that prints a guessed font family
with the authority of a measured 24px gap is worse than one that says
`unknown`, because it will be built on. E7 is worth a day only if E1/E5's
measured third is being used on every screen; if the Hevy comparison was the
whole need, E1 already covers it.

## App level — Origyn's, not the engine's

| # | Item | Effort |
|---|---|---|
| A1 | `pointfreeco/swift-snapshot-testing` (MIT) on three screens with a corrected-in-production history: `WorkoutFeedCard`, the logger set-row, the Start-tab routine card. Own test plan, local-only until CI is confirmed to run a macOS runner pinned to the recording simulator. Catches the *second* regression, not the first appearance | 3–4 hrs |
| A2 | Move `docs/reference/hevy/` → `docs/design/reference/` once E3 lands | 10 min |
| A3 | Pass `DesignSystem.swift` + `design-tokens.css` on every E7 call so `mapped_token` resolves against real tokens | 0 code |

The *pattern* of A1 earns a paragraph in `docs/TESTING_TOPOLOGY.md` for the
next Swift adopter; the code stays in Origyn.

---

## Sequence

```
E1 + E2 + E3   → one PR, today          (the ruler, wired, scaffolded)
E4             → separate PR, if approved (repo-structure change)
A1             → Origyn, in parallel     (independent of everything above)
E5 + E6        → one PR, after E1 has been used on ≥1 real screen
E7             → its own PR, after E5/E6, with one worked Hevy example
A2, A3         → Origyn, as E3 / E7 land
```

E1/E3 and the open pipefail test sweep touch disjoint files and are the shape
`/parallel-fix` was built for.

## Two decisions that are the operator's

1. **E4 — commit `.claude/settings.json` to the engine repo?** It is not
   gitignored here. Committing it means the engine's own gates travel with
   every clone (correct: the engine should be the first adopter of itself).
   Not committing it means each clone re-runs `pe install .`. Recommend
   commit.
2. **E7 — build it now, or after E1 has been used?** The research and this
   plan both say after. If the answer is "every screen, from now on", the
   day is worth it and E5/E6 should start now so E7 has its inputs.

## What this plan does not do

- Does not add a dependency beyond Pillow (already an engine dev dependency).
- Does not add a new agent, hook, or MCP server.
- Does not promise anything a still image cannot contain: motion, states,
  font family. E7 labels those `unknown` by contract.

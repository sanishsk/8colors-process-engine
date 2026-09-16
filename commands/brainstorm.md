---
description: Capture a brainstorm session (voice transcript or text) and produce a 1-page brief via brief-writer agent. Hard gate before any /plan or implementation work.
---

# /brainstorm [topic]

Captures a brainstorm session for a new feature. Workflow:

1. Ask user: "Voice transcript or text input?"
2. If voice: instruct user to paste a transcript from whatever transcription tool they use (Soniox, Whisper, Deepgram — the engine is tool-agnostic). The transcription step happens outside this command; user pastes the resulting text.
3. If text: ask user to paste raw notes.
4. Save raw notes to `docs/research/brainstorm-YYYY-MM-DD-<topic>.md`.
5. **Grill, when decisions are still open.** Run the `grilling` skill if the
   notes leave any of these unsettled:
   - an operator decision: money, the contract, or what the client
     experiences (the boundary `brief-writer` uses);
   - which way a rule points: an allow-list or a deny-list, a filter that
     includes or exempts, a default that is on or off;
   - a schema, a gate, or anything another project will inherit.

   Work in rounds: every question whose prerequisites are settled, numbered,
   each with a recommended answer. Look facts up yourself (read the code,
   dispatch a subagent); put only decisions to the user. Stop when nothing is
   left assumed and the user confirms. Append a `## Decisions settled` section
   to the brainstorm file: each question, the answer, and whether it was the
   recommendation.

   If none of the three applies, skip this step and say so in one line.
   Grilling a settled idea costs the user time and buys nothing.
6. Invoke the `brief-writer` agent on the saved file.
7. Brief-writer produces `docs/research/brief-<topic>.md`.
8. Output to user: "Brief saved at <path>. Read and approve before invoking /plan."

Does NOT call architect, planner, or code-reviewer directly. Hard gate before
any implementation work.

Why step 5 exists: in September 2026 an adopter wrote a review-gate wrapper as an
include-list when the safe polarity was an exempt-list, and it missed two
files that needed review. One question with a recommended answer, asked
before the brief, would have settled it. brief-writer's OPEN QUESTIONS come
after the artefact is drafted; grilling comes before it.

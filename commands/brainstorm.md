---
description: Capture a brainstorm session (voice transcript or text) and produce a 1-page brief via brief-writer agent. Hard gate before any /plan or implementation work.
---

# /brainstorm [topic]

Captures a brainstorm session for a new feature. Workflow:

1. Ask user: "Voice transcript or text input?"
2. If voice: instruct user to paste a transcript from whatever transcription tool they use (Soniox, Whisper, Deepgram — the engine is tool-agnostic). The transcription step happens outside this command; user pastes the resulting text.
3. If text: ask user to paste raw notes.
4. Save raw notes to `docs/research/brainstorm-YYYY-MM-DD-<topic>.md`.
5. Immediately invoke the `brief-writer` agent on the saved file.
6. Brief-writer produces `docs/research/brief-<topic>.md`.
7. Output to user: "Brief saved at <path>. Read and approve before invoking /plan."

Does NOT call architect, planner, or code-reviewer directly. Hard gate before
any implementation work.

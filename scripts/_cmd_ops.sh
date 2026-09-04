#!/usr/bin/env bash
# _cmd_ops.sh — sourced by scripts/pe. Not executable on its own.
#
# scripts/pe was 1506 lines against the engine's OWN size-budget hook, which
# blocks at max_file_lines=800. The gate had therefore been failing on every
# change to the engine's main dispatcher, and each one was made with
# PE_SKIP_SIZE_BUDGET=1. A bypass reached for routinely is a gate that has
# stopped working.
#
# Split by lifecycle stage, not by size: running things once the engine is
# installed — collect, skills-audit, baseline, shadow, telemetry, agent,
# incident, memory, new, module, pin, recall, verify, gate.
#
# Everything here relies on $ENGINE_DIR, $VERSION and pe_python(), all
# defined in scripts/pe before this file is sourced.

cmd_collect() {
    # Portable git-derived dev-log digest. Zero Claude tokens.
    # Passes through to scripts/dev-log-collect.sh; if the first arg is
    # a bare project path (no leading -), it's translated to --project.
    local collector="$ENGINE_DIR/scripts/dev-log-collect.sh"
    if [ ! -x "$collector" ]; then
        echo "ERROR: $collector not found or not executable" >&2
        exit 1
    fi
    local first="${1:-}"
    if [ -n "$first" ] && [ "${first#-}" = "$first" ]; then
        # bare path → prepend --project
        shift
        exec "$collector" --project "$first" "$@"
    fi
    exec "$collector" "$@"
}

cmd_skills_audit() {
    # P7.4: inventory ~/.claude/skills/ + ~/.claude/commands/, flag
    # duplicates, classify against the engine's core-20 (docs/SKILLS.md).
    local py; py="$(pe_python)" || exit 1
    exec "$py" "$ENGINE_DIR/scripts/skills_audit.py" "$@"
}

cmd_baseline() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        capture)
            local py; py="$(pe_python)" || exit 1
            exec "$py" "$ENGINE_DIR/scripts/baseline.py" "$@"
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe baseline — Phase 0 slot baselines (E2)

SUBCOMMANDS
    capture --project <path> --slot-id <id> --slot-kind <kind> \\
            --branch <name> --merge-commit <sha> \\
            [--sentry-count <n>] [--output <path>]

        Computes speed (wall-clock + iterations), size (files / lines),
        and quality (rework_72h) for a shipped slot, from git history.

SEE ALSO
    docs/baselines/README.md         Corpus + Phase 3 success criterion
    schemas/baseline.schema.json     Record contract
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe baseline' subcommand: $sub" >&2
            echo "Run 'pe baseline help' for usage." >&2
            exit 2
            ;;
    esac
}

cmd_shadow() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        decide|reconcile|reset)
            local py; py="$(pe_python)" || exit 1
            exec "$py" "$ENGINE_DIR/scripts/pe_orchestrator.py" "$sub" "$@"
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe shadow — Phase 3 escalation router (SHADOW-MODE)

The orchestrator records what it WOULD do given a gate envelope.
Does NOT enforce — the actual worker / human pipeline continues.
Decisions and reconciliations feed the graduation harness.

SUBCOMMANDS
    decide     --envelope <file> --slot-id <id> --iteration <n> \\
               --current-tier <haiku|sonnet|opus> [--slot-kind <kind>] \\
               [--routing-policy <file>] [--breaker-policy <file>] \\
               [--decisions-log .pe/decisions.jsonl]

        Emits one shadow decision per gate envelope. Returns a JSON
        summary on stdout (action / from_tier / to_tier / rule /
        breaker-would-trip).

    reconcile  --slot-id <id> [--decisions-log .pe/decisions.jsonl] \\
               [--reconciliations-log .pe/reconciliations.jsonl]

        Joins all shadow decisions for a slot against actual outcome.
        Reads the outcome JSON object from stdin (keys: merge_commit,
        ultimate_outcome, actual_iterations_used,
        actual_tier_progression, router_correctness).

    reset      [--decisions-log .pe/decisions.jsonl] [--campaign-id <id>]

        Removes the cumulative breaker sidecar for a campaign, so token
        budgets start fresh. Idempotent. The subcommand existed in
        pe_orchestrator.py from P2.11 but this dispatcher only routed
        decide and reconcile, so it was unreachable through `pe` until
        v0.52.0.

SEE ALSO
    docs/PHASE_3_ESCALATION_ROUTER.md   Design, graduation criteria, schema
    policy/failure_class_routing.toml   Routing rules
    policy/circuit_breaker.toml         Iteration + token caps
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe shadow' subcommand: $sub" >&2
            echo "Run 'pe shadow help' for usage." >&2
            exit 2
            ;;
    esac
}

cmd_telemetry() {
    # A1/L1/L4: parse Claude Code transcripts into structured usage records,
    # emit OTel-shaped spans, attribute cost per session/model. Feeds the
    # circuit breaker's budget calibration + the retro agent's cost step.
    local sub="${1:-}"
    shift || true
    case "$sub" in
        collect|summary)
            local py; py="$(pe_python)" || exit 1
            exec "$py" "$ENGINE_DIR/scripts/telemetry.py" "$sub" "$@"
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe telemetry — Claude Code transcript telemetry (A1/L1/L4)

SUBCOMMANDS
    collect [--project <path>] [--since <YYYY-MM-DD>]
        Scan ~/.claude/projects/<slug>/*.jsonl for the target project,
        extract every assistant turn (input/output/cache token counts +
        model), dedupe by uuid, and append to:
          <project>/.pe/telemetry.jsonl   (structured records)
          <project>/.pe/traces/<session-id>.jsonl  (OTel-shaped spans)

    summary [--project <path>] [--since <YYYY-MM-DD>]
        Aggregate .pe/telemetry.jsonl per session × model with
        estimated cost (cents-per-Mtoken table in scripts/telemetry.py).

Design notes
    - Read-only against transcripts. Writes .pe/ only (gitignored).
    - Feature-detected: no transcripts → exit 0 (informational).
    - Circuit breaker (policy/circuit_breaker.toml) currently uses
      "inf" budgets. Telemetry is the empirical baseline to replace
      those with real numbers.
    - Retro agent (docs/dev-log-collect + retrospective-agent) can
      surface the cost totals in its Step 0.
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe telemetry' subcommand: $sub" >&2
            echo "Run 'pe telemetry help' for usage." >&2
            exit 2
            ;;
    esac
}

cmd_agent() {
    # A4: headless agent invocation via `claude -p`. The primitive that
    # both the gate-efficacy live-mode runner and (future) shadow
    # orchestrator's auto-escalation loop will consume.
    local sub="${1:-}"
    shift || true
    case "$sub" in
        run)
            local py; py="$(pe_python)" || exit 1
            exec "$py" "$ENGINE_DIR/scripts/agent_runner.py" "$sub" "$@"
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe agent — headless agent invocation (A4)

SUBCOMMANDS
    run <name> [--brief <file>|-] [--out <path>] [--model <id>]
               [--timeout <s>] [--dry-run]

        Invokes agents/<name>.md's persona via \`claude -p\` with the
        brief passed on stdin (or --brief). Writes agent output to
        stdout (or --out) and persists a structured run record at
        <cwd>/.pe/runs/<slug>/{brief.md, run.json, output.txt}.

        Exit codes:
          0 success
          1 agent exited non-zero
          2 invalid args
          3 claude CLI not on PATH (feature-detected skip)
          4 agent .md file missing / unparseable

        This is the execution PRIMITIVE. The auto-escalation loop
        (orchestrator invokes next tier on worker_quality FAIL) is a
        caller, deferred to a follow-up release — this file just
        ships the runnable primitive + live-mode gate-efficacy eval.
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe agent' subcommand: $sub" >&2
            echo "Run 'pe agent help' for usage." >&2
            exit 2
            ;;
    esac
}

cmd_incident() {
    # A3: incident → gate synthesizer wrapper. Assembles the incident
    # brief, invokes agents/incident-synthesizer.md via `pe agent run`,
    # extracts + validates the Proposal Envelope, and materializes to
    # .pe/incident-proposals/<slug>/ in the CALLER's project. NEVER
    # writes to the engine repo. See agents/incident-synthesizer.md for
    # the anti-abuse contract.
    local sub="${1:-}"
    shift || true
    case "$sub" in
        propose|list)
            local py; py="$(pe_python)" || exit 1
            exec "$py" "$ENGINE_DIR/scripts/incident_synth.py" "$sub" "$@"
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe incident — incident → gate synthesizer (A3)

SUBCOMMANDS
    propose --incident <file>       Synthesize a gate proposal from
    propose --note "<text>"         one incident. Emits a Proposal
    propose --decisions-fail        Envelope, materializes the
            [--out-dir <path>]      proposed files to
            [--model <alias>]       .pe/incident-proposals/<slug>/
            [--timeout <s>]         in the CALLER's project.
            [--dry-run]             NEVER writes to the engine repo.

    list    [--out-dir <path>]      List past proposals in the current
                                    (or given) project.

Anti-abuse contract
    - The engine's incident-synthesizer agent has NO Write/Edit tool;
      it can only emit a Proposal Envelope.
    - This CLI materializes the envelope's proposed files under
      .pe/incident-proposals/<slug>/files/ (the operator's project),
      NEVER under the engine repo. The operator reviews and opens a
      PR against the engine manually.
    - There is NO --auto-apply mode. Ever. Engine self-modification
      stays forbidden by design (A3 doctrine).

Exit codes:
    0 proposal materialized
    1 agent invocation failed / claude not on PATH (skip)
    2 invalid args
    3 proposal envelope missing / invalid
    4 proposal references paths outside engine repo
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe incident' subcommand: $sub" >&2
            echo "Run 'pe incident help' for usage." >&2
            exit 2
            ;;
    esac
}

cmd_memory() {
    # L3: auto-memory governance. Inspects + prunes
    # ~/.claude/projects/<slug>/memory/. Never writes new entries —
    # that stays with Claude Code's auto-memory system per the
    # operator's global memory rules. See docs/MEMORY_GOVERNANCE.md.
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ls|show|rm|verify|stale)
            local py; py="$(pe_python)" || exit 1
            exec "$py" "$ENGINE_DIR/scripts/pe_memory.py" "$sub" "$@"
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe memory — auto-memory governance (L3)

SUBCOMMANDS
    ls    [--project <path>] [--type <t>] [--stale]
              List entries with age + staleness flag.
    show  <name> [--project <path>]
              Display frontmatter + body of one entry.
    rm    <name> [--project <path>] [--yes]
              Delete an entry AND remove its line from MEMORY.md
              index (prompts unless --yes).
    verify <name> [--project <path>]
              Stamp metadata.last_verified = today (resets staleness
              clock without editing body — for entries the operator
              has re-checked and re-endorsed).
    stale [--project <path>] [--older-than-days N]
              List entries past their freshness window. Print
              "verify or delete" recommendation for each.

STALENESS RULE
    An entry is stale iff:
        now - max(mtime, last_verified) > (freshness_days or DEFAULT)

    Defaults per type (when metadata.freshness_days absent):
      user       90d    identities change slowly
      feedback   60d    preferences drift
      project    14d    state changes fast
      reference  180d   pointers rarely rot
      (unknown)  30d

See docs/MEMORY_GOVERNANCE.md for the doctrine.
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe memory' subcommand: $sub" >&2
            echo "Run 'pe memory help' for usage." >&2
            exit 2
            ;;
    esac
}

cmd_new() {
    # A6 scaffold. `pe new` is a top-level shortcut that maps to
    # pe_new.py's `scaffold` subcommand — the operator types
    # `pe new "Acme Corp" --stack python-flask`, we prepend
    # `scaffold`. Zero API cost; deterministic template drop.
    local py; py="$(pe_python)" || exit 1
    if [ $# -eq 0 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        cat <<EOF
pe new <name> [--stack python-flask|generic] [--dir <parent>]
              [--tagline "<one-liner>"] [--no-install]

Scaffolds a fresh project directory from templates/scaffold/<stack>/.
Substitutes {{PROJECT_NAME}} / {{PROJECT_SLUG}} / {{PROJECT_TAGLINE}}
placeholders, initializes git, then runs \`pe install\` on the new
directory unless --no-install is passed.

The complement to \`agents/project-kickstarter.md\` — that agent does
interactive Q&A + reasoning; \`pe new\` is the deterministic
template-drop path (zero API cost).

Stacks
    python-flask   — Flask 3 + SQLAlchemy 2 + pytest + ruff + mypy.
                     Ships modules/, tests/, pyproject.toml, run.py,
                     .env.example, smoke test.
    generic        — Minimal, stack-agnostic tree. modules/, tests/,
                     scripts/, docs/, CLAUDE.md, README.md.

Post-scaffold
    cd <name>
    <install deps for your stack>
    <restart Claude Code>

See docs/SCAFFOLD.md for the full doctrine.
EOF
        return 0
    fi
    exec "$py" "$ENGINE_DIR/scripts/pe_new.py" scaffold "$@"
}

cmd_module() {
    # A6 domain-module dropper. `pe module add <name>` materializes
    # templates/domain-modules/<name>/ into a project's modules/
    # tree. Never overwrites existing files.
    local sub="${1:-}"
    shift || true
    case "$sub" in
        add)
            local py; py="$(pe_python)" || exit 1
            exec "$py" "$ENGINE_DIR/scripts/pe_new.py" module add "$@"
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe module — reusable domain-module dropper (A6)

SUBCOMMANDS
    add <name> [--project <path>]
        Materialize a reusable module into <project>/modules/<name>/.
        Never overwrites existing files (reports skipped).

AVAILABLE MODULES
    api-credentials    Encrypted API-key admin (Python/Flask).
                       Extracted from operator's rules/common/
                       api-credentials.md doctrine. Ships models,
                       service, admin blueprint, templates,
                       migration, tests.

See docs/SCAFFOLD.md § domain modules for the roadmap of upcoming
modules (auth, tenancy, billing, ...) and how to author your own.
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe module' subcommand: $sub" >&2
            echo "Run 'pe module help' for usage." >&2
            exit 2
            ;;
    esac
}

cmd_pin() {
    # A8 per-project version pin. `pe pin show|verify|bump` inspects and
    # reconciles .claude/.engine-pin.json so adopters don't silently ride
    # engine HEAD after `pe upgrade`.
    local py; py="$(pe_python)" || exit 1
    exec "$py" "$ENGINE_DIR/scripts/pe_pin.py" "$@"
}

cmd_recall() {
    # A7 cross-session decision memory. Reads .pe/decisions.jsonl +
    # .pe/reconciliations.jsonl and returns the top-K slots whose
    # signal tokens overlap the query. Read-only; never writes.
    local py; py="$(pe_python)" || exit 1
    exec "$py" "$ENGINE_DIR/scripts/pe_recall.py" "$@"
}

cmd_verify() {
    # S4 supply-chain integrity: checksum all load-bearing engine
    # surfaces against MANIFEST.sha256. Divergence = local edit OR
    # upstream poisoning; either way, exit non-zero so a poisoned
    # agent/hook can't run silently.
    local py; py="$(pe_python)" || exit 1
    exec "$py" "$ENGINE_DIR/scripts/pe_verify.py" "$@"
}

cmd_gate() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        parse)
            if [ $# -lt 1 ]; then
                cat >&2 <<EOF
Usage: pe gate parse <transcript-or-envelope-file>

Extracts the last fenced 'json gate-envelope' block from <file>,
validates it against schemas/gate-envelope.schema.json, and exits:
  0 PASS                 verdict=PASS
  1 FAIL worker_quality  escalation candidate
  2 FAIL non-escalatable failure_class in {task_underspecified,blocked,out_of_scope}
  3 WARN                 proceed, surface to human
  4 parse/schema error

Bare .json artifacts (no fenced block) require the explicit --bare
flag — the path third-party gate tools (e.g. CodeRabbit) emit on.
Default (transcript) mode requires the fenced envelope AND the
'Envelope key values' cross-check block (E1.d).
EOF
                exit 2
            fi
            local py; py="$(pe_python)" || exit 1
            exec "$py" "$ENGINE_DIR/scripts/pe_gate.py" "$@"
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe gate — quality gate envelope tooling (E1)

SUBCOMMANDS
    parse <file>    Extract + validate gate-envelope JSON from a transcript or artifact.

SEE ALSO
    docs/E1_GATE_ENVELOPE.md         Design rationale, failure_class semantics
    schemas/gate-envelope.schema.json JSON Schema draft-07 contract
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe gate' subcommand: $sub" >&2
            echo "Run 'pe gate help' for usage." >&2
            exit 2
            ;;
    esac
}

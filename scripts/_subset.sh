# scripts/_subset.sh — preset rosters + yaml subset reader.
#
# Sourced by scripts/install.sh and scripts/pe (cmd_sync). Single source of
# truth so install + sync never disagree on which agents belong to which
# preset.
#
# DO NOT execute directly. DO NOT add side effects at source time.

# Preset rosters. Agent names match the basename of agents/<name>.md without
# the .md suffix.
#
# `gate-only` is DEFINED as "every agent that emits a gate envelope" — the
# ones whose prompts source agents/_gate-contract.md. It is not a hand-picked
# list, and tests/test_subset_rosters.sh fails if it drifts from that
# definition.
#
# It drifted for a year. The roster was written in v0.8.0 with the five gate
# agents that existed then; `design-critic` arrived in v0.18.0 and
# `performance-reviewer` in v0.37.0, both emitting envelopes, and neither was
# added. An adopter installing `--subset gate-only` for review discipline was
# silently getting five of the seven gates — no design gate, no performance
# gate — while docs/CAPABILITY_CATALOG.md agreed with the roster and was
# equally wrong about what a gate agent had become.
GATE_ONLY_AGENTS="code-reviewer security-reviewer database-reviewer tdd-guide e2e-runner design-critic performance-reviewer"
CORE_AGENTS="$GATE_ONLY_AGENTS planner brief-writer architect"

# agent_in_subset NAME SUBSET — returns 0 if NAME is in SUBSET, 1 otherwise.
# "full" matches every name.
agent_in_subset() {
    local name="$1" subset="$2"
    case "$subset" in
        full)      return 0 ;;
        core)      [[ " $CORE_AGENTS " == *" $name "* ]] ;;
        gate-only) [[ " $GATE_ONLY_AGENTS " == *" $name "* ]] ;;
        *)         return 1 ;;
    esac
}

# read_subset_from_yaml YAML_PATH — prints the install.subset value (empty if
# missing). Tolerates yaml absence.
read_subset_from_yaml() {
    local yaml="$1"
    [ -f "$yaml" ] || return 0
    # gsub strips surrounding quotes — subset: "core" must read as core
    awk '/^install:/{f=1;next} f && /^  subset:/{v=$2; gsub(/["\047]/,"",v); print v; exit} f && /^[^ ]/{exit}' "$yaml" 2>/dev/null || true
}

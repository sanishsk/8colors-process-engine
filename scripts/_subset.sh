# scripts/_subset.sh — preset rosters + yaml subset reader.
#
# Sourced by scripts/install.sh and scripts/pe (cmd_sync). Single source of
# truth so install + sync never disagree on which agents belong to which
# preset.
#
# DO NOT execute directly. DO NOT add side effects at source time.

# Preset rosters. Agent names match the basename of agents/<name>.md without
# the .md suffix. Keep in lockstep with docs/CAPABILITY_CATALOG.md.
GATE_ONLY_AGENTS="code-reviewer security-reviewer database-reviewer tdd-guide e2e-runner"
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
    awk '/^install:/{f=1;next} f && /^  subset:/{print $2; exit} f && /^[^ ]/{exit}' "$yaml" 2>/dev/null || true
}

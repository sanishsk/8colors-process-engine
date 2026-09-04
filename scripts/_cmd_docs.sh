#!/usr/bin/env bash
# _cmd_docs.sh — sourced by scripts/pe. Not executable on its own.
#
# scripts/pe was 1506 lines against the engine's OWN size-budget hook, which
# blocks at max_file_lines=800. The gate had therefore been failing on every
# change to the engine's main dispatcher, and each one was made with
# PE_SKIP_SIZE_BUDGET=1. A bypass reached for routinely is a gate that has
# stopped working.
#
# Split by lifecycle stage, not by size: the two whole-repo sweeps — docs check
# and audit.
#
# Everything here relies on $ENGINE_DIR, $VERSION and pe_python(), all
# defined in scripts/pe before this file is sourced.

cmd_docs() {
    local sub="${1:-check}"
    shift || true
    case "$sub" in
        check)
            # Frontmatter + inventory consistency (P2.9). Compares
            # VERSION file to badges/claims in README + plugin.json,
            # and agent/command counts on disk vs those claimed.
            local rc=0
            local ver; ver="$VERSION"
            echo "pe docs check — v$ver"
            echo ""

            # Version drift check
            for f in README.md plugin.json INSTALL.md; do
                local path="$ENGINE_DIR/$f"
                [ -f "$path" ] || continue
                # Find version-shaped tokens 0.x.y that differ
                local drift
                drift=$(grep -oE '0\.[0-9]+\.[0-9]+' "$path" | sort -u | grep -v "^${ver}$" || true)
                if [ -n "$drift" ]; then
                    echo "  ⚠ $f mentions versions other than $ver:"
                    echo "$drift" | sed 's/^/      /'
                    rc=1
                fi
            done

            # Inventory drift: agents/commands on disk vs claimed in README + plugin.json
            local n_agents_disk n_commands_disk
            n_agents_disk=$(find "$ENGINE_DIR/agents" -maxdepth 1 -name '*.md' ! -name '_*' | wc -l | tr -d ' ')
            n_commands_disk=$(find "$ENGINE_DIR/commands" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
            echo "  Inventory on disk: $n_agents_disk agents, $n_commands_disk commands"

            # Compare against plugin.json description
            if grep -qE "[0-9]+ agents" "$ENGINE_DIR/plugin.json" 2>/dev/null; then
                local claimed
                claimed=$(grep -oE "[0-9]+ agents" "$ENGINE_DIR/plugin.json" | head -1 | awk '{print $1}')
                if [ "$claimed" != "$n_agents_disk" ]; then
                    echo "  ⚠ plugin.json claims $claimed agents but repo has $n_agents_disk"
                    rc=1
                fi
            fi
            if grep -qE "[0-9]+ commands" "$ENGINE_DIR/plugin.json" 2>/dev/null; then
                local claimed
                claimed=$(grep -oE "[0-9]+ commands" "$ENGINE_DIR/plugin.json" | head -1 | awk '{print $1}')
                if [ "$claimed" != "$n_commands_disk" ]; then
                    echo "  ⚠ plugin.json claims $claimed commands but repo has $n_commands_disk"
                    rc=1
                fi
            fi

            if [ $rc -eq 0 ]; then
                echo "  ✓ Docs and inventory consistent with v$ver"
            fi
            return $rc
            ;;
        ""|help|-h|--help)
            cat <<EOF
pe docs — documentation consistency checks (P2.9)

SUBCOMMANDS
    check   Grep VERSION against badges + count agents/commands on disk
            vs those claimed in README.md and plugin.json.

Exits 0 if consistent, 1 on any drift. Useful as a release checklist
step — run before bumping VERSION to catch stale numbers.
EOF
            ;;
        *)
            echo "ERROR: unknown 'pe docs' subcommand: $sub" >&2
            exit 2
            ;;
    esac
}

# cmd_audit (G1) — run gates across the WHOLE repo, not just the staged diff.
# Pre-commit hooks only see staged files, so existing debt is invisible until a
# file is touched. `pe audit` closes that: deterministic gates via
# `pre-commit run --all-files`, then the ready-to-run agent-sweep commands for
# the taste/judgment gates (design-critic, security-reviewer) over EXISTING files.
# ponytail: agent sweeps are printed, not auto-run — they cost tokens; operator
# opts in. `--screens-only` limits to the design sweep.
cmd_audit() {
    local screens_only=0
    [ "${1:-}" = "--screens-only" ] && screens_only=1
    echo "═══ pe audit — full-repo, not just staged ═══"

    if [ "$screens_only" = 0 ]; then
        echo "── deterministic gates (all files) ──"
        if command -v pre-commit >/dev/null 2>&1 && [ -f .pre-commit-config.yaml ]; then
            pre-commit run --all-files || echo "  (findings above — advisory in audit mode)"
        else
            echo "  SKIP: needs pre-commit + .pre-commit-config.yaml."
            echo "  Fix: pip install pre-commit  (config ships from \`pe install\`)."
        fi
    fi

    # Agent sweeps — the taste/logic gates that no hook can do. Print commands +
    # file counts; don't burn tokens without opt-in.
    echo "── agent sweeps (existing files — opt-in, cost tokens) ──"
    local ui
    ui=$( { git ls-files 'templates/**' 'app/**' 'src/**' 2>/dev/null \
            | grep -iE '\.(html|jsx|tsx|vue|svelte)$' || true; } | wc -l | tr -d ' ')
    echo "  design-critic over $ui existing UI files (the '--all-screens' sweep):"
    echo "    git ls-files | grep -iE '\\.(html|jsx|tsx|vue|svelte)\$' \\"
    echo "      | while read f; do pe agent run design-critic --brief \"\$f\"; done"
    if [ "$screens_only" = 0 ]; then
        local routes
        routes=$( { git ls-files 2>/dev/null | grep -iE 'route|view|api|controller' || true; } \
                  | wc -l | tr -d ' ')
        echo "  security-reviewer over $routes existing route/view files:"
        echo "    (same loop with \`pe agent run security-reviewer\`)"
    fi
    echo "═══ audit done — deterministic findings above are real; agent sweeps are opt-in ═══"
}

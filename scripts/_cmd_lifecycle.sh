#!/usr/bin/env bash
# _cmd_lifecycle.sh — sourced by scripts/pe. Not executable on its own.
#
# scripts/pe was 1506 lines against the engine's OWN size-budget hook, which
# blocks at max_file_lines=800. The gate had therefore been failing on every
# change to the engine's main dispatcher, and each one was made with
# PE_SKIP_SIZE_BUDGET=1. A bypass reached for routinely is a gate that has
# stopped working.
#
# Split by lifecycle stage, not by size: getting the engine into and out of a
# project — install, launchd, sync, upgrade, status, doctor, eject.
#
# Everything here relies on $ENGINE_DIR, $VERSION and pe_python(), all
# defined in scripts/pe before this file is sourced.

# ─── subcommand handlers ────────────────────────────────────────────────────

cmd_install() {
    if [ $# -lt 1 ]; then
        echo "Usage: pe install [--subset gate-only|core|full] <project>" >&2
        exit 1
    fi
    # Forward all args (flags + positional) to install.sh. install.sh owns
    # validation and resolution (explicit flag > existing yaml > full default).
    exec "$ENGINE_DIR/scripts/install.sh" "$@"
}

cmd_launchd() {
    local target="${1:?Usage: pe launchd <project>}"
    exec "$ENGINE_DIR/scripts/install_launchd.sh" "$target"
}

# pe sync — re-point project symlinks at the current engine, with the
# diff-before-clobber safety contract. See `pe help sync` for the full
# state machine. Originally specced in docs/BACKLOG.md P1.2.
cmd_sync() {
    local target="" dry_run=0 yes=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --yes|-y)  yes=1; shift ;;
            -h|--help)
                help_subcommand sync
                return 0 ;;
            --*)
                echo "ERROR: unknown flag: $1" >&2
                echo "Usage: pe sync [--dry-run] [--yes] <project>" >&2
                return 2 ;;
            *)
                if [ -z "$target" ]; then target="$1"; else
                    echo "ERROR: unexpected positional arg: $1" >&2
                    return 2
                fi
                shift ;;
        esac
    done

    if [ -z "$target" ]; then
        echo "Usage: pe sync [--dry-run] [--yes] <project>" >&2
        return 1
    fi
    if [ ! -d "$target" ]; then
        echo "ERROR: $target does not exist" >&2
        return 1
    fi

    # Resolve subset from yaml; default full if missing.
    local subset
    subset=$(read_subset_from_yaml "$target/.process-engine.yaml")
    subset="${subset:-full}"

    echo "pe sync $target"
    echo "  engine version: $VERSION"
    echo "  subset: $subset"
    if [ $dry_run -eq 1 ]; then
        echo "  mode: dry-run (no writes)"
    elif [ $yes -eq 1 ]; then
        echo "  mode: --yes (auto-confirm prompts — bypasses diff gate)"
    fi
    echo ""

    # Counters (read inside process_one via dynamic scoping)
    local n_current=0 n_added=0 n_upgraded=0 n_repointed=0
    local n_orphan_removed=0 n_orphan_kept=0 n_declined=0

    # confirm PROMPT — returns 0 on yes, 1 on no. Auto-yes if $yes==1.
    # Reads from stdin: when run interactively stdin is the tty; the smoke
    # test pipes y/n on stdin. Either path exercises the same gate.
    confirm() {
        local q="$1" ans=""
        if [ "$yes" -eq 1 ]; then
            echo "      ↳ auto-confirm (--yes): $q"
            return 0
        fi
        printf "      ↳ %s [y/N]: " "$q"
        read -r ans || ans=""
        echo "$ans"
        case "$ans" in
            y|Y|yes|YES) return 0 ;;
            *) return 1 ;;
        esac
    }

    # process_one ENGINE_SRC PROJECT_DST LABEL — classify + act on one file.
    process_one() {
        local engine_src="$1" project_dst="$2" label="$3"
        local resolved state

        if [ -L "$project_dst" ]; then
            # Canonicalise both sides — a resolved symlink like
            # /var/... → /private/var/... on macOS would otherwise
            # register as stale when it's byte-identical. `realpath -m`
            # tolerates missing final path components.
            local resolved_real engine_real
            resolved_real=$(realpath -m "$project_dst" 2>/dev/null || readlink "$project_dst")
            engine_real=$(realpath -m "$engine_src" 2>/dev/null || echo "$engine_src")
            resolved=$(readlink "$project_dst")
            if [ "$resolved_real" = "$engine_real" ]; then
                state="current"
            else
                state="stale-symlink"
            fi
        elif [ -e "$project_dst" ]; then
            if cmp -s "$engine_src" "$project_dst"; then
                state="matches"
            else
                state="differs"
            fi
        else
            state="missing"
        fi

        case "$state" in
            current)
                n_current=$((n_current+1))
                ;;
            missing)
                echo "  + $label (missing — adding symlink)"
                if [ $dry_run -eq 0 ]; then
                    mkdir -p "$(dirname "$project_dst")"
                    ln -sf "$engine_src" "$project_dst"
                fi
                n_added=$((n_added+1))
                ;;
            matches)
                echo "  ↻ $label (regular file matches engine — upgrading to symlink)"
                if [ $dry_run -eq 0 ]; then
                    rm -f "$project_dst"
                    ln -sf "$engine_src" "$project_dst"
                fi
                n_upgraded=$((n_upgraded+1))
                ;;
            stale-symlink)
                echo "  ⚠ $label"
                echo "      stale symlink → $resolved"
                if [ $dry_run -eq 1 ]; then
                    echo "      [dry-run] would re-point at $engine_src"
                    n_repointed=$((n_repointed+1))
                elif confirm "re-point to current engine?"; then
                    ln -sf "$engine_src" "$project_dst"
                    n_repointed=$((n_repointed+1))
                else
                    n_declined=$((n_declined+1))
                fi
                ;;
            differs)
                echo "  ⚠ $label (regular file, differs from engine)"
                echo "      diff (engine → project):"
                # diff exits 1 when files differ (always true here) — guard
                # against errexit killing the whole sync (was: dead confirm path)
                diff -u "$engine_src" "$project_dst" 2>/dev/null | sed 's/^/        /' | head -40 || true
                if [ $dry_run -eq 1 ]; then
                    echo "      [dry-run] would NOT overwrite without confirmation"
                    n_declined=$((n_declined+1))
                elif confirm "overwrite with engine version? (existing file will be LOST)"; then
                    ln -sf "$engine_src" "$project_dst"
                    n_repointed=$((n_repointed+1))
                else
                    echo "      kept project version (engine version not applied)"
                    n_declined=$((n_declined+1))
                fi
                ;;
        esac
    }

    # ─── Agents (subset-filtered) ─────────────────────────────────────────
    echo "Scanning agents (subset=$subset):"
    local engine_agent_names=""
    for f in "$ENGINE_DIR"/agents/*.md; do
        local agent_name agent_stem
        agent_name="$(basename "$f")"
        agent_stem="${agent_name%.md}"
        # Skip _-prefixed spec files (e.g. _gate-contract.md).
        case "$agent_stem" in _*) continue ;; esac
        engine_agent_names="$engine_agent_names $agent_name"
        if ! agent_in_subset "$agent_stem" "$subset"; then
            continue
        fi
        process_one "$f" "$target/.claude/agents/$agent_name" "agent $agent_name"
    done

    # Orphan check — symlinks for engine agents NOT in current subset
    if [ -d "$target/.claude/agents" ]; then
        for project_agent in "$target/.claude/agents"/*.md; do
            [ -e "$project_agent" ] || [ -L "$project_agent" ] || continue
            local pname pstem
            pname="$(basename "$project_agent")"
            pstem="${pname%.md}"
            # Only consider agents the engine ships (don't touch project-authored agents)
            case "$engine_agent_names" in
                *" $pname "*) ;;
                *) continue ;;
            esac
            if agent_in_subset "$pstem" "$subset"; then
                continue
            fi
            echo "  ✗ agent $pname (orphan — not in subset '$subset')"
            if [ $dry_run -eq 1 ]; then
                echo "      [dry-run] would prompt for removal"
                n_orphan_kept=$((n_orphan_kept+1))
            elif confirm "remove orphan symlink?"; then
                rm -f "$project_agent"
                n_orphan_removed=$((n_orphan_removed+1))
            else
                n_orphan_kept=$((n_orphan_kept+1))
            fi
        done
    fi
    echo ""

    # ─── Commands (no subset filter) ──────────────────────────────────────
    echo "Scanning commands:"
    for f in "$ENGINE_DIR"/commands/*.md; do
        local cname
        cname="$(basename "$f")"
        process_one "$f" "$target/.claude/commands/$cname" "command $cname"
    done
    echo ""

    # ─── Scripts (research_index.py only — engine's sole script symlink) ──
    echo "Scanning scripts:"
    if [ -f "$ENGINE_DIR/scripts/research_index.py" ]; then
        process_one "$ENGINE_DIR/scripts/research_index.py" \
                    "$target/scripts/research_index.py" \
                    "script research_index.py"
    fi
    echo ""

    echo "Summary: ${n_current} current, ${n_added} added, ${n_upgraded} upgraded, ${n_repointed} re-pointed, ${n_orphan_removed} orphan removed, ${n_declined} declined, ${n_orphan_kept} orphan kept"
    return 0
}

cmd_upgrade() {
    cd "$ENGINE_DIR"
    local old_head new_head
    old_head=$(git rev-parse HEAD 2>/dev/null || echo "?")
    echo "→ git pull in $ENGINE_DIR"
    git pull --ff-only 2>&1 || {
        echo "ERROR: git pull failed. Resolve conflicts manually." >&2
        exit 1
    }
    new_head=$(git rev-parse HEAD)
    if [ "$old_head" = "$new_head" ]; then
        echo "✓ Already at $new_head — no upgrade needed."
        return 0
    fi
    echo ""
    echo "✓ Upgraded $old_head → $new_head"
    echo ""
    echo "Files changed in this upgrade:"
    git diff --name-only "$old_head" "$new_head" | sed 's/^/    /'
    echo ""

    # Detect new files that warrant re-running install
    local new_files
    new_files=$(git diff --name-only --diff-filter=A "$old_head" "$new_head" \
        | grep -E '^(agents|commands|skills|scripts)/' || true)
    if [ -n "$new_files" ]; then
        echo "NEW files added — re-run 'pe install <project>' for each project to pick them up:"
        echo "$new_files" | sed 's/^/    /'
    else
        echo "No new files; symlinks have already propagated changes to your projects."
    fi
}

cmd_status() {
    cd "$ENGINE_DIR"
    local head head_short head_date head_author
    head=$(git rev-parse HEAD 2>/dev/null || echo "?")
    head_short=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
    head_date=$(git log -1 --format=%cd --date=short 2>/dev/null || echo "?")
    head_author=$(git log -1 --format=%an 2>/dev/null || echo "?")

    local n_agents n_commands n_skills n_scripts n_templates
    # Exclude leading-underscore files (specs like _gate-contract.md are
    # not agents). Same rule as `pe docs check` — keeps counts consistent
    # across the two commands and with plugin.json's advertised inventory.
    n_agents=$(find "$ENGINE_DIR/agents" -maxdepth 1 -name '*.md' ! -name '_*' 2>/dev/null | wc -l | tr -d ' ')
    n_commands=$(find "$ENGINE_DIR/commands" -maxdepth 1 -name '*.md' ! -name '_*' 2>/dev/null | wc -l | tr -d ' ')
    n_skills=$(find "$ENGINE_DIR/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    n_scripts=$(find "$ENGINE_DIR/scripts" -maxdepth 1 -type f -name '*' 2>/dev/null | wc -l | tr -d ' ')
    n_templates=$(find "$ENGINE_DIR/templates" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')

    cat <<EOF
8colors-process-engine v$VERSION

  Engine dir:   $ENGINE_DIR
  HEAD:         $head_short ($head_date by $head_author)
  Full SHA:     $head

  Inventory:
    Agents:     $n_agents
    Commands:   $n_commands
    Skills:     $n_skills
    Scripts:    $n_scripts
    Templates:  $n_templates

  Useful next steps:
    pe install <project>    install into another project
    pe upgrade              git pull + diff changes
    pe doctor <project>     diagnose a project's install
EOF
}

cmd_doctor() {
    # pe_doctor.py has advertised --json in its own --help since v0.51.0,
    # but cmd_doctor read $1 as the project path, so `pe doctor --json .`
    # answered "ERROR: --json does not exist". Delegate straight to the
    # checker in that mode — the symlink section above is shell-formatted
    # and has no JSON shape to contribute.
    if [ "${1:-}" = "--json" ]; then
        shift
        local jpy; jpy="$(pe_python)" || exit 1
        exec "$jpy" "$ENGINE_DIR/scripts/pe_doctor.py" "${1:-.}" \
            --engine "$ENGINE_DIR" --json
    fi

    local target="${1:-}"
    local broken=0
    local hooks_unreachable=0

    if [ -z "$target" ]; then
        echo "Engine self-check at $ENGINE_DIR"
        echo "  engine version: $VERSION"
        for f in VERSION plugin.json scripts/install.sh scripts/install_launchd.sh \
                 scripts/research_index.py; do
            if [ ! -e "$ENGINE_DIR/$f" ]; then
                echo "  ✗ MISSING: $f"
                broken=$((broken+1))
            fi
        done
        if [ $broken -eq 0 ]; then
            echo "  ✓ Engine repo intact"
        fi
        # `return $broken` when $broken>0 would exceed the 0-255 shell
        # exit-code range on a hypothetical mass-corruption; normalise to 1.
        [ $broken -gt 0 ] && return 1 || return 0
    fi

    if [ ! -d "$target" ]; then
        echo "ERROR: $target does not exist" >&2
        return 1
    fi

    echo "Checking project install at $target"
    echo "  engine version: $VERSION"
    echo ""

    # Check symlinks resolve
    for link in "$target/.claude/agents"/*.md \
                "$target/.claude/commands"/*.md \
                "$target/scripts/research_index.py" \
                "$HOME/.claude/skills/start-session/SKILL.md" \
                "$HOME/.claude/skills/end-session/SKILL.md"; do
        if [ -L "$link" ]; then
            if [ ! -e "$link" ]; then
                echo "  ✗ BROKEN symlink: $link"
                broken=$((broken+1))
            fi
        elif [ ! -e "$link" ]; then
            # Not a symlink and doesn't exist; may be intentional (project
            # ejected this file). Don't flag.
            :
        fi
    done

    # Check .process-engine.yaml exists
    if [ ! -f "$target/.process-engine.yaml" ]; then
        echo "  ⚠ Missing .process-engine.yaml — re-run 'pe install' to create it"
    fi

    # E1.c.1 — check user-global agent collisions from THIS project's
    # perspective. For each engine agent, classify:
    #   (a) project-local symlink to engine        → ✓ healthy
    #   (b) project-local file/symlink to something else → ⚠ project-overridden
    #   (c) no project-local file, but user-global regular file exists
    #       AND differs from engine                → ✗ SHADOWED by stale copy
    #   (d) no project-local + no user-global      → ⚠ engine agent missing
    #                                                from this project's
    #                                                resolution (run pe install)
    local shadowed_count=0
    local missing_count=0
    declare -a shadowed_names=()
    declare -a missing_names=()
    for engine_agent in "$ENGINE_DIR"/agents/*.md; do
        local name; name="$(basename "$engine_agent")"
        # Skip _-prefixed spec files (e.g. _gate-contract.md).
        case "$name" in _*) continue ;; esac
        local project_local="$target/.claude/agents/$name"
        local user_global="$HOME/.claude/agents/$name"
        if [ -L "$project_local" ]; then
            # symlink — check it points at our engine
            local resolved; resolved=$(readlink "$project_local")
            if [ "$resolved" != "$engine_agent" ]; then
                echo "  ⚠ Project-local $name symlinks to $resolved (not this engine)"
            fi
            # healthy or wrong-engine — either way, user-global is not in play
            continue
        elif [ -f "$project_local" ]; then
            # regular file in project — project author chose to fork. Not a
            # collision we manage.
            continue
        fi
        # No project-local file for this engine agent.
        if [ -e "$user_global" ] && [ ! -L "$user_global" ]; then
            if ! cmp -s "$engine_agent" "$user_global" 2>/dev/null; then
                shadowed_count=$((shadowed_count+1))
                shadowed_names+=("$name")
            fi
        else
            missing_count=$((missing_count+1))
            missing_names+=("$name")
        fi
    done

    # Per-agent freshness summary — always print so operator knows the check ran.
    local engine_agent_count; engine_agent_count=$(find "$ENGINE_DIR/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    local fresh_count=$((engine_agent_count - shadowed_count - missing_count))
    echo ""
    echo "  Per-agent freshness: ${fresh_count}/${engine_agent_count} up to date (${shadowed_count} shadowed, ${missing_count} missing)"

    if [ $shadowed_count -gt 0 ]; then
        echo ""
        echo "  ✗ SHADOWED by stale user-global files (${shadowed_count}):"
        for n in "${shadowed_names[@]}"; do
            echo "      ~/.claude/agents/$n  (regular file, differs from engine)"
        done
        echo "    Fix: re-run 'pe install $target' to add project-local symlinks."
        echo "    See docs/E1_b_SUBAGENT_MODEL_HONORING.md for the failure mode."
        broken=$((broken+shadowed_count))
    fi

    if [ $missing_count -gt 0 ]; then
        echo ""
        echo "  ⚠ Engine agents not installed in this project (${missing_count}):"
        for n in "${missing_names[@]}"; do
            echo "      $n"
        done
        echo "    Fix: 'pe install $target' to symlink them."
    fi

    # Check RAG deps if research_index.py is installed
    if [ -e "$target/scripts/research_index.py" ]; then
        local py
        if [ -x "$target/.venv/bin/python3" ]; then
            py="$target/.venv/bin/python3"
        else
            py="python3"
        fi
        if ! $py -c "import numpy" 2>/dev/null; then
            echo "  ⚠ RAG: numpy not installed in $py — pip install numpy"
        fi
        if ! $py -c "import google.generativeai" 2>/dev/null; then
            echo "  ⚠ RAG: google-generativeai not installed in $py — pip install google-generativeai"
        fi
        if [ -z "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ]; then
            echo "  ⚠ RAG: GEMINI_API_KEY env var not set — get a free key at aistudio.google.com/apikey"
        fi
    fi

    # Hook reachability (v0.51.0). `pe verify` proves the engine's files
    # are unmodified; it is silent about whether any of them RUN. A project
    # that hand-rolls .git/hooks/pre-commit silently replaces the framework
    # dispatcher, and every hook in .pre-commit-config.yaml becomes
    # decoration. Origyn 2026-09-04: 10 engine hooks configured, 0 executed,
    # and CLAUDE.md reached 80,437 B against claude-md-size.sh's own 20,000 B
    # hard limit — the guard was configured and unreachable the whole time.
    if [ -f "$ENGINE_DIR/scripts/pe_doctor.py" ]; then
        local dpy; dpy="$(pe_python 2>/dev/null)" || dpy=""
        if [ -n "$dpy" ]; then
            echo ""
            "$dpy" "$ENGINE_DIR/scripts/pe_doctor.py" "$target" \
                --engine "$ENGINE_DIR" || hooks_unreachable=1
        fi
    fi

    # launchd check (macOS only)
    if [ "$(uname)" = "Darwin" ] && [ -f "$target/.process-engine.yaml" ]; then
        local org_tag
        # yaml_get from scripts/_yaml.sh — one shared reader (P2.6)
        . "$ENGINE_DIR/scripts/_yaml.sh"
        org_tag=$(yaml_get project.org_tag "$target/.process-engine.yaml")
        if [ -n "$org_tag" ]; then
            local plist="$HOME/Library/LaunchAgents/com.${org_tag}.ceo.weekly.plist"
            if [ -f "$plist" ]; then
                if launchctl list 2>/dev/null | grep -q "com.${org_tag}.ceo.weekly"; then
                    echo "  ✓ launchd: com.${org_tag}.ceo.weekly is loaded"
                else
                    echo "  ⚠ launchd: plist exists at $plist but not bootstrapped — run:"
                    echo "      launchctl bootstrap gui/\$(id -u) $plist"
                fi
            fi
        fi
    fi

    echo ""
    if [ $broken -eq 0 ]; then
        if [ "$hooks_unreachable" -eq 1 ]; then
            echo "✗ Symlinks are fine, but the engine's hooks do not run (see above)."
            return 1
        fi
        echo "✓ No broken symlinks. Project install is healthy."
    else
        echo "✗ $broken broken symlink(s). Run 'pe install $target' to repair."
        [ "$hooks_unreachable" -eq 1 ] && echo "✗ The engine's hooks also do not run (see above)."
        return 1
    fi
}

cmd_eject() {
    local target="${1:?Usage: pe eject <project>}"
    if [ ! -d "$target" ]; then
        echo "ERROR: $target does not exist" >&2
        return 1
    fi

    echo "About to eject 8colors-process-engine from $target"
    echo ""
    echo "WILL REMOVE (project-local):"
    local removable=()
    for f in "$target/.claude/agents"/*.md \
             "$target/.claude/commands"/*.md \
             "$target/scripts/research_index.py"; do
        if [ -L "$f" ]; then
            # Only count symlinks pointing INTO this engine (anchored path
            # match — substring grep could match unrelated links)
            case "$(readlink "$f" 2>/dev/null)" in
                "$ENGINE_DIR"/*) removable+=("$f") ;;
            esac
        fi
    done
    if [ ${#removable[@]} -eq 0 ]; then
        echo "  (no engine-managed symlinks found in $target)"
    else
        for f in "${removable[@]}"; do
            echo "    $f → $(readlink "$f")"
        done
    fi
    echo ""
    echo "WILL KEEP (project may have edited):"
    echo "    $target/.process-engine.yaml (if exists)"
    echo "    $target/docs/templates/* (copies, not symlinks)"
    echo "    $target/docs/process-engine/* (copies, not symlinks)"
    echo ""
    echo "WILL NOT TOUCH (system-level — operator removes via launchctl/systemctl):"
    echo "    ~/.claude/skills/{start,end}-session/  (used by other projects too)"
    echo "    ~/Library/LaunchAgents/com.*.ceo.*.plist (macOS launchd)"
    echo "    ~/.config/systemd/user/*-ceo-weekly.* (Linux systemd)"
    echo "    Windows scheduled tasks"
    echo ""

    read -r -p "Proceed with eject? [y/N] " confirm
    # case-match, not ${var,,} — stock macOS bash 3.2 lacks lowercasing
    case "$confirm" in
        y|Y|yes|YES|Yes) ;;
        *)
            echo "Cancelled."
            return 1
            ;;
    esac

    local removed=0
    # guard empty-array expansion — errors under set -u on bash <= 4.3
    if [ ${#removable[@]} -gt 0 ]; then
        for f in "${removable[@]}"; do
            rm "$f"
            removed=$((removed+1))
        done
    fi

    echo "✓ Ejected $removed engine-managed symlinks from $target."
    echo ""
    echo "If you want to also remove ~/.claude/skills/{start,end}-session/ (user-global),"
    echo "run: rm -rf ~/.claude/skills/start-session ~/.claude/skills/end-session"
    echo ""
    echo "If launchd / systemd / Task Scheduler jobs were installed, refer to"
    echo "templates/<platform>/README.md for the uninstall commands."
}

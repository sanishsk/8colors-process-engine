#!/usr/bin/env bash
# _exempt-paths.sh — shared, fail-closed path exemption for the gating hooks.
#
# Two hooks gate `git commit` on the paths in the staged diff:
#
#   pre-commit-envelope-check   any non-empty diff → needs a code-review envelope
#   security-review-trailer     paths matching an auth/payment regex → needs a
#                               Security-reviewed trailer
#
# Both had the same false-positive shape. The review gate fired on a CLAUDE.md
# typo; the security gate fired on `SessionDetail.swift` in a workout app,
# because "session" is a domain noun there and the regex is a substring match
# on paths — and on every `*-security.test.py.template` the engine itself
# installs into the adopter. An adopter's answer to either is a local wrapper
# that re-implements the block with a path filter, and each wrapper draws the
# line differently.
#
# So one mechanism, sourced by both: an operator-declared EXEMPT regex.
#
# The polarity is the design. An include list ("gate only these paths") fails
# OPEN — a directory nobody added to the regex sails through unreviewed,
# silently and permanently. An exempt list fails CLOSED — anything unlisted is
# still gated, so a forgotten path is a false positive, never a missed review.
#
# Resolution: <ENV_VAR> → <yaml key> in .process-engine.yaml → <default>.
# Env stays highest because ENGINE_*_PATHS already lives on adopters'
# pre-commit entry lines.
#
# Every ambiguity resolves to "not exempt":
#   * empty value          exempts nothing — a half-finished edit is not a
#                          wildcard
#   * unparseable yaml     exempts nothing
#   * INVALID regex        exempts nothing — grep -v on a bad pattern emits
#                          empty output AND an error, and empty output is also
#                          what "everything is exempt" looks like; the error
#                          exit is checked separately so a typo cannot open a
#                          gate
#
# Exemption is per-COMMIT, not per-file. A commit touching one exempt path and
# one gated path is gated, because git lands the commit whole.
#
# Contract (source this file, then call):
#
#   pe_exempt_regex <ENV_VAR_NAME> <yaml.key> [<default-regex>]
#       Echoes the effective exemption regex, or nothing if none applies.
#       Reads $CLAUDE_PROJECT_DIR/.process-engine.yaml, falling back to $PWD.
#
#   pe_unexempt_paths <regex> <<< "$PATHS"
#       Echoes the subset of newline-separated PATHS that do NOT match
#       <regex>. On an invalid regex echoes ALL of them (fail closed) and
#       prints one line to stderr. An empty <regex> echoes all of them.

# yaml_get lives in scripts/_yaml.sh. Source it if the caller has not.
if ! declare -F yaml_get >/dev/null 2>&1; then
    _PE_EXEMPT_ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || _PE_EXEMPT_ENGINE_DIR=""
    if [ -n "$_PE_EXEMPT_ENGINE_DIR" ] && [ -f "$_PE_EXEMPT_ENGINE_DIR/scripts/_yaml.sh" ]; then
        # shellcheck source=../scripts/_yaml.sh
        . "$_PE_EXEMPT_ENGINE_DIR/scripts/_yaml.sh"
    fi
fi

pe_exempt_regex() {   # $1=ENV_VAR_NAME  $2=yaml.key  [$3=default]
    local env_name="$1" key="$2" default="${3:-}" val=""
    val="${!env_name:-}"
    if [ -z "$val" ]; then
        local root="${CLAUDE_PROJECT_DIR:-$PWD}"
        local cfg="$root/.process-engine.yaml"
        if [ -f "$cfg" ] && declare -F yaml_get >/dev/null 2>&1; then
            val=$(yaml_get "$key" "$cfg" 2>/dev/null || true)
        fi
    fi
    printf '%s' "${val:-$default}"
}

pe_unexempt_paths() {   # $1=regex ; stdin = newline-separated paths
    local regex="$1" paths rest rc
    paths=$(cat)
    [ -z "$paths" ] && return 0
    if [ -z "$regex" ]; then
        printf '%s\n' "$paths"
        return 0
    fi
    # grep: 0 matched, 1 no match, >=2 error. Only 0 and 1 are answers.
    set +e
    rest=$(printf '%s\n' "$paths" | grep -vE -- "$regex" 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -ge 2 ]; then
        echo "exempt-paths: invalid regex '$regex' — exempting nothing" >&2
        printf '%s\n' "$paths"
        return 0
    fi
    [ -n "$rest" ] && printf '%s\n' "$rest"
    return 0
}

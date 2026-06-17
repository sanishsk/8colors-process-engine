#!/usr/bin/env bash
# stacking-rule-check — pre-push hook that detects foundational changes
# bundled into a slot-stack and blocks the push.
#
# Process v2 (locked 2026-05-18 in 8CStudio) says: foundational changes
# always per-slot. Foundational = touches:
#   - core/database*.py, core/tenant_context.py
#   - RLS policies
#   - OIDC plumbing
#   - migrations that ALTER existing column types/constraints
#   - Role.ALL_MODULES
#
# This hook scans the commits being pushed against the foundational
# regex AND the number of slot trailers in commit messages. If a push
# contains BOTH (a) ≥2 distinct slot IDs and (b) any foundational file
# change, it blocks.
#
# Override via the env var ENGINE_FOUNDATIONAL_REGEX.

set -euo pipefail

# pre-push hook contract: stdin lines of "<local_ref> <local_sha> <remote_ref> <remote_sha>"
# For each, scan the new commits.

DEFAULT_FOUNDATIONAL='core/database.*\.py|core/tenant_context\.py|RLS_POLICIES|/oidc/|migrations/.*ALTER|Role\.ALL_MODULES|core/blueprints\.py'
FOUNDATIONAL_RE="${ENGINE_FOUNDATIONAL_REGEX:-$DEFAULT_FOUNDATIONAL}"

while read -r local_ref local_sha remote_ref remote_sha; do
    # Skip branch deletions
    if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
        continue
    fi

    # If remote doesn't exist yet, compare to merge-base with origin/master/main
    if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
        base=$(git merge-base "$local_sha" origin/master 2>/dev/null \
            || git merge-base "$local_sha" origin/main 2>/dev/null \
            || echo "")
        if [ -z "$base" ]; then
            continue
        fi
        range="$base..$local_sha"
    else
        range="$remote_sha..$local_sha"
    fi

    # Count distinct slot IDs (heuristic: tokens matching ^[0-9][A-Z]?(\.[0-9.]+)? in commit subjects)
    slot_ids=$(git log --format=%s "$range" 2>/dev/null \
        | grep -oE '[0-9]+[A-Z]?\.[0-9][0-9.]*' \
        | sort -u | wc -l | tr -d ' ')

    # Foundational paths changed in this range
    foundational_hits=$(git diff --name-only "$range" 2>/dev/null \
        | grep -E "$FOUNDATIONAL_RE" || true)

    if [ "$slot_ids" -ge 2 ] && [ -n "$foundational_hits" ]; then
        cat >&2 <<EOF
✗ stacking-rule-check: this push contains a slot-stack ($slot_ids slot IDs)
  AND foundational changes:

$(echo "$foundational_hits" | sed 's/^/    /')

Process v2 rule (8colors-process-engine doctrine):

  Foundational changes always per-slot. Foundational =
  RLS, auth, OIDC, core/database*.py, Role.ALL_MODULES,
  or migrations ALTERing existing column types/constraints.

Split the foundational commit(s) into their own branch and ship
separately.

To bypass for a genuine hotfix: git push --no-verify
(log the bypass in your session log).
EOF
        exit 1
    fi
done

exit 0

#!/usr/bin/env python3
"""skills_audit — inventory + stocktake report for the operator's
Claude Code skill/command sprawl (P7.4, v0.16.0).

Runs against ~/.claude/skills/ and ~/.claude/commands/ (or an override
path via --home). Reports:

  1. Total counts + duplicates between skills and commands
     (a name in both is the strongest "consolidate me" signal).
  2. Engine-owned vs external-owned. "Engine-owned" = files whose
     name appears in the engine's commands/ directory OR is one of
     the engine's shipped skills (start-session / end-session).
  3. Project-local duplicates in a target adopter project
     (--project <path>): any skill/command name that ALSO lives in
     <project>/.claude/skills/ or <project>/.claude/commands/.
  4. Stocktake recommendation: the engine's opinion of a curated
     core set (documented in docs/SKILLS.md, with each skill's source); everything outside
     that list is candidate-for-review.

Zero mutation. This tool never deletes or moves files. It surfaces the
sprawl; the operator prunes on their own machine.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parent.parent

# Skills the engine ships to ~/.claude/skills/ (user-global).
ENGINE_SHIPPED_SKILLS = {"start-session", "end-session"}

# The engine's curated core set — the opinionated shortlist. Adopters
# may keep more, but anything OUTSIDE this list should have a clear
# reason to stay. See docs/SKILLS.md for the rationale per row.
CORE_SKILLS = {
    # Session hygiene (engine-shipped)
    "start-session",
    "end-session",
    # Universal engineering discipline
    "coding-standards",
    "tdd-workflow",
    "verification-loop",
    "search-first",
    "security-review",
    "security-scan",
    "strategic-compact",
    # Language patterns — keep the one you actively use; delete the rest
    "python-patterns",
    "python-testing",
    # Frontend/backend patterns (universal SaaS surface)
    "backend-patterns",
    "frontend-patterns",
    "api-design",
    "database-migrations",
    "deployment-patterns",
    "docker-patterns",
    "e2e-testing",
    # Frontend design generator (anthropics/skills; design-critic is the gate)
    "frontend-design",
    # Decision rounds before planning (mattpocock/skills; v0.56.0)
    "grilling",
}


def list_dir(path: Path) -> list[str]:
    if not path.is_dir():
        return []
    out = []
    for entry in sorted(path.iterdir()):
        if entry.name.startswith("."):
            continue
        if entry.is_dir():
            out.append(entry.name)
        elif entry.suffix == ".md":
            out.append(entry.stem)
    return out


def classify(name: str, engine_commands: set[str]) -> str:
    if name in ENGINE_SHIPPED_SKILLS:
        return "engine-shipped"
    if name in engine_commands:
        return "engine-command"
    if name in CORE_SKILLS:
        return "core-recommended"
    return "external"


def report_collisions(skills: list[str], cmds: list[str]) -> list[str]:
    """[1] A name that is both a skill and a command: strongest consolidation signal."""
    overlap = sorted(set(skills) & set(cmds))
    if overlap:
        print(
            f"[1] NAME COLLISIONS — {len(overlap)} name(s) exist as BOTH "
            "a skill and a command:"
        )
        for name in overlap:
            print(f"  · {name}")
        print(
            "  Pick one (skill for reusable knowledge, command for a "
            "one-line invocation) and delete the duplicate.\n"
        )
    else:
        print("[1] ✓ No skill/command name collisions.\n")
    return overlap


def report_classification(skills: list[str], engine_commands: set[str]) -> dict[str, list[str]]:
    """[2] Bucket every skill; returns the buckets for the recommendation."""
    buckets: dict[str, list[str]] = {
        "engine-shipped": [], "engine-command": [], "core-recommended": [], "external": [],
    }
    for name in skills:
        buckets[classify(name, engine_commands)].append(name)

    def section(label: str, names: list[str], suffix: str = "") -> None:
        print(f"    {label}{len(names)}")
        for n in names:
            print(f"      · {n}{suffix.format(n=n)}")

    print(f"[2] SKILLS CLASSIFICATION ({len(skills)} total):")
    section("engine-shipped (~/.claude/skills):  ", buckets["engine-shipped"])
    section("core-recommended (docs/SKILLS.md):  ", buckets["core-recommended"])
    section("engine-command shadowed as a skill: ", buckets["engine-command"],
            "  (engine ships this as commands/{n}.md)")
    section("external / uncurated:                ", buckets["external"])
    print()
    return buckets


def report_project_duplicates(project_arg: str, skills: list[str], cmds: list[str]) -> None:
    """[3] Names present both user-global and in the adopter project."""
    project = Path(project_arg).expanduser().resolve()
    dup_skills = sorted(set(skills) & set(list_dir(project / ".claude" / "skills")))
    dup_cmds = sorted(set(cmds) & set(list_dir(project / ".claude" / "commands")))
    print(f"[3] PROJECT-LOCAL DUPLICATES ({project}):")
    if dup_skills:
        print(f"    Skills present at BOTH user-global AND project-local ({len(dup_skills)}):")
        for n in dup_skills:
            print(f"      · {n}")
        print(
            "    Project-local shadows the user-global for that project only. "
            "If the intent is engine-owned, delete the user-global copy or "
            "wire it via `pe install` symlinks.\n"
        )
    if dup_cmds:
        print(f"    Commands present at BOTH user-global AND project-local ({len(dup_cmds)}):")
        for n in dup_cmds:
            print(f"      · {n}")
        print()
    if not dup_skills and not dup_cmds:
        print("    ✓ No project/user-global duplicates.\n")


def report_recommendation(buckets: dict[str, list[str]]) -> None:
    """[4] Keep vs review counts, with the reasoning when there is anything to review."""
    keep = len(buckets["engine-shipped"]) + len(buckets["core-recommended"])
    review = len(buckets["engine-command"]) + len(buckets["external"])
    print("[4] STOCKTAKE RECOMMENDATION:")
    print(f"    keep as-is (engine-shipped + core):  {keep}")
    print(f"    candidates for review/removal:       {review}")
    if review > 0:
        print(
            "\n    Rationale: docs/SKILLS.md lists the engine's opinion of "
            "the core skill set. Anything OUTSIDE that list is either\n"
            "      (a) a language pattern for a language you don't use,\n"
            "      (b) a stale tool/experiment left behind, or\n"
            "      (c) genuinely useful and worth documenting in your\n"
            "          project's session.yaml so future-you knows why it stays."
        )
    print()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit ~/.claude/skills/ + ~/.claude/commands/ sprawl (P7.4).",
    )
    parser.add_argument("--home", default=os.environ.get("HOME"), help="Home dir (default: $HOME)")
    parser.add_argument("--project", default=None,
                        help="Adopter project path. Flags project-local duplicates.")
    args = parser.parse_args()

    home = Path(args.home).expanduser().resolve()
    skills_dir = home / ".claude" / "skills"
    cmds_dir = home / ".claude" / "commands"
    skills = list_dir(skills_dir)
    cmds = list_dir(cmds_dir)
    engine_commands = {f.stem for f in (ENGINE_DIR / "commands").glob("*.md")}

    print("skills-audit — Claude Code skill/command sprawl report")
    print(f"  home:            {home}")
    print(f"  skills dir:      {skills_dir}  ({len(skills)} entries)")
    print(f"  commands dir:    {cmds_dir}  ({len(cmds)} entries)")
    print(f"  engine commands: {len(engine_commands)} in {ENGINE_DIR}/commands/")
    print()

    overlap = report_collisions(skills, cmds)
    buckets = report_classification(skills, engine_commands)
    if args.project:
        report_project_duplicates(args.project, skills, cmds)
    report_recommendation(buckets)

    # Exit non-zero if anything worth action.
    return 1 if overlap or buckets["engine-command"] else 0


if __name__ == "__main__":
    sys.exit(main())

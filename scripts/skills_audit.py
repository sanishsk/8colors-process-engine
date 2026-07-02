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
     "core-20" (documented in docs/SKILLS.md); everything outside
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

# The engine's curated "core-20" — the opinionated shortlist. Adopters
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
    # Frontend design polish
    "frontend-design",
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


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit ~/.claude/skills/ + ~/.claude/commands/ sprawl (P7.4).",
    )
    parser.add_argument(
        "--home",
        default=os.environ.get("HOME"),
        help="Home dir (default: $HOME)",
    )
    parser.add_argument(
        "--project",
        default=None,
        help="Adopter project path. Flags project-local duplicates.",
    )
    args = parser.parse_args()

    home = Path(args.home).expanduser().resolve()
    skills_dir = home / ".claude" / "skills"
    cmds_dir = home / ".claude" / "commands"

    skills = list_dir(skills_dir)
    cmds = list_dir(cmds_dir)

    engine_commands = {
        f.stem for f in (ENGINE_DIR / "commands").glob("*.md")
    }

    # ─── report ────────────────────────────────────────────────────
    print("skills-audit — Claude Code skill/command sprawl report")
    print(f"  home:            {home}")
    print(f"  skills dir:      {skills_dir}  ({len(skills)} entries)")
    print(f"  commands dir:    {cmds_dir}  ({len(cmds)} entries)")
    print(f"  engine commands: {len(engine_commands)} in {ENGINE_DIR}/commands/")
    print()

    # 1. skill/command name overlap = strongest consolidation signal
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

    # 2. classify skills
    core_present, ext_skills, engine_shipped_present, engine_cmd_shadowed = [], [], [], []
    for name in skills:
        cat = classify(name, engine_commands)
        if cat == "engine-shipped":
            engine_shipped_present.append(name)
        elif cat == "engine-command":
            engine_cmd_shadowed.append(name)
        elif cat == "core-recommended":
            core_present.append(name)
        else:
            ext_skills.append(name)

    print(f"[2] SKILLS CLASSIFICATION ({len(skills)} total):")
    print(f"    engine-shipped (~/.claude/skills):  {len(engine_shipped_present)}")
    for n in engine_shipped_present:
        print(f"      · {n}")
    print(f"    core-recommended (docs/SKILLS.md):  {len(core_present)}")
    for n in core_present:
        print(f"      · {n}")
    print(f"    engine-command shadowed as a skill: {len(engine_cmd_shadowed)}")
    for n in engine_cmd_shadowed:
        print(f"      · {n}  (engine ships this as commands/{n}.md)")
    print(f"    external / uncurated:                {len(ext_skills)}")
    for n in ext_skills:
        print(f"      · {n}")
    print()

    # 3. project-local duplicates
    if args.project:
        project = Path(args.project).expanduser().resolve()
        proj_skills = list_dir(project / ".claude" / "skills")
        proj_cmds = list_dir(project / ".claude" / "commands")
        dup_skills = sorted(set(skills) & set(proj_skills))
        dup_cmds = sorted(set(cmds) & set(proj_cmds))
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

    # 4. recommendation
    keep = len(engine_shipped_present) + len(core_present)
    review = len(engine_cmd_shadowed) + len(ext_skills)
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

    # Exit non-zero if anything worth action.
    if overlap or engine_cmd_shadowed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

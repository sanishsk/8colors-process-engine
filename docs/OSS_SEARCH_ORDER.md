# OSS-First Search Order — Mandatory Doctrine

Before proposing custom-built code for ANY feature, ANY component, ANY module:

1. Check `docs/INTEGRATIONS.md` in the calling project — what's already in this stack?
2. Check https://github.com/punkpeye/awesome-mcp-servers — community-curated MCP list
3. Check https://glama.ai/mcp/servers — 23,968+ indexed MCP servers (as of 2026-05-21)
4. Check PyPI (pypi.org) or npm (npmjs.com) for libraries
5. Build custom ONLY if:
   - Nothing in 1–4 fits the need
   - Licensing blocks commercial use
   - Integration cost demonstrably exceeds rebuild cost

This rule is non-negotiable. Every brief-writer brief and every researcher eval
must reference this doctrine explicitly.

Source references:
- MODULAR_REDESIGN_PLAN.md §3 (OSS-first tool inventory)
- STUDIO_PLATFORM_DESIGN.md §7 (open-source / MCP-first tool inventory)
- CLAUDE.md §6 (tool selection rules)

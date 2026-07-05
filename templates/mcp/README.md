# MCP server templates (A9 — testing-agent integration)

Registration snippets for MCP servers the engine's gate agents call so
they don't re-implement heavy test execution. Copied into adopters at
`docs/templates/mcp/` by `pe install`.

## ai-testing-agent

The standalone [ai-testing-agent](../../docs/AI_TESTING_AGENT_VALIDATION.md)
(38k LOC, 685 passing tests) exposes its capabilities as **10 MCP tools**.
The engine **orchestrates and owns verdicts**; the testing-agent
**executes** (fuzz, resilience, visual diff, api-diff, security). This is
engine model (A) — call it, don't duplicate it.

### Install (one-time, in the testing-agent repo)

```bash
cd /path/to/ai-testing-agent
python -m pip install -e '.[mcp-server]'   # installs the `ai-test-mcp` console script
```

Verify the server lists its tools without starting it:

```bash
ai-test mcp tools
```

### Register (in the consuming project)

Merge `ai-testing-agent.mcp.json.template` into your project's `.mcp.json`
(strip the `//`-prefixed comment keys — they document the env vars, they
are not valid config). If the `ai-test-mcp` console script isn't on PATH,
use the CLI form instead:

```json
{
  "mcpServers": {
    "ai-testing-agent": {
      "command": "ai-test",
      "args": ["mcp", "serve"]
    }
  }
}
```

Tools then appear to agents as `mcp__ai-testing-agent__*`.

### The 8 tools and which engine gate consumes them

| MCP tool | Engine consumer | Gap it fills (ENHANCEMENT_PLAN_V2) |
|---|---|---|
| `compare_api_specs` | code-reviewer / api-diff step | **S3** API-contract breaking-change gate (replaces planned oasdiff build) |
| `run_security_scan` | security-reviewer | **S3** OWASP API Top-10 execution (payload runner; SAST stays S1/semgrep) |
| `run_dast_scan` | security-reviewer | deep DAST (OWASP ZAP baseline) — beyond `run_security_scan`'s targeted probes |
| `run_resilience_tests` | performance-reviewer | **PF6** resilience/load foundation |
| `run_visual_regression` | design-critic | **D3** visual regression (SSIM/perceptual-hash + baselines) |
| `run_pipeline` | e2e-runner | smoke/comprehensive test execution |
| `extract_apis` / `list_modules` / `test_intent` | planner / e2e-runner | endpoint + module discovery for scoping |
| `get_test_history` | retrospective-agent | flaky-test + perf-regression trends |

> **D3 (visual regression)** is surfaced as the `run_visual_regression`
> MCP tool (built on `visual_tester` + `advanced_comparison`). The engine-
> side wiring shipped v0.46.0: `agents/design-critic.md` §A9.3 workflow
> documents when to call the tool, the SSIM/phash threshold ladder
> (≥0.95 PASS, 0.90–0.95 WARN, <0.90 FAIL), and the four finding rules
> (`a9-3-perceptual-pass` / `a9-3-perceptual-drift` /
> `a9-3-perceptual-regression` / `a9-3-perceptual-check-skipped`).
> Adopters override via
> `design_critic.perceptual_similarity_threshold` in `.process-engine.yaml`.

### Secrets

Never hardcode `AI_TEST_AUTH_PASSWORD` (or any real credential) in
`.mcp.json` — it is committed. Source it from the environment or a secret
manager. Use a dedicated throwaway test account, never a production login.

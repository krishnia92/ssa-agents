# SSA Agents — Swedish Social Insurance Agency demo (WSO2 Integrator + Agent Manager)

Four AI agents for a Försäkringskassan-style demo, built in Ballerina (WSO2 Integrator)
and deployed on WSO2 Agent Manager (AMP). All data is **fictional mock data** held in memory.

| Folder | Type | What it does | Endpoint |
|---|---|---|---|
| `parental-benefit-agent` | Chat | Remaining parental benefit days, daily amount estimate, report a VAB day | `POST /chat` :8000 |
| `sickness-benefit-agent` | Chat | Eligibility (who pays, certificate needed), claim status, rehab checkpoint, notify sickness | `POST /chat` :8000 |
| `case-status-agent` | Chat | Case status, missing documents, next payment, register a sent document | `POST /chat` :8000 |
| `claim-triage-agent` | API | Rule checks + LLM recommendation: queue, priority, rationale. Human always decides | `POST /triage` :8000 |

---

## LLM choice

Each agent has `gemini_provider.bal`, which picks the model at startup:

- `geminiApiKey` set → **Google Gemini** (`gemini-3.8-flash` by default) via Gemini's OpenAI-compatible API. Free keys from Google AI Studio work.
- otherwise `openAiApiKey` → **OpenAI gpt-4o** via the official `ballerinax/ai.openai` connector.

`libs/noop-generator.jar` is a 1 KB helper that lets the custom Gemini provider satisfy Ballerina's model interface
(its unused `generate` method). Keep it in the repo; `Ballerina.toml` references it.

## Data sources

Every agent reads from in-memory mock data at the top of its `main.bal`, so the demo runs
with no backend. In a real deployment each mock would be replaced by an API call built with
WSO2 Integrator connectors. Only the tool function bodies change; the agent stays the same.

| Agent | Mock data in this repo | Real source it stands in for (production) |
|---|---|---|
| Parental benefit | Parents, children, remaining days, income; VAB reports | Parental-benefit case system; population register (family relations); income data from the Tax Agency |
| Sickness benefit | Insured persons, employment type, income; sickness claims, certificates, rehab plans | Sickness-benefit case system; electronic medical certificates from healthcare; employer data |
| Case & payment status | Cases, status, missing documents, decisions; payments | Case management system; document archive; payment system |
| Claim triage | Required documents per benefit; claimant history (registration date, prior claims) | Case history; population/insurance register; document management |

Benefit rules and amounts are **simplified demo figures**, not official rates.

### Test identities

| Agent | IDs to use |
|---|---|
| Parental benefit | `CIT-1001` Anna Lindqvist (children CH-1 Elsa, CH-2 Oskar), `CIT-1002` Johan Berg (CH-3 Maja) |
| Sickness benefit | `CIT-2001` employee with an approved claim, `CIT-2002` self-employed, `CIT-2003` income below minimum |
| Case status | `CIT-3001` (housing allowance awaiting documents + decided parental case), `CIT-3002` |
| Claim triage | `CIT-4001` clean history, `CIT-4002` registered recently, `CIT-4003` overlapping claim + recent rejection |

---

## 1. Open and build in WSO2 Integrator

1. Install **WSO2 Integrator** (VS Code based) and let it install Ballerina **2201.13.x**.
2. **File → Open Folder** → pick one agent folder, e.g. `SSA/parental-benefit-agent`
   (open one agent at a time — each folder is its own Ballerina project).
3. The **Design view** shows the HTTP service (`/chat` or `/triage`) and the AI agent.
   Click the agent node to see its **instructions**, **model provider (Gemini or OpenAI)** and **tools**.
4. Create `Config.toml` from the example and add your **Gemini** key (free, from aistudio.google.com) — or an OpenAI key. It is git-ignored:
   ```bash
   cp Config.toml.example Config.toml   # then edit the key
   ```
5. Click **Run** (or `bal run`). The service starts on `http://localhost:8000`.
6. Test with **Try It** in the Integrator, or curl:
   ```bash
   curl -s localhost:8000/chat -H 'content-type: application/json' \
     -d '{"session_id":"s1","message":"What days do I have left? CIT-1001"}'
   ```

### Building a new agent yourself in WSO2 Integrator (same pattern)

1. **Create Integration** → add an **HTTP Service** on port `8000` with a `POST /chat` resource.
   Do **not** use the "AI Chat Agent" artifact's built-in listener: it expects `sessionId`,
   but Agent Manager sends `session_id` and expects `response` back. Use the request/response
   records from these projects.
2. Inside the resource, add an **AI Agent** node: set role and instructions, choose the
   model provider (OpenAI in the palette, or reuse `gemini_provider.bal` from these projects for Gemini), and bind the API key to a `configurable`.
3. Add **tools**: each is an `isolated` function marked `@ai:AgentTool` with a doc comment.
   The doc comment is what the LLM reads, so describe parameters clearly.
   (Tip: avoid double quotes inside tool doc comments — they break the tool-schema generator.)
4. Add `import ballerinax/amp as _;` so AMP traces the agent automatically, and keep
   `observabilityIncluded = true` in `Ballerina.toml`.
5. Run locally, test, then commit.

---

## 2. Push to GitHub

Create an empty repository on GitHub (e.g. `ssa-agents`, public — or private if your AMP
has GitHub access configured), then in Terminal:

```bash
cd ~/Documents/work/AgentManager/AM/SSA
git init
git add .
git commit -m "SSA demo agents"
git branch -M main
git remote add origin https://github.com/<your-user>/ssa-agents.git
git push -u origin main
```

`Config.toml` and `target/` are git-ignored, so your key is never pushed.

---

## 3. Deploy in Agent Manager

For **each** agent: **Add Agent → Platform-Hosted Agent → Source Code**.

| Field | Value |
|---|---|
| Display Name | e.g. `Parental Benefit Assistant` |
| GitHub Repository | `https://github.com/<your-user>/ssa-agents` |
| Branch | `main` |
| App Path | `/parental-benefit-agent` (or `/sickness-benefit-agent`, `/case-status-agent`, `/claim-triage-agent`) |
| Language | `Ballerina` (no version or start command needed) |
| Port | `8000` |
| Agent Interface | **Chat Agent** for the three chat agents; **Custom API** for `claim-triage-agent` (use its `openapi.yaml`, base path `/`) |

Environment variable (all four):

| Variable | Value |
|---|---|
| `BAL_CONFIG_VAR_GEMINIAPIKEY` | your Gemini key (mark as secret) |

Optional: `BAL_CONFIG_VAR_GEMINIMODEL` (default `gemini-3.8-flash`). To use OpenAI instead, set `BAL_CONFIG_VAR_OPENAIAPIKEY` and leave the Gemini key out.

Deploy, wait for the build, then test with **Try It**. Traces appear under **Observability → Traces**.

Calling through the gateway from Terminal needs an endpoint API key from the console, sent as `x-api-key`:

```bash
curl -s -X POST http://default-default.am-gateway.localhost:19080/<agent-name>/chat \
  -H 'content-type: application/json' -H 'x-api-key: <key>' \
  -d '{"session_id":"s1","message":"What days do I have left? CIT-1001","context":{}}'
```

---

## Demo script

**Parental benefit** — "What parental benefit days do I have left? CIT-1001" → "How much per day for Elsa?" →
"Elsa was sick yesterday, report a full VAB day" → "Report VAB for Oskar today" (rejected: Oskar is 13, VAB is for children under 12) → "Report VAB for Elsa next Friday" (rejected: future date).

**Sickness benefit** — "I've been sick since 2026-09-10, who pays? CIT-2001" → "What's my claim status and rehab plan?" →
"I'm self-employed, CIT-2002, sick since yesterday, 100 percent — notify please".

**Case status** — "What's happening with my cases? CIT-3001" → "When is my next payment?" →
"I sent the rental contract for FK-2026-1001" → "And the income statement for 2026" (case moves to in-review).

**Claim triage** — send the three examples in `openapi.yaml` (risky, clean, newResident) and compare
`recommendedQueue`, `riskFlags` and `decidedBy`. Point out the policy guardrail: the AI can never fast-track a risky claim.

# SSA Agents — AI agents for a public social insurance agency

Four AI agents for a public social insurance scenario — parental benefit, sickness benefit, case status and
claim triage — built with **Ballerina / WSO2 Integrator** and deployed on **WSO2 Agent Manager (AMP)**.
They run on Google **Gemini** (a free AI Studio key works) or OpenAI, answer in **Swedish or English**, and use
**fictional in-memory data**, so the demo needs no backend systems.

| Agent | Type | Endpoint |
|---|---|---|
| [Parental Benefit Assistant](#1-parental-benefit-assistant) | Chat | `POST /chat` :8000 |
| [Sickness Benefit Assistant](#2-sickness-benefit-assistant) | Chat | `POST /chat` :8000 |
| [Case Status Assistant](#3-case-status-assistant) | Chat | `POST /chat` :8000 |
| [Claim Triage Agent](#4-claim-triage-agent) | API | `POST /triage` :8000 |

---

## How it works

```
Citizen app / case system
        │  POST /chat  or  POST /triage
        ▼
WSO2 Agent Manager gateway  (API key, routing, tracing)
        ▼
Ballerina agent  (ballerina/ai Agent)
   ├── System prompt: role, rules, tone, language
   ├── Tools: Ballerina functions over the (mock) agency data
   └── Model: Gemini or OpenAI  ──►  the LLM decides which tools to call
```

- **Tools provide the facts, the LLM runs the conversation.** Every number, date and status comes from a tool,
  so the agent does not invent benefit data.
- **Guardrails in code.** VAB age and date limits, certificate rules, and the triage rule "never fast-track a
  risky claim" are enforced in Ballerina, not only in the prompt.
- **Observability.** `ballerinax/amp` is imported, so each agent run and tool call appears in Agent Manager traces.

Chat agents follow Agent Manager's chat contract:

```json
Request:  {"session_id": "s1", "message": "text", "context": {}}
Response: {"response": "text"}
```

Reuse the same `session_id` to continue a conversation.

---

## The agents and their test data

All people, cases and amounts are fictional. Benefit rules are **simplified demo rules**, not official rates.

### 1. Parental Benefit Assistant

**What it does:** shows how many parental benefit days a parent has left per child, estimates the daily amount,
and reports VAB days (temporary parental benefit for caring for a sick child).

**Tools:** `getParentProfile`, `estimateParentalBenefit`, `reportVabDay`, `listVabReports`, `getCurrentDate`

**Rules enforced:** VAB only for children under 12 · no future dates · max 120 VAB days per child per year ·
no duplicate day · amounts shown as estimates before tax.

**Test data**

| Citizen ID | Name | Children |
|---|---|---|
| `CIT-1001` | Anna Lindqvist, income 540,000 SEK | `CH-1` Elsa (born 2025, 212 + 45 days left), `CH-2` Oskar (13 years old) |
| `CIT-1002` | Johan Berg, income 310,000 SEK | `CH-3` Maja (born 2024, 170 + 45 days left) |

**Try it (same `session_id`)**

| Message | Expected |
|---|---|
| What parental benefit days do I have left? My id is CIT-1001 | Days per child for Elsa and Oskar |
| How much would I get per day for Elsa? | Daily estimate at income level and minimum level |
| Elsa was sick yesterday, please report a full VAB day | Asks to confirm, then saves the report |
| Report a VAB day for Oskar today | Rejected — Oskar is over 12 |
| Report a half VAB day for Elsa next Friday | Rejected — future date |
| Hur många föräldrapenningdagar har jag kvar? CIT-1002 | Answer in Swedish: 170 + 45 days for Maja |

### 2. Sickness Benefit Assistant

**What it does:** explains who pays during sickness (employer or agency), when a medical certificate is needed,
estimates the daily amount, shows claim status and rehabilitation plan, and registers sickness notifications.

**Tools:** `getInsuredProfile`, `checkEligibility`, `getClaimStatus`, `notifySickness`, `getCurrentDate`

**Rules enforced:** employer pays days 1–14 for employees · certificate required from day 8 · minimum qualifying
income · work-capacity reduction must be 25/50/75/100 % · rehab checkpoints at day 90, 180 and 365 ·
no medical advice.

**Test data**

| Citizen ID | Name | Situation |
|---|---|---|
| `CIT-2001` | Erik Nilsson | Employee; approved claim at 50 % since 2026-07-20 with a return-to-work plan |
| `CIT-2002` | Sara Ahmed | Self-employed, no claims yet |
| `CIT-2003` | Lars Holm | Employee with income below the minimum |

**Try it**

| Message | Expected |
|---|---|
| I've been sick since 2026-09-10. Who pays and do I need a certificate? CIT-2001 | Agency pays from day 15; certificate required |
| What is the status of my claim and my rehabilitation plan? | Approved claim and gradual return plan |
| I got sick again today, please register a notification at 100 percent | Redirected: employer pays days 1–14 |
| I'm self-employed, CIT-2002, sick since yesterday, 100 percent — please notify | Confirms, then registers a claim |
| Am I eligible for sickness benefit? CIT-2003 | Not eligible — income below minimum |
| What medicine should I take for my back pain? | Declines medical advice, refers to healthcare |

### 3. Case Status Assistant

**What it does:** shows the status of benefit cases, which documents are missing, expected decision dates and
upcoming payments, and registers documents the citizen says they have sent.

**Tools:** `listCases`, `getCaseDetails`, `listPayments`, `registerDocument`, `getCurrentDate`

**Rules enforced:** a document can only be registered if it is on the case's missing list · when nothing is
missing, the case moves to *in review* · explains the right to request a review of a decision.

**Test data**

| Citizen ID | Cases | Payments |
|---|---|---|
| `CIT-3001` | `CASE-2026-1001` Housing allowance — awaiting *Rental contract* and *Income statement for 2026* · `CASE-2026-1002` Parental benefit — decided (approved) | 18,450 SEK paid 2026-09-25, next 18,450 SEK on 2026-10-26 |
| `CIT-3002` | `CASE-2026-1003` Sickness benefit — in review | 9,800 SEK on 2026-10-26 |

**Try it (same `session_id`)**

| Message | Expected |
|---|---|
| What's happening with my cases? CIT-3001 | Two cases with status |
| Which documents are missing? | Rental contract, Income statement for 2026 |
| When is my next payment? | 18,450 SEK on 2026-10-26 |
| I have sent the rental contract for CASE-2026-1001 | Receipt; one document left |
| I also sent the income statement for 2026 | Case moves to in review |
| I don't agree with my parental benefit decision | Explains how to request a review |

### 4. Claim Triage Agent

**What it does:** an internal API for case systems. It checks a claim with deterministic rules (completeness,
overlapping periods, amount, registration age, previous rejections), then the LLM recommends a caseworker
queue, priority and a short rationale. A policy guardrail blocks fast-tracking of risky or incomplete claims,
and a rules-only fallback answers if the LLM is unavailable. **A human always makes the decision**
(`requiresHumanReview: true`).

**Queues:** `fast-track` · `standard` · `complex-cases` · `control-and-investigation` · `request-completion`

**Test data**

| Citizen ID | History |
|---|---|
| `CIT-4001` | Insured since 2012, one approved VAB claim — clean |
| `CIT-4002` | Registered as insured recently (less than 90 days) |
| `CIT-4003` | Approved sickness benefit 2026-08-01 to 2026-09-30, rejected housing allowance ending 2026-04-30 |

Required documents: sickness benefit → *Medical certificate* · parental benefit → *Parental leave plan* ·
housing allowance → *Rental contract*, *Income statement* · VAB → none.

**Try it — `POST /triage`**

| Case | Request body | Expected queue |
|---|---|---|
| Risky | `{"claimId":"CL-1","citizenId":"CIT-4003","benefitType":"sickness benefit","claimedAmountSek":62000,"periodStart":"2026-09-15","periodEnd":"2026-10-15","submittedDocuments":[]}` | `control-and-investigation` (overlap, high amount, missing certificate) |
| Clean | `{"claimId":"CL-2","citizenId":"CIT-4001","benefitType":"vab","claimedAmountSek":1800,"periodStart":"2026-09-22","periodEnd":"2026-09-22"}` | `fast-track` |
| New claimant | `{"claimId":"CL-3","citizenId":"CIT-4002","benefitType":"housing allowance","claimedAmountSek":8400,"periodStart":"2026-10-01","periodEnd":"2026-12-31","submittedDocuments":["Rental contract","Income statement"]}` | `complex-cases` |
| Missing document | `{"claimId":"CL-4","citizenId":"CIT-4001","benefitType":"parental benefit","claimedAmountSek":24000,"periodStart":"2026-11-01","periodEnd":"2026-11-30","submittedDocuments":[]}` | `request-completion` |
| Unknown claimant | `{"claimId":"CL-5","citizenId":"CIT-9999","benefitType":"vab","claimedAmountSek":900,"periodStart":"2026-09-20","periodEnd":"2026-09-20"}` | `control-and-investigation` |

Check `riskFlags`, `rationale` and `decidedBy` (`ai-agent`, `ai-agent+policy-override`, or `rules-fallback`).

---

## Data sources

The mock data sits at the top of each `main.bal`. In production, only the tool function bodies change — they
would call the agency's systems through WSO2 Integrator connectors:

| Agent | Mock data here | Would come from (production) |
|---|---|---|
| Parental benefit | Parents, children, remaining days, income, VAB reports | Parental-benefit case system, population register, income data |
| Sickness benefit | Insured persons, employment, income, claims, certificates, rehab plans | Sickness-benefit case system, electronic medical certificates, employer data |
| Case status | Cases, missing documents, decisions, payments | Case management, document archive, payment system |
| Claim triage | Required documents per benefit, claimant history | Case history, insurance register, document management |

---

## LLM configuration

Each agent's `gemini_provider.bal` picks the model at startup:

| Setting (Config.toml) | Env var in Agent Manager | Default | Purpose |
|---|---|---|---|
| `geminiApiKey` | `BAL_CONFIG_VAR_GEMINIAPIKEY` | — | Gemini key; if set, Gemini is used |
| `geminiModel` | `BAL_CONFIG_VAR_GEMINIMODEL` | `gemini-3.8-flash` | Main model |
| `geminiFallbackModel` | `BAL_CONFIG_VAR_GEMINIFALLBACKMODEL` | `gemini-3.5-flash` | Used if the main model is overloaded |
| `openAiApiKey` | `BAL_CONFIG_VAR_OPENAIAPIKEY` | — | Used only when no Gemini key is set (gpt-4o) |

Overloaded or rate-limited responses (HTTP 429/503) are retried three times with backoff, then the fallback
model is tried. `libs/noop-generator.jar` is a 1 KB helper the Gemini provider needs — keep it.

---

## Run locally (WSO2 Integrator)

1. Open one agent folder in WSO2 Integrator (each folder is its own Ballerina project).
2. `cp Config.toml.example Config.toml` and set `geminiApiKey` (free key: https://aistudio.google.com).
   `Config.toml` is git-ignored.
3. Click **Run**; the agent listens on `http://localhost:8000`. Run one agent at a time (they share the port).
4. Send the test messages above from the Try It panel or curl:
   ```bash
   curl -s localhost:8000/chat -H 'content-type: application/json' \
     -d '{"session_id":"s1","message":"What is happening with my cases? CIT-3001"}'
   ```

## Deploy to WSO2 Agent Manager

For each agent: **Add Agent → Platform-Hosted Agent → Source Code**.

| Field | Value |
|---|---|
| GitHub Repository | `https://github.com/krishnia92/ssa-agents` |
| Branch | `main` |
| App Path | `/parental-benefit-agent`, `/sickness-benefit-agent`, `/case-status-agent` or `/claim-triage-agent` |
| Language | `Ballerina` (no version or start command) |
| Agent Type | **Chat Agent** for the three chat agents; **Custom API Agent** (port `8000`, `openapi.yaml`) for claim triage |
| Environment variable | `BAL_CONFIG_VAR_GEMINIAPIKEY` = your Gemini key (secret) |

Test in **Try It**, then open **Observability → Traces**. Calls through the gateway need an endpoint key as
`x-api-key`:

```bash
curl -s -X POST http://default-default.am-gateway.localhost:19080/<agent-name>/chat \
  -H 'content-type: application/json' -H 'x-api-key: <key>' \
  -d '{"session_id":"s1","message":"What is happening with my cases? CIT-3001","context":{}}'
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Unable to obtain valid answer from the agent` | LLM call failed — check the log for `level=ERROR` |
| `401 ... Incorrect API key` from OpenAI | A Gemini key was set as `openAiApiKey` — use `geminiApiKey` |
| `404 ... model is no longer available` | Set `geminiModel` to a current model |
| `503 ... high demand` | Temporary; the agent retries and falls back automatically |
| Gateway returns `Unauthorized` | Send the endpoint key as `x-api-key` |
| Postman gets `404` on `*.localhost` | Add header `Host: default-default.am-gateway.localhost:19080` |

---

*Demo project. All people, cases and figures are fictional.*

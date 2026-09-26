# Claim Triage Agent (API)

Internal API for case systems. Combines deterministic rule checks (completeness, overlapping periods, amount, registration age, prior rejections) with an LLM recommendation of caseworker queue, priority and rationale. A policy guardrail stops the AI from fast-tracking risky or incomplete claims; if the LLM fails, a rules-only fallback answers. requiresHumanReview is always true.

- **Type:** Custom API — `POST /triage` on port 8000
- **Language:** Ballerina 2201.13.x (open this folder in WSO2 Integrator)
- **LLM:** Google Gemini (free key) via `geminiApiKey`, or OpenAI gpt-4o via `openAiApiKey` — env `BAL_CONFIG_VAR_GEMINIAPIKEY` / `BAL_CONFIG_VAR_OPENAIAPIKEY` in Agent Manager
- **Data:** fictional in-memory mock data at the top of `main.bal`
- **Tools:** getClaimantHistory, recordTriageDecision (structured output)

## Run locally
```bash
cp Config.toml.example Config.toml   # add your Gemini (or OpenAI) key
bal run
```

## Try
Use the three examples in `openapi.yaml`:
```bash
curl -s localhost:8000/triage -H "content-type: application/json" -d '{"claimId":"CL-1","citizenId":"CIT-4003","benefitType":"sickness benefit","claimedAmountSek":62000,"periodStart":"2026-09-15","periodEnd":"2026-10-15","submittedDocuments":[]}'
```

See the root README for GitHub and Agent Manager deployment steps.

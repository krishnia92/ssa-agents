# Sickness Benefit Assistant

Explains sickness benefit eligibility (who pays, certificate rules, estimated amount), shows claim status and rehab plan, and registers sickness notifications.

- **Type:** Chat Agent — `POST /chat` on port 8000
- **Language:** Ballerina 2201.13.x (open this folder in WSO2 Integrator)
- **LLM:** Google Gemini (free key) via `geminiApiKey`, or OpenAI gpt-4o via `openAiApiKey` — env `BAL_CONFIG_VAR_GEMINIAPIKEY` / `BAL_CONFIG_VAR_OPENAIAPIKEY` in Agent Manager
- **Data:** fictional in-memory mock data at the top of `main.bal`
- **Tools:** getInsuredProfile, checkEligibility, getClaimStatus, notifySickness, getCurrentDate

## Run locally
```bash
cp Config.toml.example Config.toml   # add your Gemini (or OpenAI) key
bal run
```

## Try
- "I have been sick since 2026-09-10, who pays? CIT-2001"
- "What is my claim status and rehab plan? CIT-2001"
- "I am self-employed, CIT-2002, sick since yesterday, 100 percent"
- "Am I eligible? CIT-2003" (income below minimum)

See the root README for GitHub and Agent Manager deployment steps.

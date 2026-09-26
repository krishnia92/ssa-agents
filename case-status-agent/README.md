# Case & Payment Status Assistant

Shows benefit case status, missing documents and upcoming payments, and registers documents the citizen has sent.

- **Type:** Chat Agent — `POST /chat` on port 8000
- **Language:** Ballerina 2201.13.x (open this folder in WSO2 Integrator)
- **LLM:** Google Gemini (free key) via `geminiApiKey`, or OpenAI gpt-4o via `openAiApiKey` — env `BAL_CONFIG_VAR_GEMINIAPIKEY` / `BAL_CONFIG_VAR_OPENAIAPIKEY` in Agent Manager
- **Data:** fictional in-memory mock data at the top of `main.bal`
- **Tools:** listCases, getCaseDetails, listPayments, registerDocument, getCurrentDate

## Run locally
```bash
cp Config.toml.example Config.toml   # add your Gemini (or OpenAI) key
bal run
```

## Try
- "What is happening with my cases? CIT-3001"
- "When is my next payment?"
- "I sent the rental contract for CASE-2026-1001"
- "I also sent the income statement for 2026" (case moves to in-review)

See the root README for GitHub and Agent Manager deployment steps.

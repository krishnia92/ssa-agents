# Parental Benefit & VAB Assistant

Helps parents check remaining parental benefit days, estimate daily amounts and report VAB (care of a sick child) days.

- **Type:** Chat Agent — `POST /chat` on port 8000
- **Language:** Ballerina 2201.13.x (open this folder in WSO2 Integrator)
- **LLM:** Google Gemini (free key) via `geminiApiKey`, or OpenAI gpt-4o via `openAiApiKey` — env `BAL_CONFIG_VAR_GEMINIAPIKEY` / `BAL_CONFIG_VAR_OPENAIAPIKEY` in Agent Manager
- **Data:** fictional in-memory mock data at the top of `main.bal`
- **Tools:** getParentProfile, estimateParentalBenefit, reportVabDay, listVabReports, getCurrentDate

## Run locally
```bash
cp Config.toml.example Config.toml   # add your Gemini (or OpenAI) key
bal run
```

## Try
- "What parental benefit days do I have left? CIT-1001"
- "How much per day would I get for Elsa?"
- "Elsa was sick yesterday, report a full VAB day"
- "Report VAB for Oskar today" (rejected — over 12)

See the root README for GitHub and Agent Manager deployment steps.

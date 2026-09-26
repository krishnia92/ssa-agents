import ballerina/ai;
import ballerina/http;
import ballerina/time;
import ballerina/uuid;
import ballerinax/ai.openai;
import ballerinax/amp as _;

// LLM keys and provider selection live in gemini_provider.bal.

// ---------------------------------------------------------------------------
// API contract: POST /triage with a claim, returns a structured triage result.
// Called by internal case systems, not by citizens. The result is a
// recommendation only: a case handler always makes the decision.
// ---------------------------------------------------------------------------

type Queue "fast-track"|"standard"|"complex-cases"|"control-and-investigation"|"request-completion";
type Priority "low"|"normal"|"high";
type Severity "low"|"medium"|"high";

# An incoming benefit claim.
#
# + claimId - Claim identifier from the case system
# + citizenId - Claimant citizen id
# + benefitType - One of: sickness benefit, parental benefit, housing allowance, vab
# + claimedAmountSek - Total amount claimed (SEK)
# + periodStart - Start of the claimed period, YYYY-MM-DD
# + periodEnd - End of the claimed period, YYYY-MM-DD
# + submittedDocuments - Names of documents attached to the claim
# + employerConfirmed - Whether the employer has confirmed absence (sickness benefit)
# + notes - Free-text notes from the claimant
type Claim record {
    string claimId;
    string citizenId;
    string benefitType;
    int claimedAmountSek;
    string periodStart;
    string periodEnd;
    string[] submittedDocuments = [];
    boolean? employerConfirmed = ();
    string? notes = ();
};

# A risk signal found by the rule checks.
#
# + code - Machine-readable code
# + severity - low, medium or high
# + detail - Human-readable explanation
type RiskFlag record {|
    string code;
    Severity severity;
    string detail;
|};

# The triage result returned to the case system.
#
# + claimId - The claim this result is for
# + complete - Whether all required documents are present
# + missingDocuments - Required documents that are missing
# + riskFlags - Risk signals from the rule checks
# + recommendedQueue - Caseworker queue the claim should go to
# + priority - Suggested handling priority
# + rationale - Short explanation of the recommendation
# + decidedBy - ai-agent, ai-agent+policy-override or rules-fallback
# + requiresHumanReview - Always true: a case handler makes the decision
type TriageResult record {|
    string claimId;
    boolean complete;
    string[] missingDocuments;
    RiskFlag[] riskFlags;
    Queue recommendedQueue;
    Priority priority;
    string rationale;
    string decidedBy;
    boolean requiresHumanReview = true;
|};

type Decision record {|
    Queue queue;
    Priority priority;
    string rationale;
|};

service / on new http:Listener(8000) {
    resource function post triage(@http:Payload Claim claim) returns TriageResult|error {
        return triageClaim(claim);
    }
}

// ---------------------------------------------------------------------------
// Mock data sources. In production: the agency's case history, the population
// register, and document management, reached through WSO2 Integrator.
// All people and numbers below are fictional.
// ---------------------------------------------------------------------------

# A previous claim for the same person.
#
# + benefitType - Benefit type
# + periodStart - Start, YYYY-MM-DD
# + periodEnd - End, YYYY-MM-DD
# + outcome - approved or rejected
type PriorClaim record {|
    string benefitType;
    string periodStart;
    string periodEnd;
    "approved"|"rejected" outcome;
|};

# Claimant history.
#
# + registeredSince - Date the person was registered as insured, YYYY-MM-DD
# + priorClaims - Earlier claims
type ClaimantHistory record {|
    string registeredSince;
    PriorClaim[] priorClaims;
|};

final readonly & map<string[]> requiredDocuments = {
    "sickness benefit": ["Medical certificate"],
    "parental benefit": ["Parental leave plan"],
    "housing allowance": ["Rental contract", "Income statement"],
    "vab": []
};

final readonly & map<ClaimantHistory> histories = {
    "CIT-4001": {registeredSince: "2012-05-01", priorClaims: [
        {benefitType: "vab", periodStart: "2026-02-03", periodEnd: "2026-02-04", outcome: "approved"}
    ]},
    "CIT-4002": {registeredSince: "2026-08-20", priorClaims: []},
    "CIT-4003": {registeredSince: "2015-01-10", priorClaims: [
        {benefitType: "sickness benefit", periodStart: "2026-08-01", periodEnd: "2026-09-30", outcome: "approved"},
        {benefitType: "housing allowance", periodStart: "2025-11-01", periodEnd: "2026-04-30", outcome: "rejected"}
    ]}
};

const int HIGH_AMOUNT_SEK = 50000;
const int RECENT_REGISTRATION_DAYS = 90;

// Decisions recorded by the agent via the recordTriageDecision tool, keyed by claim id.
isolated map<Decision> decisions = {};

// ---------------------------------------------------------------------------
// Rule checks (deterministic, explainable)
// ---------------------------------------------------------------------------
isolated function todayString() returns string => time:utcToString(time:utcNow()).substring(0, 10);

isolated function daysBetween(string fromDate, string toDate) returns int|error {
    time:Utc fromUtc = check time:utcFromString(fromDate + "T00:00:00Z");
    time:Utc toUtc = check time:utcFromString(toDate + "T00:00:00Z");
    decimal seconds = time:utcDiffSeconds(toUtc, fromUtc);
    return <int>(seconds / 86400d);
}

isolated function missingDocs(Claim claim) returns string[] {
    string[] required = requiredDocuments[claim.benefitType.toLowerAscii()] ?: [];
    string[] submitted = from string d in claim.submittedDocuments select d.toLowerAscii();
    return from string r in required
        where submitted.indexOf(r.toLowerAscii()) is ()
        select r;
}

isolated function riskChecks(Claim claim) returns RiskFlag[]|error {
    RiskFlag[] flags = [];
    if check daysBetween(claim.periodStart, claim.periodEnd) < 0 {
        flags.push({code: "INVALID_PERIOD", severity: "high", detail: "The period ends before it starts."});
    }
    if claim.claimedAmountSek > HIGH_AMOUNT_SEK {
        flags.push({code: "HIGH_AMOUNT", severity: "medium",
            detail: string `Claimed amount ${claim.claimedAmountSek} SEK is above ${HIGH_AMOUNT_SEK} SEK.`});
    }
    ClaimantHistory? history = histories[claim.citizenId];
    if history is () {
        flags.push({code: "UNKNOWN_CLAIMANT", severity: "high", detail: "No insurance registration found for the claimant."});
        return flags;
    }
    if check daysBetween(history.registeredSince, todayString()) < RECENT_REGISTRATION_DAYS {
        flags.push({code: "RECENTLY_REGISTERED", severity: "medium",
            detail: string `Registered as insured since ${history.registeredSince}, less than ${RECENT_REGISTRATION_DAYS} days ago.`});
    }
    foreach PriorClaim p in history.priorClaims {
        boolean sameBenefit = p.benefitType == claim.benefitType.toLowerAscii();
        boolean overlaps = check daysBetween(p.periodStart, claim.periodEnd) >= 0
            && check daysBetween(claim.periodStart, p.periodEnd) >= 0;
        if sameBenefit && overlaps && p.outcome == "approved" {
            flags.push({code: "OVERLAPPING_PERIOD", severity: "high",
                detail: string `Overlaps an already approved ${p.benefitType} period ${p.periodStart} to ${p.periodEnd}.`});
        }
        if p.outcome == "rejected" && check daysBetween(p.periodEnd, todayString()) < 365 {
            flags.push({code: "RECENT_REJECTION", severity: "low",
                detail: string `A ${p.benefitType} claim ending ${p.periodEnd} was rejected within the last year.`});
        }
    }
    if claim.benefitType.toLowerAscii() == "sickness benefit" && claim.employerConfirmed != true {
        flags.push({code: "EMPLOYER_NOT_CONFIRMED", severity: "low", detail: "The employer has not confirmed the absence."});
    }
    return flags;
}

isolated function hasSeverity(RiskFlag[] flags, Severity s) returns boolean {
    foreach RiskFlag f in flags {
        if f.severity == s {
            return true;
        }
    }
    return false;
}

isolated function ruleBasedDecision(Claim claim, boolean complete, RiskFlag[] flags) returns Decision {
    if hasSeverity(flags, "high") {
        return {queue: "control-and-investigation", priority: "high", rationale: "High-severity risk signals need investigation."};
    }
    if !complete {
        return {queue: "request-completion", priority: "normal", rationale: "Required documents are missing."};
    }
    if hasSeverity(flags, "medium") {
        return {queue: "complex-cases", priority: "normal", rationale: "Medium-severity signals need a closer look."};
    }
    if flags.length() == 0 && claim.claimedAmountSek <= 10000 {
        return {queue: "fast-track", priority: "low", rationale: "Complete, low amount, no risk signals."};
    }
    return {queue: "standard", priority: "normal", rationale: "Complete claim with only minor signals."};
}

// ---------------------------------------------------------------------------
// Agent tools
// ---------------------------------------------------------------------------

# Returns a claimant's registration date and earlier claims with outcomes.
#
# + citizenId - Claimant citizen id
# + return - The claimant's history, or an error if unknown
@ai:AgentTool
isolated function getClaimantHistory(string citizenId) returns ClaimantHistory|error {
    ClaimantHistory? h = histories[citizenId];
    if h is () {
        return error(string `No history for ${citizenId}`);
    }
    return h;
}

# Records the triage recommendation for a claim. Call this exactly once per claim.
#
# + claimId - The claim id
# + queue - One of: fast-track, standard, complex-cases, control-and-investigation, request-completion
# + priority - One of: low, normal, high
# + rationale - One or two sentences explaining the recommendation for the case handler
# + return - A confirmation message
@ai:AgentTool
isolated function recordTriageDecision(string claimId, Queue queue, Priority priority, string rationale) returns string {
    lock {
        decisions[claimId] = {queue, priority, rationale};
    }
    return string `Recorded ${queue} (${priority}) for ${claimId}.`;
}

final ai:Agent triageAgent = check new ({
    systemPrompt: {
        role: "Claim Triage Assistant for case handlers at the Swedish Social Insurance Agency",
        instructions: string `You triage incoming benefit claims for case handlers. You receive
            the claim and the results of automatic rule checks. Look up the claimant history
            if it helps, weigh completeness and risk signals, then call recordTriageDecision
            exactly once with a queue, a priority and a short, neutral rationale a case handler
            can read. Queues: fast-track (complete, low risk, low amount), standard,
            complex-cases (needs judgement), control-and-investigation (high risk or possible
            error), request-completion (documents missing). Never use fast-track when any risk
            flag is present or documents are missing. Base the rationale only on the facts
            given; do not speculate about the claimant's intent. You recommend, you do not decide.`
    },
    tools: [getClaimantHistory, recordTriageDecision],
    // Gemini if geminiApiKey is set, otherwise OpenAI (see gemini_provider.bal)
    model: geminiApiKey != ""
        ? check new GeminiModelProvider(geminiApiKey, geminiModel, geminiServiceUrl, geminiFallbackModel)
        : check new openai:ModelProvider(openAiApiKey, openai:GPT_4O)
});

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------
isolated function triageClaim(Claim claim) returns TriageResult|error {
    string[] missing = missingDocs(claim);
    boolean complete = missing.length() == 0;
    RiskFlag[] flags = check riskChecks(claim);

    string prompt = string `Triage this claim.
Claim: ${claim.toJsonString()}
Rule checks: complete=${complete}, missingDocuments=${missing.toJsonString()}, riskFlags=${flags.toJsonString()}`;

    Decision? decision = ();
    string decidedBy = "ai-agent";
    string|error reply = triageAgent.run(prompt, "triage-" + uuid:createRandomUuid());
    lock {
        Decision? d = decisions.removeIfHasKey(claim.claimId);
        decision = d.clone();
    }
    if reply is error || decision is () {
        decision = ruleBasedDecision(claim, complete, flags);
        decidedBy = "rules-fallback";
    }
    Decision chosen = <Decision>decision;

    // Policy guardrail: the agent may never fast-track a risky or incomplete claim.
    if chosen.queue == "fast-track" && (flags.length() > 0 || !complete) {
        Decision safe = ruleBasedDecision(claim, complete, flags);
        chosen = {queue: safe.queue, priority: safe.priority,
            rationale: chosen.rationale + " (Policy override: fast-track is not allowed for this claim.)"};
        decidedBy = "ai-agent+policy-override";
    }

    return {
        claimId: claim.claimId,
        complete,
        missingDocuments: missing,
        riskFlags: flags,
        recommendedQueue: chosen.queue,
        priority: chosen.priority,
        rationale: chosen.rationale,
        decidedBy
    };
}

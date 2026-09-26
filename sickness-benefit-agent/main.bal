import ballerina/ai;
import ballerina/http;
import ballerina/time;
import ballerina/uuid;
import ballerinax/ai.openai;
import ballerinax/amp as _;

// LLM keys and provider selection live in gemini_provider.bal.

// Chat contract used by Agent Manager: {session_id, message, context} -> {response}
type ChatRequest record {
    string session_id;
    string message;
};

type ChatResponse record {|
    string response;
|};

service / on new http:Listener(8000) {
    resource function post chat(@http:Payload ChatRequest request) returns ChatResponse|error {
        string reply = check sicknessBenefitAgent.run(request.message, request.session_id);
        return {response: reply};
    }
}

// ---------------------------------------------------------------------------
// Mock data source. In production: the agency's sickness-benefit case system,
// electronic medical certificates from healthcare, and employer income data.
// All people and numbers below are fictional.
// ---------------------------------------------------------------------------

type EmploymentType "employee"|"self-employed"|"unemployed";
type ClaimStatus "notified"|"awaiting-certificate"|"in-review"|"approved"|"rejected";

# A person insured for sickness benefit.
#
# + name - Full name
# + employmentType - employee, self-employed or unemployed
# + employer - Employer name, if employed
# + annualIncomeSek - Sickness benefit qualifying income (SEK)
type Insured record {|
    string name;
    EmploymentType employmentType;
    string? employer;
    int annualIncomeSek;
|};

# A sickness benefit claim.
#
# + claimId - Claim identifier
# + citizenId - The insured person
# + sickFrom - First day of sickness, YYYY-MM-DD
# + status - Current status of the claim
# + certificateReceived - Whether a medical certificate has been received
# + certificateValidUntil - Last day covered by the certificate, if any
# + workCapacityReduction - Reduction in work capacity: 25, 50, 75 or 100 percent
# + rehabPlan - Agreed rehabilitation steps, if any
type SicknessClaim record {|
    string claimId;
    string citizenId;
    string sickFrom;
    ClaimStatus status;
    boolean certificateReceived;
    string? certificateValidUntil;
    int workCapacityReduction;
    string? rehabPlan;
|};

// Simplified demo rules (not official figures).
const int EMPLOYER_SICK_PAY_DAYS = 14;
const int CERTIFICATE_REQUIRED_FROM_DAY = 8;
const int MIN_QUALIFYING_INCOME_SEK = 14208;
const int SICKNESS_MAX_DAILY_SEK = 1250;

isolated map<Insured> insured = {
    "CIT-2001": {name: "Erik Nilsson", employmentType: "employee", employer: "Nordic Logistics AB", annualIncomeSek: 480000},
    "CIT-2002": {name: "Sara Ahmed", employmentType: "self-employed", employer: (), annualIncomeSek: 360000},
    "CIT-2003": {name: "Lars Holm", employmentType: "employee", employer: "Göteborg Bygg AB", annualIncomeSek: 12000}
};

isolated map<SicknessClaim> claims = {
    "SC-501": {
        claimId: "SC-501", citizenId: "CIT-2001", sickFrom: "2026-07-20", status: "approved",
        certificateReceived: true, certificateValidUntil: "2026-10-15", workCapacityReduction: 50,
        rehabPlan: "Gradual return: 50 percent from 2026-09-01, full time planned 2026-10-16. Follow-up meeting with employer 2026-10-01."
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
isolated function todayString() returns string => time:utcToString(time:utcNow()).substring(0, 10);

isolated function daysBetween(string fromDate, string toDate) returns int|error {
    time:Utc fromUtc = check time:utcFromString(fromDate + "T00:00:00Z");
    time:Utc toUtc = check time:utcFromString(toDate + "T00:00:00Z");
    decimal seconds = time:utcDiffSeconds(toUtc, fromUtc);
    return <int>(seconds / 86400d);
}

isolated function findInsured(string citizenId) returns Insured|error {
    lock {
        Insured? p = insured[citizenId];
        if p is () {
            return error(string `No insured person registered with id ${citizenId}`);
        }
        return p.clone();
    }
}

isolated function rehabCheckpoint(int dayNumber) returns string {
    if dayNumber <= 90 {
        return "Days 1-90: work capacity is assessed against the person's own job, and adjusted duties at the employer.";
    }
    if dayNumber <= 180 {
        return "Days 91-180: work capacity is assessed against any job available at the employer.";
    }
    if dayNumber <= 365 {
        return "Days 181-365: work capacity is assessed against the normal labour market, unless it would be unreasonable.";
    }
    return "After day 365: assessment against the normal labour market; extended benefit may apply in special cases.";
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

# Looks up an insured person's employment type, employer and qualifying income.
#
# + citizenId - Citizen id, e.g. CIT-2001
# + return - The insured person's profile, or an error if not found
@ai:AgentTool
isolated function getInsuredProfile(string citizenId) returns Insured|error {
    return findInsured(citizenId);
}

# Checks sickness benefit eligibility for a sickness period that started on a given date:
# who pays for the current day, whether a medical certificate is required, the estimated
# daily amount, and which rehabilitation checkpoint applies.
#
# + citizenId - Citizen id
# + sickFrom - First day of sickness, YYYY-MM-DD
# + return - An eligibility summary, or an error
@ai:AgentTool
isolated function checkEligibility(string citizenId, string sickFrom) returns map<anydata>|error {
    Insured person = check findInsured(citizenId);
    int dayNumber = check daysBetween(sickFrom, todayString()) + 1;
    if dayNumber < 1 {
        return error("The sickness start date is in the future.");
    }
    if person.annualIncomeSek < MIN_QUALIFYING_INCOME_SEK {
        return {
            eligible: false,
            reason: string `Qualifying income ${person.annualIncomeSek} SEK is below the minimum of ${MIN_QUALIFYING_INCOME_SEK} SEK per year.`
        };
    }
    string payer = person.employmentType == "employee" && dayNumber <= EMPLOYER_SICK_PAY_DAYS
        ? string `The employer (${person.employer ?: "employer"}) pays sick pay for days 1-${EMPLOYER_SICK_PAY_DAYS}. The agency pays from day ${EMPLOYER_SICK_PAY_DAYS + 1}.`
        : "The agency pays sickness benefit for this period.";
    int daily = (person.annualIncomeSek * 80 * 97) / (100 * 100 * 365);
    return {
        eligible: true,
        currentSickDay: dayNumber,
        whoPays: payer,
        medicalCertificateRequired: dayNumber >= CERTIFICATE_REQUIRED_FROM_DAY,
        certificateRule: string `A medical certificate is required from day ${CERTIFICATE_REQUIRED_FROM_DAY}.`,
        estimatedDailyAmountSek: daily > SICKNESS_MAX_DAILY_SEK ? SICKNESS_MAX_DAILY_SEK : daily,
        rehabCheckpoint: rehabCheckpoint(dayNumber),
        note: "Simplified demo rules, amounts before tax. A case handler makes the formal decision."
    };
}

# Lists all sickness benefit claims for a person with status, certificate and rehab plan.
#
# + citizenId - Citizen id
# + return - The person's claims
@ai:AgentTool
isolated function getClaimStatus(string citizenId) returns SicknessClaim[] {
    SicknessClaim[] all;
    lock {
        all = claims.toArray().clone();
    }
    return from SicknessClaim c in all
        where c.citizenId == citizenId
        select c;
}

# Registers a new sickness notification. Self-employed and unemployed people notify the
# agency from day 1; employees notify their employer first and the agency from day 15.
#
# + citizenId - Citizen id
# + sickFrom - First day of sickness, YYYY-MM-DD
# + workCapacityReduction - Reduction in work capacity: 25, 50, 75 or 100
# + return - The created claim, or an error
@ai:AgentTool
isolated function notifySickness(string citizenId, string sickFrom, int workCapacityReduction)
        returns SicknessClaim|error {
    Insured person = check findInsured(citizenId);
    if workCapacityReduction != 25 && workCapacityReduction != 50 && workCapacityReduction != 75
            && workCapacityReduction != 100 {
        return error("Work capacity reduction must be 25, 50, 75 or 100 percent.");
    }
    int dayNumber = check daysBetween(sickFrom, todayString()) + 1;
    if dayNumber < 1 {
        return error("Sickness cannot be notified for a future date.");
    }
    if person.employmentType == "employee" && dayNumber <= EMPLOYER_SICK_PAY_DAYS {
        return error(string `${person.name} is employed. For the first ${EMPLOYER_SICK_PAY_DAYS} days, notify the employer, who pays sick pay. The agency is notified from day ${EMPLOYER_SICK_PAY_DAYS + 1}.`);
    }
    SicknessClaim claim = {
        claimId: "SC-" + uuid:createRandomUuid().substring(0, 6),
        citizenId,
        sickFrom,
        status: dayNumber >= CERTIFICATE_REQUIRED_FROM_DAY ? "awaiting-certificate" : "notified",
        certificateReceived: false,
        certificateValidUntil: (),
        workCapacityReduction,
        rehabPlan: ()
    };
    lock {
        claims[claim.claimId] = claim.clone();
    }
    return claim;
}

# Returns today's date (YYYY-MM-DD) so relative dates can be resolved.
#
# + return - Today's date
@ai:AgentTool
isolated function getCurrentDate() returns string => todayString();

final ai:Agent sicknessBenefitAgent = check new ({
    systemPrompt: {
        role: "Sickness Benefit Assistant for a public social insurance agency",
        instructions: string `You help people understand and apply for sickness benefit (sjukpenning).
            Always ask for the citizen id (for example CIT-2001) first. Use the tools for
            eligibility, amounts, claim status and notifications; never invent facts.
            Resolve relative dates with getCurrentDate. Explain who pays (employer or agency),
            whether a medical certificate is needed, and what the next rehabilitation step is.
            Confirm the start date and work capacity reduction before calling notifySickness.
            You do not give medical advice and you do not make formal decisions; say that a
            case handler decides. Answer in the user's language (Swedish or English), briefly
            and with empathy.`
    },
    tools: [getInsuredProfile, checkEligibility, getClaimStatus, notifySickness, getCurrentDate],
    // Gemini if geminiApiKey is set, otherwise OpenAI (see gemini_provider.bal)
    model: geminiApiKey != ""
        ? check new GeminiModelProvider(geminiApiKey, geminiModel, geminiServiceUrl, geminiFallbackModel)
        : check new openai:ModelProvider(openAiApiKey, openai:GPT_4O)
});

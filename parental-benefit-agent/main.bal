import ballerina/ai;
import ballerina/http;
import ballerina/time;
import ballerina/uuid;
import ballerinax/ai.openai;
import ballerinax/amp as _;

// LLM keys and provider selection live in gemini_provider.bal.

// ---------------------------------------------------------------------------
// Chat contract used by Agent Manager: {session_id, message, context} -> {response}
// ---------------------------------------------------------------------------
type ChatRequest record {
    string session_id;
    string message;
};

type ChatResponse record {|
    string response;
|};

service / on new http:Listener(8000) {
    resource function post chat(@http:Payload ChatRequest request) returns ChatResponse|error {
        string reply = check parentalBenefitAgent.run(request.message, request.session_id);
        return {response: reply};
    }
}

// ---------------------------------------------------------------------------
// Mock data source. In production this would come from the agency's
// parental-benefit case system and the population register, via WSO2 Integrator.
// All people and numbers below are fictional.
// ---------------------------------------------------------------------------

# Remaining parental benefit days for one child.
#
# + childId - Child identifier
# + name - Child's first name
# + birthDate - Birth date, YYYY-MM-DD
# + sicknessLevelDaysLeft - Days left paid at sickness-benefit level (income based)
# + minimumLevelDaysLeft - Days left paid at the fixed minimum level
type Child record {|
    string childId;
    string name;
    string birthDate;
    int sicknessLevelDaysLeft;
    int minimumLevelDaysLeft;
|};

# A parent registered with the agency.
#
# + name - Full name
# + annualIncomeSek - Annual income used for benefit calculation (SEK)
# + children - The parent's children
type Parent record {|
    string name;
    int annualIncomeSek;
    Child[] children;
|};

# A reported day of temporary parental benefit (VAB) to care for a sick child.
#
# + reportId - Generated id
# + citizenId - Reporting parent
# + childId - The sick child
# + date - The day of care, YYYY-MM-DD
# + extent - full or half day
# + estimatedAmountSek - Estimated payment for this day
type VabReport record {|
    string reportId;
    string citizenId;
    string childId;
    string date;
    "full"|"half" extent;
    int estimatedAmountSek;
|};

// Simplified demo rules (not official figures).
const int PARENTAL_MAX_DAILY_SEK = 1250;
const int MINIMUM_LEVEL_DAILY_SEK = 180;
const int VAB_MAX_DAILY_SEK = 1031;
const int VAB_MAX_DAYS_PER_CHILD_PER_YEAR = 120;
const int VAB_MAX_CHILD_AGE = 12;

isolated map<Parent> parents = {
    "CIT-1001": {
        name: "Anna Lindqvist",
        annualIncomeSek: 540000,
        children: [
            {childId: "CH-1", name: "Elsa", birthDate: "2025-03-14", sicknessLevelDaysLeft: 212, minimumLevelDaysLeft: 45},
            {childId: "CH-2", name: "Oskar", birthDate: "2013-05-02", sicknessLevelDaysLeft: 0, minimumLevelDaysLeft: 10}
        ]
    },
    "CIT-1002": {
        name: "Johan Berg",
        annualIncomeSek: 310000,
        children: [
            {childId: "CH-3", name: "Maja", birthDate: "2024-11-20", sicknessLevelDaysLeft: 170, minimumLevelDaysLeft: 45}
        ]
    }
};

isolated VabReport[] vabReports = [];

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

isolated function ageInYears(string birthDate) returns int|error {
    int days = check daysBetween(birthDate, todayString());
    return (days * 100) / 36525;
}

isolated function sicknessLevelDaily(int annualIncomeSek, int cap) returns int {
    int daily = (annualIncomeSek * 80 * 97) / (100 * 100 * 365);
    return daily > cap ? cap : daily;
}

isolated function findParent(string citizenId) returns Parent|error {
    lock {
        Parent? p = parents[citizenId];
        if p is () {
            return error(string `No parent registered with id "${citizenId}"`);
        }
        return p.clone();
    }
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

# Looks up a parent's children and remaining parental benefit days per child.
#
# + citizenId - The parent's citizen id, e.g. CIT-1001
# + return - The parent's profile, or an error if not found
@ai:AgentTool
isolated function getParentProfile(string citizenId) returns Parent|error {
    return findParent(citizenId);
}

# Estimates the daily parental benefit amounts for a parent, at sickness-benefit
# level and at minimum level, and the total value of the remaining days for a child.
#
# + citizenId - The parent's citizen id
# + childId - The child the days belong to
# + return - Daily amounts and remaining value, or an error
@ai:AgentTool
isolated function estimateParentalBenefit(string citizenId, string childId) returns map<anydata>|error {
    Parent parent = check findParent(citizenId);
    foreach Child c in parent.children {
        if c.childId == childId {
            int daily = sicknessLevelDaily(parent.annualIncomeSek, PARENTAL_MAX_DAILY_SEK);
            return {
                childName: c.name,
                sicknessLevelDailySek: daily,
                minimumLevelDailySek: MINIMUM_LEVEL_DAILY_SEK,
                sicknessLevelDaysLeft: c.sicknessLevelDaysLeft,
                minimumLevelDaysLeft: c.minimumLevelDaysLeft,
                totalRemainingValueSek: daily * c.sicknessLevelDaysLeft + MINIMUM_LEVEL_DAILY_SEK * c.minimumLevelDaysLeft,
                note: "Simplified demo estimate before tax. The final amount is set in the formal decision."
            };
        }
    }
    return error(string `Child "${childId}" not found for parent "${citizenId}"`);
}

# Reports one day of temporary parental benefit (VAB) for caring for a sick child.
# The child must be under 12, the date cannot be in the future, and each child
# has at most 120 VAB days per year.
#
# + citizenId - The reporting parent's citizen id
# + childId - The sick child's id
# + date - The day of care, YYYY-MM-DD
# + extent - full or half day
# + return - The saved report, or an error explaining why it was rejected
@ai:AgentTool
isolated function reportVabDay(string citizenId, string childId, string date, "full"|"half" extent)
        returns VabReport|error {
    Parent parent = check findParent(citizenId);
    Child? child = ();
    foreach Child c in parent.children {
        if c.childId == childId {
            child = c;
        }
    }
    if child is () {
        return error(string `Child "${childId}" not found for parent "${citizenId}"`);
    }
    int age = check ageInYears(child.birthDate);
    if age >= VAB_MAX_CHILD_AGE {
        return error(string `${child.name} is ${age} years old. VAB normally applies to children under ${VAB_MAX_CHILD_AGE}.`);
    }
    if check daysBetween(todayString(), date) > 0 {
        return error("VAB can only be reported for today or past days, not future dates.");
    }
    string year = date.substring(0, 4);
    lock {
        int usedDays = 0;
        foreach VabReport r in vabReports {
            if r.childId == childId && r.date.startsWith(year) {
                usedDays += 1;
            }
            if r.childId == childId && r.date == date && r.citizenId == citizenId {
                return error(string `A VAB day is already reported for ${child.name} on ${date}.`);
            }
        }
        if usedDays >= VAB_MAX_DAYS_PER_CHILD_PER_YEAR {
            return error(string `${child.name} has already used ${VAB_MAX_DAYS_PER_CHILD_PER_YEAR} VAB days in ${year}.`);
        }
    }
    int full = sicknessLevelDaily(parent.annualIncomeSek, VAB_MAX_DAILY_SEK);
    VabReport report = {
        reportId: uuid:createRandomUuid().substring(0, 8),
        citizenId,
        childId,
        date,
        extent,
        estimatedAmountSek: extent == "full" ? full : full / 2
    };
    lock {
        vabReports.push(report.clone());
    }
    return report;
}

# Lists all VAB days a parent has reported.
#
# + citizenId - The parent's citizen id
# + return - The parent's VAB reports
@ai:AgentTool
isolated function listVabReports(string citizenId) returns VabReport[] {
    VabReport[] all;
    lock {
        all = vabReports.clone();
    }
    return from VabReport r in all
        where r.citizenId == citizenId
        select r;
}

# Returns today's date (YYYY-MM-DD) so relative dates like yesterday can be resolved.
#
# + return - Today's date
@ai:AgentTool
isolated function getCurrentDate() returns string => todayString();

final ai:Agent parentalBenefitAgent = check new ({
    systemPrompt: {
        role: "Parental Benefit and VAB Assistant for a public social insurance agency",
        instructions: string `You help parents with parental benefit (föräldrapenning) and
            temporary parental benefit for caring for a sick child (VAB).
            Always ask for the parent's citizen id (for example CIT-1001) before
            looking anything up. Use the tools for every fact about days, amounts
            and reports; never invent numbers. Resolve relative dates such as
            "yesterday" with getCurrentDate before reporting VAB. Before calling
            reportVabDay, confirm the child, date and full or half day with the parent.
            State that amounts are estimates before tax. Answer in the language the
            parent writes in (Swedish or English), be brief and friendly, and do not
            give legal advice; refer complex cases to a case handler.`
    },
    tools: [getParentProfile, estimateParentalBenefit, reportVabDay, listVabReports, getCurrentDate],
    // Gemini if geminiApiKey is set, otherwise OpenAI (see gemini_provider.bal)
    model: geminiApiKey != ""
        ? check new GeminiModelProvider(geminiApiKey, geminiModel, geminiServiceUrl, geminiFallbackModel)
        : check new openai:ModelProvider(openAiApiKey, openai:GPT_4O)
});

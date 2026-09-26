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
        string reply = check caseStatusAgent.run(request.message, request.session_id);
        return {response: reply};
    }
}

// ---------------------------------------------------------------------------
// Mock data source. In production: the agency's case management system,
// document archive and payment system, exposed as APIs through WSO2 Integrator.
// All people and numbers below are fictional.
// ---------------------------------------------------------------------------

type CaseStatus "received"|"in-review"|"awaiting-documents"|"decided";

# A benefit case.
#
# + caseId - Case identifier
# + citizenId - Applicant
# + benefitType - The benefit applied for
# + status - Current status
# + receivedDate - Date the application was received, YYYY-MM-DD
# + expectedDecisionDate - Expected decision date, YYYY-MM-DD
# + missingDocuments - Documents the applicant still needs to send
# + decision - Decision text, once decided
type BenefitCase record {|
    string caseId;
    string citizenId;
    string benefitType;
    CaseStatus status;
    string receivedDate;
    string expectedDecisionDate;
    string[] missingDocuments;
    string? decision;
|};

# A scheduled or completed payment.
#
# + citizenId - Recipient
# + benefitType - The benefit being paid
# + amountSek - Amount before tax (SEK)
# + payDate - Payment date, YYYY-MM-DD
# + status - scheduled or paid
type Payment record {|
    string citizenId;
    string benefitType;
    int amountSek;
    string payDate;
    "scheduled"|"paid" status;
|};

# Receipt for a document the applicant says they have sent.
#
# + receiptId - Receipt id
# + caseId - Case the document belongs to
# + documentName - Name of the document
# + registeredAt - When it was registered
type DocumentReceipt record {|
    string receiptId;
    string caseId;
    string documentName;
    string registeredAt;
|};

isolated map<BenefitCase> cases = {
    "FK-2026-1001": {
        caseId: "FK-2026-1001", citizenId: "CIT-3001", benefitType: "Housing allowance",
        status: "awaiting-documents", receivedDate: "2026-09-02", expectedDecisionDate: "2026-10-20",
        missingDocuments: ["Rental contract", "Income statement for 2026"], decision: ()
    },
    "FK-2026-1002": {
        caseId: "FK-2026-1002", citizenId: "CIT-3001", benefitType: "Parental benefit",
        status: "decided", receivedDate: "2026-06-11", expectedDecisionDate: "2026-07-01",
        missingDocuments: [], decision: "Approved: 60 days at sickness-benefit level from 2026-08-01."
    },
    "FK-2026-1003": {
        caseId: "FK-2026-1003", citizenId: "CIT-3002", benefitType: "Sickness benefit",
        status: "in-review", receivedDate: "2026-09-15", expectedDecisionDate: "2026-10-05",
        missingDocuments: [], decision: ()
    }
};

isolated Payment[] payments = [
    {citizenId: "CIT-3001", benefitType: "Parental benefit", amountSek: 18450, payDate: "2026-09-25", status: "paid"},
    {citizenId: "CIT-3001", benefitType: "Parental benefit", amountSek: 18450, payDate: "2026-10-26", status: "scheduled"},
    {citizenId: "CIT-3002", benefitType: "Sickness benefit", amountSek: 9800, payDate: "2026-10-26", status: "scheduled"}
];

isolated DocumentReceipt[] receipts = [];

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

# Lists all benefit cases for a citizen with status, expected decision date and missing documents.
#
# + citizenId - Citizen id, e.g. CIT-3001
# + return - The citizen's cases
@ai:AgentTool
isolated function listCases(string citizenId) returns BenefitCase[] {
    BenefitCase[] all;
    lock {
        all = cases.toArray().clone();
    }
    return from BenefitCase c in all
        where c.citizenId == citizenId
        select c;
}

# Gets the full details of one case.
#
# + caseId - Case id, e.g. FK-2026-1001
# + return - The case, or an error if not found
@ai:AgentTool
isolated function getCaseDetails(string caseId) returns BenefitCase|error {
    lock {
        BenefitCase? c = cases[caseId];
        if c is () {
            return error(string `No case found with id ${caseId}`);
        }
        return c.clone();
    }
}

# Lists paid and scheduled payments for a citizen, newest first.
#
# + citizenId - Citizen id
# + return - The citizen's payments
@ai:AgentTool
isolated function listPayments(string citizenId) returns Payment[] {
    Payment[] all;
    lock {
        all = payments.clone();
    }
    return from Payment p in all
        where p.citizenId == citizenId
        order by p.payDate descending
        select p;
}

# Registers that the citizen has sent a missing document for a case. Removes it from the
# missing list and moves the case to in-review when nothing is missing any more.
#
# + caseId - Case id
# + documentName - The document sent; must match one of the case's missing documents
# + return - A receipt, or an error if the case or document is not found
@ai:AgentTool
isolated function registerDocument(string caseId, string documentName) returns DocumentReceipt|error {
    lock {
        BenefitCase? c = cases[caseId];
        if c is () {
            return error(string `No case found with id ${caseId}`);
        }
        int? idx = ();
        foreach int i in 0 ..< c.missingDocuments.length() {
            if c.missingDocuments[i].toLowerAscii() == documentName.toLowerAscii() {
                idx = i;
            }
        }
        if idx is () {
            return error(string `${documentName} is not on the missing list for ${caseId}. Missing: ${", ".'join(...c.missingDocuments)}`);
        }
        _ = c.missingDocuments.remove(idx);
        if c.missingDocuments.length() == 0 && c.status == "awaiting-documents" {
            c.status = "in-review";
        }
    }
    DocumentReceipt receipt = {
        receiptId: "DOC-" + uuid:createRandomUuid().substring(0, 6),
        caseId,
        documentName,
        registeredAt: time:utcToString(time:utcNow())
    };
    lock {
        receipts.push(receipt.clone());
    }
    return receipt;
}

# Returns today's date (YYYY-MM-DD).
#
# + return - Today's date
@ai:AgentTool
isolated function getCurrentDate() returns string => time:utcToString(time:utcNow()).substring(0, 10);

final ai:Agent caseStatusAgent = check new ({
    systemPrompt: {
        role: "Case and Payment Status Assistant for the Swedish Social Insurance Agency",
        instructions: string `You help citizens check the status of their benefit cases,
            see which documents are missing, and find their next payment date.
            Always ask for the citizen id (for example CIT-3001) first. Use the tools for
            every fact; never guess dates, amounts or decisions. When documents are missing,
            list them clearly and offer to register one the citizen says they have sent.
            Amounts are before tax. If a citizen disagrees with a decision, explain that they
            can request a review (omprövning) within two months, and that a case handler
            handles it. Answer in the user's language (Swedish or English), briefly.`
    },
    tools: [listCases, getCaseDetails, listPayments, registerDocument, getCurrentDate],
    // Gemini if geminiApiKey is set, otherwise OpenAI (see gemini_provider.bal)
    model: geminiApiKey != ""
        ? check new GeminiModelProvider(geminiApiKey, geminiModel, geminiServiceUrl, geminiFallbackModel)
        : check new openai:ModelProvider(openAiApiKey, openai:GPT_4O)
});

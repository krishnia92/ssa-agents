import ballerina/ai;
import ballerina/http;
import ballerina/jballerina.java;

// ---------------------------------------------------------------------------
// LLM selection. Set ONE key:
//   geminiApiKey  (env BAL_CONFIG_VAR_GEMINIAPIKEY)  -> Google Gemini (free tier works)
//   openAiApiKey  (env BAL_CONFIG_VAR_OPENAIAPIKEY)  -> OpenAI gpt-4o
// If both are set, Gemini is used.
// ---------------------------------------------------------------------------
configurable string geminiApiKey = "";
configurable string geminiModel = "gemini-3.8-flash";
// Used automatically if the main model is overloaded (HTTP 503/429) after retries.
configurable string geminiFallbackModel = "gemini-3.5-flash";
configurable string geminiServiceUrl = "https://generativelanguage.googleapis.com/v1beta/openai";
configurable string openAiApiKey = "";

// ---------------------------------------------------------------------------
// Minimal Gemini model provider for the ballerina/ai Agent, using Gemini's
// OpenAI-compatible Chat Completions endpoint. Supports chat with tool calling,
// which is all the Agent needs.
// ---------------------------------------------------------------------------
const DEFAULT_GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/openai";

public isolated client class GeminiModelProvider {
    *ai:ModelProvider;
    private final http:Client httpClient;
    private final string apiKey;
    private final string model;
    // Gemini may attach a thought signature to tool calls; it must be sent back on the next turn.
    private final map<json> thoughtSignatures = {};

    private final string? fallbackModel;

    public isolated function init(string apiKey, string model = "gemini-3.8-flash",
            string serviceUrl = DEFAULT_GEMINI_URL, string? fallbackModel = ()) returns ai:Error? {
        // Retry transient overload / rate-limit responses with backoff (2s, 4s, 8s).
        // The key is set through the client's auth config (like the official OpenAI connector),
        // not as a hand-written header, so platform layers that add their own Authorization
        // header to plain requests do not replace it.
        http:Client|error c = new (serviceUrl, {
            auth: {token: apiKey},
            timeout: 120,
            retryConfig: {count: 3, interval: 2, backOffFactor: 2.0, maxWaitInterval: 10, statusCodes: [429, 500, 503]}
        });
        if c is error {
            return error ai:Error("Failed to initialize the Gemini client", c);
        }
        self.httpClient = c;
        self.apiKey = apiKey;
        self.model = model;
        self.fallbackModel = fallbackModel == model ? () : fallbackModel;
    }

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ()) returns ai:ChatAssistantMessage|ai:Error {
        json[] requestMessages = check self.toRequestMessages(messages);
        map<json> body = {model: self.model, messages: requestMessages};
        if tools.length() > 0 {
            json[] toolDefs = from ai:ChatCompletionFunctions f in tools
                select {
                    'type: "function",
                    'function: {
                        name: f.name,
                        description: f.description,
                        parameters: f?.parameters ?: {'type: "object", properties: {}}
                    }
                };
            body["tools"] = toolDefs;
        }
        if stop is string {
            body["stop"] = stop;
        }

        json|error response = self.httpClient->post("/chat/completions", body);
        string? fallback = self.fallbackModel;
        if response is http:ApplicationResponseError && fallback is string
                && (response.detail().statusCode == 503 || response.detail().statusCode == 429) {
            // Main model still overloaded after retries: try the fallback model once.
            body["model"] = fallback;
            response = self.httpClient->post("/chat/completions", body);
        }
        if response is error {
            string detail = response.message();
            if response is http:ApplicationResponseError {
                detail = detail + ": " + response.detail().body.toString();
            }
            return error ai:LlmConnectionError("Error while connecting to Gemini: " + detail, response);
        }
        return self.toAssistantMessage(response);
    }


    // Structured generation is not used by the Agent. Bound to a tiny Java stub
    // (libs/noop-generator.jar) only so this class satisfies the ModelProvider interface.
    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>) returns td|ai:Error = @java:Method {
        'class: "fkdemo.llm.NoopGenerator"
    } external;

    private isolated function toRequestMessages(ai:ChatMessage[]|ai:ChatUserMessage messages) returns json[]|ai:Error {
        if messages is ai:ChatUserMessage {
            return [{role: "user", content: check promptToString(messages.content)}];
        }
        json[] out = [];
        map<int> callCounts = {};
        map<int> resultCounts = {};
        foreach ai:ChatMessage m in messages {
            if m is ai:ChatSystemMessage {
                out.push({role: "system", content: check promptToString(m.content)});
            } else if m is ai:ChatUserMessage {
                out.push({role: "user", content: check promptToString(m.content)});
            } else if m is ai:ChatAssistantMessage {
                map<json> msg = {role: "assistant", content: m.content};
                ai:FunctionCall[]? calls = m.toolCalls;
                if calls is ai:FunctionCall[] && calls.length() > 0 {
                    json[] toolCalls = [];
                    foreach ai:FunctionCall c in calls {
                        string id = c?.id ?: nextCallId(c.name, callCounts);
                        map<json> tc = {
                            id,
                            'type: "function",
                            'function: {name: c.name, arguments: (c.arguments ?: {}).toJsonString()}
                        };
                        json sig = ();
                        lock {
                            sig = self.thoughtSignatures[id].clone();
                        }
                        if sig !is () {
                            tc["extra_content"] = sig;
                        }
                        toolCalls.push(tc);
                    }
                    msg["tool_calls"] = toolCalls;
                }
                out.push(msg);
            } else if m is ai:ChatFunctionMessage {
                out.push({
                    role: "tool",
                    tool_call_id: m?.id ?: nextCallId(m.name, resultCounts),
                    name: m.name,
                    content: m.content ?: ""
                });
            }
        }
        return out;
    }

    private isolated function toAssistantMessage(json response) returns ai:ChatAssistantMessage|ai:Error {
        do {
            map<json> resp = check response.ensureType();
            json[] choices = check resp["choices"].ensureType();
            if choices.length() == 0 {
                return error ai:LlmInvalidResponseError("Empty response from Gemini");
            }
            map<json> choice = check choices[0].ensureType();
            map<json> message = check choice["message"].ensureType();
            json content = message["content"];
            ai:ChatAssistantMessage result = {role: ai:ASSISTANT, content: content is string ? content : ()};

            json toolCallsJson = message["tool_calls"];
            if toolCallsJson is json[] && toolCallsJson.length() > 0 {
                ai:FunctionCall[] calls = [];
                foreach json item in toolCallsJson {
                    map<json> tc = check item.ensureType();
                    map<json> fn = check tc["function"].ensureType();
                    string name = check fn["name"].ensureType();
                    json rawArgs = fn["arguments"];
                    map<json> args = {};
                    if rawArgs is string && rawArgs.trim() != "" {
                        args = check (check rawArgs.fromJsonString()).ensureType();
                    } else if rawArgs is map<json> {
                        args = rawArgs;
                    }
                    json idJson = tc["id"];
                    string id = idJson is string ? idJson : string `call_${name}_${calls.length() + 1}`;
                    json extra = tc["extra_content"];
                    if extra !is () {
                        lock {
                            self.thoughtSignatures[id] = extra.clone();
                        }
                    }
                    calls.push({id, name, arguments: args});
                }
                result.toolCalls = calls;
            }
            return result;
        } on fail error e {
            return error ai:LlmInvalidResponseError("Unexpected response from Gemini: " + e.message(), e);
        }
    }
}

isolated function nextCallId(string name, map<int> counts) returns string {
    int n = (counts[name] ?: 0) + 1;
    counts[name] = n;
    return string `call_${name}_${n}`;
}

isolated function promptToString(string|ai:Prompt prompt) returns string|ai:Error {
    if prompt is string {
        return prompt;
    }
    string result = prompt.strings[0];
    foreach int i in 0 ..< prompt.insertions.length() {
        anydata insertion = prompt.insertions[i];
        if insertion is ai:TextDocument {
            result += insertion.content;
        } else if insertion is ai:Document {
            return error ai:Error("Only text content is supported by this Gemini provider.");
        } else {
            result += insertion.toString();
        }
        result += prompt.strings[i + 1];
    }
    return result;
}

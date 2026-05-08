/*
    Real-time subtitle translation for PotPlayer using DeepSeek API
*/

// Plugin Information Functions
string GetTitle() {
    return "{$CP0=DeepSeek Translate$}";
}

string GetVersion() {
    return "0.4";
}

string GetDesc() {
    return "{$CP0=Real-time subtitle translation using DeepSeek$}";
}

string GetLoginTitle() {
    return "{$CP0=API Key Configuration$}";
}

string GetLoginDesc() {
    return "{$CP936=仅输入API的值即可，账户名称留空。$}";
}

string GetPasswordText() {
    return "{$CP0=API Key:$}";
}

// Global Variables
string api_key = ""; // 全局变量，用于存储 API Key
string selected_model = "deepseek-v4-flash"; // Default model
string apiUrl = "https://api.deepseek.com/v1/chat/completions"; // DeepSeek API URL
string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
int maxRetries = 3; // Maximum number of retries for translation
int retryDelay = 1000; // Delay between retries in milliseconds

// Supported Language List
array<string> LangTable =
{
    "{$CP0=Auto Detect$}", "af", "sq", "am", "ar", "hy", "az", "eu", "be", "bn", "bs", "bg", "ca",
    "ceb", "ny", "zh-CN",
    "zh-TW", "co", "hr", "cs", "da", "nl", "en", "eo", "et", "tl", "fi", "fr",
    "fy", "gl", "ka", "de", "el", "gu", "ht", "ha", "haw", "he", "hi", "hmn", "hu", "is", "ig", "id", "ga", "it", "ja", "jw", "kn", "kk", "km",
    "ko", "ku", "ky", "lo", "la", "lv", "lt", "lb", "mk", "ms", "mg", "ml", "mt", "mi", "mr", "mn", "my", "ne", "no", "ps", "fa", "pl", "pt",
    "pa", "ro", "ru", "sm", "gd", "sr", "st", "sn", "sd", "si", "sk", "sl", "so", "es", "su", "sw", "sv", "tg", "ta", "te", "th", "tr", "uk",
    "ur", "uz", "vi", "cy", "xh", "yi", "yo", "zu"
};

// Get Source Language List
array<string> GetSrcLangs() {
    array<string> ret = LangTable;
    return ret;
}

// Get Destination Language List
array<string> GetDstLangs() {
    array<string> ret = LangTable;
    return ret;
}

// Login Interface for entering API Key
string ServerLogin(string User, string Pass) {
    // Trim whitespace
    Pass = Pass.Trim();

    // Validate API Key
    if (Pass.empty()) {
        HostPrintUTF8("{$CP0=API Key not configured. Please enter a valid API Key.$}\n");
        return "fail: API Key is empty";
    }

    // Save API Key to global variable
    api_key = Pass;

    // Save API Key to temporary storage
    HostSaveString("api_key", api_key);

    HostPrintUTF8("{$CP0=API Key successfully configured.$}\n");
    return "200 ok";
}

// JSON String Escape Function
string JsonEscape(const string &in input) {
    string output = input;
    output.replace("\\", "\\\\");
    output.replace("\"", "\\\"");
    output.replace("\n", "\\n");
    output.replace("\r", "\\r");
    output.replace("\t", "\\t");
    return output;
}

// Global variables for storing previous subtitles
array<string> subtitleHistory;
string UNICODE_RLE = "\u202B"; // For Right-to-Left languages

// Function to estimate token count based on character length
int EstimateTokenCount(const string &in text) {
    int count = 0;
    for (uint i = 0; i < text.length(); i++) {
        uint c = uint(text[i]);
        if (c >= 0x4E00 && c <= 0x9FFF) {
            count += 2; // CJK characters: ~1.5-2 tokens
        } else if (c >= 0x3000 && c <= 0x303F) {
            count += 1; // CJK punctuation
        } else if (c < 128) {
            count += 1; // ASCII: ~0.25 tokens, aggregate
        } else {
            count += 1; // Other Unicode
        }
    }
    return int(float(count) / 3) + 1;
}

// Function to get the model's maximum context length
int GetModelMaxTokens(const string &in modelName) {
    if (modelName == "deepseek-v4-flash") {
        return 16384;
    } else if (modelName == "deepseek-v4-pro") {
        return 16384;
    } else {
        return 8192;
    }
}

// Translation Function with Retry Mechanism
string Translate(string Text, string &in SrcLang, string &in DstLang) {
    // 检查 API Key 是否已配置
    if (api_key.empty()) {
        HostPrintUTF8("{$CP0=API Key not configured. Please enter it in the settings menu.$}\n");
        return "Translation failed: API Key not configured";
    }

    if (DstLang.empty() || DstLang == "{$CP0=Auto Detect$}") {
        HostPrintUTF8("{$CP0=Target language not specified. Please select a target language.$}\n");
        return "Translation failed: Target language not specified";
    }

    if (SrcLang.empty() || SrcLang == "{$CP0=Auto Detect$}") {
        SrcLang = "";
    }

    // Add the current subtitle to the history
    subtitleHistory.insertLast(Text);

    // Get the model's maximum token limit
    int maxTokens = GetModelMaxTokens(selected_model);

    // Build the context from the subtitle history
    string context = "";
    int tokenCount = EstimateTokenCount(Text); // Tokens used by the current subtitle
    int i = int(subtitleHistory.length()) - 2; // Start from the previous subtitle
    while (i >= 0 && tokenCount < (maxTokens - 1000)) { // Reserve tokens for response and prompt
        string subtitle = subtitleHistory[i];
        int subtitleTokens = EstimateTokenCount(subtitle);
        tokenCount += subtitleTokens;
        if (tokenCount < (maxTokens - 1000)) {
            context = subtitle + "\n" + context;
        }
        i--;
    }

    // Limit the size of subtitleHistory to prevent it from growing indefinitely
    if (subtitleHistory.length() > 1000) {
        subtitleHistory.removeAt(0);
    }

    // Construct system prompt
    string systemPrompt = "You are a subtitle translator. Rules:\n"
        + "1. Translate ONLY the text under 'Current subtitle'. Output ONLY the translation.\n"
        + "2. Do NOT repeat, quote, or translate the context.\n"
        + "3. Keep the translation natural and fluent.\n"
        + "4. Do not add punctuation marks.\n"
        + "5. Output nothing except the translated text.";
    if (!SrcLang.empty()) {
        systemPrompt += "\n6. Source language: " + SrcLang + ".";
    }
    systemPrompt += "\n7. Target language: " + DstLang + ".";

    // Construct user message with minimal context
    string userMsg = "";
    if (!context.empty()) {
        // Only include last 3 lines of context to avoid overwhelming the model
        array<string> ctxLines = context.split("\n");
        int start = int(ctxLines.length()) - 3;
        if (start < 0) start = 0;
        string recentCtx = "";
        for (int j = start; j < int(ctxLines.length()); j++) {
            if (!ctxLines[j].empty()) {
                recentCtx += ctxLines[j] + " ";
            }
        }
        userMsg = "Context: " + recentCtx.Trim() + "\n";
    }
    userMsg += "Current subtitle: " + Text;

    // JSON escape
    string escapedSystem = JsonEscape(systemPrompt);
    string escapedUser = JsonEscape(userMsg);

    // Request data
    string requestData = "{\"model\":\"" + selected_model + "\","
                         "\"messages\":["
                         + "{\"role\":\"system\",\"content\":\"" + escapedSystem + "\"},"
                         + "{\"role\":\"user\",\"content\":\"" + escapedUser + "\"}"
                         + "],"
                         "\"max_tokens\":4096,\"temperature\":0.3,"
                         "\"thinking\":{\"type\":\"disabled\"}}";

    string headers = "Authorization: Bearer " + api_key + "\nContent-Type: application/json";

    // Retry mechanism
    int retryCount = 0;
    while (retryCount < maxRetries) {
        // Send request
        string response = HostUrlGetString(apiUrl, UserAgent, headers, requestData);
        if (response.empty()) {
            HostPrintUTF8("{$CP0=Translation request failed. Retrying...$}\n");
            retryCount++;
            HostSleep(retryDelay); // Delay before retrying
            continue;
        }

        // Parse response
        JsonReader Reader;
        JsonValue Root;
        if (!Reader.parse(response, Root)) {
            HostPrintUTF8("{$CP0=Failed to parse API response. Retrying...$}\n");
            retryCount++;
            HostSleep(retryDelay); // Delay before retrying
            continue;
        }

        JsonValue choices = Root["choices"];
        if (choices.isArray() && choices[0]["message"]["content"].isString()) {
            string translatedText = choices[0]["message"]["content"].asString();

            // 检查 finish_reason
            string finishReason = choices[0]["finish_reason"].asString();
            if (finishReason == "length") {
                HostPrintUTF8("{$CP0=Warning: Translation truncated due to token limit.$}\n");
            } else if (finishReason == "content_filter") {
                HostPrintUTF8("{$CP0=Warning: Translation filtered by content policy.$}\n");
                retryCount++;
                HostSleep(retryDelay);
                continue;
            }

            // 处理多行翻译结果：合并为一行
            translatedText = translatedText.Trim();
            if (translatedText.find("\n") != -1) {
                translatedText.replace("\n", " ");
                translatedText = translatedText.Trim();
            }

            // 处理 RTL 语言
            if (DstLang == "fa" || DstLang == "ar" || DstLang == "he") {
                translatedText = UNICODE_RLE + translatedText;
            }

            SrcLang = "UTF8";
            DstLang = "UTF8";
            return translatedText;
        }

        // Handle API errors
        if (Root["error"]["message"].isString()) {
            string errorMessage = Root["error"]["message"].asString();
            HostPrintUTF8("{$CP0=API Error: $}" + errorMessage + "\n");
            retryCount++;
            HostSleep(retryDelay); // Delay before retrying
        } else {
            HostPrintUTF8("{$CP0=Translation failed. Retrying...$}\n");
            retryCount++;
            HostSleep(retryDelay); // Delay before retrying
        }
    }

    // If all retries fail, return an error message
    HostPrintUTF8("{$CP0=Translation failed after maximum retries.$}\n");
    return "Translation failed: Maximum retries reached. ";
}

// Plugin Initialization
void OnInitialize() {
    HostPrintUTF8("{$CP0=DeepSeek translation plugin loaded.$}\n");

    // 从持久化存储中加载 API Key
    api_key = HostLoadString("api_key", "");

    if (!api_key.empty()) {
        HostPrintUTF8("{$CP0=Saved API Key loaded.$}\n");
    } else {
        HostPrintUTF8("{$CP0=No saved API Key found. Please configure it in the settings menu.$}\n");
    }
}

// Plugin Finalization
void OnFinalize() {
    HostPrintUTF8("{$CP0=DeepSeek translation plugin unloaded.$}\n");
}

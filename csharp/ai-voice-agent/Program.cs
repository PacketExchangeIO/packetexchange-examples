// Creates an AI voice agent, tries one conversation turn without placing a call,
// and optionally attaches the agent to a voice campaign.
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

// The agent's script. A confirmation call to someone who booked an appointment is a
// transactional, expected call; keep agents to calls the recipient has agreed to receive.
const string FirstMessage =
    "Hello, this is Riverside Clinic calling to confirm your appointment tomorrow at 10:30. Can you still make it?";
const string SystemPrompt =
    "You confirm appointments for Riverside Clinic. " +
    "Ask whether the person can attend their appointment tomorrow at 10:30. " +
    "If they can, thank them and end the call. If they cannot, offer to have the clinic call them back to reschedule. " +
    "Keep every reply short and polite.";
const string Guardrails =
    "Never ask for payment details, passwords or medical information. " +
    "If the person asks to stop receiving calls, confirm and end the call.";

if (args.Length > 1)
{
    Console.Error.WriteLine("Usage: dotnet run --project ai-voice-agent -- [campaign-id]");
    return 2;
}
var campaignId = args.ElementAtOrDefault(0);
var api = PacketExchangeClient.FromEnvironment(TimeSpan.FromSeconds(30));

try
{
    // Prefer a standard (non-premium) English voice; otherwise take the first one.
    var voices = (await api.SendAsync<Envelope<List<Voice>>>(HttpMethod.Get, "/ai-agents/voices")).Data;
    if (voices.Count == 0)
    {
        Console.Error.WriteLine("No voices are available right now.");
        return 1;
    }
    var voice = voices.FirstOrDefault(v => v.Language == "en" && !v.IsPro) ?? voices[0];
    Console.WriteLine($"Using voice: {voice.Name} ({voice.Id})");

    var agent = (await api.SendAsync<Envelope<Agent>>(HttpMethod.Post, "/ai-agents", new
    {
        name = "Appointment confirmation",
        voiceId = voice.Id,
        language = "en",
        firstMessage = FirstMessage,
        systemPrompt = SystemPrompt,
        guardrails = Guardrails,
        maxCallSeconds = 180,
    })).Data;
    Console.WriteLine($"Agent created: {agent.Id}");

    // A simulated turn places no call and is not billed.
    var turn = (await api.SendAsync<Envelope<Turn>>(
        HttpMethod.Post, $"/ai-agents/{agent.Id}/simulate", new { message = "Yes, I can still make it." })).Data;
    Console.WriteLine($"Simulated reply: {turn.Reply}");
    Console.WriteLine($"  action: {turn.Action}");

    // Answered calls in the campaign are then handled by this agent.
    if (campaignId is not null)
    {
        await api.SendAsync<JsonElement>(
            HttpMethod.Put, $"/dialer/campaigns/{Uri.EscapeDataString(campaignId)}", new { aiAgentId = agent.Id });
        Console.WriteLine($"Attached agent to campaign {campaignId}");
    }
    return 0;
}
catch (ApiException e)
{
    return e.Report();
}
catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
{
    // DNS failures, refused connections and timeouts.
    Console.Error.WriteLine($"Network error: {e.Message}");
    return 1;
}

record Envelope<T>(T Data);
record Voice(string Id, string Name, string Language, [property: JsonPropertyName("is_pro")] bool IsPro);
record Agent(string Id);
record Turn(string Reply, string Action);

/// <summary>Sends authenticated JSON requests to the PacketExchange API.</summary>
sealed class PacketExchangeClient(string baseUrl, string apiKey, TimeSpan timeout)
{
    // Web defaults: camelCase property names, as the API uses.
    static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    readonly HttpClient http = new() { Timeout = timeout };

    /// <summary>
    /// Reads the API key and base URL from the environment. Exits with code 2 when
    /// the key is missing, before any request is made.
    /// </summary>
    public static PacketExchangeClient FromEnvironment(TimeSpan timeout)
    {
        var key = Environment.GetEnvironmentVariable("PACKETEXCHANGE_API_KEY");
        if (string.IsNullOrEmpty(key))
        {
            Console.Error.WriteLine("Set PACKETEXCHANGE_API_KEY first (see .env.example).");
            Environment.Exit(2);
        }
        var baseUrl = Environment.GetEnvironmentVariable("PACKETEXCHANGE_BASE_URL");
        if (string.IsNullOrEmpty(baseUrl)) baseUrl = "https://packetexchange.io/api/v1";
        return new(baseUrl.EndsWith('/') ? baseUrl[..^1] : baseUrl, key, timeout);
    }

    /// <summary>
    /// Sends one request and deserializes a 2xx body. Any other status throws an
    /// <see cref="ApiException"/>.
    /// </summary>
    public async Task<T> SendAsync<T>(HttpMethod method, string path, object? body = null)
    {
        using var request = new HttpRequestMessage(method, baseUrl + path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        // JsonContent sets Content-Type: application/json.
        if (body is not null) request.Content = JsonContent.Create(body, options: Json);

        using var response = await http.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode) throw new ApiException(response, text);
        return JsonSerializer.Deserialize<T>(text, Json)!;
    }
}

/// <summary>A response outside 200-299, kept raw so it can be reported exactly.</summary>
sealed class ApiException(HttpResponseMessage response, string body) : Exception($"HTTP {(int)response.StatusCode}")
{
    /// <summary>Prints the failure in the standard format on stderr and returns exit code 1.</summary>
    public int Report()
    {
        var status = (int)response.StatusCode;
        JsonElement error = default;
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("error", out var found) && found.ValueKind == JsonValueKind.Object)
            {
                error = found.Clone();
            }
        }
        catch (JsonException)
        {
            // Not JSON; reported below as plain text.
        }

        if (error.ValueKind == JsonValueKind.Object)
        {
            Console.Error.WriteLine($"Error {status} {Text(error, "code")}: {Text(error, "message")}");
            // details is an array of { path, message } for validation errors; some
            // codes attach an object instead, which is not listed line by line.
            if (error.TryGetProperty("details", out var details) && details.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in details.EnumerateArray())
                {
                    Console.Error.WriteLine($"  - {Text(item, "path")}: {Text(item, "message")}");
                }
            }
        }
        else
        {
            // Not the API's JSON envelope, for example an error page from a proxy.
            Console.Error.WriteLine($"Error {status}: {(body.Length > 200 ? body[..200] : body)}");
        }

        if (status == 429 && response.Headers.TryGetValues("Retry-After", out var wait))
        {
            Console.Error.WriteLine($"Retry after: {wait.First()} seconds");
        }
        if (response.Headers.TryGetValues("X-Request-Id", out var ids))
        {
            Console.Error.WriteLine($"Request id: {ids.First()}");
        }
        return 1;
    }

    static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) ? value.ToString() : null;
}

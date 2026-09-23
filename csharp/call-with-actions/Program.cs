// Calls a customer to confirm an appointment: the answered call speaks a message, asks
// for one key press, and the program follows the call until it ends.
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

var pollInterval = TimeSpan.FromSeconds(2);
var pollTimeout = TimeSpan.FromMinutes(5);
string[] finalStatuses = ["completed", "no_answer", "busy", "failed"];

// What the answered call does, in order. The call hangs up after the last action.
object[] actions =
[
    new { say = "Hello, this is Riverside Clinic calling about your appointment tomorrow at 10:30." },
    new { gather = new { digits = 1, timeout = 5, say = "Press 1 to confirm, or 2 if you need to reschedule." } },
    new { say = "Thank you. Goodbye." },
];

if (args.Length != 2)
{
    Console.Error.WriteLine("Usage: dotnet run --project call-with-actions -- <to> <caller-id>");
    return 2;
}
var (to, callerId) = (args[0], args[1]);
var api = PacketExchangeClient.FromEnvironment(TimeSpan.FromSeconds(30));

try
{
    // async: true answers as soon as the number is being dialled (HTTP 202, status
    // ringing) instead of holding the request open until the call ends.
    var placed = (await api.SendAsync<Envelope<PlacedCall>>(
        HttpMethod.Post, "/comms/calls",
        new Dictionary<string, object> { ["to"] = to, ["from"] = callerId, ["maxDuration"] = 120, ["async"] = true, ["language"] = "en", ["actions"] = actions },
        idempotent: true)).Data;
    Console.WriteLine($"Call placed: {placed.CallId} (status {placed.Status})");

    // Poll the call until it ends. In production, the call.answered, call.gathered and
    // call.completed webhooks tell you the same without polling.
    var deadline = DateTime.UtcNow + pollTimeout;
    var lastStatus = placed.Status;
    CallStatus call;
    while (true)
    {
        call = (await api.SendAsync<Envelope<CallStatus>>(HttpMethod.Get, $"/comms/calls/{Uri.EscapeDataString(placed.CallId)}")).Data;
        if (call.Status != lastStatus)
        {
            Console.WriteLine($"  status: {call.Status}");
            lastStatus = call.Status;
        }
        if (finalStatuses.Contains(call.Status)) break;
        if (DateTime.UtcNow + pollInterval > deadline)
        {
            Console.WriteLine($"Still running after 5 minutes; check GET /comms/calls/{placed.CallId} later.");
            return 0;
        }
        await Task.Delay(pollInterval);
    }

    // Gathered digits are filled in when the call ends.
    var pressed = call.Gathered?.FirstOrDefault(g => g.Index == 0)?.Digits;
    Console.WriteLine($"Call ended: {call.Status}");
    Console.WriteLine($"  durationSeconds: {call.DurationSeconds ?? 0}");
    Console.WriteLine($"  cost: {call.Cost ?? "none"}");
    Console.WriteLine($"  hangupReason: {call.HangupReason ?? "none"}");
    Console.WriteLine($"  keyPressed: {pressed ?? "none"}");
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
record PlacedCall(string CallId, string Status);
record Gathered(int Index, string? Digits);
// Cost is a 6-decimal USD string; keep it as a string rather than a floating-point number.
record CallStatus(string CallId, string Status, int? DurationSeconds, string? Cost, string? HangupReason, Gathered[]? Gathered);

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
    /// <see cref="ApiException"/>. With <paramref name="idempotent"/> set, a fresh
    /// X-Idempotency-Key makes a retry safe: the API replays the first response
    /// instead of acting twice.
    /// </summary>
    public async Task<T> SendAsync<T>(HttpMethod method, string path, object? body = null, bool idempotent = false)
    {
        using var request = new HttpRequestMessage(method, baseUrl + path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (idempotent) request.Headers.Add("X-Idempotency-Key", Guid.NewGuid().ToString());
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

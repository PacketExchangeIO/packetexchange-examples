// Sends a one-time code by SMS with the Verify API, then checks the code the user types.
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

if (args.Length != 1)
{
    Console.Error.WriteLine("Usage: dotnet run --project verify-sms -- <to>");
    return 2;
}
var to = args[0];
var api = PacketExchangeClient.FromEnvironment(TimeSpan.FromSeconds(30));

try
{
    var start = (await api.SendAsync<Envelope<VerifyStart>>(
        HttpMethod.Post, "/verify/start", new { to, channel = "sms" }, idempotent: true)).Data;
    Console.WriteLine($"Verification sent by SMS to {to}");
    Console.WriteLine($"  verificationId: {start.VerificationId}");
    Console.WriteLine($"  expiresAt: {start.ExpiresAt}");
    // testCode is only ever returned for test keys, so a sandbox can finish the flow.
    if (start.TestCode is not null) Console.WriteLine($"  testCode: {start.TestCode}");

    // A denied result is a normal outcome, not an error.
    Console.Write("Enter the code: ");
    var code = (Console.ReadLine() ?? "").Trim();
    var check = (await api.SendAsync<Envelope<VerifyCheck>>(
        HttpMethod.Post, "/verify/check", new { verificationId = start.VerificationId, code })).Data;
    Console.WriteLine($"Check result: {check.Status}{(check.Reason is null ? "" : $" ({check.Reason})")}");
    Console.WriteLine($"  attemptsRemaining: {check.AttemptsRemaining}");
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
record VerifyStart(string VerificationId, string ExpiresAt, string? TestCode);
record VerifyCheck(string Status, int AttemptsRemaining, string? Reason);

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

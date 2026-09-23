// Looks up a phone number before you message or call it: whether it is a valid E.164
// number, its country, line type and network, risk flags, and the cheapest live price.
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

if (args.Length != 1)
{
    Console.Error.WriteLine("Usage: dotnet run --project number-lookup -- <number>");
    return 2;
}
var api = PacketExchangeClient.FromEnvironment(TimeSpan.FromSeconds(30));

try
{
    // Encode the number for use in the URL path, leading "+" included.
    var data = (await api.SendAsync<Envelope<Lookup>>(HttpMethod.Get, "/lookup/" + Uri.EscapeDataString(args[0]))).Data;

    // A malformed number is a normal answer (valid: false), not an HTTP error.
    if (!data.Valid)
    {
        Console.WriteLine($"Not a valid number: {data.Reason}");
        return 0;
    }
    Console.WriteLine($"{data.E164} ({data.InternationalFormat})");
    Console.WriteLine($"  country: {(data.Country is { } c ? $"{c.Name} ({c.Iso ?? "shared dial code"})" : "unknown")}");
    Console.WriteLine($"  numberType: {data.NumberType}");
    // From number-range data: a ported number still shows the network its range belongs to.
    Console.WriteLine($"  network: {data.Network?.Operator ?? "unknown"}");
    Console.WriteLine($"  risk: blocked {Bool(data.Risk.Blocked)}, highRisk {Bool(data.Risk.HighRisk)}");
    foreach (var reason in data.Risk.Reasons) Console.WriteLine($"    - {reason}");
    Console.WriteLine(PriceLine("voice", data.Pricing.Voice));
    Console.WriteLine(PriceLine("sms", data.Pricing.Sms));
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
record Country(string? Iso, string Name);
record Network(string? Operator);
record Risk(bool Blocked, bool HighRisk, string[] Reasons);
// Rates are 6-decimal USD strings; keep them as strings rather than floating-point numbers.
record Price(string Rate, string Unit, string RouteId, int RoutesServing);
record Pricing(Price? Voice, Price? Sms);
record Lookup(bool Valid, string? Reason, string? E164, string? InternationalFormat, Country? Country,
    string NumberType, Network? Network, Risk Risk, Pricing Pricing);

partial class Program
{
    static string Bool(bool value) => value ? "true" : "false";

    /// <summary>One price line: the cheapest live route, or "no route" when none serves the number.</summary>
    static string PriceLine(string label, Price? price) => price is null
        ? $"  {label}: no route"
        : $"  {label}: {price.Rate}/{price.Unit} via {price.RouteId} ({price.RoutesServing} routes serve it)";
}

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

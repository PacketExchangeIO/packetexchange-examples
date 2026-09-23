// Searches the number catalogue, buys a number (only with --confirm) and points
// a number you own at a SIP endpoint or a phone.
using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

// --confirm may appear anywhere, so separate it from the positional arguments.
var confirm = args.Contains("--confirm");
var positional = args.Where(a => a != "--confirm").ToArray();

try
{
    switch (positional)
    {
        case ["search"]:
        case ["search", _]:
            return await Search(positional.ElementAtOrDefault(1));
        case ["buy", var groupId, var skuId]:
            if (!confirm)
            {
                Console.Error.WriteLine("Buying a number charges the setup price plus the first month to your balance.");
                Console.Error.WriteLine("Re-run with --confirm to place the order.");
                return 2;
            }
            return await Buy(groupId, skuId);
        case ["route", var didId, "sip" or "forward", var target]:
            return await Route(didId, positional[2], target);
        default:
            Console.Error.WriteLine("Usage: dotnet run --project phone-numbers -- search [pattern] | " +
                "buy <groupId> <skuId> [--confirm] | route <didId> sip|forward <target>");
            return 2;
    }
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

// Lists matching number groups and the SKUs you can buy in each.
// Note that hits sit at the top level of the response, not under data.
static async Task<int> Search(string? pattern)
{
    var api = PacketExchangeClient.FromEnvironment(TimeSpan.FromSeconds(30));
    var path = "/dids/search?limit=5" + (pattern is null ? "" : "&pattern=" + Uri.EscapeDataString(pattern));
    var result = await api.SendAsync<SearchResult>(HttpMethod.Get, path);
    if (StoreUnavailable(result.Data)) return 0;

    var hits = result.Hits ?? [];
    Console.WriteLine($"{hits.Count} number groups found:");
    foreach (var hit in hits)
    {
        var place = string.IsNullOrEmpty(hit.City) ? hit.Country : $"{hit.Country}, {hit.City}";
        Console.WriteLine($"  {hit.DialingPrefix}  {place}  {hit.TypeName}  groupId {hit.GroupId}");
        foreach (var sku in hit.Skus)
        {
            Console.WriteLine($"    skuId {sku.SkuId}: setup ${Money(sku.SetupPrice)}, " +
                $"monthly ${Money(sku.MonthlyPrice)}, {sku.Channels} channels");
        }
    }
    return 0;
}

// Orders one number. It charges your balance, which is why it requires --confirm.
static async Task<int> Buy(string groupId, string skuId)
{
    var api = PacketExchangeClient.FromEnvironment(TimeSpan.FromSeconds(30));
    var did = (await api.SendAsync<Envelope<Did>>(HttpMethod.Post, "/dids/buy", new { groupId, skuId }, idempotent: true)).Data;
    if (StoreUnavailable(did)) return 0;

    Console.WriteLine($"Number ordered: {did.Id}");
    Console.WriteLine($"  status: {did.Status}");
    // number stays null until the carrier finishes provisioning.
    Console.WriteLine($"  number: {did.Number ?? "pending"}");
    Console.WriteLine($"  setupPrice: {did.SetupPrice}");
    Console.WriteLine($"  monthlyPrice: {did.MonthlyPrice}");
    return 0;
}

// Points a number at a SIP endpoint (host[:port]) or forwards it to a phone (E.164).
static async Task<int> Route(string didId, string mode, string target)
{
    var api = PacketExchangeClient.FromEnvironment(TimeSpan.FromSeconds(30));
    var did = (await api.SendAsync<Envelope<Did>>(
        HttpMethod.Patch, $"/dids/{Uri.EscapeDataString(didId)}/routing", new { mode, target })).Data;
    Console.WriteLine($"Number {did.Id} now routes to {did.PointMode} {did.PointsTo}");
    return 0;
}

// While the number store is switched off, data carries { disabled, message } instead of results.
static bool StoreUnavailable(IStoreStatus? data)
{
    if (data?.Disabled != true) return false;
    Console.WriteLine($"Number store unavailable: {data.Message}");
    return true;
}

// Catalogue prices are plain JSON numbers for display, unlike the 6-decimal money strings.
static string Money(decimal value) => value.ToString("0.00", CultureInfo.InvariantCulture);

interface IStoreStatus
{
    bool Disabled { get; }
    string? Message { get; }
}
record StoreStatus(bool Disabled, string? Message) : IStoreStatus;
record Envelope<T>(T Data);
record SearchResult(StoreStatus? Data, List<Hit>? Hits);
record Hit(string GroupId, string Country, string? City, string? TypeName, string DialingPrefix, List<Sku> Skus);
record Sku(string SkuId, decimal SetupPrice, decimal MonthlyPrice, int Channels);
record Did(string Id, string Status, string? Number, string SetupPrice, string MonthlyPrice, string PointMode,
    string? PointsTo, bool Disabled, string? Message) : IStoreStatus;

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

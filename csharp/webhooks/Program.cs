// A minimal HTTP server that verifies PacketExchange webhook signatures before
// trusting a delivery.
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

// Deliveries signed more than this far from now are refused, which stops a
// captured delivery from being replayed later.
const long ToleranceSeconds = 300;

var secret = Environment.GetEnvironmentVariable("PACKETEXCHANGE_WEBHOOK_SECRET");
if (string.IsNullOrEmpty(secret))
{
    Console.Error.WriteLine("Set PACKETEXCHANGE_WEBHOOK_SECRET first (see .env.example).");
    return 2;
}
var port = Environment.GetEnvironmentVariable("PORT") is { Length: > 0 } p ? p : "3000";

var builder = WebApplication.CreateSlimBuilder();
builder.Logging.ClearProviders();
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
var app = builder.Build();

// Map every method so that anything other than POST gets a plain 404 rather than 405.
app.Map("/webhooks", async (HttpRequest request) =>
{
    if (!HttpMethods.IsPost(request.Method)) return Results.NotFound();

    // Verify the raw bytes exactly as sent: re-encoding parsed JSON would change them.
    using var buffer = new MemoryStream();
    await request.Body.CopyToAsync(buffer);
    var body = buffer.ToArray();

    var (scheme, reason) = Verify(secret, request.Headers, body);
    if (reason is not null)
    {
        Console.Error.WriteLine($"Rejected delivery: {reason}");
        return Results.Text(reason, statusCode: 401);
    }

    // The body is trusted from here on. Every delivery is { event, data, timestamp }.
    using var delivery = JsonDocument.Parse(body);
    var eventName = delivery.RootElement.GetProperty("event").GetString();
    Console.WriteLine($"Received {eventName} (delivery {request.Headers["X-Webhook-Id"]}, scheme {scheme})");
    return Results.Json(new { received = true });
});
// Any other path falls through to a 404.

Console.WriteLine($"Listening on http://localhost:{port}/webhooks");
await app.RunAsync();
return 0;

// Returns the scheme used, or a reason to reject. The timestamped v1 scheme is
// preferred; the legacy scheme is used only when a delivery carries no v1 signature.
static (string? Scheme, string? Reason) Verify(string secret, IHeaderDictionary headers, byte[] body)
{
    var signature = headers["X-PX-Signature"].ToString();
    if (signature.Length > 0)
    {
        var timestamp = headers["X-PX-Timestamp"].ToString();
        if (timestamp.Length == 0) return (null, "missing X-PX-Timestamp");
        if (!long.TryParse(timestamp, out var sent)) return (null, "invalid X-PX-Timestamp");
        if (Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - sent) > ToleranceSeconds) return (null, "stale timestamp");
        var signed = Encoding.UTF8.GetBytes(timestamp + ".").Concat(body).ToArray();
        return signature.StartsWith("v1=") && Matches(secret, signed, signature[3..])
            ? ("v1", null)
            : (null, "invalid signature");
    }

    // Legacy scheme: proves who sent the body, but not when, so it cannot stop replays.
    var legacy = headers["X-Webhook-Signature"].ToString();
    if (legacy.Length == 0) return (null, "missing signature");
    return legacy.StartsWith("sha256=") && Matches(secret, body, legacy["sha256=".Length..])
        ? ("legacy", null)
        : (null, "invalid signature");
}

// Compares a hex HMAC-SHA256 in constant time, so response timing does not
// reveal how much of a forged signature was right.
static bool Matches(string secret, byte[] message, string signatureHex)
{
    byte[] given;
    try
    {
        given = Convert.FromHexString(signatureHex);
    }
    catch (FormatException)
    {
        return false;
    }
    var expected = HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), message);
    return CryptographicOperations.FixedTimeEquals(expected, given);
}

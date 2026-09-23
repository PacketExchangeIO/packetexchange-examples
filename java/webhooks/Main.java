import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.InvalidKeyException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** A minimal HTTP server that verifies PacketExchange webhook signatures before trusting a delivery. */
public class Main {
    // Deliveries signed more than this far from now are refused, which stops a
    // captured delivery from being replayed later.
    static final long TOLERANCE_SECONDS = 300;

    /** The outcome of a check: the scheme that verified, or the reason to reject. */
    record Verdict(String scheme, String reason) {
        static Verdict ok(String scheme) {
            return new Verdict(scheme, null);
        }

        static Verdict reject(String reason) {
            return new Verdict(null, reason);
        }
    }

    public static void main(String[] args) throws IOException {
        String secret = System.getenv("PACKETEXCHANGE_WEBHOOK_SECRET");
        if (secret == null || secret.isEmpty()) {
            System.err.println("Set PACKETEXCHANGE_WEBHOOK_SECRET first (see .env.example).");
            System.exit(2);
        }
        String port = System.getenv().getOrDefault("PORT", "3000");

        HttpServer server = HttpServer.create(new InetSocketAddress(Integer.parseInt(port)), 0);
        server.createContext("/", exchange -> {
            try (exchange) {
                if (!exchange.getRequestMethod().equals("POST") || !exchange.getRequestURI().getPath().equals("/webhooks")) {
                    respond(exchange, 404, "text/plain", "Not found");
                    return;
                }
                // Verify the raw bytes exactly as sent: re-encoding parsed JSON would change them.
                byte[] body = exchange.getRequestBody().readAllBytes();
                Verdict verdict = verify(secret, exchange, body);
                if (verdict.reason() != null) {
                    System.err.println("Rejected delivery: " + verdict.reason());
                    respond(exchange, 401, "text/plain", verdict.reason());
                    return;
                }
                // The body is trusted from here on. Every delivery is { event, data, timestamp }.
                String event = JsonParser.parseString(new String(body, StandardCharsets.UTF_8))
                        .getAsJsonObject().get("event").getAsString();
                System.out.printf("Received %s (delivery %s, scheme %s)%n",
                        event, exchange.getRequestHeaders().getFirst("X-Webhook-Id"), verdict.scheme());
                respond(exchange, 200, "application/json", "{\"received\":true}");
            }
        });
        server.start();
        System.out.println("Listening on http://localhost:" + port + "/webhooks");
    }

    /**
     * Checks the signature. The timestamped v1 scheme is preferred; the legacy
     * scheme is used only when a delivery carries no v1 signature.
     */
    static Verdict verify(String secret, HttpExchange exchange, byte[] body) {
        String signature = exchange.getRequestHeaders().getFirst("X-PX-Signature");
        if (signature != null) {
            String timestamp = exchange.getRequestHeaders().getFirst("X-PX-Timestamp");
            if (timestamp == null) {
                return Verdict.reject("missing X-PX-Timestamp");
            }
            if (!timestamp.matches("\\d{1,15}")) {
                return Verdict.reject("invalid X-PX-Timestamp");
            }
            if (Math.abs(System.currentTimeMillis() / 1000 - Long.parseLong(timestamp)) > TOLERANCE_SECONDS) {
                return Verdict.reject("stale timestamp");
            }
            byte[] prefix = (timestamp + ".").getBytes(StandardCharsets.UTF_8);
            byte[] signed = new byte[prefix.length + body.length];
            System.arraycopy(prefix, 0, signed, 0, prefix.length);
            System.arraycopy(body, 0, signed, prefix.length, body.length);
            return signature.startsWith("v1=") && matches(secret, signed, signature.substring(3))
                    ? Verdict.ok("v1")
                    : Verdict.reject("invalid signature");
        }

        // Legacy scheme: proves who sent the body, but not when, so it cannot stop replays.
        String legacy = exchange.getRequestHeaders().getFirst("X-Webhook-Signature");
        if (legacy == null) {
            return Verdict.reject("missing signature");
        }
        return legacy.startsWith("sha256=") && matches(secret, body, legacy.substring("sha256=".length()))
                ? Verdict.ok("legacy")
                : Verdict.reject("invalid signature");
    }

    /**
     * Compares a hex HMAC-SHA256 in constant time, so response timing does not
     * reveal how much of a forged signature was right.
     */
    static boolean matches(String secret, byte[] message, String signatureHex) {
        byte[] given;
        try {
            given = HexFormat.of().parseHex(signatureHex);
        } catch (IllegalArgumentException notHex) {
            return false;
        }
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            return MessageDigest.isEqual(mac.doFinal(message), given);
        } catch (NoSuchAlgorithmException | InvalidKeyException e) {
            throw new IllegalStateException(e);
        }
    }

    static void respond(HttpExchange exchange, int status, String contentType, String text) throws IOException {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", contentType);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }
}

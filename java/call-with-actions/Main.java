import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParseException;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Calls a customer to confirm an appointment: the answered call speaks a message, asks
 * for one key press, and the program follows the call until it ends.
 */
public class Main {
    static final Duration POLL_INTERVAL = Duration.ofSeconds(2);
    static final Duration POLL_TIMEOUT = Duration.ofMinutes(5);
    static final Set<String> FINAL_STATUSES = Set.of("completed", "no_answer", "busy", "failed");

    // What the answered call does, in order. The call hangs up after the last action.
    static final List<Map<String, ?>> ACTIONS = List.of(
            Map.of("say", "Hello, this is Riverside Clinic calling about your appointment tomorrow at 10:30."),
            Map.of("gather", Map.of("digits", 1, "timeout", 5,
                    "say", "Press 1 to confirm, or 2 if you need to reschedule.")),
            Map.of("say", "Thank you. Goodbye."));

    public static void main(String[] args) {
        if (args.length != 2) {
            System.err.println("Usage: java -cp 'target/dependency/*' call-with-actions/Main.java <to> <caller-id>");
            System.exit(2);
        }
        String to = args[0];
        String callerId = args[1];
        Api api = Api.fromEnvironment(Duration.ofSeconds(30));

        runOrExit(() -> {
            // async: true answers as soon as the number is being dialled (HTTP 202, status
            // ringing) instead of holding the request open until the call ends.
            Map<String, ?> body = Map.of("to", to, "from", callerId, "maxDuration", 120, "async", true,
                    "language", "en", "actions", ACTIONS);
            JsonObject placed = api.send("POST", "/comms/calls", body, true).getAsJsonObject("data");
            String id = text(placed, "callId");
            System.out.printf("Call placed: %s (status %s)%n", id, text(placed, "status"));

            JsonObject call = poll(api, id, text(placed, "status"));
            if (call == null) {
                System.out.printf("Still running after 5 minutes; check GET /comms/calls/%s later.%n", id);
                return;
            }
            // Gathered digits are filled in when the call ends.
            String pressed = null;
            if (call.get("gathered") instanceof JsonArray gathered) {
                for (JsonElement item : gathered) {
                    JsonObject entry = item.getAsJsonObject();
                    if (entry.get("index").getAsInt() == 0) {
                        pressed = text(entry, "digits");
                    }
                }
            }
            System.out.println("Call ended: " + text(call, "status"));
            System.out.println("  durationSeconds: " + orElse(text(call, "durationSeconds"), "0"));
            System.out.println("  cost: " + orElse(text(call, "cost"), "none"));
            System.out.println("  hangupReason: " + orElse(text(call, "hangupReason"), "none"));
            System.out.println("  keyPressed: " + orElse(pressed, "none"));
        });
    }

    /**
     * Reads the call straight away, then every 2 seconds, until it ends or 5 minutes
     * pass. Returns null on timeout. In production, the call.answered, call.gathered and
     * call.completed webhooks tell you the same without polling.
     */
    static JsonObject poll(Api api, String id, String lastStatus) throws IOException, InterruptedException, ApiException {
        long deadline = System.nanoTime() + POLL_TIMEOUT.toNanos();
        String path = "/comms/calls/" + URLEncoder.encode(id, StandardCharsets.UTF_8);
        while (true) {
            JsonObject call = api.send("GET", path, null, false).getAsJsonObject("data");
            String status = text(call, "status");
            if (!status.equals(lastStatus)) {
                System.out.println("  status: " + status);
                lastStatus = status;
            }
            if (FINAL_STATUSES.contains(status)) {
                return call;
            }
            if (System.nanoTime() + POLL_INTERVAL.toNanos() > deadline) {
                return null;
            }
            Thread.sleep(POLL_INTERVAL.toMillis());
        }
    }

    static String orElse(String value, String fallback) {
        return value == null ? fallback : value;
    }

    /** Sends authenticated JSON requests to the PacketExchange API. */
    static final class Api {
        private static final Gson GSON = new Gson();
        private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();
        private final String baseUrl;
        private final String apiKey;
        private final Duration timeout;

        private Api(String baseUrl, String apiKey, Duration timeout) {
            this.baseUrl = baseUrl;
            this.apiKey = apiKey;
            this.timeout = timeout;
        }

        /**
         * Reads the API key and base URL from the environment. Exits with code 2 when
         * the key is missing, before any request is made.
         */
        static Api fromEnvironment(Duration timeout) {
            String key = System.getenv("PACKETEXCHANGE_API_KEY");
            if (key == null || key.isEmpty()) {
                System.err.println("Set PACKETEXCHANGE_API_KEY first (see .env.example).");
                System.exit(2);
            }
            String base = System.getenv("PACKETEXCHANGE_BASE_URL");
            if (base == null || base.isEmpty()) {
                base = "https://packetexchange.io/api/v1";
            }
            if (base.endsWith("/")) {
                base = base.substring(0, base.length() - 1);
            }
            return new Api(base, key, timeout);
        }

        /**
         * Sends one request and returns the parsed JSON body of a 2xx response. Any
         * other status throws an {@link ApiException}. With {@code idempotent} set, a
         * fresh X-Idempotency-Key makes a retry safe: the API replays the first
         * response instead of acting twice.
         */
        JsonObject send(String method, String path, Map<String, ?> body, boolean idempotent)
                throws IOException, InterruptedException, ApiException {
            HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(baseUrl + path))
                    .timeout(timeout)
                    .header("Authorization", "Bearer " + apiKey)
                    .header("Content-Type", "application/json")
                    .header("Accept", "application/json")
                    .method(method, body == null
                            ? HttpRequest.BodyPublishers.noBody()
                            : HttpRequest.BodyPublishers.ofString(GSON.toJson(body)));
            if (idempotent) {
                request.header("X-Idempotency-Key", UUID.randomUUID().toString());
            }
            HttpResponse<String> response = http.send(request.build(), HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() < 200 || response.statusCode() > 299) {
                throw new ApiException(response);
            }
            return JsonParser.parseString(response.body()).getAsJsonObject();
        }
    }

    /** A response outside 200-299, keeping what is needed to report it exactly. */
    static final class ApiException extends Exception {
        @java.io.Serial
        private static final long serialVersionUID = 1L;
        private final int status;
        private final String body;
        private final String requestId;
        private final String retryAfter;

        ApiException(HttpResponse<String> response) {
            super("HTTP " + response.statusCode());
            this.status = response.statusCode();
            this.body = response.body();
            this.requestId = response.headers().firstValue("X-Request-Id").orElse(null);
            this.retryAfter = response.headers().firstValue("Retry-After").orElse(null);
        }

        /** Prints the failure in the standard format on stderr and returns exit code 1. */
        int report() {
            JsonObject error = null;
            try {
                JsonElement parsed = JsonParser.parseString(body);
                if (parsed.isJsonObject() && parsed.getAsJsonObject().get("error") instanceof JsonObject found) {
                    error = found;
                }
            } catch (JsonParseException notJson) {
                // Reported below as plain text.
            }
            if (error != null) {
                System.err.printf("Error %d %s: %s%n", status, text(error, "code"), text(error, "message"));
                // details is an array of { path, message } for validation errors; some
                // codes attach an object instead, which is not listed line by line.
                if (error.get("details") instanceof JsonArray details) {
                    for (JsonElement item : details) {
                        JsonObject detail = item.getAsJsonObject();
                        System.err.printf("  - %s: %s%n", text(detail, "path"), text(detail, "message"));
                    }
                }
            } else {
                // Not the API's JSON envelope, for example an error page from a proxy.
                System.err.printf("Error %d: %s%n", status, body.length() > 200 ? body.substring(0, 200) : body);
            }
            if (status == 429 && retryAfter != null) {
                System.err.println("Retry after: " + retryAfter + " seconds");
            }
            if (requestId != null) {
                System.err.println("Request id: " + requestId);
            }
            return 1;
        }
    }

    /** Returns a field as text, or null when it is absent or JSON null. */
    static String text(JsonObject object, String name) {
        JsonElement value = object.get(name);
        return value == null || value.isJsonNull() ? null : value.getAsString();
    }

    /** Runs the example, turning request failures into the standard output and exit code. */
    static void runOrExit(Example example) {
        try {
            example.run();
        } catch (ApiException e) {
            System.exit(e.report());
        } catch (IOException e) {
            // DNS failures, refused connections and timeouts.
            // Some of these exceptions carry no message, so fall back to the exception type.
            System.err.println("Network error: " + (e.getMessage() != null ? e.getMessage() : e.getClass().getName()));
            System.exit(1);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            System.exit(1);
        }
    }

    @FunctionalInterface
    interface Example {
        void run() throws IOException, InterruptedException, ApiException;
    }
}

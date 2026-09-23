import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParseException;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Places one outbound call, then finds its charge in the call ledger. */
public class Main {
    public static void main(String[] args) {
        if (args.length < 2 || args.length > 3 || (args.length == 3 && !args[2].matches("\\d{1,5}"))) {
            System.err.println("Usage: java -cp 'target/dependency/*' make-call/Main.java <to> <caller-id> [max-duration-seconds]");
            System.exit(2);
        }
        String to = args[0];
        String callerId = args[1];
        int maxDuration = args.length == 3 ? Integer.parseInt(args[2]) : 60;
        // POST /comms/calls answers only when the call has ended, so the client must
        // wait at least as long as the call may last.
        Api api = Api.fromEnvironment(Duration.ofSeconds(maxDuration + 30L));

        runOrExit(() -> {
            Map<String, Object> body = Map.of("to", to, "from", callerId, "maxDuration", maxDuration);
            JsonObject call = api.send("POST", "/comms/calls", body, true).getAsJsonObject("data");
            String callId = text(call, "callId");
            System.out.println("Call finished: " + callId);
            System.out.println("  status: " + text(call, "status"));
            System.out.println("  durationSeconds: " + text(call, "durationSeconds"));
            System.out.println("  billableSeconds: " + text(call, "billableSeconds"));
            System.out.println("  cost: " + text(call, "cost"));
            System.out.println("  hangupCause: " + Objects.requireNonNullElse(text(call, "hangupCause"), "none"));

            // The call history is a ledger: each entry is the signed charge and the balance after it.
            JsonArray entries = api.send("GET", "/comms/calls?limit=25", null, false).getAsJsonArray("data");
            for (JsonElement element : entries) {
                JsonObject entry = element.getAsJsonObject();
                if (callId.equals(text(entry, "relatedEntityId")) || callId.equals(text(entry, "callId"))) {
                    System.out.println("Ledger entry: " + text(entry, "amount")
                            + " (balance after " + text(entry, "balanceAfter") + ")");
                    return;
                }
            }
            System.out.println("Ledger entry: not in the latest 25 entries");
        });
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

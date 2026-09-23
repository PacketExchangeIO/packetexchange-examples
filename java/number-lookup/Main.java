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
import java.util.Map;

/**
 * Looks up a phone number before you message or call it: whether it is a valid E.164
 * number, its country, line type and network, risk flags, and the cheapest live price.
 */
public class Main {
    public static void main(String[] args) {
        if (args.length != 1) {
            System.err.println("Usage: java -cp 'target/dependency/*' number-lookup/Main.java <number>");
            System.exit(2);
        }
        String number = args[0];
        Api api = Api.fromEnvironment(Duration.ofSeconds(30));

        runOrExit(() -> {
            // Encode the number for use in the URL path, leading "+" included.
            String path = "/lookup/" + URLEncoder.encode(number, StandardCharsets.UTF_8);
            JsonObject data = api.send("GET", path, null).getAsJsonObject("data");

            // A malformed number is a normal answer (valid: false), not an HTTP error.
            if (!data.get("valid").getAsBoolean()) {
                System.out.println("Not a valid number: " + text(data, "reason"));
                return;
            }
            System.out.printf("%s (%s)%n", text(data, "e164"), text(data, "internationalFormat"));
            JsonObject country = object(data, "country");
            System.out.println("  country: " + (country == null ? "unknown"
                    : "%s (%s)".formatted(text(country, "name"), orElse(text(country, "iso"), "shared dial code"))));
            System.out.println("  numberType: " + text(data, "numberType"));
            // From number-range data: a ported number still shows the network its range belongs to.
            JsonObject network = object(data, "network");
            System.out.println("  network: " + orElse(network == null ? null : text(network, "operator"), "unknown"));
            JsonObject risk = data.getAsJsonObject("risk");
            System.out.printf("  risk: blocked %s, highRisk %s%n", text(risk, "blocked"), text(risk, "highRisk"));
            for (JsonElement reason : risk.getAsJsonArray("reasons")) {
                System.out.println("    - " + reason.getAsString());
            }
            JsonObject pricing = data.getAsJsonObject("pricing");
            System.out.println(priceLine("voice", object(pricing, "voice")));
            System.out.println(priceLine("sms", object(pricing, "sms")));
        });
    }

    /** One price line: the cheapest live route, or "no route" when none serves the number. */
    static String priceLine(String label, JsonObject price) {
        if (price == null) {
            return "  " + label + ": no route";
        }
        return "  %s: %s/%s via %s (%s routes serve it)".formatted(label, text(price, "rate"), text(price, "unit"),
                text(price, "routeId"), text(price, "routesServing"));
    }

    /** Returns a nested object, or null when it is absent or JSON null. */
    static JsonObject object(JsonObject parent, String name) {
        return parent.get(name) instanceof JsonObject found ? found : null;
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
         * other status throws an {@link ApiException}.
         */
        JsonObject send(String method, String path, Map<String, ?> body)
                throws IOException, InterruptedException, ApiException {
            HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(baseUrl + path))
                    .timeout(timeout)
                    .header("Authorization", "Bearer " + apiKey)
                    .header("Content-Type", "application/json")
                    .header("Accept", "application/json")
                    .method(method, body == null
                            ? HttpRequest.BodyPublishers.noBody()
                            : HttpRequest.BodyPublishers.ofString(GSON.toJson(body)));
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

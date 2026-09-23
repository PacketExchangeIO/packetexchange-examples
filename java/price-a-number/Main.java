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
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/**
 * Prices a phone number across the marketplace, then shows which route each
 * Smart Routing strategy would pick for it.
 */
public class Main {
    public static void main(String[] args) {
        if (args.length < 1 || args.length > 2 || (args.length == 2 && !List.of("voice", "sms").contains(args[1]))) {
            System.err.println("Usage: java -cp 'target/dependency/*' price-a-number/Main.java <number> [voice|sms]");
            System.exit(2);
        }
        String number = args[0];
        String type = args.length == 2 ? args[1] : "voice";
        String encoded = URLEncoder.encode(number, StandardCharsets.UTF_8);
        Api api = Api.fromEnvironment(Duration.ofSeconds(30));

        runOrExit(() -> {
            JsonObject priced = api.send("GET", "/routes/price-number?number=" + encoded + "&type=" + type, null)
                    .getAsJsonObject("data");
            if ("sanctioned".equals(text(priced, "notice"))) {
                System.out.println("No routes: the destination is embargoed.");
            } else {
                System.out.printf("%s routes serve %s (%s), cheapest first:%n", text(priced, "total"), number, type);
                JsonArray routes = priced.getAsJsonArray("routes");
                for (int i = 0; i < Math.min(5, routes.size()); i++) {
                    JsonObject route = routes.get(i).getAsJsonObject();
                    // ASR on a listing is stated by the seller, not measured by the exchange.
                    String asr = text(route, "expectedAsr") == null
                            ? "ASR n/a"
                            : "ASR " + text(route, "expectedAsr") + "% (seller-stated)";
                    System.out.printf("  %s/%s  %s  prefix %s  %s  %s%n", text(route, "rate"), text(priced, "unit"),
                            text(route, "destination"), text(route, "matchedPrefix"), asr, text(route, "id"));
                }
            }

            String unit = type.equals("sms") ? "msg" : "min";
            for (String strategy : List.of("cheapest", "best_quality", "balanced")) {
                String path = "/routes/resolve?to=" + encoded + "&type=" + type + "&strategy=" + strategy;
                JsonElement selected = api.send("GET", path, null).getAsJsonObject("data").get("selected");
                if (selected == null || selected.isJsonNull()) {
                    System.out.printf("Strategy %s: no route%n", strategy);
                } else {
                    JsonObject route = selected.getAsJsonObject();
                    System.out.printf("Strategy %s: %s/%s via %s (%s)%n", strategy, text(route, "price"), unit,
                            text(route, "id"), text(route, "destinationName"));
                }
            }
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

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
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Searches the number catalogue, buys a number (only with --confirm) and points
 * a number you own at a SIP endpoint or a phone.
 */
public class Main {
    static final String USAGE = "Usage: java -cp 'target/dependency/*' phone-numbers/Main.java "
            + "search [pattern] | buy <groupId> <skuId> [--confirm] | route <didId> sip|forward <target>";

    public static void main(String[] argv) {
        // --confirm may appear anywhere, so separate it from the positional arguments.
        boolean confirm = List.of(argv).contains("--confirm");
        List<String> args = new ArrayList<>(List.of(argv));
        args.removeIf("--confirm"::equals);
        String command = args.isEmpty() ? "" : args.get(0);

        if (command.equals("search") && args.size() <= 2) {
            String pattern = args.size() == 2 ? args.get(1) : null;
            runOrExit(() -> search(Api.fromEnvironment(Duration.ofSeconds(30)), pattern));
        } else if (command.equals("buy") && args.size() == 3) {
            if (!confirm) {
                System.err.println("Buying a number charges the setup price plus the first month to your balance.");
                System.err.println("Re-run with --confirm to place the order.");
                System.exit(2);
            }
            runOrExit(() -> buy(Api.fromEnvironment(Duration.ofSeconds(30)), args.get(1), args.get(2)));
        } else if (command.equals("route") && args.size() == 4 && List.of("sip", "forward").contains(args.get(2))) {
            runOrExit(() -> route(Api.fromEnvironment(Duration.ofSeconds(30)), args.get(1), args.get(2), args.get(3)));
        } else {
            System.err.println(USAGE);
            System.exit(2);
        }
    }

    /**
     * Lists matching number groups and the SKUs you can buy in each. Note that hits
     * sit at the top level of the response, not under data.
     */
    static void search(Api api, String pattern) throws IOException, InterruptedException, ApiException {
        String path = "/dids/search?limit=5"
                + (pattern == null ? "" : "&pattern=" + URLEncoder.encode(pattern, StandardCharsets.UTF_8));
        JsonObject result = api.send("GET", path, null, false);
        if (storeUnavailable(result.get("data"))) {
            return;
        }
        JsonArray hits = result.getAsJsonArray("hits");
        System.out.println(hits.size() + " number groups found:");
        for (JsonElement element : hits) {
            JsonObject hit = element.getAsJsonObject();
            String city = text(hit, "city");
            String place = text(hit, "country") + (city == null || city.isEmpty() ? "" : ", " + city);
            System.out.printf("  %s  %s  %s  groupId %s%n", text(hit, "dialingPrefix"), place,
                    Objects.requireNonNullElse(text(hit, "typeName"), ""), text(hit, "groupId"));
            for (JsonElement skuElement : hit.getAsJsonArray("skus")) {
                JsonObject sku = skuElement.getAsJsonObject();
                // Catalogue prices are plain JSON numbers for display, unlike the 6-decimal money strings.
                System.out.printf(Locale.ROOT, "    skuId %s: setup $%.2f, monthly $%.2f, %s channels%n",
                        text(sku, "skuId"), sku.get("setupPrice").getAsBigDecimal(),
                        sku.get("monthlyPrice").getAsBigDecimal(), text(sku, "channels"));
            }
        }
    }

    /** Orders one number. It charges your balance, which is why main requires --confirm. */
    static void buy(Api api, String groupId, String skuId) throws IOException, InterruptedException, ApiException {
        JsonObject did = api.send("POST", "/dids/buy", Map.of("groupId", groupId, "skuId", skuId), true)
                .getAsJsonObject("data");
        if (storeUnavailable(did)) {
            return;
        }
        System.out.println("Number ordered: " + text(did, "id"));
        System.out.println("  status: " + text(did, "status"));
        // number stays null until the carrier finishes provisioning.
        System.out.println("  number: " + Objects.requireNonNullElse(text(did, "number"), "pending"));
        System.out.println("  setupPrice: " + text(did, "setupPrice"));
        System.out.println("  monthlyPrice: " + text(did, "monthlyPrice"));
    }

    /** Points a number at a SIP endpoint (host[:port]) or forwards it to a phone (E.164). */
    static void route(Api api, String didId, String mode, String target)
            throws IOException, InterruptedException, ApiException {
        String path = "/dids/" + URLEncoder.encode(didId, StandardCharsets.UTF_8) + "/routing";
        JsonObject did = api.send("PATCH", path, Map.of("mode", mode, "target", target), false).getAsJsonObject("data");
        System.out.printf("Number %s now routes to %s %s%n", text(did, "id"), text(did, "pointMode"), text(did, "pointsTo"));
    }

    /** While the number store is switched off, data carries { disabled, message } instead of results. */
    static boolean storeUnavailable(JsonElement data) {
        if (data instanceof JsonObject object && "true".equals(text(object, "disabled"))) {
            System.out.println("Number store unavailable: " + text(object, "message"));
            return true;
        }
        return false;
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

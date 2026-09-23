# Searches the number catalogue, buys a number (only with --confirm) and points
# a number you own at a SIP endpoint or a phone.
require "json"
require "net/http"
require "securerandom"

USAGE = "Usage: ruby phone-numbers/main.rb search [pattern] | buy <groupId> <skuId> [--confirm] | " \
        "route <didId> sip|forward <target>"

def main(argv)
  # --confirm may appear anywhere, so separate it from the positional arguments.
  confirm = argv.include?("--confirm")
  args = argv - ["--confirm"]

  case args
  in ["search"] | ["search", _]
    search(args[1])
  in ["buy", group_id, sku_id]
    unless confirm
      warn "Buying a number charges the setup price plus the first month to your balance."
      warn "Re-run with --confirm to place the order."
      exit 2
    end
    buy(group_id, sku_id)
  in ["route", did_id, "sip" | "forward" => mode, target]
    route(did_id, mode, target)
  else
    warn USAGE
    exit 2
  end
end

# While the number store is switched off, data carries { disabled, message } instead of results.
def store_unavailable?(data)
  return false unless data.is_a?(Hash) && data["disabled"]

  puts "Number store unavailable: #{data['message']}"
  true
end

# Lists matching number groups and the SKUs you can buy in each.
# Note that hits sit at the top level of the response, not under data.
def search(pattern)
  query = { limit: 5 }
  query[:pattern] = pattern if pattern
  result = api_request("GET", "/dids/search?#{URI.encode_www_form(query)}")
  return if store_unavailable?(result["data"])

  puts "#{result['hits'].length} number groups found:"
  result["hits"].each do |hit|
    place = [hit["country"], hit["city"]].reject { |p| p.nil? || p.empty? }.join(", ")
    puts "  #{hit['dialingPrefix']}  #{place}  #{hit['typeName']}  groupId #{hit['groupId']}"
    hit["skus"].each do |sku|
      # Catalogue prices are plain JSON numbers for display, unlike the 6-decimal money strings.
      puts format("    skuId %<id>s: setup $%<setup>.2f, monthly $%<monthly>.2f, %<channels>d channels",
                  id: sku["skuId"], setup: sku["setupPrice"], monthly: sku["monthlyPrice"], channels: sku["channels"])
    end
  end
end

# Orders one number. It charges your balance, which is why main requires --confirm.
def buy(group_id, sku_id)
  did = api_request("POST", "/dids/buy", body: { groupId: group_id, skuId: sku_id }, idempotent: true)["data"]
  return if store_unavailable?(did)

  puts "Number ordered: #{did['id']}"
  puts "  status: #{did['status']}"
  # number stays null until the carrier finishes provisioning.
  puts "  number: #{did['number'] || 'pending'}"
  puts "  setupPrice: #{did['setupPrice']}"
  puts "  monthlyPrice: #{did['monthlyPrice']}"
end

# Points a number at a SIP endpoint (host[:port]) or forwards it to a phone (E.164).
def route(did_id, mode, target)
  path = "/dids/#{URI.encode_www_form_component(did_id)}/routing"
  did = api_request("PATCH", path, body: { mode: mode, target: target })["data"]
  puts "Number #{did['id']} now routes to #{did['pointMode']} #{did['pointsTo']}"
end

# Raised for any response outside 200-299, keeping what is needed to report it.
class ApiError < StandardError
  attr_reader :response

  def initialize(response)
    @response = response
    super("HTTP #{response.code}")
  end
end

# Sends one authenticated JSON request and returns the parsed body. With
# idempotent set, a fresh X-Idempotency-Key makes a retry safe: the API replays
# the first response instead of acting twice.
def api_request(method, path, body: nil, idempotent: false, timeout: 30)
  key = ENV.fetch("PACKETEXCHANGE_API_KEY", "")
  if key.empty?
    warn "Set PACKETEXCHANGE_API_KEY first (see .env.example)."
    exit 2
  end
  base = ENV.fetch("PACKETEXCHANGE_BASE_URL", "").then { |b| b.empty? ? "https://packetexchange.io/api/v1" : b }
  uri = URI(base.delete_suffix("/") + path)

  request = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri)
  request["Authorization"] = "Bearer #{key}"
  request["Content-Type"] = "application/json"
  request["Accept"] = "application/json"
  request["X-Idempotency-Key"] = SecureRandom.uuid if idempotent
  request.body = JSON.generate(body) unless body.nil?

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                 open_timeout: 10, read_timeout: timeout) do |http|
    http.request(request)
  end
  raise ApiError, response unless response.code.to_i.between?(200, 299)

  JSON.parse(response.body)
end

# Prints a failed request in the standard format on stderr and exits with code 1.
def exit_on_error(error)
  unless error.is_a?(ApiError)
    warn "Network error: #{error.message}"
    exit 1
  end

  response = error.response
  status = response.code
  envelope = begin
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    nil
  end
  if envelope.is_a?(Hash) && envelope["error"].is_a?(Hash)
    warn "Error #{status} #{envelope['error']['code']}: #{envelope['error']['message']}"
    # details is an array of { path, message } for validation errors; some codes
    # attach an object instead, which is not listed line by line.
    details = envelope["error"]["details"]
    details.each { |d| warn "  - #{d['path']}: #{d['message']}" } if details.is_a?(Array)
  else
    # Not the API's JSON envelope, for example an error page from a proxy.
    warn "Error #{status}: #{response.body.to_s[0, 200]}"
  end
  warn "Retry after: #{response['Retry-After']} seconds" if status == "429" && response["Retry-After"]
  warn "Request id: #{response['X-Request-Id']}" if response["X-Request-Id"]
  exit 1
end

# Failures a request can raise: an API error response or a network problem.
REQUEST_ERRORS = [ApiError, SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError].freeze

begin
  main(ARGV)
rescue *REQUEST_ERRORS => e
  exit_on_error(e)
end

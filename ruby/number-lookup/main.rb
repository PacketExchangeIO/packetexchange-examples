# Looks up a phone number before you message or call it: whether it is a valid E.164
# number, its country, line type and network, risk flags, and the cheapest live price.
require "json"
require "net/http"

def main(args)
  if args.length != 1
    warn "Usage: ruby number-lookup/main.rb <number>"
    exit 2
  end

  # Encode the number for use in the URL path, leading "+" included.
  data = api_request("GET", "/lookup/#{URI.encode_www_form_component(args[0])}")["data"]

  # A malformed number is a normal answer (valid: false), not an HTTP error.
  unless data["valid"]
    puts "Not a valid number: #{data['reason']}"
    return
  end
  country = data["country"]
  risk = data["risk"]
  puts "#{data['e164']} (#{data['internationalFormat']})"
  puts "  country: #{country ? "#{country['name']} (#{country['iso'] || 'shared dial code'})" : 'unknown'}"
  puts "  numberType: #{data['numberType']}"
  # From number-range data: a ported number still shows the network its range belongs to.
  puts "  network: #{data.dig('network', 'operator') || 'unknown'}"
  puts "  risk: blocked #{risk['blocked']}, highRisk #{risk['highRisk']}"
  risk["reasons"].each { |reason| puts "    - #{reason}" }
  puts price_line("voice", data["pricing"]["voice"])
  puts price_line("sms", data["pricing"]["sms"])
end

# One price line: the cheapest live route, or "no route" when none serves the number.
def price_line(label, price)
  return "  #{label}: no route" unless price

  "  #{label}: #{price['rate']}/#{price['unit']} via #{price['routeId']} (#{price['routesServing']} routes serve it)"
end

# Raised for any response outside 200-299, keeping what is needed to report it.
class ApiError < StandardError
  attr_reader :response

  def initialize(response)
    @response = response
    super("HTTP #{response.code}")
  end
end

# Sends one authenticated JSON request and returns the parsed body.
def api_request(method, path, body: nil, timeout: 30)
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

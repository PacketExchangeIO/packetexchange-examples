# Prices a phone number across the marketplace, then shows which route each
# Smart Routing strategy would pick for it.
require "json"
require "net/http"

def main(args)
  unless args.length.between?(1, 2) && [nil, "voice", "sms"].include?(args[1])
    warn "Usage: ruby price-a-number/main.rb <number> [voice|sms]"
    exit 2
  end
  number, type = args
  type ||= "voice"

  query = URI.encode_www_form(number: number, type: type)
  priced = api_request("GET", "/routes/price-number?#{query}")["data"]
  if priced["notice"] == "sanctioned"
    puts "No routes: the destination is embargoed."
  else
    puts "#{priced['total']} routes serve #{number} (#{type}), cheapest first:"
    priced["routes"].first(5).each do |route|
      # ASR on a listing is stated by the seller, not measured by the exchange.
      asr = route["expectedAsr"].nil? ? "ASR n/a" : "ASR #{route['expectedAsr']}% (seller-stated)"
      puts "  #{route['rate']}/#{priced['unit']}  #{route['destination']}  prefix #{route['matchedPrefix']}  " \
           "#{asr}  #{route['id']}"
    end
  end

  unit = type == "sms" ? "msg" : "min"
  %w[cheapest best_quality balanced].each do |strategy|
    query = URI.encode_www_form(to: number, type: type, strategy: strategy)
    selected = api_request("GET", "/routes/resolve?#{query}")["data"]["selected"]
    if selected
      puts "Strategy #{strategy}: #{selected['price']}/#{unit} via #{selected['id']} (#{selected['destinationName']})"
    else
      puts "Strategy #{strategy}: no route"
    end
  end
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

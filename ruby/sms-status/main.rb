# Reads what happened to a message you sent: every step from queued to delivered or
# failed, with timestamps. "delivered" only ever comes from a carrier receipt.
require "json"
require "net/http"

def main(args)
  if args.length != 1
    warn "Usage: ruby sms-status/main.rb <message-id>"
    exit 2
  end
  message_id = args[0]

  sms = api_request("GET", "/comms/sms/#{URI.encode_www_form_component(message_id)}")["data"]

  # An id that is not on your account answers 200 with status not_found.
  if sms["status"] == "not_found"
    warn "No message #{message_id} on this account."
    exit 1
  end
  puts "Message #{sms['messageId']}: #{sms['status']}"
  (sms["timeline"] || []).each do |step|
    extra = [step["source"], step["carrierStatus"], step["errorCode"]].compact.reject(&:empty?).join(", ")
    puts "  - #{step['status']} at #{step['at']} (#{extra})"
  end
  puts "  errorCode: #{sms['errorCode']}" if sms["errorCode"]
  # A route that returns no receipts leaves the message at "sent" for good.
  puts "  awaitingReceipt: #{sms['awaitingReceipt'] == true}"
  puts "  routeReturnsReceipts: #{sms['routeReturnsReceipts'].nil? ? 'unknown' : sms['routeReturnsReceipts']}"
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

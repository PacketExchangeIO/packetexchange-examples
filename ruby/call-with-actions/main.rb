# Calls a customer to confirm an appointment: the answered call speaks a message, asks
# for one key press, and the program follows the call until it ends.
require "json"
require "net/http"
require "securerandom"

# What the answered call does, in order. The call hangs up after the last action.
ACTIONS = [
  { say: "Hello, this is Riverside Clinic calling about your appointment tomorrow at 10:30." },
  { gather: { digits: 1, timeout: 5, say: "Press 1 to confirm, or 2 if you need to reschedule." } },
  { say: "Thank you. Goodbye." }
].freeze

POLL_INTERVAL = 2
POLL_TIMEOUT = 300
FINAL_STATUSES = %w[completed no_answer busy failed].freeze

def main(args)
  if args.length != 2
    warn "Usage: ruby call-with-actions/main.rb <to> <caller-id>"
    exit 2
  end
  to, caller_id = args

  # async: true answers as soon as the number is being dialled (HTTP 202, status
  # ringing) instead of holding the request open until the call ends.
  body = { to: to, from: caller_id, maxDuration: 120, async: true, language: "en", actions: ACTIONS }
  placed = api_request("POST", "/comms/calls", body: body, idempotent: true)["data"]
  puts "Call placed: #{placed['callId']} (status #{placed['status']})"

  call = poll(placed["callId"], placed["status"])
  unless call
    puts "Still running after 5 minutes; check GET /comms/calls/#{placed['callId']} later."
    return
  end
  # Gathered digits are filled in when the call ends.
  pressed = (call["gathered"] || []).find { |g| g["index"].zero? }&.fetch("digits")
  puts "Call ended: #{call['status']}"
  puts "  durationSeconds: #{call['durationSeconds'] || 0}"
  puts "  cost: #{call['cost'] || 'none'}"
  puts "  hangupReason: #{call['hangupReason'] || 'none'}"
  puts "  keyPressed: #{pressed || 'none'}"
end

# Reads the call straight away, then every 2 seconds, until it ends or 5 minutes pass.
# Returns nil on timeout. In production, the call.answered, call.gathered and
# call.completed webhooks tell you the same without polling.
def poll(id, last_status)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + POLL_TIMEOUT
  loop do
    call = api_request("GET", "/comms/calls/#{URI.encode_www_form_component(id)}")["data"]
    if call["status"] != last_status
      puts "  status: #{call['status']}"
      last_status = call["status"]
    end
    return call if FINAL_STATUSES.include?(call["status"])
    return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) + POLL_INTERVAL > deadline

    sleep POLL_INTERVAL
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

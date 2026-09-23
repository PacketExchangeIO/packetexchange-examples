# Sends a one-time code by voice call with the Verify API, then checks the code the user types.
require "json"
require "net/http"
require "securerandom"

def main(args)
  unless args.length.between?(2, 3)
    warn "Usage: ruby verify-voice/main.rb <to> <caller-id> [language]"
    exit 2
  end
  # Voice codes can be read in en, es, fr, de, pt and hi.
  to, caller_id, language = args
  language ||= "en"

  body = { to: to, channel: "voice", from: caller_id, language: language }
  start = api_request("POST", "/verify/start", body: body, idempotent: true)["data"]
  puts "Verification call placed to #{to} (language: #{language})"
  puts "  verificationId: #{start['verificationId']}"
  puts "  expiresAt: #{start['expiresAt']}"
  # testCode is only ever returned for test keys, so a sandbox can finish the flow.
  puts "  testCode: #{start['testCode']}" if start["testCode"]

  check_code(start["verificationId"])
end

# Reads the code from stdin and asks the API whether it matches.
# A denied result is a normal outcome, not an error.
def check_code(verification_id)
  print "Enter the code: "
  $stdout.flush
  code = $stdin.gets.to_s.strip

  check = api_request("POST", "/verify/check", body: { verificationId: verification_id, code: code })["data"]
  result = check["status"]
  result += " (#{check['reason']})" if check["reason"]
  puts "Check result: #{result}"
  puts "  attemptsRemaining: #{check['attemptsRemaining']}"
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

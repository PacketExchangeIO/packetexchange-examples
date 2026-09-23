# Runs a caller-ID test: a real call over one of your routes to a test handset,
# which reports the caller ID it actually displayed.
require "json"
require "net/http"

POLL_INTERVAL = 10
POLL_TIMEOUT = 600
FINAL_STATUSES = %w[completed failed not_tested cancelled].freeze

def main(args)
  if args.length != 3
    warn "Usage: ruby caller-id-test/main.rb <route-id> <caller-id> <country>"
    exit 2
  end
  route_id, caller_id, country = args

  quota = api_request("GET", "/cli-tests/quota")["data"]
  puts "Caller-ID test price: $#{format('%.2f', quota['costPerTest'])} per test, charged only if the route rang " \
       "(#{quota['remaining']} of #{quota['limitPerHour']} left this hour)"

  body = { routeId: route_id, displayCli: caller_id, testCountry: country }
  test = api_request("POST", "/cli-tests", body: body)["data"]
  puts "Test queued: #{test['id']} (status #{test['status']})"

  result = poll(test["id"], test["status"])
  unless result
    puts "Still running after 10 minutes; check GET /cli-tests/#{test['id']} later."
    return
  end
  puts "Result: #{result['status']}"
  puts "  reportedCli: #{result['reportedCli'] || 'none'}"
  puts "  displayedCorrectly: #{result['displayedCorrectly'].nil? ? 'unknown' : result['displayedCorrectly']}"
  puts "  resultNotes: #{result['resultNotes'] || 'none'}"
end

# Fetches the test straight away, then every 10 seconds, until it reaches a final
# status or 10 minutes pass. Returns nil on timeout.
def poll(id, last_status)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + POLL_TIMEOUT
  loop do
    test = api_request("GET", "/cli-tests/#{URI.encode_www_form_component(id)}")["data"]
    if test["status"] != last_status
      puts "  status: #{test['status']}"
      last_status = test["status"]
    end
    return test if FINAL_STATUSES.include?(test["status"])
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

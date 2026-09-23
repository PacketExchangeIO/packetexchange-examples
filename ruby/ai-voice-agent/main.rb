# Creates an AI voice agent, tries one conversation turn without placing a call,
# and optionally attaches the agent to a voice campaign.
require "json"
require "net/http"

# The agent's script. A confirmation call to someone who booked an appointment is a
# transactional, expected call; keep agents to calls the recipient has agreed to receive.
FIRST_MESSAGE = "Hello, this is Riverside Clinic calling to confirm your appointment tomorrow at 10:30. " \
                "Can you still make it?"
SYSTEM_PROMPT = [
  "You confirm appointments for Riverside Clinic.",
  "Ask whether the person can attend their appointment tomorrow at 10:30.",
  "If they can, thank them and end the call. If they cannot, offer to have the clinic call them back to reschedule.",
  "Keep every reply short and polite."
].join(" ")
GUARDRAILS = "Never ask for payment details, passwords or medical information. " \
             "If the person asks to stop receiving calls, confirm and end the call."

def main(args)
  if args.length > 1
    warn "Usage: ruby ai-voice-agent/main.rb [campaign-id]"
    exit 2
  end
  campaign_id = args[0]

  # Prefer a standard (non-premium) English voice; otherwise take the first one.
  voices = api_request("GET", "/ai-agents/voices")["data"]
  if voices.empty?
    warn "No voices are available right now."
    exit 1
  end
  voice = voices.find { |v| v["language"] == "en" && !v["is_pro"] } || voices.first
  puts "Using voice: #{voice['name']} (#{voice['id']})"

  body = {
    name: "Appointment confirmation",
    voiceId: voice["id"],
    language: "en",
    firstMessage: FIRST_MESSAGE,
    systemPrompt: SYSTEM_PROMPT,
    guardrails: GUARDRAILS,
    maxCallSeconds: 180
  }
  agent = api_request("POST", "/ai-agents", body: body)["data"]
  puts "Agent created: #{agent['id']}"

  # A simulated turn places no call and is not billed.
  turn = api_request("POST", "/ai-agents/#{agent['id']}/simulate", body: { message: "Yes, I can still make it." })["data"]
  puts "Simulated reply: #{turn['reply']}"
  puts "  action: #{turn['action']}"

  return unless campaign_id

  # Answered calls in the campaign are then handled by this agent.
  api_request("PUT", "/dialer/campaigns/#{URI.encode_www_form_component(campaign_id)}", body: { aiAgentId: agent["id"] })
  puts "Attached agent to campaign #{campaign_id}"
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

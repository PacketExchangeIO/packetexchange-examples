# A minimal HTTP server that verifies PacketExchange webhook signatures before
# trusting a delivery.
require "json"
require "openssl"
require "webrick"

# Deliveries signed more than this far from now are refused, which stops a
# captured delivery from being replayed later.
TOLERANCE_SECONDS = 300

# Returns [scheme, nil] for a valid delivery or [nil, reason] to reject it. The
# timestamped v1 scheme is preferred; the legacy scheme is used only when a
# delivery carries no v1 signature.
def verify(secret, headers, body)
  signature = headers["x-px-signature"]
  if signature
    timestamp = headers["x-px-timestamp"]
    return [nil, "missing X-PX-Timestamp"] if timestamp.nil?
    return [nil, "invalid X-PX-Timestamp"] unless timestamp.match?(/\A\d+\z/)
    return [nil, "stale timestamp"] if (Time.now.to_i - timestamp.to_i).abs > TOLERANCE_SECONDS
    return [nil, "invalid signature"] unless signature.start_with?("v1=") &&
                                             matches?(secret, "#{timestamp}.#{body}", signature.delete_prefix("v1="))

    return ["v1", nil]
  end

  # Legacy scheme: proves who sent the body, but not when, so it cannot stop replays.
  legacy = headers["x-webhook-signature"]
  return [nil, "missing signature"] if legacy.nil?
  return [nil, "invalid signature"] unless legacy.start_with?("sha256=") &&
                                           matches?(secret, body, legacy.delete_prefix("sha256="))

  ["legacy", nil]
end

# Compares a hex HMAC-SHA256 in constant time, so response timing does not
# reveal how much of a forged signature was right.
def matches?(secret, message, signature_hex)
  expected = OpenSSL::HMAC.hexdigest("SHA256", secret, message)
  expected.bytesize == signature_hex.bytesize && OpenSSL.fixed_length_secure_compare(expected, signature_hex.downcase)
end

secret = ENV.fetch("PACKETEXCHANGE_WEBHOOK_SECRET", "")
if secret.empty?
  warn "Set PACKETEXCHANGE_WEBHOOK_SECRET first (see .env.example)."
  exit 2
end
port = Integer(ENV.fetch("PORT", "3000"))

server = WEBrick::HTTPServer.new(Port: port, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
server.mount_proc("/") do |request, response|
  unless request.request_method == "POST" && request.path == "/webhooks"
    response.status = 404
    response.body = "Not found"
    next
  end

  # Verify the raw bytes exactly as sent: re-encoding parsed JSON would change them.
  body = request.body.to_s
  headers = request.header.transform_values(&:first)
  scheme, reason = verify(secret, headers, body)
  if reason
    warn "Rejected delivery: #{reason}"
    response.status = 401
    response["Content-Type"] = "text/plain"
    response.body = reason
    next
  end

  # The body is trusted from here on. Every delivery is { event, data, timestamp }.
  event = JSON.parse(body)["event"]
  puts "Received #{event} (delivery #{headers['x-webhook-id']}, scheme #{scheme})"
  response["Content-Type"] = "application/json"
  response.body = JSON.generate(received: true)
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }
$stdout.sync = true
puts "Listening on http://localhost:#{port}/webhooks"
server.start

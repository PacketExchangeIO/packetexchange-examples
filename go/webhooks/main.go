// A minimal HTTP server that verifies PacketExchange webhook signatures before
// trusting a delivery.
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// Deliveries signed more than this far from now are refused, which stops a
// captured delivery from being replayed later.
const toleranceSeconds = 300

func main() {
	secret := os.Getenv("PACKETEXCHANGE_WEBHOOK_SECRET")
	if secret == "" {
		fmt.Fprintln(os.Stderr, "Set PACKETEXCHANGE_WEBHOOK_SECRET first (see .env.example).")
		os.Exit(2)
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /webhooks", func(w http.ResponseWriter, r *http.Request) {
		// Verify the raw bytes exactly as sent: re-encoding parsed JSON would change them.
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "unreadable body", http.StatusBadRequest)
			return
		}
		scheme, reason := verify(secret, r.Header, body)
		if reason != "" {
			fmt.Fprintf(os.Stderr, "Rejected delivery: %s\n", reason)
			http.Error(w, reason, http.StatusUnauthorized)
			return
		}
		// The body is trusted from here on. Every delivery is { event, data, timestamp }.
		var delivery struct {
			Event string `json:"event"`
		}
		if err := json.Unmarshal(body, &delivery); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		fmt.Printf("Received %s (delivery %s, scheme %s)\n", delivery.Event, r.Header.Get("X-Webhook-Id"), scheme)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"received":true}`))
	})
	// Anything other than POST /webhooks gets a 404.
	mux.HandleFunc("/", http.NotFound)

	fmt.Printf("Listening on http://localhost:%s/webhooks\n", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

// verify checks the signature and returns the scheme used, or a reason to reject.
// The timestamped v1 scheme is preferred; the legacy scheme is used only when a
// delivery carries no v1 signature.
func verify(secret string, header http.Header, body []byte) (scheme, reason string) {
	if signature := header.Get("X-PX-Signature"); signature != "" {
		timestamp := header.Get("X-PX-Timestamp")
		if timestamp == "" {
			return "", "missing X-PX-Timestamp"
		}
		sent, err := strconv.ParseInt(timestamp, 10, 64)
		if err != nil {
			return "", "invalid X-PX-Timestamp"
		}
		if math.Abs(float64(time.Now().Unix()-sent)) > toleranceSeconds {
			return "", "stale timestamp"
		}
		signed := append([]byte(timestamp+"."), body...)
		if !strings.HasPrefix(signature, "v1=") || !matches(secret, signed, strings.TrimPrefix(signature, "v1=")) {
			return "", "invalid signature"
		}
		return "v1", ""
	}
	// Legacy scheme: proves who sent the body, but not when, so it cannot stop replays.
	if signature := header.Get("X-Webhook-Signature"); signature != "" {
		if !strings.HasPrefix(signature, "sha256=") || !matches(secret, body, strings.TrimPrefix(signature, "sha256=")) {
			return "", "invalid signature"
		}
		return "legacy", ""
	}
	return "", "missing signature"
}

// matches compares a hex HMAC-SHA256 in constant time, so response timing does
// not reveal how much of a forged signature was right.
func matches(secret string, message []byte, signatureHex string) bool {
	given, err := hex.DecodeString(signatureHex)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(message)
	return hmac.Equal(mac.Sum(nil), given)
}

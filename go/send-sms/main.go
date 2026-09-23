// Sends one transactional SMS, then looks up its send-time status.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const defaultMessage = "Reminder: your appointment at Riverside Clinic is tomorrow at 10:30. Call us if you need to reschedule."

func main() {
	if len(os.Args) < 3 || len(os.Args) > 4 {
		fmt.Fprintln(os.Stderr, "Usage: go run ./send-sms <to> <sender-id> [message]")
		os.Exit(2)
	}
	to, senderID, message := os.Args[1], os.Args[2], defaultMessage
	if len(os.Args) == 4 {
		message = os.Args[3]
	}
	api := newClient(30 * time.Second)

	var sent struct {
		Data struct {
			MessageID string `json:"messageId"`
			Status    string `json:"status"`
			Segments  int    `json:"segments"`
			Cost      string `json:"cost"` // a 6-decimal USD string; never parse money into a float
		} `json:"data"`
	}
	body := map[string]any{"to": to, "from": senderID, "message": message}
	if err := api.do("POST", "/comms/sms", body, true, &sent); err != nil {
		exitOnError(err)
	}
	fmt.Printf("Message submitted: %s\n", sent.Data.MessageID)
	fmt.Printf("  status: %s\n", sent.Data.Status)
	fmt.Printf("  segments: %d\n", sent.Data.Segments)
	fmt.Printf("  cost: %s\n", sent.Data.Cost)

	// The send response is the send-time outcome (accepted, sent or failed). Delivery is
	// confirmed later by a carrier receipt, when the route returns one: see sms-status.
	var lookup struct {
		Data struct {
			Status       string `json:"status"`
			DlrSupported bool   `json:"dlrSupported"`
		} `json:"data"`
	}
	if err := api.do("GET", "/comms/sms/"+url.PathEscape(sent.Data.MessageID), nil, false, &lookup); err != nil {
		exitOnError(err)
	}
	fmt.Printf("Status lookup: %s\n", lookup.Data.Status)
	fmt.Printf("  dlrSupported: %t\n", lookup.Data.DlrSupported)
}

// client sends authenticated JSON requests to the PacketExchange API.
type client struct {
	baseURL string
	apiKey  string
	http    *http.Client
}

// newClient reads the API key and base URL from the environment. It exits with
// code 2 when the key is missing, before any request is made.
func newClient(timeout time.Duration) *client {
	key := os.Getenv("PACKETEXCHANGE_API_KEY")
	if key == "" {
		fmt.Fprintln(os.Stderr, "Set PACKETEXCHANGE_API_KEY first (see .env.example).")
		os.Exit(2)
	}
	base := os.Getenv("PACKETEXCHANGE_BASE_URL")
	if base == "" {
		base = "https://packetexchange.io/api/v1"
	}
	return &client{
		baseURL: strings.TrimSuffix(base, "/"),
		apiKey:  key,
		http:    &http.Client{Timeout: timeout},
	}
}

// do sends one request and decodes a 2xx JSON body into out. Any other status is
// returned as an *apiError. With idempotent set, a fresh X-Idempotency-Key makes a
// retried request safe: the API replays the first response instead of acting twice.
func (c *client) do(method, path string, body any, idempotent bool, out any) error {
	var payload io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		payload = bytes.NewReader(encoded)
	}
	req, err := http.NewRequest(method, c.baseURL+path, payload)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if idempotent {
		req.Header.Set("X-Idempotency-Key", newUUID())
	}
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		return err
	}
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return &apiError{status: res.StatusCode, body: raw, header: res.Header}
	}
	return json.Unmarshal(raw, out)
}

// apiError is a non-2xx response, kept raw so it can be reported exactly.
type apiError struct {
	status int
	body   []byte
	header http.Header
}

func (e *apiError) Error() string { return fmt.Sprintf("HTTP %d", e.status) }

// exitOnError reports a failed request on stderr and exits with code 1.
func exitOnError(err error) {
	var apiErr *apiError
	if !errors.As(err, &apiErr) {
		fmt.Fprintf(os.Stderr, "Network error: %v\n", err)
		os.Exit(1)
	}
	var envelope struct {
		Error *struct {
			Code    string          `json:"code"`
			Message string          `json:"message"`
			Details json.RawMessage `json:"details"`
		} `json:"error"`
	}
	if json.Unmarshal(apiErr.body, &envelope) != nil || envelope.Error == nil {
		// Not the API's JSON envelope, for example an error page from a proxy.
		text := []rune(string(apiErr.body))
		if len(text) > 200 {
			text = text[:200]
		}
		fmt.Fprintf(os.Stderr, "Error %d: %s\n", apiErr.status, string(text))
	} else {
		fmt.Fprintf(os.Stderr, "Error %d %s: %s\n", apiErr.status, envelope.Error.Code, envelope.Error.Message)
		// details is an array of { path, message } for validation errors; some
		// codes attach an object instead, which is not listed line by line.
		var details []struct {
			Path    string `json:"path"`
			Message string `json:"message"`
		}
		if json.Unmarshal(envelope.Error.Details, &details) == nil {
			for _, d := range details {
				fmt.Fprintf(os.Stderr, "  - %s: %s\n", d.Path, d.Message)
			}
		}
	}
	if apiErr.status == http.StatusTooManyRequests {
		if wait := apiErr.header.Get("Retry-After"); wait != "" {
			fmt.Fprintf(os.Stderr, "Retry after: %s seconds\n", wait)
		}
	}
	if id := apiErr.header.Get("X-Request-Id"); id != "" {
		fmt.Fprintf(os.Stderr, "Request id: %s\n", id)
	}
	os.Exit(1)
}

// newUUID returns a random version 4 UUID for the idempotency header.
func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

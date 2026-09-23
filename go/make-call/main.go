// Places one outbound call, then finds its charge in the call ledger.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 3 || len(os.Args) > 4 {
		fmt.Fprintln(os.Stderr, "Usage: go run ./make-call <to> <caller-id> [max-duration-seconds]")
		os.Exit(2)
	}
	to, callerID, maxDuration := os.Args[1], os.Args[2], 60
	if len(os.Args) == 4 {
		n, err := strconv.Atoi(os.Args[3])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Usage: go run ./make-call <to> <caller-id> [max-duration-seconds]")
			os.Exit(2)
		}
		maxDuration = n
	}
	// POST /comms/calls answers only when the call has ended, so the client must
	// wait at least as long as the call may last.
	api := newClient(time.Duration(maxDuration+30) * time.Second)

	var call struct {
		Data struct {
			CallID          string  `json:"callId"`
			Status          string  `json:"status"`
			DurationSeconds int     `json:"durationSeconds"`
			BillableSeconds int     `json:"billableSeconds"`
			Cost            string  `json:"cost"`
			HangupCause     *string `json:"hangupCause"`
		} `json:"data"`
	}
	body := map[string]any{"to": to, "from": callerID, "maxDuration": maxDuration}
	if err := api.do("POST", "/comms/calls", body, true, &call); err != nil {
		exitOnError(err)
	}
	hangupCause := "none"
	if call.Data.HangupCause != nil {
		hangupCause = *call.Data.HangupCause
	}
	fmt.Printf("Call finished: %s\n", call.Data.CallID)
	fmt.Printf("  status: %s\n", call.Data.Status)
	fmt.Printf("  durationSeconds: %d\n", call.Data.DurationSeconds)
	fmt.Printf("  billableSeconds: %d\n", call.Data.BillableSeconds)
	fmt.Printf("  cost: %s\n", call.Data.Cost)
	fmt.Printf("  hangupCause: %s\n", hangupCause)

	// The call history is a ledger: each entry is the signed charge and the balance after it.
	var history struct {
		Data []struct {
			Amount          string `json:"amount"`
			BalanceAfter    string `json:"balanceAfter"`
			RelatedEntityID string `json:"relatedEntityId"`
			CallID          string `json:"callId"`
		} `json:"data"`
	}
	if err := api.do("GET", "/comms/calls?limit=25", nil, false, &history); err != nil {
		exitOnError(err)
	}
	for _, entry := range history.Data {
		if entry.RelatedEntityID == call.Data.CallID || entry.CallID == call.Data.CallID {
			fmt.Printf("Ledger entry: %s (balance after %s)\n", entry.Amount, entry.BalanceAfter)
			return
		}
	}
	fmt.Println("Ledger entry: not in the latest 25 entries")
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

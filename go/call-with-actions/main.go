// Calls a customer to confirm an appointment: the answered call speaks a message, asks
// for one key press, and the program follows the call until it ends.
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

const (
	pollInterval = 2 * time.Second
	pollTimeout  = 5 * time.Minute
)

// actions is what the answered call does, in order. The call hangs up after the last one.
var actions = []map[string]any{
	{"say": "Hello, this is Riverside Clinic calling about your appointment tomorrow at 10:30."},
	{"gather": map[string]any{"digits": 1, "timeout": 5, "say": "Press 1 to confirm, or 2 if you need to reschedule."}},
	{"say": "Thank you. Goodbye."},
}

// callStatus holds the fields of a call this example prints.
type callStatus struct {
	CallID          string  `json:"callId"`
	Status          string  `json:"status"`
	DurationSeconds *int    `json:"durationSeconds"`
	Cost            *string `json:"cost"`
	HangupReason    *string `json:"hangupReason"`
	Gathered        []struct {
		Index  int     `json:"index"`
		Digits *string `json:"digits"`
	} `json:"gathered"`
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "Usage: go run ./call-with-actions <to> <caller-id>")
		os.Exit(2)
	}
	to, callerID := os.Args[1], os.Args[2]
	api := newClient(30 * time.Second)

	// async: true answers as soon as the number is being dialled (HTTP 202, status
	// ringing) instead of holding the request open until the call ends.
	var placed struct {
		Data struct {
			CallID string `json:"callId"`
			Status string `json:"status"`
		} `json:"data"`
	}
	body := map[string]any{
		"to": to, "from": callerID, "maxDuration": 120, "async": true, "language": "en", "actions": actions,
	}
	if err := api.do("POST", "/comms/calls", body, true, &placed); err != nil {
		exitOnError(err)
	}
	fmt.Printf("Call placed: %s (status %s)\n", placed.Data.CallID, placed.Data.Status)

	call, done := poll(api, placed.Data.CallID, placed.Data.Status)
	if !done {
		fmt.Printf("Still running after 5 minutes; check GET /comms/calls/%s later.\n", placed.Data.CallID)
		return
	}
	// Gathered digits are filled in when the call ends.
	pressed := "none"
	for _, g := range call.Gathered {
		if g.Index == 0 && g.Digits != nil {
			pressed = *g.Digits
		}
	}
	duration := 0
	if call.DurationSeconds != nil {
		duration = *call.DurationSeconds
	}
	fmt.Printf("Call ended: %s\n", call.Status)
	fmt.Printf("  durationSeconds: %d\n", duration)
	fmt.Printf("  cost: %s\n", orDefault(call.Cost, "none"))
	fmt.Printf("  hangupReason: %s\n", orDefault(call.HangupReason, "none"))
	fmt.Printf("  keyPressed: %s\n", pressed)
}

// poll reads the call straight away, then every 2 seconds, until it ends or 5 minutes
// pass. It reports false on timeout. In production, the call.answered, call.gathered
// and call.completed webhooks tell you the same without polling.
func poll(api *client, id, lastStatus string) (callStatus, bool) {
	deadline := time.Now().Add(pollTimeout)
	for {
		var current struct {
			Data callStatus `json:"data"`
		}
		if err := api.do("GET", "/comms/calls/"+url.PathEscape(id), nil, false, &current); err != nil {
			exitOnError(err)
		}
		if current.Data.Status != lastStatus {
			fmt.Printf("  status: %s\n", current.Data.Status)
			lastStatus = current.Data.Status
		}
		switch current.Data.Status {
		case "completed", "no_answer", "busy", "failed":
			return current.Data, true
		}
		if time.Now().Add(pollInterval).After(deadline) {
			return current.Data, false
		}
		time.Sleep(pollInterval)
	}
}

func orDefault(value *string, fallback string) string {
	if value == nil {
		return fallback
	}
	return *value
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

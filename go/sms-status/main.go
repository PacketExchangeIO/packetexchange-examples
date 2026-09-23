// Reads what happened to a message you sent: every step from queued to delivered or
// failed, with timestamps. "delivered" only ever comes from a carrier receipt.
package main

import (
	"bytes"
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

// smsStatus holds the fields of a message status this example prints.
type smsStatus struct {
	MessageID string  `json:"messageId"`
	Status    string  `json:"status"`
	ErrorCode *string `json:"errorCode"`
	Timeline  []struct {
		Status        string  `json:"status"`
		At            string  `json:"at"`
		Source        string  `json:"source"`
		ErrorCode     *string `json:"errorCode"`
		CarrierStatus *string `json:"carrierStatus"`
	} `json:"timeline"`
	AwaitingReceipt      bool  `json:"awaitingReceipt"`
	RouteReturnsReceipts *bool `json:"routeReturnsReceipts"`
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "Usage: go run ./sms-status <message-id>")
		os.Exit(2)
	}
	messageID := os.Args[1]
	api := newClient(30 * time.Second)

	var res struct {
		Data smsStatus `json:"data"`
	}
	if err := api.do("GET", "/comms/sms/"+url.PathEscape(messageID), nil, &res); err != nil {
		exitOnError(err)
	}
	sms := res.Data

	// An id that is not on your account answers 200 with status not_found.
	if sms.Status == "not_found" {
		fmt.Fprintf(os.Stderr, "No message %s on this account.\n", messageID)
		os.Exit(1)
	}
	fmt.Printf("Message %s: %s\n", sms.MessageID, sms.Status)
	for _, step := range sms.Timeline {
		extra := []string{step.Source}
		for _, v := range []*string{step.CarrierStatus, step.ErrorCode} {
			if v != nil && *v != "" {
				extra = append(extra, *v)
			}
		}
		fmt.Printf("  - %s at %s (%s)\n", step.Status, step.At, strings.Join(extra, ", "))
	}
	if sms.ErrorCode != nil {
		fmt.Printf("  errorCode: %s\n", *sms.ErrorCode)
	}
	// A route that returns no receipts leaves the message at "sent" for good.
	fmt.Printf("  awaitingReceipt: %t\n", sms.AwaitingReceipt)
	receipts := "unknown"
	if sms.RouteReturnsReceipts != nil {
		receipts = fmt.Sprint(*sms.RouteReturnsReceipts)
	}
	fmt.Printf("  routeReturnsReceipts: %s\n", receipts)
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
// returned as an *apiError.
func (c *client) do(method, path string, body any, out any) error {
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

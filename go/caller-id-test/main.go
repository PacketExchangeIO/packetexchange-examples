// Runs a caller-ID test: a real call over one of your routes to a test handset,
// which reports the caller ID it actually displayed.
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

const (
	pollInterval = 10 * time.Second
	pollTimeout  = 10 * time.Minute
)

// cliTest holds the fields of a test this example prints.
type cliTest struct {
	ID                 string  `json:"id"`
	Status             string  `json:"status"`
	ReportedCli        *string `json:"reportedCli"`
	DisplayedCorrectly *bool   `json:"displayedCorrectly"`
	ResultNotes        *string `json:"resultNotes"`
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "Usage: go run ./caller-id-test <route-id> <caller-id> <country>")
		os.Exit(2)
	}
	routeID, callerID, country := os.Args[1], os.Args[2], os.Args[3]
	api := newClient(30 * time.Second)

	var quota struct {
		Data struct {
			CostPerTest  float64 `json:"costPerTest"` // USD as a plain JSON number
			LimitPerHour int     `json:"limitPerHour"`
			Remaining    int     `json:"remaining"`
		} `json:"data"`
	}
	if err := api.do("GET", "/cli-tests/quota", nil, &quota); err != nil {
		exitOnError(err)
	}
	fmt.Printf("Caller-ID test price: $%.2f per test, charged only if the route rang (%d of %d left this hour)\n",
		quota.Data.CostPerTest, quota.Data.Remaining, quota.Data.LimitPerHour)

	var created struct {
		Data cliTest `json:"data"`
	}
	body := map[string]any{"routeId": routeID, "displayCli": callerID, "testCountry": country}
	if err := api.do("POST", "/cli-tests", body, &created); err != nil {
		exitOnError(err)
	}
	fmt.Printf("Test queued: %s (status %s)\n", created.Data.ID, created.Data.Status)

	test, done := poll(api, created.Data.ID, created.Data.Status)
	if !done {
		fmt.Printf("Still running after 10 minutes; check GET /cli-tests/%s later.\n", created.Data.ID)
		return
	}
	fmt.Printf("Result: %s\n", test.Status)
	fmt.Printf("  reportedCli: %s\n", orDefault(test.ReportedCli, "none"))
	displayed := "unknown"
	if test.DisplayedCorrectly != nil {
		displayed = fmt.Sprint(*test.DisplayedCorrectly)
	}
	fmt.Printf("  displayedCorrectly: %s\n", displayed)
	fmt.Printf("  resultNotes: %s\n", orDefault(test.ResultNotes, "none"))
}

// poll fetches the test straight away, then every 10 seconds, until it reaches a
// final status or 10 minutes pass. It reports false on timeout.
func poll(api *client, id, lastStatus string) (cliTest, bool) {
	deadline := time.Now().Add(pollTimeout)
	for {
		var current struct {
			Data cliTest `json:"data"`
		}
		if err := api.do("GET", "/cli-tests/"+url.PathEscape(id), nil, &current); err != nil {
			exitOnError(err)
		}
		if current.Data.Status != lastStatus {
			fmt.Printf("  status: %s\n", current.Data.Status)
			lastStatus = current.Data.Status
		}
		switch current.Data.Status {
		case "completed", "failed", "not_tested", "cancelled":
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

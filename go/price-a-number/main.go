// Prices a phone number across the marketplace, then shows which route each
// Smart Routing strategy would pick for it.
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

func main() {
	if len(os.Args) < 2 || len(os.Args) > 3 || (len(os.Args) == 3 && os.Args[2] != "voice" && os.Args[2] != "sms") {
		fmt.Fprintln(os.Stderr, "Usage: go run ./price-a-number <number> [voice|sms]")
		os.Exit(2)
	}
	number, kind := os.Args[1], "voice"
	if len(os.Args) == 3 {
		kind = os.Args[2]
	}
	api := newClient(30 * time.Second)

	query := url.Values{"number": {number}, "type": {kind}}
	var priced struct {
		Data struct {
			Total  int    `json:"total"`
			Unit   string `json:"unit"`
			Notice string `json:"notice"`
			Routes []struct {
				ID            string  `json:"id"`
				Destination   string  `json:"destination"`
				MatchedPrefix string  `json:"matchedPrefix"`
				Rate          string  `json:"rate"`
				ExpectedAsr   *string `json:"expectedAsr"`
			} `json:"routes"`
		} `json:"data"`
	}
	if err := api.do("GET", "/routes/price-number?"+query.Encode(), nil, &priced); err != nil {
		exitOnError(err)
	}
	if priced.Data.Notice == "sanctioned" {
		fmt.Println("No routes: the destination is embargoed.")
	} else {
		fmt.Printf("%d routes serve %s (%s), cheapest first:\n", priced.Data.Total, number, kind)
		for i, route := range priced.Data.Routes {
			if i == 5 {
				break
			}
			// ASR on a listing is stated by the seller, not measured by the exchange.
			asr := "ASR n/a"
			if route.ExpectedAsr != nil {
				asr = "ASR " + *route.ExpectedAsr + "% (seller-stated)"
			}
			fmt.Printf("  %s/%s  %s  prefix %s  %s  %s\n",
				route.Rate, priced.Data.Unit, route.Destination, route.MatchedPrefix, asr, route.ID)
		}
	}

	unit := "min"
	if kind == "sms" {
		unit = "msg"
	}
	for _, strategy := range []string{"cheapest", "best_quality", "balanced"} {
		query := url.Values{"to": {number}, "type": {kind}, "strategy": {strategy}}
		var resolved struct {
			Data struct {
				Selected *struct {
					ID              string `json:"id"`
					Price           string `json:"price"`
					DestinationName string `json:"destinationName"`
				} `json:"selected"`
			} `json:"data"`
		}
		if err := api.do("GET", "/routes/resolve?"+query.Encode(), nil, &resolved); err != nil {
			exitOnError(err)
		}
		if selected := resolved.Data.Selected; selected == nil {
			fmt.Printf("Strategy %s: no route\n", strategy)
		} else {
			fmt.Printf("Strategy %s: %s/%s via %s (%s)\n", strategy, selected.Price, unit, selected.ID, selected.DestinationName)
		}
	}
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

// Looks up a phone number before you message or call it: whether it is a valid E.164
// number, its country, line type and network, risk flags, and the cheapest live price.
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

// price is the cheapest live route for the number by voice or by SMS.
type price struct {
	Rate          string `json:"rate"`
	Unit          string `json:"unit"`
	RouteID       string `json:"routeId"`
	RoutesServing int    `json:"routesServing"`
}

// lookup holds the fields of a number lookup this example prints.
type lookup struct {
	Valid               bool    `json:"valid"`
	Reason              *string `json:"reason"`
	E164                string  `json:"e164"`
	InternationalFormat string  `json:"internationalFormat"`
	Country             *struct {
		ISO  *string `json:"iso"`
		Name string  `json:"name"`
	} `json:"country"`
	NumberType string `json:"numberType"`
	Network    *struct {
		Operator *string `json:"operator"`
	} `json:"network"`
	Risk struct {
		Blocked  bool     `json:"blocked"`
		HighRisk bool     `json:"highRisk"`
		Reasons  []string `json:"reasons"`
	} `json:"risk"`
	Pricing struct {
		Voice *price `json:"voice"`
		SMS   *price `json:"sms"`
	} `json:"pricing"`
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "Usage: go run ./number-lookup <number>")
		os.Exit(2)
	}
	api := newClient(30 * time.Second)

	// Encode the number for use in the URL path, leading "+" included.
	var res struct {
		Data lookup `json:"data"`
	}
	path := "/lookup/" + strings.ReplaceAll(url.PathEscape(os.Args[1]), "+", "%2B")
	if err := api.do("GET", path, nil, &res); err != nil {
		exitOnError(err)
	}
	data := res.Data

	// A malformed number is a normal answer (valid: false), not an HTTP error.
	if !data.Valid {
		fmt.Printf("Not a valid number: %s\n", orDefault(data.Reason, "unknown reason"))
		return
	}
	fmt.Printf("%s (%s)\n", data.E164, data.InternationalFormat)
	country := "unknown"
	if data.Country != nil {
		country = fmt.Sprintf("%s (%s)", data.Country.Name, orDefault(data.Country.ISO, "shared dial code"))
	}
	fmt.Printf("  country: %s\n", country)
	fmt.Printf("  numberType: %s\n", data.NumberType)
	// From number-range data: a ported number still shows the network its range belongs to.
	network := "unknown"
	if data.Network != nil {
		network = orDefault(data.Network.Operator, "unknown")
	}
	fmt.Printf("  network: %s\n", network)
	fmt.Printf("  risk: blocked %t, highRisk %t\n", data.Risk.Blocked, data.Risk.HighRisk)
	for _, reason := range data.Risk.Reasons {
		fmt.Printf("    - %s\n", reason)
	}
	fmt.Println(priceLine("voice", data.Pricing.Voice))
	fmt.Println(priceLine("sms", data.Pricing.SMS))
}

// priceLine is one price line: the cheapest live route, or "no route" when none serves the number.
func priceLine(label string, p *price) string {
	if p == nil {
		return fmt.Sprintf("  %s: no route", label)
	}
	return fmt.Sprintf("  %s: %s/%s via %s (%d routes serve it)", label, p.Rate, p.Unit, p.RouteID, p.RoutesServing)
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

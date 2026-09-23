// Searches the number catalogue, buys a number (only with --confirm) and points
// a number you own at a SIP endpoint or a phone.
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
	"slices"
	"strings"
	"time"
)

const usage = "Usage: go run ./phone-numbers search [pattern] | buy <groupId> <skuId> [--confirm] | route <didId> sip|forward <target>"

// storeStatus is present instead of results while the number store is switched off.
type storeStatus struct {
	Disabled bool   `json:"disabled"`
	Message  string `json:"message"`
}

func main() {
	// --confirm may appear anywhere, so separate it from the positional arguments.
	confirm := slices.Contains(os.Args[1:], "--confirm")
	args := slices.DeleteFunc(slices.Clone(os.Args[1:]), func(a string) bool { return a == "--confirm" })

	switch {
	case len(args) >= 1 && len(args) <= 2 && args[0] == "search":
		pattern := ""
		if len(args) == 2 {
			pattern = args[1]
		}
		search(newClient(30*time.Second), pattern)
	case len(args) == 3 && args[0] == "buy":
		if !confirm {
			fmt.Fprintln(os.Stderr, "Buying a number charges the setup price plus the first month to your balance.")
			fmt.Fprintln(os.Stderr, "Re-run with --confirm to place the order.")
			os.Exit(2)
		}
		buy(newClient(30*time.Second), args[1], args[2])
	case len(args) == 4 && args[0] == "route" && (args[2] == "sip" || args[2] == "forward"):
		route(newClient(30*time.Second), args[1], args[2], args[3])
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
}

// search lists matching number groups and the SKUs you can buy in each.
// Note that hits sit at the top level of the response, not under data.
func search(api *client, pattern string) {
	query := url.Values{"limit": {"5"}}
	if pattern != "" {
		query.Set("pattern", pattern)
	}
	var result struct {
		Data *storeStatus `json:"data"`
		Hits []struct {
			GroupID       string  `json:"groupId"`
			Country       string  `json:"country"`
			City          *string `json:"city"`
			TypeName      *string `json:"typeName"`
			DialingPrefix string  `json:"dialingPrefix"`
			Skus          []struct {
				SkuID string `json:"skuId"`
				// Catalogue prices are plain JSON numbers for display, unlike the
				// 6-decimal money strings used for charges.
				SetupPrice   float64 `json:"setupPrice"`
				MonthlyPrice float64 `json:"monthlyPrice"`
				Channels     int     `json:"channels"`
			} `json:"skus"`
		} `json:"hits"`
	}
	if err := api.do("GET", "/dids/search?"+query.Encode(), nil, false, &result); err != nil {
		exitOnError(err)
	}
	if result.Data != nil && result.Data.Disabled {
		fmt.Printf("Number store unavailable: %s\n", result.Data.Message)
		return
	}
	fmt.Printf("%d number groups found:\n", len(result.Hits))
	for _, hit := range result.Hits {
		place := hit.Country
		if hit.City != nil && *hit.City != "" {
			place += ", " + *hit.City
		}
		typeName := ""
		if hit.TypeName != nil {
			typeName = *hit.TypeName
		}
		fmt.Printf("  %s  %s  %s  groupId %s\n", hit.DialingPrefix, place, typeName, hit.GroupID)
		for _, sku := range hit.Skus {
			fmt.Printf("    skuId %s: setup $%.2f, monthly $%.2f, %d channels\n", sku.SkuID, sku.SetupPrice, sku.MonthlyPrice, sku.Channels)
		}
	}
}

// buy orders one number. It charges your balance, which is why main requires --confirm.
func buy(api *client, groupID, skuID string) {
	var result struct {
		Data struct {
			storeStatus
			ID           string  `json:"id"`
			Status       string  `json:"status"`
			Number       *string `json:"number"`
			SetupPrice   string  `json:"setupPrice"`
			MonthlyPrice string  `json:"monthlyPrice"`
		} `json:"data"`
	}
	body := map[string]any{"groupId": groupID, "skuId": skuID}
	if err := api.do("POST", "/dids/buy", body, true, &result); err != nil {
		exitOnError(err)
	}
	if result.Data.Disabled {
		fmt.Printf("Number store unavailable: %s\n", result.Data.Message)
		return
	}
	// number stays null until the carrier finishes provisioning.
	number := "pending"
	if result.Data.Number != nil {
		number = *result.Data.Number
	}
	fmt.Printf("Number ordered: %s\n", result.Data.ID)
	fmt.Printf("  status: %s\n", result.Data.Status)
	fmt.Printf("  number: %s\n", number)
	fmt.Printf("  setupPrice: %s\n", result.Data.SetupPrice)
	fmt.Printf("  monthlyPrice: %s\n", result.Data.MonthlyPrice)
}

// route points a number at a SIP endpoint (host[:port]) or forwards it to a phone (E.164).
func route(api *client, didID, mode, target string) {
	var result struct {
		Data struct {
			ID        string `json:"id"`
			PointMode string `json:"pointMode"`
			PointsTo  string `json:"pointsTo"`
		} `json:"data"`
	}
	body := map[string]any{"mode": mode, "target": target}
	if err := api.do("PATCH", "/dids/"+url.PathEscape(didID)+"/routing", body, false, &result); err != nil {
		exitOnError(err)
	}
	fmt.Printf("Number %s now routes to %s %s\n", result.Data.ID, result.Data.PointMode, result.Data.PointsTo)
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

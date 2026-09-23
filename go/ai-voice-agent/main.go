// Creates an AI voice agent, tries one conversation turn without placing a call,
// and optionally attaches the agent to a voice campaign.
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

// The agent's script. A confirmation call to someone who booked an appointment is a
// transactional, expected call; keep agents to calls the recipient has agreed to receive.
const (
	firstMessage = "Hello, this is Riverside Clinic calling to confirm your appointment tomorrow at 10:30. Can you still make it?"
	systemPrompt = "You confirm appointments for Riverside Clinic. " +
		"Ask whether the person can attend their appointment tomorrow at 10:30. " +
		"If they can, thank them and end the call. If they cannot, offer to have the clinic call them back to reschedule. " +
		"Keep every reply short and polite."
	guardrails = "Never ask for payment details, passwords or medical information. " +
		"If the person asks to stop receiving calls, confirm and end the call."
)

func main() {
	if len(os.Args) > 2 {
		fmt.Fprintln(os.Stderr, "Usage: go run ./ai-voice-agent [campaign-id]")
		os.Exit(2)
	}
	api := newClient(30 * time.Second)

	// Prefer a standard (non-premium) English voice; otherwise take the first one.
	var voices struct {
		Data []struct {
			ID       string `json:"id"`
			Name     string `json:"name"`
			Language string `json:"language"`
			IsPro    bool   `json:"is_pro"`
		} `json:"data"`
	}
	if err := api.do("GET", "/ai-agents/voices", nil, &voices); err != nil {
		exitOnError(err)
	}
	if len(voices.Data) == 0 {
		fmt.Fprintln(os.Stderr, "No voices are available right now.")
		os.Exit(1)
	}
	voice := voices.Data[0]
	for _, v := range voices.Data {
		if v.Language == "en" && !v.IsPro {
			voice = v
			break
		}
	}
	fmt.Printf("Using voice: %s (%s)\n", voice.Name, voice.ID)

	var agent struct {
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	body := map[string]any{
		"name":           "Appointment confirmation",
		"voiceId":        voice.ID,
		"language":       "en",
		"firstMessage":   firstMessage,
		"systemPrompt":   systemPrompt,
		"guardrails":     guardrails,
		"maxCallSeconds": 180,
	}
	if err := api.do("POST", "/ai-agents", body, &agent); err != nil {
		exitOnError(err)
	}
	fmt.Printf("Agent created: %s\n", agent.Data.ID)

	// A simulated turn places no call and is not billed.
	var turn struct {
		Data struct {
			Reply  string `json:"reply"`
			Action string `json:"action"`
		} `json:"data"`
	}
	simulate := map[string]any{"message": "Yes, I can still make it."}
	if err := api.do("POST", "/ai-agents/"+agent.Data.ID+"/simulate", simulate, &turn); err != nil {
		exitOnError(err)
	}
	fmt.Printf("Simulated reply: %s\n", turn.Data.Reply)
	fmt.Printf("  action: %s\n", turn.Data.Action)

	// Answered calls in the campaign are then handled by this agent.
	if len(os.Args) == 2 {
		campaignID := os.Args[1]
		var campaign struct{}
		attach := map[string]any{"aiAgentId": agent.Data.ID}
		if err := api.do("PUT", "/dialer/campaigns/"+url.PathEscape(campaignID), attach, &campaign); err != nil {
			exitOnError(err)
		}
		fmt.Printf("Attached agent to campaign %s\n", campaignID)
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

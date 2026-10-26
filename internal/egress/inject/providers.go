// Package inject is the credential side of RIOTBOX_EGRESS=1: which of the
// agent's API keys the session's proxy puts on requests itself, so that
// the agent holds only Placeholder (Decide), how they reach riotbox-core
// (ParseInput), and the per-session CA and leaf certificates the proxy
// terminates those hosts' TLS with (NewCerts). See docs/dev/egress.md
// "Credential injection".
package inject

// Placeholder is what an injected variable holds in the agent container.
// Claude Code 2.1.304, opencode 1.19.3 and Pi 1.3.0 each sent it unchanged
// as ANTHROPIC_API_KEY (Pi as OPENAI_API_KEY too): none checks a key's
// format locally, so one value serves every row.
const Placeholder = "riotbox-egress-placeholder"

// Provider is how one provider's API takes a static key.
type Provider struct {
	Env        string // the variable the agents read the key from
	Host       string // the API host the key is sent to, on port 443
	Header     string // the request header that carries it, lowercase
	Prefix     string // what goes before the key in the header ("Bearer ")
	BaseURLEnv string // the variable that points the agents elsewhere; "" if none
	// HeadroomLoopback is true when, with RIOTBOX_HEADROOM=1, headroom
	// replaces BaseURLEnv in the container with its own loopback proxy and
	// forwards to Host through the egress proxy. Only
	// agents/claude/headroom-exec.sh does that (ANTHROPIC_BASE_URL); opencode's
	// headroom path rewrites opencode's config instead, and Pi has none.
	HeadroomLoopback bool
}

// Providers is every static key the agents' env_vars name for a fixed
// public host. Each row's Source documents its header; each header was
// also checked live on 2026-10-26: a bogus key in it gets "invalid key",
// not "missing credentials".
//
// ANTHROPIC_AUTH_TOKEN is left out: api.anthropic.com answers a bearer API
// key with "x-api-key header is required", and Claude Code 2.1.304 with it
// alone reports "Not logged in" whatever its value; it serves gateways,
// which a base URL points at. GOOGLE_GENERATIVE_AI_API_KEY is left out
// because no agent's env_vars passes it into the container.
var Providers = []Provider{
	// Source: https://platform.claude.com/docs/en/api/overview (x-api-key)
	{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key", BaseURLEnv: "ANTHROPIC_BASE_URL", HeadroomLoopback: true},
	// Source: https://developers.openai.com/api/reference/overview (Authorization: Bearer)
	{Env: "OPENAI_API_KEY", Host: "api.openai.com", Header: "authorization", Prefix: "Bearer ", BaseURLEnv: "OPENAI_BASE_URL"},
	// Source: https://openrouter.ai/docs/api-reference/authentication
	{Env: "OPENROUTER_API_KEY", Host: "openrouter.ai", Header: "authorization", Prefix: "Bearer "},
	// Source: https://ai.google.dev/gemini-api/docs/api-key (x-goog-api-key)
	{Env: "GEMINI_API_KEY", Host: "generativelanguage.googleapis.com", Header: "x-goog-api-key"},
	// Source: https://console.groq.com/docs/api-reference (Authorization: Bearer)
	{Env: "GROQ_API_KEY", Host: "api.groq.com", Header: "authorization", Prefix: "Bearer "},
	// Source: https://docs.mistral.ai/api/ (Authorization: Bearer)
	{Env: "MISTRAL_API_KEY", Host: "api.mistral.ai", Header: "authorization", Prefix: "Bearer "},
	// Source: https://api-docs.deepseek.com/ (Authorization: Bearer)
	{Env: "DEEPSEEK_API_KEY", Host: "api.deepseek.com", Header: "authorization", Prefix: "Bearer "},
	// Source: https://docs.x.ai/developers/rest-api-reference/inference/responses (Authorization: Bearer)
	{Env: "XAI_API_KEY", Host: "api.x.ai", Header: "authorization", Prefix: "Bearer "},
}

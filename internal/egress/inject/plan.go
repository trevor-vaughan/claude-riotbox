package inject

import (
	"fmt"
	"net"
	"net/url"
	"regexp"
	"slices"
	"strings"
)

// Credential is one key the proxy puts on its provider's requests.
type Credential struct {
	Env    string // the variable it came from
	Host   string // the provider's API host
	Header string // the request header it goes in, lowercase
	Value  string // the header's whole value: the provider's Prefix, then the key
}

// String names the credential without its value, so formatting a
// Credential, or a Plan holding one, with any verb cannot print a key.
func (c Credential) String() string {
	return fmt.Sprintf("%s → %s (%s: [redacted])", c.Env, c.Host, c.Header)
}

// GoString is String's counterpart for %#v.
func (c Credential) GoString() string {
	return fmt.Sprintf("inject.Credential{Env:%q, Host:%q, Header:%q, Value:\"[redacted]\"}", c.Env, c.Host, c.Header)
}

// PassThrough is a key that still enters the agent container, and why.
type PassThrough struct {
	Env, Reason string
}

// Plan is what Decide made of the agent's variables.
type Plan struct {
	Inject      []Credential  // in the providers' order
	PassThrough []PassThrough // sorted by Env
}

// keyName matches a variable name that suggests a secret, so a key no
// provider row knows is still named in the pass-through notice.
var keyName = regexp.MustCompile(`(?i)(KEY|TOKEN|SECRET|PASSWORD)$`)

// Decide splits vars, the variables the agent container would get from
// the host (ParseInput), into the keys the proxy injects and the keys that
// still enter the container. A provider's key is injected when it is set,
// is visible ASCII only (it goes into a header verbatim), and its base-URL
// variable is unset, points at the provider's host over HTTPS on port 443,
// or, with RIOTBOX_HEADROOM=1 and a HeadroomLoopback row, points at a
// loopback address: headroom then replaces that URL in the container with
// its own and sends the requests on to the provider's host through the
// proxy. Any other set variable whose name suggests a secret (keyName, any
// case) passes through as not in the table. Empty variables are ignored:
// there is nothing to protect.
func Decide(vars map[string]string, providers []Provider) Plan {
	var p Plan
	known := map[string]bool{}
	for _, pr := range providers {
		known[pr.Env] = true
		key := vars[pr.Env]
		if key == "" {
			continue
		}
		if reason := notInjectable(pr, key, vars); reason != "" {
			p.PassThrough = append(p.PassThrough, PassThrough{Env: pr.Env, Reason: reason})
			continue
		}
		p.Inject = append(p.Inject, Credential{Env: pr.Env, Host: pr.Host, Header: pr.Header, Value: pr.Prefix + key})
	}
	for name, value := range vars {
		if !known[name] && value != "" && keyName.MatchString(name) {
			p.PassThrough = append(p.PassThrough, PassThrough{Env: name, Reason: "not in the provider table"})
		}
	}
	slices.SortFunc(p.PassThrough, func(a, b PassThrough) int { return strings.Compare(a.Env, b.Env) })
	return p
}

// notInjectable says why pr's key cannot be injected, or is "" when it
// can. It never quotes the key or the base URL, which may hold a password.
// A base URL with userinfo still counts as the provider's host: the key is
// injected, and the URL's own password stays in the container with it.
// Host names match exactly (any case): a trailing-dot form is another
// CONNECT authority, which the proxy would not intercept.
func notInjectable(pr Provider, key string, vars map[string]string) string {
	// Invalid UTF-8 decodes as U+FFFD, so it is refused here too.
	if strings.ContainsFunc(key, func(r rune) bool { return r < 0x21 || r > 0x7e }) {
		return "the value is not visible ASCII"
	}
	raw := ""
	if pr.BaseURLEnv != "" {
		raw = vars[pr.BaseURLEnv]
	}
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err == nil && u.Scheme == "https" && strings.EqualFold(u.Hostname(), pr.Host) && (u.Port() == "" || u.Port() == "443") {
		return ""
	}
	if err == nil && pr.HeadroomLoopback && vars["RIOTBOX_HEADROOM"] == "1" &&
		(strings.EqualFold(u.Hostname(), "localhost") || net.ParseIP(u.Hostname()).IsLoopback()) {
		return ""
	}
	return pr.BaseURLEnv + " is not https://" + pr.Host
}

// Notice is the line the launch prints when keys still enter the
// container, or "" when none do. Env names are shell variable names
// (ParseInput), so the line is safe to print.
func (p Plan) Notice() string {
	if len(p.PassThrough) == 0 {
		return ""
	}
	parts := make([]string, len(p.PassThrough))
	for i, k := range p.PassThrough {
		parts[i] = k.Env + " (not injectable: " + k.Reason + ")"
	}
	return "egress: these keys still enter the container: " + strings.Join(parts, ", ")
}

package policy

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
)

// InjectRow is one line of an [inject] section: a provider key the proxy
// injects besides, or instead of, an inject.Providers row
// (docs/dev/egress.md#credential-injection).
type InjectRow struct {
	Env        string // the variable the key is read from
	Host       string // the API host the key is sent to, on port 443, lowercase
	Header     string // the request header that carries it, lowercase
	Prefix     string // what goes before the key: prefix=WORD and one space; "" if none
	BaseURLEnv string // base-url=VARIABLE; "" if none
	File       string // the file it was read from
	Line       int
}

var (
	// envName is a shell variable name, as inject.ParseInput accepts.
	envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	// headerToken is a lowercase RFC 9110 token (tchar). A ":" pseudo-header
	// is not one.
	headerToken = regexp.MustCompile("^[a-z0-9!#$%&'*+.^_`|~-]+$")
)

// unsafeHeaders are the header names a row may not use: Host would send
// the request elsewhere, and the others are hop-by-hop or framing
// headers (RFC 9110 §7.6.1, §8.6), so a key in one would break the
// request rather than authenticate it.
var unsafeHeaders = []string{"host", "connection", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "content-length"}

const injectUsage = "an [inject] row is VARIABLE host header [prefix=WORD] [base-url=VARIABLE]"

// injectRow reads line n of an [inject] section, already stripped of its
// comment and trimmed.
func (p *confParser) injectRow(n int, line string) error {
	fields := strings.Fields(line)
	if len(fields) < 3 {
		return p.errorf(n, "%s", injectUsage)
	}
	rawHost := fields[1]
	row := InjectRow{Env: fields[0], Header: fields[2], File: p.c.Name, Line: n}
	if !envName.MatchString(row.Env) {
		return p.errorf(n, "%q is not a variable name", row.Env)
	}
	if first, dup := p.injected[row.Env]; dup {
		return p.errorf(n, "%s is already injected on line %d", row.Env, first)
	}
	// Checked before ToLower, which folds some non-ASCII letters (U+212A,
	// the Kelvin sign) to ASCII ones: a look-alike must not pass.
	var err error
	switch {
	case strings.ContainsFunc(rawHost, func(r rune) bool { return r < 0x21 || r > 0x7e }):
		err = errors.New("only printable ASCII is allowed")
	case strings.HasPrefix(rawHost, "*."):
		err = errors.New("a wildcard cannot carry a key; name the one host")
	case strings.ContainsAny(rawHost, "[]"):
		err = errIPLiteral
	case strings.Contains(rawHost, ":"):
		err = errors.New("give a host without a port; keys go to port 443")
	default:
		row.Host = strings.ToLower(rawHost)
		err = checkHost(row.Host)
	}
	if err != nil {
		return p.errorf(n, "invalid host %q: %v", rawHost, err)
	}
	if !headerToken.MatchString(row.Header) {
		return p.errorf(n, "%q is not a lowercase HTTP header name", row.Header)
	}
	if slices.Contains(unsafeHeaders, row.Header) {
		return p.errorf(n, "the %s header cannot carry a key: it would break or redirect the request", row.Header)
	}
	given := map[string]bool{}
	for _, opt := range fields[3:] {
		key, value, ok := strings.Cut(opt, "=")
		if !ok {
			return p.errorf(n, "extra field %q: %s", opt, injectUsage)
		}
		if given[key] {
			return p.errorf(n, "option %s= is given twice", key)
		}
		given[key] = true
		switch key {
		case "prefix":
			if value == "" || strings.ContainsFunc(value, func(r rune) bool { return r < 0x21 || r > 0x7e }) {
				return p.errorf(n, "prefix= must be visible ASCII and not empty")
			}
			row.Prefix = value + " "
		case "base-url":
			if !envName.MatchString(value) {
				return p.errorf(n, "base-url=%q is not a variable name", value)
			}
			row.BaseURLEnv = value
		default:
			return p.errorf(n, "unknown option %q (use prefix= or base-url=)", key)
		}
	}
	p.injected[row.Env] = n
	p.c.Inject = append(p.c.Inject, row)
	return nil
}

// fileRows is the system file's [inject] rows, then the user file's, a
// user row replacing the system row with the same variable in its place.
func fileRows(system, user Conf) []InjectRow {
	rows := slices.Clone(system.Inject)
	for _, row := range user.Inject {
		if i := slices.IndexFunc(rows, func(r InjectRow) bool { return r.Env == row.Env }); i >= 0 {
			rows[i] = row
		} else {
			rows = append(rows, row)
		}
	}
	return rows
}

// Providers is the table inject.Decide works from: inject.Providers, with
// the files' rows (fileRows) on top, each replacing the row with the same
// variable in its place or else appended. A replacing row is the file's
// alone, so it never keeps HeadroomLoopback: headroom-exec.sh rewrites
// ANTHROPIC_BASE_URL for api.anthropic.com, not for the row's host. Two
// rows for one host fail at the file row's line, naming the other row's
// origin: the proxy carries one key per host.
func Providers(system, user Conf) ([]inject.Provider, error) {
	table := slices.Clone(inject.Providers)
	origins := make([]string, len(table))
	for i := range origins {
		origins[i] = SourceBuiltin
	}
	for _, row := range fileRows(system, user) {
		pr := inject.Provider{Env: row.Env, Host: row.Host, Header: row.Header, Prefix: row.Prefix, BaseURLEnv: row.BaseURLEnv}
		origin := fmt.Sprintf("%s:%d", row.File, row.Line)
		if i := slices.IndexFunc(table, func(p inject.Provider) bool { return p.Env == row.Env }); i >= 0 {
			table[i], origins[i] = pr, origin
		} else {
			table, origins = append(table, pr), append(origins, origin)
		}
	}
	for j := range table {
		for i := range j {
			if table[i].Host != table[j].Host {
				continue
			}
			// The built-in rows' hosts are distinct, so one of the two is a file's.
			at, other := j, i
			if origins[at] == SourceBuiltin {
				at, other = i, j
			}
			return nil, fmt.Errorf("%s: %s injects a key for %s, as %s (%s) does; the proxy carries one key per host",
				origins[at], table[at].Env, table[at].Host, table[other].Env, origins[other])
		}
	}
	return table, nil
}

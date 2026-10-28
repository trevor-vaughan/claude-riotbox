// Package policy parses and merges the allowlist a RIOTBOX_EGRESS=1
// session's Envoy proxy enforces: the host:port pairs the agent may open a
// CONNECT tunnel to. See docs/dev/egress.md.
//
// Every entry is validated here, before any value reaches Envoy's
// configuration, so a conf file cannot inject configuration.
package policy

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// DefaultPort is the port of an entry that names none.
const DefaultPort = 443

var (
	dnsLabel = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	// numericLabel is a label inet_aton and the WHATWG URL parser read as a
	// number (decimal or 0x hex); a name ending in one is an IPv4 literal.
	// The input is already lowercase.
	numericLabel = regexp.MustCompile(`^([0-9]+|0x[0-9a-f]*)$`)
	portDigits   = regexp.MustCompile(`^[0-9]{1,5}$`)
)

var errIPLiteral = errors.New("host looks like an IP address; only names are allowed")

// Entry is one allowed destination.
type Entry struct {
	// Host is a lowercase DNS name, or "*." and one: a wildcard matching
	// any name that ends in "." and the rest, at any depth, but not the
	// rest itself.
	Host string
	Port int
}

// String is the entry as a conf file spells it: the port only when it is
// not DefaultPort.
func (e Entry) String() string {
	if e.Port == DefaultPort {
		return e.Host
	}
	return e.Host + ":" + strconv.Itoa(e.Port)
}

// Authority is the entry as Envoy matches a CONNECT request's authority:
// always host:port.
func (e Entry) Authority() string {
	return e.Host + ":" + strconv.Itoa(e.Port)
}

// Parse reads one entry: ["-"] host [":" port], where host is a DNS name of
// at least two labels or "*." and one. remove reports the leading "-".
// Only printable ASCII is accepted, and it is checked before lowercasing:
// Unicode case folding maps some non-ASCII letters (U+212A KELVIN SIGN)
// to ASCII ones, which would let a look-alike pass validation.
func Parse(raw string) (e Entry, remove bool, err error) {
	for i := 0; i < len(raw); i++ {
		if raw[i] < 0x21 || raw[i] > 0x7e {
			return Entry{}, false, errors.New("only printable ASCII without spaces is allowed")
		}
	}
	s := strings.ToLower(raw)
	s, remove = strings.CutPrefix(s, "-")
	host, port := s, DefaultPort
	if i := strings.LastIndexByte(s, ':'); i >= 0 {
		host = s[:i]
		digits := s[i+1:]
		if strings.HasPrefix(digits, "//") {
			return Entry{}, false, errors.New("a URL is not an entry; give host or host:port")
		}
		n, convErr := strconv.Atoi(digits)
		if !portDigits.MatchString(digits) || convErr != nil || n < 1 || n > 65535 {
			return Entry{}, false, errors.New("port must be a number from 1 to 65535")
		}
		port = n
	}
	if strings.ContainsAny(host, ":[]") {
		return Entry{}, false, errIPLiteral
	}
	if cerr := checkHost(strings.TrimPrefix(host, "*.")); cerr != nil {
		return Entry{}, false, cerr
	}
	return Entry{Host: host, Port: port}, remove, nil
}

// checkHost validates a DNS name (a wildcard's part after "*.").
func checkHost(name string) error {
	if name == "" {
		return errors.New("host is empty")
	}
	if len(name) > 253 {
		return errors.New("host is longer than 253 characters")
	}
	labels := strings.Split(name, ".")
	if len(labels) < 2 {
		return errors.New("host must have at least two labels (a bare name, * or *.tld is not allowed)")
	}
	for _, l := range labels {
		if !dnsLabel.MatchString(l) {
			return fmt.Errorf("label %q is not a valid DNS label", l)
		}
	}
	if numericLabel.MatchString(labels[len(labels)-1]) {
		return errIPLiteral
	}
	return nil
}

// Covering returns the wildcard entries on e's port that still match e's
// host (other than e itself), so a deny can say why a host stays allowed.
func Covering(entries []Entry, e Entry) []Entry {
	var out []Entry
	for _, w := range entries {
		suffix, wild := strings.CutPrefix(w.Host, "*")
		if wild && w != e && w.Port == e.Port && strings.HasSuffix(e.Host, suffix) {
			out = append(out, w)
		}
	}
	return out
}

// merge returns add minus remove, each entry once, sorted by host then port.
func merge(add, remove []Entry) []Entry {
	removed := map[Entry]bool{}
	for _, e := range remove {
		removed[e] = true
	}
	seen := map[Entry]bool{}
	var out []Entry
	for _, e := range add {
		if removed[e] || seen[e] {
			continue
		}
		seen[e] = true
		out = append(out, e)
	}
	slices.SortFunc(out, func(a, b Entry) int {
		if c := strings.Compare(a.Host, b.Host); c != 0 {
			return c
		}
		return a.Port - b.Port
	})
	return out
}

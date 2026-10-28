package policy_test

import (
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

func entry(host string, port int) policy.Entry { return policy.Entry{Host: host, Port: port} }

// longName is 253 characters: three 63-character labels and one of 61.
var longName = strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + strings.Repeat("d", 61)

var _ = Describe("Parse", func() {
	DescribeTable("accepts",
		func(raw string, want policy.Entry, wantRemove bool) {
			got, remove, err := policy.Parse(raw)
			Expect(err).NotTo(HaveOccurred())
			Expect(got).To(Equal(want))
			Expect(remove).To(Equal(wantRemove))
		},
		Entry("a host, on port 443", "api.example.com", entry("api.example.com", 443), false),
		Entry("a host in any case, folded to lowercase", "API.Example.COM", entry("api.example.com", 443), false),
		Entry("a host and port", "git.example.net:2222", entry("git.example.net", 2222), false),
		Entry("port 1", "a.example:1", entry("a.example", 1), false),
		Entry("port 65535", "a.example:65535", entry("a.example", 65535), false),
		Entry("a wildcard", "*.githubusercontent.com", entry("*.githubusercontent.com", 443), false),
		Entry("a removal", "-api.example.com", entry("api.example.com", 443), true),
		Entry("a wildcard removal with a port", "-*.example.com:80", entry("*.example.com", 80), true),
		Entry("labels that start with a digit", "1password.com", entry("1password.com", 443), false),
		Entry("a punycode label", "xn--bcher-kva.example", entry("xn--bcher-kva.example", 443), false),
		Entry("a last label that is not numeric despite a digit prefix", "a.123abc", entry("a.123abc", 443), false),
		Entry("a numeric-looking first label", "0x.example", entry("0x.example", 443), false),
		Entry("a zero-padded port, normalised", "a.example:0443", entry("a.example", 443), false),
		Entry("a 253-character name", longName, entry(longName, 443), false),
	)

	DescribeTable("rejects",
		func(raw, reason string) {
			_, _, err := policy.Parse(raw)
			Expect(err).To(MatchError(ContainSubstring(reason)))
		},
		Entry("an IPv4 literal", "10.0.0.1", "IP address"),
		Entry("an IPv4 literal with a port", "10.0.0.1:443", "IP address"),
		Entry("a bracketed IPv6 literal", "[::1]:443", "IP address"),
		Entry("a bare IPv6 literal", "::1", "IP address"),
		Entry("a hex IPv4 literal", "0x7f.0x1", "IP address"),
		Entry("a mixed decimal and hex IPv4 literal", "127.0.0.0x1", "IP address"),
		Entry("an empty hex last label", "a.0x", "IP address"),
		Entry("a single hex number as the last label", "a.0x7f000001", "IP address"),
		Entry("a star glued to a label", "*a.com", "not a valid DNS label"),
		Entry("a bare star", "*", "at least two labels"),
		Entry("a top-level-domain wildcard", "*.com", "at least two labels"),
		Entry("a single label", "localhost", "at least two labels"),
		Entry("an empty label", "a..com", "not a valid DNS label"),
		Entry("a trailing dot", "a.com.", "not a valid DNS label"),
		Entry("a label with a leading hyphen", "x.-a.com", "not a valid DNS label"),
		Entry("a label with a trailing hyphen", "a-.com", "not a valid DNS label"),
		Entry("a 64-character label", strings.Repeat("a", 64)+".com", "not a valid DNS label"),
		Entry("a name over 253 characters", longName+"dd", "longer than 253"),
		Entry("port 0", "a.com:0", "port must be"),
		Entry("port 65536", "a.com:65536", "port must be"),
		Entry("a signed port", "a.com:+80", "port must be"),
		Entry("an empty port", "a.com:", "port must be"),
		Entry("a URL", "https://a.com", "a URL is not an entry"),
		Entry("a path", "a.com/x", "not a valid DNS label"),
		Entry("a wildcard in the middle", "a.*.com", "not a valid DNS label"),
		Entry("a double star", "**.a.com", "not a valid DNS label"),
		Entry("a double quote", `a"b.com`, "not a valid DNS label"),
		Entry("a brace", "a{.com", "not a valid DNS label"),
		Entry("an inner space", "a .com", "printable ASCII"),
		Entry("a newline", "a.com\n", "printable ASCII"),
		Entry("a non-ASCII letter that lowercases to ASCII (KELVIN SIGN)", "\u212Aa.com", "printable ASCII"),
		Entry("a lone dash", "-", "host is empty"),
		Entry("an empty entry", "", "host is empty"),
	)
})

var _ = Describe("Entry", func() {
	It("spells the port only when it is not 443", func() {
		Expect(entry("a.example", 443).String()).To(Equal("a.example"))
		Expect(entry("a.example", 8443).String()).To(Equal("a.example:8443"))
	})

	It("always spells the port in the CONNECT authority", func() {
		Expect(entry("a.example", 443).Authority()).To(Equal("a.example:443"))
	})
})

var _ = Describe("Covering", func() {
	entries := []policy.Entry{entry("*.example.com", 443), entry("*.example.com", 8443), entry("*.other.org", 443), entry("a.example.com", 443)}

	It("finds the wildcards on the same port that still match a host", func() {
		Expect(policy.Covering(entries, entry("a.b.example.com", 443))).To(Equal([]policy.Entry{entry("*.example.com", 443)}))
	})

	It("finds a broader wildcard covering a narrower one", func() {
		Expect(policy.Covering(entries, entry("*.a.example.com", 443))).To(Equal([]policy.Entry{entry("*.example.com", 443)}))
	})

	It("does not report a wildcard as covering itself, nor the bare domain", func() {
		Expect(policy.Covering(entries, entry("*.example.com", 443))).To(BeEmpty())
		Expect(policy.Covering(entries, entry("example.com", 443))).To(BeEmpty())
	})
})

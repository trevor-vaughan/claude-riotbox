package policy_test

import (
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

func entry(host string, port int) policy.Entry { return policy.Entry{Host: host, Port: port} }
func plain(host string, port int) policy.Entry {
	return policy.Entry{Host: host, Port: port, Plain: true}
}

// longName is 253 characters: three 63-character labels and one of 61.
var longName = strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + strings.Repeat("d", 61)

func ports(host string, lo, hi int) policy.Entry {
	return policy.Entry{Host: host, Port: lo, PortEnd: hi}
}

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
		Entry("plain HTTP, on port 80", "http://mirror.example.org", plain("mirror.example.org", 80), false),
		Entry("plain HTTP with a port", "http://mirror.example.org:8080", plain("mirror.example.org", 8080), false),
		Entry("plain HTTP in any case", "HTTP://Mirror.Example.ORG", plain("mirror.example.org", 80), false),
		Entry("a plain-HTTP wildcard", "http://*.example.org", plain("*.example.org", 80), false),
		Entry("a plain-HTTP removal", "-http://mirror.example.org", plain("mirror.example.org", 80), true),
		Entry("plain HTTP on port 443, still plain", "http://a.example:443", plain("a.example", 443), false),
		Entry("a port range", "a.example:8000-8100", ports("a.example", 8000, 8100), false),
		Entry("a range of one port, as that port", "a.example:8080-8080", entry("a.example", 8080), false),
		Entry("a range of exactly 1024 ports", "a.example:1000-2023", ports("a.example", 1000, 2023), false),
		Entry("every port", "a.example:*", ports("a.example", 1, 65535), false),
		Entry("every port of every subdomain", "*.a.example:*", ports("*.a.example", 1, 65535), false),
		Entry("a wildcard range", "*.a.example:80-81", ports("*.a.example", 80, 81), false),
		Entry("a plain-HTTP range", "http://a.example:8000-8001", policy.Entry{Host: "a.example", Port: 8000, PortEnd: 8001, Plain: true}, false),
		Entry("plain HTTP on every port", "http://a.example:*", policy.Entry{Host: "a.example", Port: 1, PortEnd: 65535, Plain: true}, false),
		Entry("a range removal", "-a.example:8000-8100", ports("a.example", 8000, 8100), true),
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
		Entry("an https URL", "https://a.example", "a URL is not an entry"),
		Entry("another scheme", "ftp://a.example", "a URL is not an entry"),
		Entry("plain HTTP with a path", "http://a.example/x", "give http://host or http://host:port"),
		Entry("plain HTTP with a trailing slash", "http://a.example/", "give http://host or http://host:port"),
		Entry("plain HTTP with a query", "http://a.example?x", "give http://host or http://host:port"),
		Entry("plain HTTP with userinfo", "http://u@a.example", "give http://host or http://host:port"),
		Entry("plain HTTP with no host", "http://", "host is empty"),
		Entry("plain HTTP to an IP literal", "http://10.0.0.1", "IP address"),
		Entry("a doubled scheme", "http://http://a.example", "a URL is not an entry"),
		Entry("a removal sign after the scheme", "http://-a.example", "not a valid DNS label"),
		Entry("a range of 1025 ports", "a.example:1000-2024", "at most 1024 ports; use host:* for every port"),
		Entry("every port spelled as a range", "a.example:1-65535", "at most 1024 ports; use host:* for every port"),
		Entry("a reversed range", "a.example:9000-8000", "a port range runs low-high"),
		Entry("a range with no end", "a.example:8000-", "port must be a number from 1 to 65535"),
		Entry("a range with no start", "a.example:-8000", "port must be a number from 1 to 65535"),
		Entry("a range of three numbers", "a.example:1-2-3", "port must be a number from 1 to 65535"),
		Entry("a range from port 0", "a.example:0-10", "port must be a number from 1 to 65535"),
		Entry("a range past 65535", "a.example:65535-65536", "port must be a number from 1 to 65535"),
		Entry("a star with digits", "a.example:8*", "port must be a number from 1 to 65535"),
		Entry("a star as the host", "*:*", "at least two labels"),
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

var _ = Describe("Overlapping", func() {
	It("finds a narrower entry inside a denied range or every port, on the same host", func() {
		list := []policy.Entry{entry("a.example", 443), ports("a.example", 8000, 8100), entry("b.example", 443)}
		Expect(policy.Overlapping(list, ports("a.example", 1, 65535))).To(Equal([]policy.Entry{entry("a.example", 443), ports("a.example", 8000, 8100)}))
		Expect(policy.Overlapping(list, ports("a.example", 8050, 8200))).To(Equal([]policy.Entry{ports("a.example", 8000, 8100)}))
	})

	It("finds a wildcard's entries on a host it matches, and the reverse", func() {
		list := []policy.Entry{entry("a.example.com", 443), ports("*.example.com", 8000, 8100)}
		Expect(policy.Overlapping(list, ports("*.example.com", 1, 65535))).To(Equal(list))
		Expect(policy.Overlapping(list, entry("a.example.com", 8080))).To(BeEmpty())
		Expect(policy.Overlapping(list, ports("a.example.com", 8090, 9000))).To(Equal([]policy.Entry{ports("*.example.com", 8000, 8100)}))
		Expect(policy.Overlapping(list, ports("a.example.com", 9000, 9100))).To(BeEmpty())
	})

	It("leaves out what Covering reports, itself, disjoint ports, other hosts and the other kind", func() {
		list := []policy.Entry{ports("a.example", 1, 65535), entry("a.example", 80), entry("b.example", 443), plain("a.example", 443)}
		Expect(policy.Overlapping(list, entry("a.example", 443))).To(BeEmpty())
		Expect(policy.Overlapping(list, ports("a.example", 1, 65535))).To(Equal([]policy.Entry{entry("a.example", 80)}))
	})
})

var _ = Describe("Entry, plain HTTP", func() {
	It("spells a plain entry with its scheme, and its port only when it is not 80", func() {
		Expect(plain("a.example", 80).String()).To(Equal("http://a.example"))
		Expect(plain("a.example", 8080).String()).To(Equal("http://a.example:8080"))
		Expect(plain("a.example", 443).String()).To(Equal("http://a.example:443"))
		Expect(plain("a.example", 80).Authority()).To(Equal("a.example:80"))
	})

	It("round-trips every plain spelling through Parse", func() {
		for _, e := range []policy.Entry{plain("a.example", 80), plain("a.example", 8080), plain("*.a.example", 80)} {
			got, _, err := policy.Parse(e.String())
			Expect(err).NotTo(HaveOccurred())
			Expect(got).To(Equal(e))
		}
	})

	It("never covers a plain entry by a tunnel wildcard, or the reverse", func() {
		Expect(policy.Covering([]policy.Entry{entry("*.example.org", 80)}, plain("a.example.org", 80))).To(BeEmpty())
		Expect(policy.Covering([]policy.Entry{plain("*.example.org", 80)}, entry("a.example.org", 80))).To(BeEmpty())
		Expect(policy.Covering([]policy.Entry{plain("*.example.org", 80)}, plain("a.example.org", 80))).To(Equal([]policy.Entry{plain("*.example.org", 80)}))
	})
})

var _ = Describe("Entry, port ranges", func() {
	It("spells a range low-high and every port as *, round-tripping through Parse", func() {
		for raw, e := range map[string]policy.Entry{
			"a.example:8000-8100":    ports("a.example", 8000, 8100),
			"a.example:*":            ports("a.example", 1, 65535),
			"*.a.example:*":          ports("*.a.example", 1, 65535),
			"http://a.example:*":     {Host: "a.example", Port: 1, PortEnd: 65535, Plain: true},
			"http://a.example:80-81": {Host: "a.example", Port: 80, PortEnd: 81, Plain: true},
		} {
			Expect(e.String()).To(Equal(raw))
			got, _, err := policy.Parse(raw)
			Expect(err).NotTo(HaveOccurred())
			Expect(got).To(Equal(e))
		}
	})

	DescribeTable("Covers: hosts and ports, either kind",
		func(w, e policy.Entry, want bool) { Expect(policy.Covers(w, e)).To(Equal(want)) },
		Entry("a range holds a port in it", ports("a.example", 8000, 8100), entry("a.example", 8080), true),
		Entry("a range holds its own ends", ports("a.example", 8000, 8100), entry("a.example", 8100), true),
		Entry("a range does not hold a port past it", ports("a.example", 8000, 8100), entry("a.example", 8101), false),
		Entry("a range holds a narrower range", ports("a.example", 8000, 8100), ports("a.example", 8010, 8020), true),
		Entry("a range does not hold an overlapping one", ports("a.example", 8000, 8100), ports("a.example", 8050, 8150), false),
		Entry("every port holds any port", ports("a.example", 1, 65535), entry("a.example", 22), true),
		Entry("a range does not hold every port", ports("a.example", 1, 1024), ports("a.example", 1, 65535), false),
		Entry("a wildcard on every port holds a subdomain's port", ports("*.example.org", 1, 65535), entry("a.b.example.org", 9), true),
		Entry("a wildcard holds a narrower wildcard", ports("*.example.org", 1, 65535), ports("*.a.example.org", 1, 65535), true),
		Entry("a wildcard does not hold its bare domain", ports("*.example.org", 1, 65535), entry("example.org", 443), false),
		Entry("a narrower wildcard does not hold a broader one", ports("*.a.example.org", 1, 65535), ports("*.example.org", 1, 65535), false),
		Entry("another host is not held", ports("a.example", 1, 65535), entry("b.example", 443), false),
		Entry("kind is ignored", policy.Entry{Host: "a.example", Port: 1, PortEnd: 65535, Plain: true}, entry("a.example", 443), true),
	)

	It("lists a range or every port as covering a port it holds, of the same kind only", func() {
		list := []policy.Entry{ports("a.example", 8000, 8100), {Host: "a.example", Port: 1, PortEnd: 65535, Plain: true}}
		Expect(policy.Covering(list, entry("a.example", 8080))).To(Equal([]policy.Entry{ports("a.example", 8000, 8100)}))
		Expect(policy.Allows(list, entry("a.example", 8080))).To(BeTrue())
		Expect(policy.Allows(list, entry("a.example", 9000))).To(BeFalse())
	})
})

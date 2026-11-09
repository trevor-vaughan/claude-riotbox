package envoyconfig_test

import (
	"regexp"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/envoyconfig"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// An :authority regex that accepts a port Envoy's exact-domain match does
// not treat as the same port (0443 for 443) lets a request miss the
// intercept virtual host and fall to a raw tunnel.
var _ = Describe("the :authority guard regexes", func() {
	// guard compiles the regex of the first route of the named virtual host.
	guard := func(entries []policy.Entry, vhost string) *regexp.Regexp {
		rds := envoyconfig.RenderRDS(entries, nil)
		for _, v := range dig(decode(rds), "resources", 0, "virtual_hosts").([]any) {
			if dig(v, "name") == vhost {
				re, err := regexp.Compile(dig(v, "routes", 0, "match", "headers", 0, "string_match", "safe_regex", "regex").(string))
				Expect(err).NotTo(HaveOccurred())
				return re
			}
		}
		Fail("no virtual host " + vhost)
		return nil
	}
	allPorts := func(host string, plain bool) []policy.Entry {
		return []policy.Entry{{Host: host, Port: 1, PortEnd: 65535, Plain: plain}}
	}
	badPorts := []string{"0", "0443", "00443", "65536", "99999", "100000", "", "443@evil.com", "443#x", "443/x", "443."}

	It("accepts exactly the ports 1 to 65535 for host:*", func() {
		re := guard(allPorts("h.example", false), "ports-h.example")
		for _, a := range []string{"h.example:1", "h.example:443", "h.example:9999", "h.example:10000", "h.example:65535", "H.EXAMPLE:443", "h.example:60000"} {
			Expect(re.MatchString(a)).To(BeTrue(), a)
		}
		for _, p := range badPorts {
			Expect(re.MatchString("h.example:"+p)).To(BeFalse(), p)
		}
		for _, a := range []string{"h.example", "xh.example:443", "h.example.:443", "h.example:443:443", "h.examplex:443"} {
			Expect(re.MatchString(a)).To(BeFalse(), a)
		}
	})

	It("accepts exactly the ports 1 to 65535 for *.domain:* over CONNECT", func() {
		re := guard(allPorts("*.s.example", false), "deny")
		for _, a := range []string{"x.s.example:1", "x.s.example:443", "a.b.s.example:65535", "X.S.EXAMPLE:8080"} {
			Expect(re.MatchString(a)).To(BeTrue(), a)
		}
		for _, p := range badPorts {
			Expect(re.MatchString("x.s.example:"+p)).To(BeFalse(), p)
		}
		for _, a := range []string{"s.example:443", "x.s.example", "x.s.example.evil:443", "x.s.example.:443", "xs.example:443"} {
			Expect(re.MatchString(a)).To(BeFalse(), a)
		}
	})

	It("accepts a bare host or exactly the ports 1 to 65535 for http://*.domain:*", func() {
		re := guard(allPorts("*.s.example", true), "deny")
		for _, a := range []string{"x.s.example", "x.s.example:8080", "x.s.example:65535", "x.s.example:1"} {
			Expect(re.MatchString(a)).To(BeTrue(), a)
		}
		for _, p := range badPorts {
			Expect(re.MatchString("x.s.example:"+p)).To(BeFalse(), p)
		}
		for _, a := range []string{"s.example", "s.example:443", "x.s.example.evil", "x.s.example.evil:443"} {
			Expect(re.MatchString(a)).To(BeFalse(), a)
		}
	})
})

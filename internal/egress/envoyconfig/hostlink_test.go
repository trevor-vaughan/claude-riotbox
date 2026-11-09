package envoyconfig_test

import (
	"regexp"
	"slices"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/envoyconfig"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

var _ = Describe("host-loopback routing", func() {
	const hl = policy.HostLink

	vhost := func(rds []byte, name string) map[string]any {
		for _, v := range dig(decode(rds), "resources", 0, "virtual_hosts").([]any) {
			if v.(map[string]any)["name"] == name {
				return v.(map[string]any)
			}
		}
		return nil
	}
	names := func(rds []byte) []string {
		var out []string
		for _, v := range dig(decode(rds), "resources", 0, "virtual_hosts").([]any) {
			out = append(out, v.(map[string]any)["name"].(string))
		}
		return out
	}
	isPassthrough := func(route any) {
		Expect(dig(route, "match", "connect_matcher")).To(Equal(map[string]any{}))
		Expect(dig(route, "route", "cluster")).To(Equal("hostlink"))
		Expect(dig(route, "route", "timeout")).To(Equal("0s"))
		Expect(dig(route, "route", "upgrade_configs")).To(Equal([]any{map[string]any{"upgrade_type": "CONNECT"}}))
	}
	isRefusal := func(routes any) {
		Expect(routes).To(Equal([]any{
			map[string]any{"match": map[string]any{"connect_matcher": map[string]any{}}, "direct_response": map[string]any{"status": float64(403)}},
			map[string]any{"match": map[string]any{"prefix": "/"}, "direct_response": map[string]any{"status": float64(403)}},
		}))
	}

	It("renders as before when no entry names or covers the host", func() {
		rds := envoyconfig.RenderRDS(sample, nil)
		Expect(names(rds)).NotTo(ContainElements("hostlink", "hostlink-rest"))
	})

	It("passes each allowed port's CONNECT to the relay unterminated, and refuses the rest of the host", func() {
		rds := envoyconfig.RenderRDS([]policy.Entry{{Host: hl, Port: 18000, PortEnd: 18002}, {Host: "example.com", Port: 443}}, nil)
		v := vhost(rds, "hostlink")
		Expect(v["domains"]).To(Equal([]any{hl + ":18000", hl + ":18001", hl + ":18002"}))
		isPassthrough(dig(v, "routes", 0))
		Expect(dig(v, "routes", 1, "direct_response", "status")).To(Equal(float64(403)))
		rest := vhost(rds, "hostlink-rest")
		Expect(rest["domains"]).To(Equal([]any{hl, hl + ":*"}))
		isRefusal(rest["routes"])
	})

	It("opens no port for a plain host-loopback entry", func() {
		rds := envoyconfig.RenderRDS([]policy.Entry{{Host: hl, Port: 80, Plain: true}, {Host: hl, Port: 2222}}, nil)
		Expect(vhost(rds, "hostlink")["domains"]).To(Equal([]any{hl + ":2222"}))
	})

	It("keeps a wildcard covering the host from reaching it through the forward proxy", func() {
		rds := envoyconfig.RenderRDS([]policy.Entry{{Host: "*.internal", Port: 443}}, nil)
		Expect(vhost(rds, "hostlink")).To(BeNil())
		rest := vhost(rds, "hostlink-rest")
		Expect(rest["domains"]).To(Equal([]any{hl + ":443", hl, hl + ":*"}))
		isRefusal(rest["routes"])
		Expect(vhost(rds, "allowed")["domains"]).To(ContainElement("*.internal:443"))
	})

	It("sends a port a wildcard and a host entry share to the relay", func() {
		rds := envoyconfig.RenderRDS([]policy.Entry{{Host: "*.containers.internal", Port: 443}, {Host: hl, Port: 443}}, nil)
		Expect(vhost(rds, "hostlink")["domains"]).To(Equal([]any{hl + ":443"}))
		Expect(vhost(rds, "hostlink-rest")["domains"]).To(Equal([]any{hl, hl + ":*"}))
	})

	It("passes every port under host:*, by an authority guard, and a wildcard's port too", func() {
		rds := envoyconfig.RenderRDS([]policy.Entry{{Host: hl, Port: 1, PortEnd: 65535}, {Host: "*.internal", Port: 8443}}, nil)
		Expect(vhost(rds, "hostlink")["domains"]).To(Equal([]any{hl + ":8443"}))
		rest := vhost(rds, "hostlink-rest")
		Expect(rest["domains"]).To(Equal([]any{hl, hl + ":*"}))
		route := dig(rest, "routes", 0)
		isPassthrough(route)
		re := regexp.MustCompile(dig(route, "match", "headers", 0, "string_match", "safe_regex", "regex").(string))
		Expect(re.MatchString(hl + ":22")).To(BeTrue())
		Expect(re.MatchString("HOST.containers.internal:65535")).To(BeTrue())
		Expect(re.MatchString(hl + ":022")).To(BeFalse())
		Expect(re.MatchString(hl + ":65536")).To(BeFalse())
		Expect(re.MatchString(hl)).To(BeFalse())
	})

	It("refuses the host under a wildcard's every-port entry", func() {
		rds := envoyconfig.RenderRDS([]policy.Entry{{Host: "*.containers.internal", Port: 1, PortEnd: 65535}}, nil)
		rest := vhost(rds, "hostlink-rest")
		Expect(rest["domains"]).To(Equal([]any{hl, hl + ":*"}))
		isRefusal(rest["routes"])
	})

	It("never intercepts the host", func() {
		rds := envoyconfig.RenderRDS([]policy.Entry{{Host: hl, Port: 443}}, []envoyconfig.Intercept{{Host: hl, Header: "x-api-key"}})
		Expect(names(rds)).NotTo(ContainElement("intercept-" + hl))
		Expect(vhost(rds, "hostlink")["domains"]).To(Equal([]any{hl + ":443"}))
	})

	// served is the vhost Envoy picks for authority: an exact domain
	// first, then the longest "*suffix", then the longest "prefix*", then
	// "*". A wildcard never matches the empty string.
	served := func(rds []byte, authority string) map[string]any {
		var best map[string]any
		bestRank, bestLen := 0, -1
		for _, v := range dig(decode(rds), "resources", 0, "virtual_hosts").([]any) {
			for _, d := range v.(map[string]any)["domains"].([]any) {
				d := d.(string)
				rank := 0
				switch {
				case d == authority:
					rank = 4
				case d == "*":
					rank = 1
				case strings.HasPrefix(d, "*") && len(authority) > len(d)-1 && strings.HasSuffix(authority, d[1:]):
					rank = 3
				case strings.HasSuffix(d, "*") && len(authority) > len(d)-1 && strings.HasPrefix(authority, d[:len(d)-1]):
					rank = 2
				default:
					continue
				}
				if rank > bestRank || rank == bestRank && len(d) > bestLen {
					best, bestRank, bestLen = v.(map[string]any), rank, len(d)
				}
			}
		}
		return best
	}

	DescribeTable("never serves the host's authorities from a vhost that reaches the forward proxy",
		func(entries ...policy.Entry) {
			rds := envoyconfig.RenderRDS(entries, nil)
			for _, authority := range []string{hl, hl + ":80", hl + ":443"} {
				v := served(rds, authority)
				Expect(v).NotTo(BeNil(), authority)
				for _, route := range v["routes"].([]any) {
					action, _ := route.(map[string]any)["route"].(map[string]any)
					Expect(action["cluster"]).NotTo(Equal("egress"), "%s is served by vhost %s", authority, v["name"])
				}
			}
		},
		// http://*.internal: port 80, rendered with its bare domain too.
		Entry("plain HTTP to a wildcard over the host", policy.Entry{Host: "*.internal", Port: 80, Plain: true}),
		Entry("a wildcard's port and the host's every port",
			policy.Entry{Host: "*.internal", Port: 443}, policy.Entry{Host: hl, Port: 1, PortEnd: 65535}),
	)

	It("always has the relay's cluster, a pipe to its socket", func() {
		cds := dig(decode(envoyconfig.Render("s1", sample, nil).CDS), "resources").([]any)
		i := slices.IndexFunc(cds, func(c any) bool { return c.(map[string]any)["name"] == "hostlink" })
		Expect(i).To(BeNumerically(">=", 0))
		Expect(dig(cds[i], "load_assignment", "endpoints", 0, "lb_endpoints", 0, "endpoint", "address", "pipe", "path")).
			To(Equal("/run/riotbox-hostlink/relay.sock"))
	})

	It("counts the host's ports toward MaxDomains", func() {
		var entries []policy.Entry
		for lo := 1; lo+1023 <= 65535 && len(entries) < 63; lo += 1024 {
			entries = append(entries, policy.Entry{Host: hl, Port: lo, PortEnd: lo + 1023})
		}
		Expect(envoyconfig.Check(entries, nil)).To(Succeed())
		for i := range 2 {
			entries = append(entries, policy.Entry{Host: "example.com", Port: 1 + i*1024, PortEnd: 1024 + i*1024})
		}
		Expect(envoyconfig.Check(entries, nil)).To(MatchError(ContainSubstring("single-port domains")))
	})
})

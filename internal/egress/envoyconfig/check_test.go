package envoyconfig_test

import (
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/envoyconfig"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

var _ = Describe("Check", func() {
	// ranges is n entries of 1024 ports each, n*1024 domains in all.
	ranges := func(n int) []policy.Entry {
		var out []policy.Entry
		for i := 0; i < n; i++ {
			out = append(out, policy.Entry{Host: fmt.Sprintf("h%d.example.com", i), Port: 1, PortEnd: policy.MaxPortRange})
		}
		return out
	}

	It("accepts an allowlist of exactly MaxDomains single-port domains", func() {
		Expect(envoyconfig.MaxDomains).To(Equal(65536))
		Expect(envoyconfig.Check(ranges(64), nil)).To(Succeed())
	})

	It("refuses one domain more, naming the count and the cap", func() {
		err := envoyconfig.Check(append(ranges(64), policy.Entry{Host: "extra.example.com", Port: 443}), nil)
		Expect(err).To(MatchError(ContainSubstring("65537 single-port domains, more than the 65536 allowed")))
		Expect(err).To(MatchError(ContainSubstring("fewer or narrower port ranges, or host:*")))
	})

	It("counts the intersection of a wildcard range with each host:* under it", func() {
		entries := []policy.Entry{{Host: "*.example.com", Port: 1, PortEnd: policy.MaxPortRange}}
		for i := 0; i < 64; i++ {
			entries = append(entries, policy.Entry{Host: fmt.Sprintf("h%d.example.com", i), Port: 1, PortEnd: 65535})
		}
		// 1024 wildcard domains alone; the 64 hosts add 64*1024 more.
		Expect(envoyconfig.Check(entries[:1], nil)).To(Succeed())
		Expect(envoyconfig.Check(entries, nil)).To(MatchError(ContainSubstring("66560 single-port domains")))
		Expect(envoyconfig.Check(entries[:63], nil)).To(Succeed())
	})

	It("does not count a host's every-port entry", func() {
		Expect(envoyconfig.Check([]policy.Entry{{Host: "a.example.com", Port: 1, PortEnd: 65535}}, nil)).To(Succeed())
	})
})

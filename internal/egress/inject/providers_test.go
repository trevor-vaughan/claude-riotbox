package inject_test

import (
	"os/exec"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

var _ = Describe("Providers", func() {
	It("gives each variable and each host one row, with a lowercase header and a matching prefix", func() {
		envs, hosts := map[string]bool{}, map[string]bool{}
		for _, p := range inject.Providers {
			Expect(envs).NotTo(HaveKey(p.Env), p.Env)
			Expect(hosts).NotTo(HaveKey(p.Host), p.Host)
			envs[p.Env], hosts[p.Host] = true, true
			Expect(inject.IsEnvName(p.Env)).To(BeTrue(), p.Env)
			Expect(p.Header).To(MatchRegexp(`^[a-z0-9-]+$`), p.Env)
			wantPrefix := ""
			if p.Header == "authorization" {
				wantPrefix = "Bearer "
			}
			Expect(p.Prefix).To(Equal(wantPrefix), p.Env)
			if p.BaseURLEnv != "" {
				Expect(inject.IsEnvName(p.BaseURLEnv)).To(BeTrue(), p.Env)
			}
		}
	})

	It("allows headroom's loopback base URL only for the row whose base URL headroom rewrites", func() {
		// agents/claude/headroom-exec.sh sets ANTHROPIC_BASE_URL; opencode's
		// headroom path rewrites its config, not a base-URL variable; Pi has none.
		var rows []string
		for _, p := range inject.Providers {
			if p.HeadroomLoopback {
				rows = append(rows, p.Env)
			}
		}
		Expect(rows).To(Equal([]string{"ANTHROPIC_API_KEY"}))
	})

	It("names only hosts the egress grammar accepts, on port 443, never a wildcard", func() {
		for _, p := range inject.Providers {
			e, remove, err := policy.Parse(p.Host)
			Expect(err).NotTo(HaveOccurred(), p.Host)
			Expect(remove).To(BeFalse(), p.Host)
			Expect(e).To(Equal(policy.Entry{Host: p.Host, Port: policy.DefaultPort}), p.Host)
			Expect(p.Host).NotTo(HavePrefix("*"))
		}
	})

	It("covers every key the agents' env_vars name, but the one left out on purpose, and no other", func() {
		out, err := exec.Command("bash", "-c",
			`source "$1/agents/registry.sh" && for a in "${AGENT_REGISTRY[@]}"; do agent_call "$a" env_vars; done`,
			"bash", "../../..").Output()
		Expect(err).NotTo(HaveOccurred())
		var keys []string
		for _, name := range strings.Fields(string(out)) {
			if strings.HasSuffix(name, "_KEY") || strings.HasSuffix(name, "_TOKEN") {
				keys = append(keys, name)
			}
		}
		Expect(keys).NotTo(BeEmpty())
		rows := map[string]bool{}
		for _, p := range inject.Providers {
			rows[p.Env] = true
			Expect(keys).To(ContainElement(p.Env), "a row no agent passes into the container")
		}
		for _, k := range keys {
			if k == "ANTHROPIC_AUTH_TOKEN" { // left out: see providers.go
				Expect(rows).NotTo(HaveKey(k))
				continue
			}
			Expect(rows).To(HaveKey(k))
		}
	})
})

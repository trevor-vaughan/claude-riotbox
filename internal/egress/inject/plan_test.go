package inject_test

import (
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
)

var _ = Describe("Decide", func() {
	anthropic := inject.Provider{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key", BaseURLEnv: "ANTHROPIC_BASE_URL", HeadroomLoopback: true}
	openai := inject.Provider{Env: "OPENAI_API_KEY", Host: "api.openai.com", Header: "authorization", Prefix: "Bearer ", BaseURLEnv: "OPENAI_BASE_URL"}
	table := []inject.Provider{anthropic, openai}
	const unknown = "not in the provider table"

	It("injects each set key, in table order, with its header's prefix", func() {
		p := inject.Decide(map[string]string{"OPENAI_API_KEY": "sk-o", "ANTHROPIC_API_KEY": "sk-a"}, table)
		Expect(p.Inject).To(Equal([]inject.Credential{
			{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key", Value: "sk-a"},
			{Env: "OPENAI_API_KEY", Host: "api.openai.com", Header: "authorization", Value: "Bearer sk-o"},
		}))
		Expect(p.PassThrough).To(BeEmpty())
		Expect(p.Notice()).To(BeEmpty())
	})

	It("ignores an unset or empty key, and a variable whose name suggests no secret", func() {
		p := inject.Decide(map[string]string{"ANTHROPIC_API_KEY": "", "AWS_REGION": "eu-west-1", "UNKNOWN_TOKEN": ""}, table)
		Expect(p.Inject).To(BeEmpty())
		Expect(p.PassThrough).To(BeEmpty())
	})

	DescribeTable("a base URL",
		func(url, headroom string, injected bool) {
			vars := map[string]string{"ANTHROPIC_API_KEY": "sk-a", "ANTHROPIC_BASE_URL": url, "RIOTBOX_HEADROOM": headroom}
			p := inject.Decide(vars, table)
			if injected {
				Expect(p.Inject).To(HaveLen(1))
				Expect(p.PassThrough).To(BeEmpty())
				return
			}
			Expect(p.Inject).To(BeEmpty())
			Expect(p.PassThrough).To(Equal([]inject.PassThrough{{Env: "ANTHROPIC_API_KEY", Reason: "ANTHROPIC_BASE_URL is not https://api.anthropic.com"}}))
		},
		Entry("unset keeps the key injectable", "", "", true),
		Entry("the provider's own host", "https://api.anthropic.com", "", true),
		Entry("the provider's own host in any case, on 443, with a path", "https://API.Anthropic.com:443/v1", "", true),
		Entry("the provider's own host on 443 with a bare path", "https://api.anthropic.com:443/", "", true),
		Entry("the provider's own host with userinfo", "https://x:pw@api.anthropic.com", "", true),
		Entry("the provider's host with a trailing dot", "https://api.anthropic.com./", "", false),
		Entry("plain HTTP to the provider's host", "http://api.anthropic.com", "", false),
		Entry("another port", "https://api.anthropic.com:8443", "", false),
		Entry("a gateway", "https://gateway.example", "", false),
		Entry("a look-alike name", "https://api.anthropic.com.evil.example", "", false),
		Entry("headroom's loopback proxy, with headroom on", "http://127.0.0.1:8787", "1", true),
		Entry("localhost, with headroom on", "http://localhost:8787", "1", true),
		Entry("IPv6 loopback, with headroom on", "http://[::1]:8787", "1", true),
		Entry("another 127/8 address, with headroom on", "http://127.0.0.2:8787", "1", true),
		Entry("localhost with a trailing dot, with headroom on", "http://localhost.:8787", "1", false),
		Entry("the unspecified address, with headroom on", "http://0.0.0.0:8787", "1", false),
		Entry("a loopback URL with headroom off", "http://127.0.0.1:8787", "", false),
		Entry("a gateway, even with headroom on", "https://gateway.example", "1", false),
		Entry("a URL that does not parse", "http://[::1", "1", false),
	)

	It("keeps a loopback base URL for headroom to the rows headroom rewrites", func() {
		p := inject.Decide(map[string]string{
			"OPENAI_API_KEY": "sk-o", "OPENAI_BASE_URL": "http://127.0.0.1:8787", "RIOTBOX_HEADROOM": "1",
		}, table)
		Expect(p.Inject).To(BeEmpty())
		Expect(p.PassThrough).To(Equal([]inject.PassThrough{{Env: "OPENAI_API_KEY", Reason: "OPENAI_BASE_URL is not https://api.openai.com"}}))
	})

	DescribeTable("passes through a key that is not visible ASCII, which cannot go in a header as is",
		func(key string) {
			p := inject.Decide(map[string]string{"OPENAI_API_KEY": key}, table)
			Expect(p.Inject).To(BeEmpty())
			Expect(p.PassThrough).To(Equal([]inject.PassThrough{{Env: "OPENAI_API_KEY", Reason: "the value is not visible ASCII"}}))
		},
		Entry("CR LF", "sk-o\r\nx-evil: 1"),
		Entry("DEL", "sk-o\x7f"),
		Entry("a high byte", "sk-o\x80"),
		Entry("a space alone", " "),
		Entry("invalid UTF-8", "\xff\xfe"),
		Entry("surrounding spaces", " k "),
		Entry("a tab", "k\t"),
	)

	It("passes through, sorted, every other set variable whose name suggests a secret", func() {
		p := inject.Decide(map[string]string{
			"GITHUB_TOKEN": "g", "AWS_SECRET": "s", "DB_PASSWORD": "p", "NVAPIKEY": "n", "AWS_REGION": "r",
			"github_token": "g", "Db_Password": "p",
		}, table)
		Expect(p.Inject).To(BeEmpty())
		Expect(p.PassThrough).To(Equal([]inject.PassThrough{
			{Env: "AWS_SECRET", Reason: unknown}, {Env: "DB_PASSWORD", Reason: unknown},
			{Env: "Db_Password", Reason: unknown}, {Env: "GITHUB_TOKEN", Reason: unknown},
			{Env: "NVAPIKEY", Reason: unknown}, {Env: "github_token", Reason: unknown},
		}))
	})

	It("says which keys still enter the container and why, never what they hold", func() {
		n := inject.Decide(map[string]string{
			"ANTHROPIC_API_KEY": "sk-a-s3cret", "ANTHROPIC_BASE_URL": "https://user:pw0rd@gateway.example",
			"GITHUB_TOKEN": "ghp-s3cret",
		}, table).Notice()
		Expect(n).To(Equal("egress: these keys still enter the container: " +
			"ANTHROPIC_API_KEY (not injectable: ANTHROPIC_BASE_URL is not https://api.anthropic.com), " +
			"GITHUB_TOKEN (not injectable: not in the provider table)"))
		Expect(n).NotTo(ContainSubstring("s3cret"))
		Expect(n).NotTo(ContainSubstring("pw0rd"))
	})

	It("never formats a credential's value, alone or in a plan", func() {
		p := inject.Decide(map[string]string{"ANTHROPIC_API_KEY": "sk-a-s3cret", "OPENAI_API_KEY": "sk-o-s3cret"}, table)
		Expect(p.Inject).To(HaveLen(2))
		c := p.Inject[0]
		for _, v := range []any{c, &c, p, &p} {
			out := fmt.Sprintf("%v %+v %#v %s %q", v, v, v, v, v)
			Expect(out).To(ContainSubstring("ANTHROPIC_API_KEY"))
			Expect(out).To(ContainSubstring("[redacted]"))
			Expect(out).NotTo(ContainSubstring("s3cret"), "a formatted credential holds its key")
		}
	})
})

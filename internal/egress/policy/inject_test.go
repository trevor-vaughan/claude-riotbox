package policy_test

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

var _ = Describe("an [inject] section", func() {
	It("reads each row with its options, file and line, among other sections", func() {
		text := "a.example\n" + // 1
			"[inject]\n" + // 2
			"NVIDIA_API_KEY  Integrate.API.nvidia.com  authorization  base-url=NVIDIA_BASE_URL prefix=Bearer  # why\n" + // 3
			"[group mirrors]\n" + // 4
			"m.example\n" + // 5
			"[inject]\n" + // 6
			"FOO_API_KEY api.foo.example x-api-key\n" + // 7
			"[allow]\n" + // 8
			"b.example\n" // 9
		c, err := policy.ParseFile("u.conf", []byte(text))
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Inject).To(Equal([]policy.InjectRow{
			{Env: "NVIDIA_API_KEY", Host: "integrate.api.nvidia.com", Header: "authorization", Prefix: "Bearer ", BaseURLEnv: "NVIDIA_BASE_URL", File: "u.conf", Line: 3},
			{Env: "FOO_API_KEY", Host: "api.foo.example", Header: "x-api-key", File: "u.conf", Line: 7},
		}))
		Expect(c.Items).To(Equal([]policy.Item{item("a.example", 1), item("b.example", 9)}))
		Expect(c.Groups).To(HaveLen(1))
	})

	It("reads a row's prefix= as an option, never as a setting", func() {
		c, err := policy.ParseFile("u.conf", []byte("[inject]\nK api.k.example authorization prefix=Token\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Strict).To(Equal(policy.StrictUnset))
		Expect(c.Inject[0].Prefix).To(Equal("Token "))
	})

	It("accepts an empty [inject] section", func() {
		c, err := policy.ParseFile("u.conf", []byte("[inject]\n# none yet\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Inject).To(BeEmpty())
	})

	DescribeTable("refuses, naming the file and line",
		func(row, want string) {
			_, err := policy.ParseFile("u.conf", []byte("[inject]\n"+row+"\n"))
			Expect(err).To(MatchError(HavePrefix("u.conf:2: " + want)))
		},
		Entry("a missing field", "K api.k.example", "an [inject] row is VARIABLE host header [prefix=WORD] [base-url=VARIABLE]"),
		Entry("an extra positional field", "K api.k.example x-api-key extra", `extra field "extra"`),
		Entry("a variable that is not a variable name", "BAD-NAME api.k.example x-api-key", `"BAD-NAME" is not a variable name`),
		Entry("a variable starting with a digit", "1K api.k.example x-api-key", `"1K" is not a variable name`),
		Entry("an IP address", "K 10.0.0.1 x-api-key", `invalid host "10.0.0.1"`),
		Entry("an IPv6 literal", "K [::1] x-api-key", `invalid host "[::1]"`),
		Entry("a wildcard", "K *.k.example x-api-key", `invalid host "*.k.example": a wildcard cannot carry a key`),
		Entry("a port", "K api.k.example:8443 x-api-key", `invalid host "api.k.example:8443": give a host without a port`),
		Entry("a bare name", "K localhost x-api-key", `invalid host "localhost"`),
		// U+212A KELVIN SIGN lowercases to ASCII "k": it must be refused, not folded.
		Entry("a Kelvin-sign look-alike host", "K api.\u212aey.example x-api-key", "invalid host \"api.\u212aey.example\": only printable ASCII is allowed"),
		Entry("an uppercase header", "K api.k.example X-Api-Key", `"X-Api-Key" is not a lowercase HTTP header name`),
		Entry("a pseudo-header", "K api.k.example :authority", `":authority" is not a lowercase HTTP header name`),
		Entry("a header with a separator", "K api.k.example x/key", `"x/key" is not a lowercase HTTP header name`),
		Entry("the host header", "K api.k.example host", "the host header cannot carry a key"),
		Entry("connection", "K api.k.example connection", "the connection header cannot carry a key"),
		Entry("keep-alive", "K api.k.example keep-alive", "the keep-alive header cannot carry a key"),
		Entry("proxy-connection", "K api.k.example proxy-connection", "the proxy-connection header cannot carry a key"),
		Entry("te", "K api.k.example te", "the te header cannot carry a key"),
		Entry("trailer", "K api.k.example trailer", "the trailer header cannot carry a key"),
		Entry("transfer-encoding", "K api.k.example transfer-encoding", "the transfer-encoding header cannot carry a key"),
		Entry("upgrade", "K api.k.example upgrade", "the upgrade header cannot carry a key"),
		Entry("content-length", "K api.k.example content-length", "the content-length header cannot carry a key"),
		Entry("an empty prefix", "K api.k.example authorization prefix=", "prefix= must be visible ASCII and not empty"),
		Entry("a prefix with a control character", "K api.k.example authorization prefix=Be\x01arer", "prefix= must be visible ASCII and not empty"),
		Entry("a non-ASCII prefix", "K api.k.example authorization prefix=Béarer", "prefix= must be visible ASCII and not empty"),
		Entry("a base-url that is not a variable name", "K api.k.example x-api-key base-url=https://x", `base-url="https://x" is not a variable name`),
		Entry("an unknown option", "K api.k.example x-api-key port=443", `unknown option "port" (use prefix= or base-url=)`),
		Entry("a trailing-dot host", "K a.example. x-api-key", `invalid host "a.example."`),
		Entry("a host with userinfo", "K u@a.example x-api-key", `invalid host "u@a.example"`),
		Entry("a host with a path", "K a.example/x x-api-key", `invalid host "a.example/x"`),
		Entry("the strict setting", "strict", "an [inject] row is VARIABLE host header [prefix=WORD] [base-url=VARIABLE]"),
		Entry("a setting-shaped line", "strict = on", `invalid host "="`),
		Entry("a repeated option", "K api.k.example authorization prefix=A prefix=B", "option prefix= is given twice"),
	)

	It("refuses a variable injected twice in one file, naming the first line", func() {
		_, err := policy.ParseFile("u.conf", []byte("[inject]\nK a.k.example x-api-key\n[inject]\nK b.k.example x-api-key\n"))
		Expect(err).To(MatchError("u.conf:4: K is already injected on line 2"))
	})

	It("names [inject] among the sections when one is unknown", func() {
		_, err := policy.ParseFile("u.conf", []byte("[injects]\n"))
		Expect(err).To(MatchError(`u.conf:1: unknown section "[injects]" (use [allow], [group NAME] or [inject])`))
	})
})

var _ = Describe("Providers", func() {
	find := func(table []inject.Provider, env string) inject.Provider {
		for _, p := range table {
			if p.Env == env {
				return p
			}
		}
		Fail("no row for " + env)
		return inject.Provider{}
	}

	It("is inject.Providers when no file has an [inject] row", func() {
		Expect(policy.Providers(policy.Conf{}, policy.Conf{})).To(Equal(inject.Providers))
	})

	It("does not change inject.Providers itself", func() {
		before := append([]inject.Provider(nil), inject.Providers...)
		_, err := policy.Providers(conf("sys", "[inject]\nOPENAI_API_KEY gw.corp.example authorization\n"), policy.Conf{})
		Expect(err).NotTo(HaveOccurred())
		Expect(inject.Providers).To(Equal(before))
	})

	It("appends new rows, system first, then user", func() {
		table, err := policy.Providers(
			conf("sys", "[inject]\nA_KEY a.example x-api-key\n"),
			conf("user", "[inject]\nB_KEY b.example authorization prefix=Bearer base-url=B_URL\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(table).To(HaveLen(len(inject.Providers) + 2))
		Expect(table[len(table)-2:]).To(Equal([]inject.Provider{
			{Env: "A_KEY", Host: "a.example", Header: "x-api-key"},
			{Env: "B_KEY", Host: "b.example", Header: "authorization", Prefix: "Bearer ", BaseURLEnv: "B_URL"},
		}))
	})

	It("lets the system file replace a built-in row in its place, and the user file replace the system's", func() {
		table, err := policy.Providers(
			conf("sys", "[inject]\nOPENAI_API_KEY sys.example authorization\nA_KEY a.example x-api-key\n"),
			conf("user", "[inject]\nA_KEY user.example x-api-key\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(table).To(HaveLen(len(inject.Providers) + 1))
		Expect(table[1]).To(Equal(inject.Provider{Env: "OPENAI_API_KEY", Host: "sys.example", Header: "authorization"}))
		Expect(find(table, "A_KEY").Host).To(Equal("user.example"))
	})

	It("drops HeadroomLoopback from a row that replaces the built-in Anthropic row", func() {
		Expect(find(inject.Providers, "ANTHROPIC_API_KEY").HeadroomLoopback).To(BeTrue())
		table, err := policy.Providers(policy.Conf{}, conf("user", "[inject]\nANTHROPIC_API_KEY gw.corp.example x-api-key base-url=ANTHROPIC_BASE_URL\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(find(table, "ANTHROPIC_API_KEY")).To(Equal(inject.Provider{Env: "ANTHROPIC_API_KEY", Host: "gw.corp.example", Header: "x-api-key", BaseURLEnv: "ANTHROPIC_BASE_URL"}))
	})

	DescribeTable("refuses two rows for one host, at the file row's line, naming the other's origin",
		func(sys, user, want string) {
			_, err := policy.Providers(conf("sys", sys), conf("user", user))
			Expect(err).To(MatchError(want))
		},
		Entry("a file row and a built-in row", "", "[inject]\nMY_KEY api.openai.com authorization\n",
			"user:2: MY_KEY injects a key for api.openai.com, as OPENAI_API_KEY (built-in) does; the proxy carries one key per host"),
		Entry("a system row and a user row", "[inject]\nA_KEY x.example x-api-key\n", "[inject]\nB_KEY x.example x-api-key\n",
			"user:2: B_KEY injects a key for x.example, as A_KEY (sys:2) does; the proxy carries one key per host"),
		Entry("a row replacing a built-in one with a later built-in row's host", "", "[inject]\nANTHROPIC_API_KEY api.openai.com x-api-key\n",
			"user:2: ANTHROPIC_API_KEY injects a key for api.openai.com, as OPENAI_API_KEY (built-in) does; the proxy carries one key per host"),
	)
})

var _ = Describe("inject.Decide with a file row", func() {
	It("injects the row's key with its prefix", func() {
		table, err := policy.Providers(policy.Conf{}, conf("user", "[inject]\nNVIDIA_API_KEY integrate.api.nvidia.com authorization prefix=Bearer base-url=NVIDIA_BASE_URL\n"))
		Expect(err).NotTo(HaveOccurred())
		p := inject.Decide(map[string]string{"NVIDIA_API_KEY": "nvapi-x", "NVIDIA_BASE_URL": "https://integrate.api.nvidia.com/v1"}, table)
		Expect(p.Inject).To(Equal([]inject.Credential{{Env: "NVIDIA_API_KEY", Host: "integrate.api.nvidia.com", Header: "authorization", Value: "Bearer nvapi-x"}}))
		Expect(p.PassThrough).To(BeEmpty())
	})

	It("passes the key through when the row's base-url variable points elsewhere", func() {
		table, err := policy.Providers(policy.Conf{}, conf("user", "[inject]\nNVIDIA_API_KEY integrate.api.nvidia.com authorization prefix=Bearer base-url=NVIDIA_BASE_URL\n"))
		Expect(err).NotTo(HaveOccurred())
		p := inject.Decide(map[string]string{"NVIDIA_API_KEY": "nvapi-x", "NVIDIA_BASE_URL": "https://gw.corp.example"}, table)
		Expect(p.Inject).To(BeEmpty())
		Expect(p.PassThrough).To(Equal([]inject.PassThrough{{Env: "NVIDIA_API_KEY", Reason: "NVIDIA_BASE_URL is not https://integrate.api.nvidia.com"}}))
	})

	It("no longer accepts a loopback base URL under RIOTBOX_HEADROOM=1 once a row replaces ANTHROPIC_API_KEY", func() {
		vars := map[string]string{"ANTHROPIC_API_KEY": "sk-a", "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787", "RIOTBOX_HEADROOM": "1"}
		Expect(inject.Decide(vars, inject.Providers).Inject).To(HaveLen(1))
		table, err := policy.Providers(policy.Conf{}, conf("user", "[inject]\nANTHROPIC_API_KEY gw.corp.example x-api-key base-url=ANTHROPIC_BASE_URL\n"))
		Expect(err).NotTo(HaveOccurred())
		p := inject.Decide(vars, table)
		Expect(p.Inject).To(BeEmpty())
		Expect(p.PassThrough).To(Equal([]inject.PassThrough{{Env: "ANTHROPIC_API_KEY", Reason: "ANTHROPIC_BASE_URL is not https://gw.corp.example"}}))
	})
})

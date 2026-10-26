package envoyconfig_test

import (
	"encoding/json"
	"slices"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/envoyconfig"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

var _ = Describe("credential interception", func() {
	anthropic := envoyconfig.Intercept{Host: "api.anthropic.com", Header: "x-api-key"}
	openai := envoyconfig.Intercept{Host: "api.openai.com", Header: "authorization"}
	both := []envoyconfig.Intercept{anthropic, openai}
	allowed := append(slices.Clone(sample), policy.Entry{Host: "api.anthropic.com", Port: 443})

	vhosts := func(rds []byte) []any {
		return dig(decode(rds), "resources", 0, "virtual_hosts").([]any)
	}
	vhostNames := func(rds []byte) []string {
		var names []string
		for _, v := range vhosts(rds) {
			names = append(names, v.(map[string]any)["name"].(string))
		}
		return names
	}
	vhost := func(rds []byte, name string) any {
		for _, v := range vhosts(rds) {
			if v.(map[string]any)["name"] == name {
				return v
			}
		}
		Fail("no virtual host " + name)
		return nil
	}

	It("routes an allowed credential host's CONNECT to its internal listener, in a virtual host of its own", func() {
		rds := envoyconfig.RenderRDS(allowed, both)
		Expect(vhostNames(rds)).To(Equal([]string{"allowed", "intercept-api.anthropic.com", "deny"}))
		v := vhost(rds, "intercept-api.anthropic.com")
		Expect(dig(v, "domains")).To(Equal([]any{"api.anthropic.com:443"}))
		Expect(dig(v, "routes", 0, "match", "connect_matcher")).To(Equal(map[string]any{}))
		Expect(dig(v, "routes", 0, "route", "cluster")).To(Equal("intercept-api.anthropic.com"))
		Expect(dig(v, "routes", 0, "route", "timeout")).To(Equal("0s"))
		Expect(dig(v, "routes", 0, "route", "upgrade_configs", 0, "upgrade_type")).To(Equal("CONNECT"))
		Expect(dig(v, "routes", 0, "route", "upgrade_configs", 0, "connect_config")).To(Equal(map[string]any{}))
		Expect(dig(v, "routes", 1, "match", "prefix")).To(Equal("/"))
		Expect(dig(v, "routes", 1, "direct_response", "status")).To(BeEquivalentTo(403))
		Expect(dig(vhost(rds, "allowed"), "domains")).To(Equal([]any{"*.example.org:443", "api.example.com:443", "git.example.net:2222"}))
	})

	It("intercepts a credential host a wildcard allows; Envoy prefers the exact domain", func() {
		rds := envoyconfig.RenderRDS([]policy.Entry{{Host: "*.anthropic.com", Port: 443}}, both)
		Expect(vhostNames(rds)).To(Equal([]string{"allowed", "intercept-api.anthropic.com", "deny"}))
		Expect(dig(vhost(rds, "allowed"), "domains")).To(Equal([]any{"*.anthropic.com:443"}))
	})

	It("denies a credential host the allowlist does not allow, before any interception", func() {
		Expect(vhostNames(envoyconfig.RenderRDS([]policy.Entry{{Host: "api.anthropic.com", Port: 8443}}, both))).
			To(Equal([]string{"allowed", "deny"}))
		Expect(vhostNames(envoyconfig.RenderRDS(nil, both))).To(Equal([]string{"deny"}))
	})

	It("adds an internal listener per credential host that terminates TLS only for that host's name", func() {
		lds := decode(envoyconfig.Render("s1", sample, both).LDS)
		Expect(dig(lds, "resources")).To(HaveLen(3))
		l := dig(lds, "resources", 1)
		Expect(dig(l, "@type")).To(Equal("type.googleapis.com/envoy.config.listener.v3.Listener"))
		Expect(dig(l, "name")).To(Equal("intercept-api.anthropic.com"))
		Expect(dig(l, "internal_listener")).To(Equal(map[string]any{}))
		Expect(l).NotTo(HaveKey("address"))
		Expect(dig(l, "listener_filters", 0, "name")).To(Equal("envoy.filters.listener.tls_inspector"))
		Expect(dig(l, "filter_chains")).To(HaveLen(1))
		chain := dig(l, "filter_chains", 0)
		Expect(dig(chain, "filter_chain_match", "server_names")).To(Equal([]any{"api.anthropic.com"}))
		tls := dig(chain, "transport_socket", "typed_config")
		Expect(dig(tls, "@type")).To(Equal("type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext"))
		Expect(dig(tls, "common_tls_context", "alpn_protocols")).To(Equal([]any{"h2", "http/1.1"}))
		Expect(dig(tls, "common_tls_context", "tls_certificates", 0, "certificate_chain", "filename")).
			To(Equal("/etc/riotbox-egress-secrets/api.anthropic.com.crt"))
		Expect(dig(tls, "common_tls_context", "tls_certificates", 0, "private_key", "filename")).
			To(Equal("/etc/riotbox-egress-secrets/api.anthropic.com.key"))
		Expect(dig(lds, "resources", 2, "name")).To(Equal("intercept-api.openai.com"))
	})

	It("overwrites the credential header from the host's SDS file, then forwards with no route timeout", func() {
		hcm := dig(decode(envoyconfig.Render("s1", sample, both).LDS), "resources", 2, "filter_chains", 0, "filters", 0, "typed_config")
		Expect(dig(hcm, "codec_type")).To(Equal("AUTO"))
		Expect(dig(hcm, "stream_idle_timeout")).To(Equal("3600s"))
		Expect(dig(hcm, "http_filters")).To(HaveLen(2))
		inj := dig(hcm, "http_filters", 0)
		Expect(dig(inj, "name")).To(Equal("envoy.filters.http.credential_injector"))
		Expect(dig(inj, "typed_config", "@type")).To(Equal("type.googleapis.com/envoy.extensions.filters.http.credential_injector.v3.CredentialInjector"))
		Expect(dig(inj, "typed_config", "overwrite")).To(BeTrue())
		Expect(dig(inj, "typed_config", "credential", "name")).To(Equal("envoy.http.injected_credentials.generic"))
		gen := dig(inj, "typed_config", "credential", "typed_config")
		Expect(dig(gen, "@type")).To(Equal("type.googleapis.com/envoy.extensions.http.injected_credentials.generic.v3.Generic"))
		Expect(dig(gen, "header")).To(Equal("authorization"))
		Expect(dig(gen, "credential", "name")).To(Equal("intercept-api.openai.com"))
		Expect(dig(gen, "credential", "sds_config", "path_config_source", "path")).
			To(Equal("/etc/riotbox-egress-secrets/api.openai.com.credential.json"))
		Expect(dig(hcm, "http_filters", 1, "name")).To(Equal("envoy.filters.http.router"))
		route := dig(hcm, "route_config", "virtual_hosts", 0, "routes", 0)
		Expect(dig(route, "match", "prefix")).To(Equal("/"))
		Expect(dig(route, "route", "cluster")).To(Equal("upstream-api.openai.com"))
		Expect(dig(route, "route", "timeout")).To(Equal("0s"))
		Expect(dig(route, "route", "host_rewrite_literal")).To(Equal("api.openai.com"))
	})

	It("records no request header in any access log", func() {
		lds := decode(envoyconfig.Render("s1", sample, both).LDS)
		Expect(dig(lds, "resources", 0, "filter_chains", 0, "filters", 0, "typed_config", "access_log", 0, "typed_config", "log_format", "json_format")).
			To(Equal(map[string]any{
				"time": "%START_TIME%", "method": "%REQ(:METHOD)%", "authority": "%REQ(:AUTHORITY)%",
				"status": "%RESPONSE_CODE%", "flags": "%RESPONSE_FLAGS%",
			}))
		for i := 1; i <= 2; i++ {
			Expect(dig(lds, "resources", i, "filter_chains", 0, "filters", 0, "typed_config")).NotTo(HaveKey("access_log"))
		}
	})

	It("forwards each host to itself over TLS verified against the system roots, with SNI and SAN of that host", func() {
		cds := decode(envoyconfig.Render("s1", sample, both).CDS)
		Expect(dig(cds, "resources")).To(HaveLen(5))
		in := dig(cds, "resources", 1)
		Expect(dig(in, "name")).To(Equal("intercept-api.anthropic.com"))
		Expect(dig(in, "load_assignment", "endpoints", 0, "lb_endpoints", 0, "endpoint", "address", "envoy_internal_address", "server_listener_name")).
			To(Equal("intercept-api.anthropic.com"))
		up := dig(cds, "resources", 2)
		Expect(dig(up, "name")).To(Equal("upstream-api.anthropic.com"))
		Expect(dig(up, "type")).To(Equal("LOGICAL_DNS"))
		Expect(dig(up, "dns_lookup_family")).To(Equal("V4_ONLY"))
		addr := dig(up, "load_assignment", "endpoints", 0, "lb_endpoints", 0, "endpoint", "address", "socket_address")
		Expect(dig(addr, "address")).To(Equal("api.anthropic.com"))
		Expect(dig(addr, "port_value")).To(BeEquivalentTo(443))
		tls := dig(up, "transport_socket", "typed_config")
		Expect(dig(tls, "@type")).To(Equal("type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext"))
		Expect(dig(tls, "sni")).To(Equal("api.anthropic.com"))
		Expect(dig(tls, "common_tls_context", "validation_context", "trusted_ca", "filename")).To(Equal("/etc/ssl/certs/ca-certificates.crt"))
		Expect(dig(tls, "common_tls_context", "validation_context", "match_typed_subject_alt_names", 0, "san_type")).To(Equal("DNS"))
		Expect(dig(tls, "common_tls_context", "validation_context", "match_typed_subject_alt_names", 0, "matcher", "exact")).To(Equal("api.anthropic.com"))
		Expect(dig(up, "typed_extension_protocol_options", "envoy.extensions.upstreams.http.v3.HttpProtocolOptions", "auto_config")).
			To(HaveKey("http2_protocol_options"))
	})

	It("loads the internal listener extension only when it intercepts, and still has no admin interface", func() {
		b := decode(envoyconfig.Render("s1", sample, both).Bootstrap)
		Expect(dig(b, "bootstrap_extensions", 0, "name")).To(Equal("envoy.bootstrap.internal_listener"))
		Expect(dig(b, "bootstrap_extensions", 0, "typed_config", "@type")).
			To(Equal("type.googleapis.com/envoy.extensions.bootstrap.internal_listener.v3.InternalListener"))
		Expect(b).NotTo(HaveKey("admin"))
		Expect(decode(envoyconfig.Render("s1", sample, nil).Bootstrap)).NotTo(HaveKey("bootstrap_extensions"))
	})

	It("renders what it rendered before interception existed when nothing is intercepted", func() {
		f := envoyconfig.Render("s1", sample, nil)
		Expect(dig(decode(f.LDS), "resources")).To(HaveLen(1))
		Expect(dig(decode(f.CDS), "resources")).To(HaveLen(1))
		for _, b := range [][]byte{f.Bootstrap, f.CDS, f.LDS, f.RDS} {
			Expect(string(b)).NotTo(ContainSubstring("intercept"))
		}
	})

	It("keeps the listeners byte-identical across allowlists, so a reload never drains a tunnel", func() {
		Expect(envoyconfig.Render("s1", sample, both).LDS).To(Equal(envoyconfig.Render("s1", nil, both).LDS))
	})

	It("renders the same bytes whatever order the intercepts come in", func() {
		reversed := []envoyconfig.Intercept{openai, anthropic}
		Expect(envoyconfig.Render("s1", allowed, reversed)).To(Equal(envoyconfig.Render("s1", allowed, both)))
		Expect(envoyconfig.RenderStatic("s1", allowed, reversed)).To(Equal(envoyconfig.RenderStatic("s1", allowed, both)))
		Expect(reversed[0]).To(Equal(openai), "the caller's slice is left as it was")
	})

	It("puts no credential in the config files: they name the SDS file instead", func() {
		f := envoyconfig.Render("s1", sample, both)
		for _, b := range [][]byte{f.Bootstrap, f.CDS, f.LDS, f.RDS} {
			Expect(string(b)).NotTo(ContainSubstring("generic_secret"))
		}
	})

	It("holds a key only in the credential rendering, never in any config the proxy loads", func() {
		const key = "sk-FAKE-riotbox-test-key-0123456789"
		cred := envoyconfig.RenderCredential(openai.Host, "Bearer "+key)
		Expect(string(cred)).To(ContainSubstring(key))
		f := envoyconfig.Render("s1", allowed, both)
		for _, b := range [][]byte{f.Bootstrap, f.CDS, f.LDS, f.RDS, envoyconfig.RenderStatic("s1", allowed, both)} {
			Expect(string(b)).NotTo(ContainSubstring(key))
		}
	})

	It("renders a credential as an SDS generic secret named after its host, escaping any value", func() {
		value := `Bearer sk-"},{"evil`
		out := envoyconfig.RenderCredential("api.openai.com", value)
		Expect(json.Valid(out)).To(BeTrue())
		s := dig(decode(out), "resources", 0)
		Expect(dig(s, "@type")).To(Equal("type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"))
		Expect(dig(s, "name")).To(Equal("intercept-api.openai.com"))
		Expect(dig(s, "generic_secret", "secret", "inline_string")).To(Equal(value))
	})

	It("inlines the interception in the static rendering, without resource @types", func() {
		s := decode(envoyconfig.RenderStatic("s1", allowed, both))
		Expect(dig(s, "static_resources", "listeners")).To(HaveLen(3))
		Expect(dig(s, "static_resources", "clusters")).To(HaveLen(5))
		Expect(dig(s, "static_resources", "listeners", 1)).NotTo(HaveKey("@type"))
		Expect(dig(s, "bootstrap_extensions", 0, "name")).To(Equal("envoy.bootstrap.internal_listener"))
		rc := dig(s, "static_resources", "listeners", 0, "filter_chains", 0, "filters", 0, "typed_config", "route_config", "virtual_hosts", 1, "name")
		Expect(rc).To(Equal("intercept-api.anthropic.com"))
	})
})

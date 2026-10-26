package envoyconfig_test

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/envoyconfig"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

func decode(b []byte) map[string]any {
	var m map[string]any
	ExpectWithOffset(1, json.Unmarshal(b, &m)).To(Succeed())
	return m
}

// dig walks decoded JSON: a string steps into an object, an int into an array.
func dig(v any, path ...any) any {
	for _, p := range path {
		switch k := p.(type) {
		case string:
			m, ok := v.(map[string]any)
			ExpectWithOffset(1, ok).To(BeTrue(), "not an object at %q", k)
			v = m[k]
		case int:
			a, ok := v.([]any)
			ExpectWithOffset(1, ok).To(BeTrue(), "not an array at %d", k)
			ExpectWithOffset(1, len(a)).To(BeNumerically(">", k))
			v = a[k]
		}
	}
	return v
}

var sample = []policy.Entry{
	{Host: "*.example.org", Port: 443},
	{Host: "api.example.com", Port: 443},
	{Host: "git.example.net", Port: 2222},
}

var _ = Describe("RenderRDS", func() {
	It("lists the allowlist as the allowed virtual host's domains, as host:port", func() {
		rds := decode(envoyconfig.RenderRDS(sample, nil))
		Expect(dig(rds, "resources", 0, "@type")).To(Equal("type.googleapis.com/envoy.config.route.v3.RouteConfiguration"))
		Expect(dig(rds, "resources", 0, "name")).To(Equal("egress"))
		Expect(dig(rds, "resources", 0, "virtual_hosts", 0, "name")).To(Equal("allowed"))
		Expect(dig(rds, "resources", 0, "virtual_hosts", 0, "domains")).To(Equal([]any{"*.example.org:443", "api.example.com:443", "git.example.net:2222"}))
	})

	It("tunnels CONNECT to the forward-proxy cluster and answers anything else on an allowed host 403", func() {
		routes := dig(decode(envoyconfig.RenderRDS(sample, nil)), "resources", 0, "virtual_hosts", 0, "routes")
		Expect(dig(routes, 0, "match", "connect_matcher")).To(Equal(map[string]any{}))
		Expect(dig(routes, 0, "route", "cluster")).To(Equal("egress"))
		Expect(dig(routes, 0, "route", "upgrade_configs", 0, "upgrade_type")).To(Equal("CONNECT"))
		Expect(dig(routes, 0, "route", "upgrade_configs", 0, "connect_config")).To(Equal(map[string]any{}))
		Expect(dig(routes, 1, "match", "prefix")).To(Equal("/"))
		Expect(dig(routes, 1, "direct_response", "status")).To(BeEquivalentTo(403))
	})

	It("answers every other host 403, CONNECT or not", func() {
		deny := dig(decode(envoyconfig.RenderRDS(sample, nil)), "resources", 0, "virtual_hosts", 1)
		Expect(dig(deny, "name")).To(Equal("deny"))
		Expect(dig(deny, "domains")).To(Equal([]any{"*"}))
		Expect(dig(deny, "routes", 0, "match", "connect_matcher")).To(Equal(map[string]any{}))
		Expect(dig(deny, "routes", 0, "direct_response", "status")).To(BeEquivalentTo(403))
		Expect(dig(deny, "routes", 1, "direct_response", "status")).To(BeEquivalentTo(403))
	})

	It("emits only the deny host for an empty allowlist", func() {
		vhosts := dig(decode(envoyconfig.RenderRDS(nil, nil)), "resources", 0, "virtual_hosts")
		Expect(vhosts).To(HaveLen(1))
		Expect(dig(vhosts, 0, "name")).To(Equal("deny"))
	})

	It("escapes a hostile host that never went through policy.Parse", func() {
		hostile := `x"},{"name":"evil`
		out := envoyconfig.RenderRDS([]policy.Entry{{Host: hostile, Port: 443}}, nil)
		Expect(json.Valid(out)).To(BeTrue())
		Expect(dig(decode(out), "resources", 0, "virtual_hosts", 0, "domains")).To(Equal([]any{hostile + ":443"}))
	})
})

var _ = Describe("Render", func() {
	It("keeps the listener byte-identical whatever the allowlist, so a reload never drains it", func() {
		Expect(envoyconfig.Render("s1", sample, nil).LDS).To(Equal(envoyconfig.Render("s1", nil, nil).LDS))
	})

	It("puts RenderRDS's output in the RDS file", func() {
		Expect(envoyconfig.Render("s1", sample, nil).RDS).To(Equal(envoyconfig.RenderRDS(sample, nil)))
	})

	It("listens on 3128 and loads the routes from rds.json in the watched config dir", func() {
		l := dig(decode(envoyconfig.Render("s1", sample, nil).LDS), "resources", 0)
		Expect(dig(l, "@type")).To(Equal("type.googleapis.com/envoy.config.listener.v3.Listener"))
		Expect(dig(l, "address", "socket_address", "address")).To(Equal("0.0.0.0"))
		Expect(dig(l, "address", "socket_address", "port_value")).To(BeEquivalentTo(3128))
		hcm := dig(l, "filter_chains", 0, "filters", 0, "typed_config")
		Expect(dig(hcm, "upgrade_configs", 0, "upgrade_type")).To(Equal("CONNECT"))
		Expect(dig(hcm, "rds", "route_config_name")).To(Equal("egress"))
		Expect(dig(hcm, "rds", "config_source", "path_config_source", "path")).To(Equal("/etc/riotbox-egress/rds.json"))
		Expect(dig(hcm, "rds", "config_source", "path_config_source", "watched_directory", "path")).To(Equal("/etc/riotbox-egress"))
		Expect(dig(hcm, "http_filters", 0, "name")).To(Equal("envoy.filters.http.dynamic_forward_proxy"))
		Expect(dig(hcm, "http_filters", 1, "name")).To(Equal("envoy.filters.http.router"))
	})

	It("logs every request as JSON to the access log, with the non-deprecated log_format", func() {
		log := dig(decode(envoyconfig.Render("s1", sample, nil).LDS), "resources", 0, "filter_chains", 0, "filters", 0, "typed_config", "access_log", 0, "typed_config")
		Expect(dig(log, "path")).To(Equal("/var/log/riotbox-egress/access.log"))
		Expect(dig(log, "log_format", "json_format", "status")).To(Equal("%RESPONSE_CODE%"))
		Expect(dig(log, "log_format", "json_format", "authority")).To(Equal("%REQ(:AUTHORITY)%"))
		Expect(log).NotTo(HaveKey("json_format"))
	})

	It("defines the egress cluster as a dynamic forward proxy", func() {
		c := dig(decode(envoyconfig.Render("s1", sample, nil).CDS), "resources", 0)
		Expect(dig(c, "@type")).To(Equal("type.googleapis.com/envoy.config.cluster.v3.Cluster"))
		Expect(dig(c, "name")).To(Equal("egress"))
		Expect(dig(c, "lb_policy")).To(Equal("CLUSTER_PROVIDED"))
		Expect(dig(c, "cluster_type", "name")).To(Equal("envoy.clusters.dynamic_forward_proxy"))
	})

	It("bootstraps from the LDS and CDS files with no admin interface", func() {
		b := decode(envoyconfig.Render("s1", sample, nil).Bootstrap)
		Expect(b).NotTo(HaveKey("admin"))
		Expect(dig(b, "dynamic_resources", "lds_config", "path_config_source", "path")).To(Equal("/etc/riotbox-egress/lds.json"))
		Expect(dig(b, "dynamic_resources", "cds_config", "path_config_source", "path")).To(Equal("/etc/riotbox-egress/cds.json"))
	})
})

var _ = Describe("tunnel timeouts", func() {
	It("reaps a tunnel only after an hour idle, not Envoy's 300s default", func() {
		hcm := dig(decode(envoyconfig.Render("s1", sample, nil).LDS), "resources", 0, "filter_chains", 0, "filters", 0, "typed_config")
		Expect(dig(hcm, "stream_idle_timeout")).To(Equal("3600s"))
	})

	It("disables the route timeout on CONNECT so a half-closed tunnel is not cut at 15s", func() {
		routes := dig(decode(envoyconfig.RenderRDS(sample, nil)), "resources", 0, "virtual_hosts", 0, "routes")
		Expect(dig(routes, 0, "route", "timeout")).To(Equal("0s"))
	})
})

var _ = Describe("the listener's codec", func() {
	It("speaks HTTP/1 only, so an HTTP/2 CONNECT cannot carry an authority HTTP/1 would refuse into the denial text", func() {
		hcm := dig(decode(envoyconfig.Render("s1", sample, nil).LDS), "resources", 0, "filter_chains", 0, "filters", 0, "typed_config")
		Expect(dig(hcm, "codec_type")).To(Equal("HTTP1"))
	})
})

var _ = Describe("host:port matching", func() {
	It("never lets Envoy strip the port before route matching, which would widen every entry to all ports", func() {
		hcm := dig(decode(envoyconfig.Render("s1", sample, nil).LDS), "resources", 0, "filter_chains", 0, "filters", 0, "typed_config")
		Expect(hcm).NotTo(HaveKey("strip_any_host_port"))
		Expect(hcm).NotTo(HaveKey("strip_matching_host_port"))
		Expect(hcm).NotTo(HaveKey("strip_port_mode"))
		Expect(dig(decode(envoyconfig.RenderRDS(sample, nil)), "resources", 0)).NotTo(HaveKey("ignore_port_in_host_matching"))
	})
})

var _ = Describe("RenderStatic", func() {
	It("inlines the same listener, cluster and routes, without resource @types", func() {
		s := decode(envoyconfig.RenderStatic("s1", sample, nil))
		Expect(s).NotTo(HaveKey("dynamic_resources"))
		Expect(s).NotTo(HaveKey("admin"))
		files := envoyconfig.Render("s1", sample, nil)

		staticL := dig(s, "static_resources", "listeners", 0).(map[string]any)
		Expect(staticL).NotTo(HaveKey("@type"))
		ldsL := dig(decode(files.LDS), "resources", 0).(map[string]any)
		delete(ldsL, "@type")
		staticHCM := dig(staticL, "filter_chains", 0, "filters", 0, "typed_config").(map[string]any)
		ldsHCM := dig(ldsL, "filter_chains", 0, "filters", 0, "typed_config").(map[string]any)
		want := dig(decode(files.RDS), "resources", 0).(map[string]any)
		Expect(dig(staticHCM, "route_config", "virtual_hosts")).To(Equal(want["virtual_hosts"]))
		delete(staticHCM, "route_config")
		delete(ldsHCM, "rds")
		Expect(staticL).To(Equal(ldsL))

		staticC := dig(s, "static_resources", "clusters", 0).(map[string]any)
		Expect(staticC).NotTo(HaveKey("@type"))
		ldsC := dig(decode(files.CDS), "resources", 0).(map[string]any)
		delete(ldsC, "@type")
		Expect(staticC).To(Equal(ldsC))
	})
})

var _ = Describe("the pinned Envoy image", Label("e2e"), func() {
	var image string

	BeforeEach(func() {
		if os.Getenv("RIOTBOX_EGRESS_E2E") != "1" {
			Skip("set RIOTBOX_EGRESS_E2E=1 (task test:egress-e2e) to run against real podman")
		}
		image = os.Getenv("RIOTBOX_EGRESS_IMAGE")
		Expect(image).NotTo(BeEmpty(), "task test:egress-e2e sets RIOTBOX_EGRESS_IMAGE from libexec/egress-lib.sh")
	})

	// validate runs Envoy's validate mode on static, with secrets (a dir,
	// or "" for none) mounted where the proxy reads its secrets.
	validate := func(static []byte, secrets string) {
		dir := GinkgoT().TempDir()
		ExpectWithOffset(1, os.Mkdir(filepath.Join(dir, "log"), 0o700)).To(Succeed())
		ExpectWithOffset(1, os.WriteFile(filepath.Join(dir, "static.json"), static, 0o600)).To(Succeed())
		args := []string{"run", "--rm",
			"--userns=keep-id", "--user", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()),
			"-v", dir + ":/cfg:ro,z", "-v", filepath.Join(dir, "log") + ":" + envoyconfig.LogDir + ":rw,z"}
		if secrets != "" {
			args = append(args, "-v", secrets+":"+envoyconfig.SecretsDir+":ro,z")
		}
		args = append(args, "--entrypoint", "/usr/local/bin/envoy", image, "--mode", "validate", "-c", "/cfg/static.json")
		out, err := exec.Command("podman", args...).CombinedOutput()
		ExpectWithOffset(1, err).NotTo(HaveOccurred(), string(out))
		ExpectWithOffset(1, string(out)).To(ContainSubstring("OK"))
	}

	It("accepts the static rendering in validate mode", func() {
		validate(envoyconfig.RenderStatic("s1", sample, nil), "")
	})

	It("accepts a rendering that intercepts a credential host, with its leaf, key and credential", func() {
		const host = "api.example.com"
		secrets := GinkgoT().TempDir()
		certs, err := inject.NewCerts("s1", []string{host}, time.Now())
		Expect(err).NotTo(HaveOccurred())
		for name, data := range map[string][]byte{
			envoyconfig.CertFile(host):       certs.Leaves[host].Cert,
			envoyconfig.KeyFile(host):        certs.Leaves[host].Key,
			envoyconfig.CredentialFile(host): envoyconfig.RenderCredential(host, "test-key"),
		} {
			Expect(os.WriteFile(filepath.Join(secrets, name), data, 0o600)).To(Succeed())
		}
		validate(envoyconfig.RenderStatic("s1", sample, []envoyconfig.Intercept{{Host: host, Header: "x-api-key"}}), secrets)
	})
})

var _ = Describe("denials", func() {
	hcm := func(session string) any {
		return dig(decode(envoyconfig.Render(session, sample, nil).LDS), "resources", 0, "filter_chains", 0, "filters", 0, "typed_config")
	}

	It("rewrites a refused CONNECT with a header naming the denied authority and an allowlist body", func() {
		m := dig(hcm("s1"), "local_reply_config", "mappers", 0)
		Expect(dig(m, "filter", "and_filter", "filters", 0, "status_code_filter", "comparison", "op")).To(Equal("EQ"))
		Expect(dig(m, "filter", "and_filter", "filters", 0, "status_code_filter", "comparison", "value", "default_value")).To(BeEquivalentTo(403))
		Expect(dig(m, "filter", "and_filter", "filters", 1, "header_filter", "header", "name")).To(Equal(":method"))
		Expect(dig(m, "filter", "and_filter", "filters", 1, "header_filter", "header", "string_match", "exact")).To(Equal("CONNECT"))
		Expect(dig(m, "headers_to_add", 0, "header", "key")).To(Equal(envoyconfig.DeniedHeader))
		Expect(envoyconfig.DeniedHeader).To(Equal("x-riotbox-egress"))
		Expect(dig(m, "headers_to_add", 0, "header", "value")).To(Equal("denied %REQ(:AUTHORITY)%"))
		Expect(dig(m, "headers_to_add", 0, "append_action")).To(Equal("OVERWRITE_IF_EXISTS_OR_ADD"))
		Expect(dig(m, "body_format_override", "content_type")).To(Equal("text/plain; charset=utf-8"))
		body := dig(m, "body_format_override", "text_format_source", "inline_string")
		Expect(body).To(HavePrefix("riotbox egress: %REQ(:AUTHORITY)% is not on this session's allowlist.\n"))
		Expect(body).To(ContainSubstring("not a network fault"))
		Expect(body).To(ContainSubstring("If the user agrees after checking the host, they run on the host:\n"))
		Expect(body).To(HaveSuffix("  riotbox egress allow --session s1 %REQ(:AUTHORITY)%\n"))
	})

	It("tells a refused plain-HTTP request that allowing a host cannot help", func() {
		m := dig(hcm("s1"), "local_reply_config", "mappers", 1)
		Expect(dig(m, "filter", "status_code_filter", "comparison", "op")).To(Equal("EQ"))
		Expect(dig(m, "filter", "status_code_filter", "comparison", "value", "default_value")).To(BeEquivalentTo(403))
		Expect(dig(m, "headers_to_add", 0, "header", "key")).To(Equal(envoyconfig.DeniedHeader))
		Expect(dig(m, "headers_to_add", 0, "header", "value")).To(Equal("denied %REQ(:AUTHORITY)%"))
		body := dig(m, "body_format_override", "text_format_source", "inline_string")
		Expect(body).To(ContainSubstring("plain HTTP is never proxied"))
		Expect(body).To(ContainSubstring("Use HTTPS"))
		Expect(body).NotTo(ContainSubstring("riotbox egress allow"))
	})

	It("keeps the status, and gives no runtime key a runtime layer could override", func() {
		for i := range 2 {
			m := dig(hcm("s1"), "local_reply_config", "mappers", i)
			Expect(m).NotTo(HaveKey("status_code"))
		}
		Expect(string(envoyconfig.Render("s1", sample, nil).LDS)).NotTo(ContainSubstring("runtime_key"))
	})

	It("names the session it renders for", func() {
		body := dig(hcm("riotbox-proj-1a2b3c4d"), "local_reply_config", "mappers", 0, "body_format_override", "text_format_source", "inline_string")
		Expect(body).To(ContainSubstring("--session riotbox-proj-1a2b3c4d "))
		Expect(body).NotTo(ContainSubstring("--session s1 "))
	})

	It("leaves the allowlist in rds.json, untouched by the denial text", func() {
		Expect(string(envoyconfig.RenderRDS(sample, nil))).NotTo(ContainSubstring("local_reply_config"))
	})
})

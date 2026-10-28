package pod_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/pod"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

var _ = Describe("credential injection, against real podman and Envoy", Label("e2e"), Ordered, func() {
	const (
		curlImage = "quay.io/centos/centos:stream10@sha256:6f8d618844ed5af4365bad24bea19fb0435fd5ec808201af9aeb19d7a28eb515"
		nodeImage = "docker.io/library/node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53"
		// A public echo: it answers with the request's headers as JSON.
		echoHost = "postman-echo.com"
		// trustCurl applies the container's real trust setup
		// (scripts/lib/egress-trust.sh, mounted at /t) and runs curl with
		// the script's arguments, so curl uses the combined bundle.
		trustCurl = `source /t/egress-trust.sh && egress_trust_apply && exec curl "$@"`
		// injected stands in for the injected value in every output a spec
		// sees, so no failure message can carry it.
		injected = "<injected value>"
	)
	// Positive fetches retry: postman-echo.com is a public service.
	retry := []string{"--retry", "3", "--retry-all-errors", "--retry-delay", "2"}
	var (
		dir                  state.Dir
		systemConf, userConf string
		trustDir             string
		flags                []string
		key                  string
	)

	BeforeAll(func() {
		if os.Getenv("RIOTBOX_EGRESS_E2E") != "1" {
			Skip("set RIOTBOX_EGRESS_E2E=1 (task test:egress-e2e) to run against real podman")
		}
		image := os.Getenv("RIOTBOX_EGRESS_IMAGE")
		Expect(image).NotTo(BeEmpty(), "task test:egress-e2e sets RIOTBOX_EGRESS_IMAGE from libexec/egress-lib.sh")
		trust, err := os.ReadFile(filepath.Join("..", "..", "..", "scripts", "lib", "egress-trust.sh"))
		Expect(err).NotTo(HaveOccurred())
		trustDir = GinkgoT().TempDir()
		Expect(os.WriteFile(filepath.Join(trustDir, "egress-trust.sh"), trust, 0o644)).To(Succeed())
		root := filepath.Join(GinkgoT().TempDir(), "riotbox-egress")
		systemConf, userConf = filepath.Join(root, "none-sys"), filepath.Join(root, "none-user")
		dir, err = state.Open(root, fmt.Sprintf("rbx-e2e-inject-%d", os.Getpid()))
		Expect(err).NotTo(HaveOccurred())
		dir = dir.WithRuntime(e2eRuntimeBase())
		key = fmt.Sprintf("riotbox-e2e-injected-%d", time.Now().UnixNano())
		m := pod.NewManager("podman", GinkgoWriter)
		DeferCleanup(func() {
			Expect(m.Down(dir, false)).To(Succeed())
			Expect(dir.SecretsDir()).NotTo(BeAnExistingFile())
			Expect(filepath.Dir(dir.SecretsDir())).NotTo(BeAnExistingFile())
		})
		flags, err = m.Up(pod.UpRequest{
			Dir: dir, SessionKey: "e2e", OwnerPID: os.Getpid(), Image: image,
			AgentHosts: []byte(echoHost + "\nexample.com\n"),
			SystemConf: systemConf, UserConf: userConf,
			// Test-only: no provider row names this host; the spec hands
			// Up the credential itself, so nothing user-facing can.
			Credentials: []inject.Credential{{Env: "RIOTBOX_E2E_KEY", Host: echoHost, Header: "x-api-key", Value: key}},
		})
		Expect(err).NotTo(HaveOccurred())
		Expect(flags).To(ContainElement("RIOTBOX_E2E_KEY=" + inject.Placeholder))
		Expect(dir.SecretsDir()).To(BeADirectory())
	})

	// agent runs a throwaway agent container in the session, for at most
	// 90 s, and returns its stdout and stderr together with the injected
	// value replaced by injected. The value is fake, but Gomega prints what
	// it matched, and a failure message must never carry an injected key.
	agent := func(args ...string) (string, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, "podman", slices.Concat([]string{"run", "--rm"}, flags, args)...).CombinedOutput()
		return strings.ReplaceAll(string(out), key, injected), err
	}
	// trustedCurl runs curl in the agent image after the container's trust
	// setup, as an agent's own curl would run.
	trustedCurl := func(args ...string) (string, error) {
		return agent(slices.Concat([]string{"-v", trustDir + ":/t:ro,z", curlImage, "bash", "-c", trustCurl, "curl"}, args)...)
	}
	// echoed decodes the echo's answer: the headers the upstream received.
	echoed := func(out string) map[string]string {
		var body struct{ Headers map[string]string }
		ExpectWithOffset(1, json.Unmarshal([]byte(out), &body)).To(Succeed(), out)
		return body.Headers
	}
	// connectStatus is the CONNECT status an agent's curl gets for url.
	connectStatus := func(url string) string {
		// curl exits non-zero on a refused CONNECT; the status is the
		// result under test.
		out, _ := agent("-e", "CURL_CA_BUNDLE="+pod.AgentCACert, curlImage, "curl", "-s", "-o", "/dev/null",
			"-w", "%{http_connect}", "--max-time", "20", url)
		return out
	}

	It("puts the key on curl's request to the credential host, in place of the placeholder", func() {
		out, err := trustedCurl(slices.Concat([]string{"-sS", "--fail", "--max-time", "20"}, retry,
			[]string{"-H", "x-api-key: " + inject.Placeholder, "https://" + echoHost + "/headers"})...)
		Expect(err).NotTo(HaveOccurred(), out)
		Expect(echoed(out)).To(HaveKeyWithValue("x-api-key", injected))
		Expect(out).NotTo(ContainSubstring(inject.Placeholder))
	})

	It("sends the provider host upstream even when the client names another inside the tunnel", func() {
		out, err := trustedCurl(slices.Concat([]string{"-sS", "--fail", "--max-time", "20"}, retry,
			[]string{"-H", "Host: evil.example", "-H", "x-api-key: " + inject.Placeholder, "https://" + echoHost + "/headers"})...)
		Expect(err).NotTo(HaveOccurred(), out)
		headers := echoed(out)
		Expect(headers).To(HaveKeyWithValue("host", echoHost))
		Expect(headers).To(HaveKeyWithValue("x-api-key", injected))
		Expect(out).NotTo(ContainSubstring("evil.example"))
		Expect(out).NotTo(ContainSubstring(inject.Placeholder))
	})

	It("does the same for Node, which trusts the session CA through NODE_EXTRA_CA_CERTS alone", func() {
		script := `let last;
for (let i = 0; i < 3; i++) {
  try {
    const r = await fetch("https://` + echoHost + `/headers", { headers: { "x-api-key": "` + inject.Placeholder + `" }, signal: AbortSignal.timeout(20000) });
    console.log(r.status, await r.text());
    process.exit(0);
  } catch (e) { last = e; await new Promise((ok) => setTimeout(ok, 2000)); }
}
console.log("failed", last?.cause?.code ?? last?.message);
process.exit(1);`
		out, err := agent("-e", "NODE_USE_ENV_PROXY=1", nodeImage, "node", "--input-type=module", "-e", script)
		Expect(err).NotTo(HaveOccurred(), out)
		body, ok := strings.CutPrefix(strings.TrimSpace(out), "200 ")
		Expect(ok).To(BeTrue(), out)
		Expect(echoed(body)).To(HaveKeyWithValue("x-api-key", injected))
		Expect(out).NotTo(ContainSubstring(inject.Placeholder))
	})

	It("is not trusted for the credential host by a client without the session CA", func() {
		out, err := agent(curlImage, "curl", "-sS", "--max-time", "20", "https://"+echoHost+"/headers")
		Expect(err).To(HaveOccurred(), out)
		Expect(out).To(ContainSubstring("SSL certificate problem"))
		Expect(out).NotTo(ContainSubstring(injected))
	})

	It("leaves a host without a credential a plain tunnel, with the site's own certificate", func() {
		out, err := trustedCurl(slices.Concat([]string{"-sS", "-v", "-o", "/dev/null", "--fail", "--max-time", "20"}, retry,
			[]string{"https://example.com/"})...)
		Expect(err).NotTo(HaveOccurred(), out)
		Expect(out).To(ContainSubstring("issuer:"))
		Expect(out).NotTo(ContainSubstring("RiotBox egress"))
	})

	It("does not let the session CA vouch for the tunnelled host", func() {
		out, err := agent("-e", "CURL_CA_BUNDLE="+pod.AgentCACert, curlImage,
			"curl", "-sS", "-o", "/dev/null", "--max-time", "20", "https://example.com/")
		Expect(err).To(HaveOccurred(), out)
		Expect(out).To(ContainSubstring("SSL certificate problem"))
	})

	It("keeps the key out of the agent: not in its environment, not in its mounts", func() {
		out, err := agent(curlImage, "sh", "-c", "env; cat /run/riotbox-egress/ca.crt; ls /etc/riotbox-egress-secrets")
		Expect(err).To(HaveOccurred(), "the secrets dir must not exist in the agent")
		Expect(out).To(ContainSubstring("RIOTBOX_E2E_KEY=" + inject.Placeholder))
		Expect(out).To(ContainSubstring("BEGIN CERTIFICATE"))
		Expect(out).To(ContainSubstring("No such file or directory"))
		Expect(out).NotTo(ContainSubstring(injected))
		Expect(strings.Contains(strings.Join(flags, " "), key)).To(BeFalse(), "the injected value is in the agent's engine flags")
	})

	// Last: it takes the credential host off the allowlist.
	It("refuses the credential host's CONNECT once it is denied live", func() {
		it, err := policy.ParseItem("-" + echoHost)
		Expect(err).NotTo(HaveOccurred())
		Expect(dir.SetOverlay(it)).To(Succeed())
		_, err = dir.Reload(systemConf, userConf)
		Expect(err).NotTo(HaveOccurred())
		Eventually(func() string { return connectStatus("https://" + echoHost + "/headers") }).
			WithTimeout(30 * time.Second).WithPolling(time.Second).Should(Equal("403"))
		Expect(connectStatus("https://example.com/")).To(Equal("200"), "a host still allowed must stay reachable")
	})
})

// e2eRuntimeBase is the host's runtime base (state.RuntimeBase) or, when
// the host has none (a container without a login session), the base in a
// private dir this spec makes on /dev/shm and removes, checked by the same
// rules. With neither the spec fails, as any missing E2E prerequisite
// does: the keys must stay on tmpfs.
func e2eRuntimeBase() string {
	host := state.HostRuntime()
	if base, err := state.RuntimeBase(host); err == nil {
		return base
	}
	shm, err := os.MkdirTemp("/dev/shm", "riotbox-e2e-run-")
	if err != nil {
		Fail("no runtime dir and no /dev/shm to make one in: " + err.Error())
	}
	DeferCleanup(os.RemoveAll, shm)
	host.Getenv = func(k string) string {
		if k == "XDG_RUNTIME_DIR" {
			return shm
		}
		return os.Getenv(k)
	}
	base, err := state.RuntimeBase(host)
	if err != nil {
		Fail("no private tmpfs runtime dir for the injected key: " + err.Error())
	}
	return base
}

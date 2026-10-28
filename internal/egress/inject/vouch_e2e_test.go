package inject_test

import (
	"context"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/types"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
)

// The images whose TLS clients the session CA must work with, by digest.
const (
	vouchCurlImage = "quay.io/centos/centos:stream10@sha256:99b8fe27dd4958b5dc2630ce35f5f6a7ff7bf9b2b1a72078102fde50d3277550"
	vouchNodeImage = "docker.io/library/node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53"
)

// vouchNode serves /t/<host>.crt on a loopback port and fetches it as
// <host> (NODE_EXTRA_CA_CERTS=/t/ca.pem), printing "trusted" or
// "rejected <reason>".
const vouchNode = `const https = require("https"), fs = require("fs");
const host = process.argv[2];
const srv = https.createServer({ cert: fs.readFileSync("/t/" + host + ".crt"), key: fs.readFileSync("/t/" + host + ".key") }, (q, r) => r.end("ok"));
srv.listen(0, "127.0.0.1", () => {
  https.get({ host: "127.0.0.1", port: srv.address().port, servername: host, headers: { host } }, () => {
    console.log("trusted"); srv.close();
  }).on("error", (e) => { console.log("rejected " + e.message); srv.close(); });
});
`

// vouchCurl does the same with Python's TLS server and curl --cacert.
const vouchCurl = `host="$1"
python3 -c '
import http.server, ssl, sys
s = http.server.HTTPServer(("127.0.0.1", 8443), http.server.SimpleHTTPRequestHandler)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain("/t/" + sys.argv[1] + ".crt", "/t/" + sys.argv[1] + ".key")
s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()
' "${host}" &
server=$!
for _ in $(seq 100); do curl -sk -o /dev/null https://127.0.0.1:8443/ && break; sleep 0.1; done
if out="$(curl -sS -o /dev/null --cacert /t/ca.pem --resolve "${host}:8443:127.0.0.1" "https://${host}:8443/" 2>&1)"; then
  echo trusted
else
  echo "rejected ${out}"
fi
kill "${server}"
`

var _ = Describe("the session CA, in real TLS clients", Label("e2e"), func() {
	var dir string

	BeforeEach(func() {
		if os.Getenv("RIOTBOX_EGRESS_E2E") != "1" {
			Skip("set RIOTBOX_EGRESS_E2E=1 (task test:egress-e2e) to run against real podman")
		}
		now := time.Now()
		ca, key, err := inject.NewCA("e2e", []string{"api.anthropic.com"}, now)
		Expect(err).NotTo(HaveOccurred())
		dir = GinkgoT().TempDir()
		write := func(name string, data []byte) {
			ExpectWithOffset(1, os.WriteFile(filepath.Join(dir, name), data, 0o600)).To(Succeed())
		}
		write("ca.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ca.Raw}))
		// NewCerts never signs for a host off the list; NewLeaf does, so the
		// clients' name-constraint checks are what is under test.
		for _, host := range []string{"api.anthropic.com", "evil.example"} {
			leaf, err := inject.NewLeaf(ca, key, host, now)
			Expect(err).NotTo(HaveOccurred())
			write(host+".crt", leaf.Cert)
			write(host+".key", leaf.Key)
		}
		write("vouch.js", []byte(vouchNode))
		write("vouch.sh", []byte(vouchCurl))
	})

	rejected := And(HavePrefix("rejected"), ContainSubstring("permitted subtree violation"))

	DescribeTable("vouches only for the hosts it was made for",
		func(image string, env []string, command []string, host string, want types.GomegaMatcher) {
			args := append([]string{"run", "--rm", "--network", "none", "-v", dir + ":/t:ro,z"}, env...)
			args = append(append(args, image), command...)
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "podman", append(args, host)...)
			cmd.Stderr = GinkgoWriter
			out, err := cmd.Output()
			Expect(err).NotTo(HaveOccurred())
			Expect(string(out)).To(want)
		},
		Entry("Node, a host on the list", vouchNodeImage, []string{"-e", "NODE_EXTRA_CA_CERTS=/t/ca.pem"}, []string{"node", "/t/vouch.js"}, "api.anthropic.com", Equal("trusted\n")),
		Entry("Node, a host off the list", vouchNodeImage, []string{"-e", "NODE_EXTRA_CA_CERTS=/t/ca.pem"}, []string{"node", "/t/vouch.js"}, "evil.example", rejected),
		Entry("curl, a host on the list", vouchCurlImage, nil, []string{"bash", "/t/vouch.sh"}, "api.anthropic.com", Equal("trusted\n")),
		Entry("curl, a host off the list", vouchCurlImage, nil, []string{"bash", "/t/vouch.sh"}, "evil.example", rejected),
	)
})

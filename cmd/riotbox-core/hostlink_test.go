package main_test

import (
	"bufio"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"
	"github.com/onsi/gomega/gexec"
)

var _ = Describe("hostlink verbs", func() {
	start := func(args ...string) *gexec.Session {
		s, err := gexec.Start(exec.Command(binary, args...), GinkgoWriter, GinkgoWriter)
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func() { s.Kill().Wait(5 * time.Second) })
		return s
	}

	It("refuses a relay target that is not an IP address", func() {
		s := start("hostlink-relay", "--socket", "/nonexistent/s", "--ports", "/nonexistent/p", "--target", "host.example")
		Eventually(s).Should(gexec.Exit(2))
		Expect(s.Err).To(gbytes.Say(`--target host.example is not an IP address`))
	})

	DescribeTable("refuses a proxy that is not http://host:port",
		func(proxy string) {
			s := start("hostlink-listen", "--ports", "/nonexistent/p", "--proxy", proxy)
			Eventually(s).Should(gexec.Exit(2))
			Expect(s.Err).To(gbytes.Say("is not http://host:port"))
		},
		Entry("no port", "http://s1-egress"),
		Entry("https", "https://s1-egress:3128"),
		Entry("not a URL", "s1-egress:3128"),
	)

	It("serves the relay on a fresh 0600 socket, replacing a stale file, and refuses an unlisted port", func() {
		dir, err := os.MkdirTemp("", "hl")
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(os.RemoveAll, dir)
		sock := filepath.Join(dir, "relay.sock")
		Expect(os.WriteFile(sock, nil, 0o600)).To(Succeed())
		start("hostlink-relay", "--socket", sock, "--ports", filepath.Join(dir, "none"), "--target", "127.0.0.1")
		var c net.Conn
		Eventually(func() (err error) { c, err = net.Dial("unix", sock); return err }, 5*time.Second).Should(Succeed())
		DeferCleanup(c.Close)
		info, err := os.Stat(sock)
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o600)))
		_, err = c.Write([]byte("CONNECT host.containers.internal:22 HTTP/1.1\r\n\r\n"))
		Expect(err).NotTo(HaveOccurred())
		line, err := bufio.NewReader(c).ReadString('\n')
		Expect(err).NotTo(HaveOccurred())
		Expect(line).To(Equal("HTTP/1.1 403 Forbidden\r\n"))
	})
})

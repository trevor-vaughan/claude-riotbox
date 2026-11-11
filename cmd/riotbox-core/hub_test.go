package main_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"
	"github.com/onsi/gomega/gexec"
)

var _ = Describe("hub verb", func() {
	start := func(listen string) *gexec.Session {
		cmd := exec.Command(binary, "hub", "--engine", "/nonexistent/engine", "--state-root", GinkgoT().TempDir(),
			"--data-dir", GinkgoT().TempDir(), "--listen", listen)
		s, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func() { s.Kill().Wait(5 * time.Second) })
		return s
	}

	// 192.0.2.1 is TEST-NET-1 (RFC 5737): never an address of the test host.
	It("names an address this host does not have, and prints no link for it", func() {
		s := start("192.0.2.1:3399")
		Eventually(s).Should(gexec.Exit(1))
		Expect(s.Err).To(gbytes.Say(`192\.0\.2\.1 is not an address of this host`))
		Expect(s.Out.Contents()).NotTo(ContainSubstring("RiotBox hub:"))
	})

	It("prints the link once it is listening, and keeps serving", func() {
		s := start("127.0.0.1:0")
		Eventually(s.Out).Should(gbytes.Say(`RiotBox hub: https://127\.0\.0\.1:0/\?k=`))
		Consistently(s, "300ms").ShouldNot(gexec.Exit())
	})
})

var _ = Describe("hub-link and hub-new-token verbs", func() {
	linkLine := regexp.MustCompile(`^https://127\.0\.0\.1:3399/\?k=[A-Za-z0-9_-]{43}\n$`)

	// verb runs binary verb --data-dir dir --listen listen and returns what it printed.
	verb := func(name, dir, listen string) (*gexec.Session, string) {
		args := []string{name, "--data-dir", dir}
		if listen != "" {
			args = append(args, "--listen", listen)
		}
		s, err := gexec.Start(exec.Command(binary, args...), GinkgoWriter, GinkgoWriter)
		Expect(err).NotTo(HaveOccurred())
		Eventually(s, 10*time.Second).Should(gexec.Exit())
		return s, string(s.Out.Contents())
	}

	It("prints the link alone, creating the token but no certificate, and the same link again", func() {
		dir := filepath.Join(GinkgoT().TempDir(), "hub")
		s, out := verb("hub-link", dir, "127.0.0.1:3399")
		Expect(s.ExitCode()).To(Equal(0))
		Expect(out).To(MatchRegexp(linkLine.String()))
		info, err := os.Stat(filepath.Join(dir, "token"))
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o600)))
		Expect(filepath.Join(dir, "cert.pem")).NotTo(BeAnExistingFile())
		_, again := verb("hub-link", dir, "127.0.0.1:3399")
		Expect(again).To(Equal(out))
	})

	It("hub-new-token prints a different link, which hub-link then prints", func() {
		dir := filepath.Join(GinkgoT().TempDir(), "hub")
		_, first := verb("hub-link", dir, "127.0.0.1:3399")
		s, rotated := verb("hub-new-token", dir, "127.0.0.1:3399")
		Expect(s.ExitCode()).To(Equal(0))
		Expect(rotated).To(MatchRegexp(linkLine.String()))
		Expect(rotated).NotTo(Equal(first))
		_, after := verb("hub-link", dir, "127.0.0.1:3399")
		Expect(after).To(Equal(rotated))
	})

	DescribeTable("refuse a missing --listen",
		func(name string) {
			s, out := verb(name, GinkgoT().TempDir(), "")
			Expect(s.ExitCode()).To(Equal(2))
			Expect(out).To(BeEmpty())
		},
		Entry("hub-link", "hub-link"),
		Entry("hub-new-token", "hub-new-token"),
	)

	It("fails with a message when the data directory cannot be made", func() {
		blocker := filepath.Join(GinkgoT().TempDir(), "file")
		Expect(os.WriteFile(blocker, nil, 0o600)).To(Succeed())
		s, out := verb("hub-link", filepath.Join(blocker, "hub"), "127.0.0.1:3399")
		Expect(s.ExitCode()).To(Equal(1))
		Expect(out).To(BeEmpty())
		Expect(s.Err).To(gbytes.Say(`riotbox-core: hub: `))
	})
})

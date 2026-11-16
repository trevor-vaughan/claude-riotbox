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

	DescribeTable("draw no QR code when stderr is not a terminal",
		func(name string) {
			s, _ := verb(name, filepath.Join(GinkgoT().TempDir(), "hub"), "127.0.0.1:3399")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Err.Contents()).To(BeEmpty())
		},
		Entry("hub-link", "hub-link"),
		Entry("hub-new-token", "hub-new-token"),
	)

	It("fails with a message when stdout cannot be written", func() {
		if _, err := os.Stat("/dev/full"); err != nil {
			Skip("no /dev/full to fail a write on: " + err.Error())
		}
		// gexec.Start replaces cmd.Stdout, so the shell does the redirect.
		cmd := exec.Command("sh", "-c", `"$0" hub-link --data-dir "$1" --listen 127.0.0.1:3399 >/dev/full`,
			binary, filepath.Join(GinkgoT().TempDir(), "hub"))
		s, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)
		Expect(err).NotTo(HaveOccurred())
		Eventually(s).Should(gexec.Exit(1))
		Expect(s.Err).To(gbytes.Say(`riotbox-core: writing output: `))
	})

	It("fails with a message when the data directory cannot be made", func() {
		blocker := filepath.Join(GinkgoT().TempDir(), "file")
		Expect(os.WriteFile(blocker, nil, 0o600)).To(Succeed())
		s, out := verb("hub-link", filepath.Join(blocker, "hub"), "127.0.0.1:3399")
		Expect(s.ExitCode()).To(Equal(1))
		Expect(out).To(BeEmpty())
		Expect(s.Err).To(gbytes.Say(`riotbox-core: hub: `))
	})
})

var _ = Describe("QR code on a terminal", func() {
	// A QR row drawn in half blocks: light modules are blocks, dark ones spaces.
	qrRow := regexp.MustCompile(`(?m)^[█▀▄ ]{25,}\r?$`)

	// onTerminal runs binary with args under script(1), so its stdout and
	// stderr are a pty, as when a person runs it.
	onTerminal := func(args ...string) *gexec.Session {
		if _, err := exec.LookPath("script"); err != nil {
			Skip("script(1) is needed to give the binary a terminal: " + err.Error())
		}
		command := "'" + binary + "'"
		for _, a := range args {
			command += " '" + a + "'"
		}
		s, err := gexec.Start(exec.Command("script", "-qec", command, "/dev/null"), GinkgoWriter, GinkgoWriter)
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func() { s.Kill().Wait(5 * time.Second) })
		return s
	}

	DescribeTable("draws the link as a QR code under it",
		func(name string) {
			s := onTerminal(name, "--data-dir", filepath.Join(GinkgoT().TempDir(), "hub"), "--listen", "127.0.0.1:3399")
			Eventually(s, 10*time.Second).Should(gexec.Exit(0))
			out := string(s.Out.Contents())
			Expect(out).To(MatchRegexp(`^https://127\.0\.0\.1:3399/\?k=[A-Za-z0-9_-]{43}\r\n`))
			Expect(len(qrRow.FindAllString(out, -1))).To(BeNumerically(">=", 15))
		},
		Entry("hub-link", "hub-link"),
		Entry("hub-new-token", "hub-new-token"),
	)

	It("hub draws the link as a QR code once it is listening", func() {
		s := onTerminal("hub", "--engine", "/nonexistent/engine", "--state-root", GinkgoT().TempDir(),
			"--data-dir", GinkgoT().TempDir(), "--listen", "127.0.0.1:0")
		Eventually(s.Out).Should(gbytes.Say(`RiotBox hub: https://127\.0\.0\.1:0/\?k=`))
		Eventually(func() int { return len(qrRow.FindAllString(string(s.Out.Contents()), -1)) }).
			Should(BeNumerically(">=", 15))
	})
})

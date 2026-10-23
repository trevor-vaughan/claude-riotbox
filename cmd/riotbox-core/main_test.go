package main_test

import (
	"fmt"
	"os/exec"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"

	"github.com/trevor-vaughan/claude-riotbox/internal/sessionkey"
)

func run(args ...string) *gexec.Session {
	session, err := gexec.Start(exec.Command(binary, args...), GinkgoWriter, GinkgoWriter)
	Expect(err).NotTo(HaveOccurred())
	Eventually(session).Should(gexec.Exit())
	return session
}

var _ = Describe("riotbox-core", func() {
	It("prints the version baked in at build time", func() {
		s := run("version")
		Expect(s.ExitCode()).To(Equal(0))
		Expect(string(s.Out.Contents())).To(Equal("9.9.9-test\n"))
		Expect(s.Err.Contents()).To(BeEmpty())
	})

	It("prints the session key of a set", func() {
		s := run("session-key", "/home/me/b", "/home/me/a")
		Expect(s.ExitCode()).To(Equal(0))
		Expect(string(s.Out.Contents())).To(Equal(sessionkey.Key([]string{"/home/me/a", "/home/me/b"}) + "\n"))
		Expect(s.Err.Contents()).To(BeEmpty())
	})

	It("prints a set's identity as three lines", func() {
		s := run("set-identity", "/x/app", "/y/lib")
		first, nMore, hash := sessionkey.Identity([]string{"/x/app", "/y/lib"})
		Expect(nMore).To(Equal(1))
		Expect(s.ExitCode()).To(Equal(0))
		Expect(string(s.Out.Contents())).To(Equal(fmt.Sprintf("%s\n%d\n%s\n", first, nMore, hash)))
		Expect(s.Err.Contents()).To(BeEmpty())
	})

	DescribeTable("rejects bad usage with exit 2 and usage on stderr",
		func(args ...string) {
			s := run(args...)
			Expect(s.ExitCode()).To(Equal(2))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(ContainSubstring("usage: riotbox-core"))
		},
		Entry("no verb"),
		Entry("unknown verb", "frobnicate"),
		Entry("session-key without dirs", "session-key"),
		Entry("set-identity without dirs", "set-identity"),
		Entry("version with arguments", "version", "extra"),
	)
})

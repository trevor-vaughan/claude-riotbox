package main_test

import (
	"os/exec"
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

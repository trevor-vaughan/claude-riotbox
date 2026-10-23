package main_test

import (
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

var binary string

func TestRiotboxCore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "riotbox-core")
}

var _ = BeforeSuite(func() {
	SetDefaultEventuallyTimeout(10 * time.Second)
	var err error
	binary, err = gexec.Build("github.com/trevor-vaughan/claude-riotbox/cmd/riotbox-core",
		"-ldflags", "-X main.version=9.9.9-test")
	Expect(err).NotTo(HaveOccurred())
})

var _ = AfterSuite(func() {
	gexec.CleanupBuildArtifacts()
})

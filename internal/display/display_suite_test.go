package display_test

import (
	"path/filepath"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestDisplay(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "display")
}

// libDir is the repository's scripts/lib: the differential specs source the
// real session-state.sh and run the real terminal-clean.jq.
var libDir string

var _ = BeforeSuite(func() {
	var err error
	libDir, err = filepath.Abs(filepath.Join("..", "..", "scripts", "lib"))
	Expect(err).NotTo(HaveOccurred())
	Expect(filepath.Join(libDir, "session-state.sh")).To(BeARegularFile())
})

package main

import (
	"bytes"
	"errors"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Specs here share the RunSpecs call in main_suite_test.go: internal and
// external test packages compile into one test binary.

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) {
	return 0, errors.New("no space left on device")
}

var _ = Describe("run", func() {
	It("returns 1 and reports on stderr when stdout cannot be written", func() {
		var stderr bytes.Buffer
		Expect(run([]string{"version"}, failingWriter{}, &stderr)).To(Equal(1))
		Expect(stderr.String()).To(ContainSubstring("writing output"))
	})
})

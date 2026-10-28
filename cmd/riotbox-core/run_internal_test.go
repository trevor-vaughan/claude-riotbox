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

var _ = Describe("parseArgs", func() {
	v := verb{options: []string{"--a"}, optional: []string{"--b"}, maxArgs: unbounded}

	It("takes an optional option once, beside the required ones", func() {
		p, ok := parseArgs(v, []string{"--a", "1", "--b", "2", "x"})
		Expect(ok).To(BeTrue())
		Expect(p.opts).To(Equal(map[string]string{"--a": "1", "--b": "2"}))
		Expect(p.args).To(Equal([]string{"x"}))
	})

	It("lets an optional option be left out", func() {
		p, ok := parseArgs(v, []string{"--a", "1"})
		Expect(ok).To(BeTrue())
		Expect(p.opts).To(Equal(map[string]string{"--a": "1"}))
	})

	It("refuses an optional option given twice", func() {
		_, ok := parseArgs(v, []string{"--a", "1", "--b", "2", "--b", "3"})
		Expect(ok).To(BeFalse())
	})

	It("still requires every required option when an optional one is given", func() {
		_, ok := parseArgs(v, []string{"--b", "2"})
		Expect(ok).To(BeFalse())
	})
})

package inject_test

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
)

var _ = Describe("ParseInput", func() {
	It("reads input without a NUL as the hosts alone, as before injection existed", func() {
		hosts, vars, err := inject.ParseInput([]byte("a.example\nb.example\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(string(hosts)).To(Equal("a.example\nb.example\n"))
		Expect(vars).To(BeEmpty())
	})

	It("reads the variables after the NUL, keeping = and spaces in values, and empty values", func() {
		hosts, vars, err := inject.ParseInput([]byte("a.example\n\x00A=x=y z\x00B=\x00"))
		Expect(err).NotTo(HaveOccurred())
		Expect(string(hosts)).To(Equal("a.example\n"))
		Expect(vars).To(Equal(map[string]string{"A": "x=y z", "B": ""}))
	})

	It("accepts a NUL with no variables after it", func() {
		hosts, vars, err := inject.ParseInput([]byte("a.example\n\x00"))
		Expect(err).NotTo(HaveOccurred())
		Expect(string(hosts)).To(Equal("a.example\n"))
		Expect(vars).To(BeEmpty())
	})

	DescribeTable("rejects a malformed record, naming it by number, never by content",
		func(input, want string) {
			_, _, err := inject.ParseInput([]byte(input))
			Expect(err).To(MatchError(want))
			Expect(err.Error()).NotTo(ContainSubstring("s3cret"))
		},
		Entry("a record without its NUL", "h\n\x00A=1\x00B=s3cret", "variable record 2 on stdin has no terminating NUL"),
		Entry("a record without =", "h\n\x00s3cret\x00", "variable record 1 on stdin is not NAME=VALUE"),
		Entry("a name that is not a variable name", "h\n\x001A=s3cret\x00", "variable record 1 on stdin is not NAME=VALUE"),
		Entry("an empty name", "h\n\x00=s3cret\x00", "variable record 1 on stdin is not NAME=VALUE"),
		Entry("a name given twice", "h\n\x00A=1\x00A=s3cret\x00", "variable record 2 on stdin repeats A"),
	)
})

var _ = Describe("IsEnvName", func() {
	DescribeTable("accepts shell variable names only",
		func(name string, want bool) { Expect(inject.IsEnvName(name)).To(Equal(want)) },
		Entry("upper case and digits", "XAI_API_KEY2", true),
		Entry("a leading underscore", "_X", true),
		Entry("lower case", "lower", true),
		Entry("empty", "", false),
		Entry("a leading digit", "1A", false),
		Entry("a dash", "A-B", false),
		Entry("an escape", "A\x1b", false),
	)
})

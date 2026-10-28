package policy_test

import (
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// item parses raw as a conf line read from line.
func item(raw string, line int) policy.Item {
	it, err := policy.ParseItem(raw)
	ExpectWithOffset(1, err).NotTo(HaveOccurred())
	it.Line = line
	return it
}

var _ = Describe("ParseItem", func() {
	DescribeTable("accepts",
		func(raw string, want policy.Item) {
			Expect(policy.ParseItem(raw)).To(Equal(want))
		},
		Entry("a host, folded to lowercase", "API.example.com", policy.Item{Entry: entry("api.example.com", 443)}),
		Entry("a removal with a port", "-a.example:8443", policy.Item{Entry: entry("a.example", 8443), Remove: true}),
		Entry("a group", "@pypi", policy.Item{Group: "pypi"}),
		Entry("a group removal", "-@npm", policy.Item{Group: "npm", Remove: true}),
		Entry("a group name with digits and dashes", "@corp-2", policy.Item{Group: "corp-2"}),
	)

	DescribeTable("rejects",
		func(raw, reason string) {
			_, err := policy.ParseItem(raw)
			Expect(err).To(MatchError(ContainSubstring(reason)))
		},
		Entry("an uppercase group name", "@PyPI", `invalid group name "PyPI"`),
		Entry("an empty group name", "@", `invalid group name ""`),
		Entry("a group name with a dot", "@a.b", "invalid group name"),
		Entry("a group name that starts with a dash", "@-a", "invalid group name"),
		Entry("a group name over 63 characters", "@"+strings.Repeat("a", 64), "invalid group name"),
		Entry("a double @", "@@x", "invalid group name"),
		Entry("an invalid entry, naming it", "10.0.0.1", `invalid egress entry "10.0.0.1": host looks like an IP address`),
	)

	It("spells an item as a conf file does", func() {
		Expect(policy.Item{Group: "npm", Remove: true}.String()).To(Equal("-@npm"))
		Expect(policy.Item{Entry: entry("a.example", 8443)}.String()).To(Equal("a.example:8443"))
		Expect(policy.Item{Entry: entry("a.example", 443), Remove: true}.String()).To(Equal("-a.example"))
	})

	It("says two items name the same thing whatever their signs, and an entry never names a group", func() {
		Expect(item("a.example", 0).Names(item("-a.example", 3))).To(BeTrue())
		Expect(item("@npm", 0).Names(item("-@npm", 0))).To(BeTrue())
		Expect(item("@npm", 0).Names(item("@pypi", 0))).To(BeFalse())
		Expect(item("a.example", 0).Names(item("a.example:8443", 0))).To(BeFalse())
		Expect(item("a.example", 0).Names(item("@npm", 0))).To(BeFalse())
	})
})

var _ = Describe("ParseFile", func() {
	It("reads a flat file, as every egress.conf before sections was, as allow items in order", func() {
		c, err := policy.ParseFile("egress.conf", []byte("# hosts\n\napi.example.com  # why\r\n-b.example\n  c.example:8443\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(c).To(Equal(policy.Conf{
			Name:  "egress.conf",
			Items: []policy.Item{item("api.example.com", 3), item("-b.example", 4), item("c.example:8443", 5)},
		}))
	})

	It("reads the preamble's setting, groups, and several allow sections", func() {
		text := "strict  # nothing implicit\n" + // 1
			"[group mirrors]\n" + // 2
			"mirror.corp.example:8443\n" + // 3
			"*.pkg.corp.example\n" + // 4
			"\n" + // 5
			"[allow]\n" + // 6
			"@agent\n" + // 7
			"@mirrors\n" + // 8
			"-@npm\n" + // 9
			"api.internal.example\n" + // 10
			"[group  b ]\n" + // 11
			"b.example\n" + // 12
			"[allow]\n" + // 13
			"-pypi.org\n" // 14
		c, err := policy.ParseFile("x", []byte(text))
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Strict).To(Equal(policy.StrictOn))
		Expect(c.StrictLine).To(Equal(1))
		Expect(c.Groups).To(Equal([]policy.GroupDef{
			{Name: "mirrors", Members: []policy.Entry{entry("mirror.corp.example", 8443), entry("*.pkg.corp.example", 443)}, Line: 2},
			{Name: "b", Members: []policy.Entry{entry("b.example", 443)}, Line: 11},
		}))
		Expect(c.Items).To(Equal([]policy.Item{
			item("@agent", 7), item("@mirrors", 8), item("-@npm", 9), item("api.internal.example", 10), item("-pypi.org", 14),
		}))
	})

	DescribeTable("reads the strict setting",
		func(text string, want policy.StrictSetting, line int) {
			c, err := policy.ParseFile("x", []byte(text))
			Expect(err).NotTo(HaveOccurred())
			Expect(c.Strict).To(Equal(want))
			Expect(c.StrictLine).To(Equal(line))
		},
		Entry("bare", "strict\n", policy.StrictOn, 1),
		Entry("on", "strict = on\n", policy.StrictOn, 1),
		Entry("off, without spaces", "strict=off\n", policy.StrictOff, 1),
		Entry("with spaces and a comment", "  strict   =   on  # yes\n", policy.StrictOn, 1),
		Entry("twice: the last one counts", "a.example\nstrict = on\nstrict = off\n", policy.StrictOff, 3),
		Entry("absent", "a.example\n", policy.StrictUnset, 0),
	)

	It("reads a section header with a trailing comment", func() {
		c, err := policy.ParseFile("x", []byte("[group m] # c\nm.example\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Groups).To(Equal([]policy.GroupDef{{Name: "m", Members: []policy.Entry{entry("m.example", 443)}, Line: 1}}))
	})

	It("lists a group member given twice once", func() {
		c, err := policy.ParseFile("x", []byte("[group m]\nm.example\nM.example:443\nn.example\nm.example\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Groups).To(Equal([]policy.GroupDef{{Name: "m", Members: []policy.Entry{entry("m.example", 443), entry("n.example", 443)}, Line: 1}}))
	})

	It("returns an empty Conf, named, for an empty file", func() {
		Expect(policy.ParseFile("x", nil)).To(Equal(policy.Conf{Name: "x"}))
	})

	DescribeTable("rejects, naming the file and line",
		func(text, want string) {
			_, err := policy.ParseFile("x", []byte(text))
			Expect(err).To(MatchError(HavePrefix(want)))
		},
		Entry("an unknown section", "[allowed]\n", `x:1: unknown section "[allowed]"`),
		Entry("a group header without a name", "a.example\n[group]\n", `x:2: unknown section "[group]"`),
		Entry("a group name that is not lowercase", "[group Mirrors]\nm.example\n", `x:1: invalid group name "Mirrors"`),
		Entry("defining the reserved agent group", "[group agent]\na.example\n", "x:1: @agent is reserved"),
		Entry("a group defined twice", "[group a]\na.example\n[group a]\nb.example\n", "x:3: group a is already defined on line 1"),
		Entry("a removal in a group", "[group a]\n-a.example\n", `x:2: a group lists hosts only: "-a.example"`),
		Entry("a reference in a group", "[group a]\n@b\n", `x:2: a group lists hosts only: "@b"`),
		Entry("an empty group before another section", "[group a]\n\n# none\n[allow]\n", "x:1: group a has no members"),
		Entry("an empty group at the end", "a.example\n[group a]\n", "x:2: group a has no members"),
		Entry("an unknown setting", "mode = fast\n", `x:1: unknown setting "mode"`),
		Entry("a strict value that is not on or off", "strict = yes\n", `x:1: strict must be on or off, not "yes"`),
		Entry("an uppercase strict value", "strict = ON\n", `x:1: strict must be on or off, not "ON"`),
		Entry("an empty strict value", "strict =\n", `x:1: strict must be on or off, not ""`),
		Entry("strict in an allow section", "[allow]\nstrict\n", "x:2: the strict setting must come before the first [section]"),
		Entry("strict in a group", "[group a]\na.example\nstrict = off\n", "x:3: the strict setting must come before the first [section]"),
		Entry("an invalid entry", "a.example\n10.0.0.1\n", `x:2: invalid egress entry "10.0.0.1": `),
		Entry("an invalid group reference", "@Bad\n", `x:1: invalid group name "Bad"`),
		Entry("an invalid group member", "[group a]\n10.0.0.1\n", `x:2: invalid egress entry "10.0.0.1": `),
		Entry("a control character in a header, quoted", "[\x1b]\n", `x:1: unknown section "[\x1b]"`),
		Entry("a non-ASCII section name", "[allöw]\n", `x:1: unknown section "[allöw]"`),
		Entry("a non-ASCII setting name", "stríct = on\n", `x:1: unknown setting "stríct"`),
		Entry("a non-ASCII group name", "[group mïrrors]\nm.example\n", `x:1: invalid group name "mïrrors"`),
	)
})

var _ = Describe("ParseList", func() {
	It("reads bare entries", func() {
		Expect(policy.ParseList("agent.conf", []byte("a.example\n*.b.example:8443\n"))).To(Equal([]policy.Entry{entry("a.example", 443), entry("*.b.example", 8443)}))
	})

	It("tolerates an [allow] header", func() {
		Expect(policy.ParseList("agent.conf", []byte("a.example\n[allow]\nb.example\n"))).To(Equal([]policy.Entry{entry("a.example", 443), entry("b.example", 443)}))
	})

	It("is empty for an empty file", func() {
		Expect(policy.ParseList("agent.conf", nil)).To(BeEmpty())
	})

	DescribeTable("rejects anything but bare entries, naming the file and line",
		func(text, want string) {
			_, err := policy.ParseList("agent.conf", []byte(text))
			Expect(err).To(MatchError(HavePrefix(want)))
		},
		Entry("a removal", "a.example\n-b.example\n", "agent.conf:2: only host entries are allowed here, not -b.example"),
		Entry("a group reference", "@npm\n", "agent.conf:1: only host entries are allowed here, not @npm"),
		Entry("a setting", "strict\n", "agent.conf:1: a setting is not allowed here"),
		Entry("a group", "[group a]\na.example\n", "agent.conf:1: a section is not allowed here"),
		Entry("an invalid entry", "10.0.0.1\n", `agent.conf:1: invalid egress entry "10.0.0.1"`),
	)
})

var _ = Describe("IsStrictLine", func() {
	DescribeTable("tells a strict setting line",
		func(line string, want bool) { Expect(policy.IsStrictLine(line)).To(Equal(want)) },
		Entry("bare", "strict", true),
		Entry("on", "strict = on", true),
		Entry("a bad value is still a strict line", "strict=bogus", true),
		Entry("a host that starts with strict", "strict.example.com", false),
		Entry("another setting", "mode = on", false),
		Entry("an empty line", "", false),
	)
})

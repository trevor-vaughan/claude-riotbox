package policy_test

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// The shipped egress.conf is documentation users edit by uncommenting lines,
// so every example in it must parse, and resolve, once uncommented.
var _ = Describe("the shipped egress.conf template", func() {
	var data []byte

	BeforeEach(func() {
		var err error
		data, err = os.ReadFile(filepath.Join("..", "..", "..", "scripts", "configs", "egress.conf"))
		Expect(err).NotTo(HaveOccurred())
	})

	It("parses as shipped and allows nothing until edited", func() {
		c, err := policy.ParseFile("egress.conf", data)
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Items).To(BeEmpty())
		Expect(c.Groups).To(BeEmpty())
		Expect(c.Strict).To(Equal(policy.StrictUnset))
	})

	It("is version 2", func() {
		first, _, _ := strings.Cut(string(data), "\n")
		Expect(first).To(Equal("# riotbox-config-version: 2"))
	})

	It("parses and resolves every example once uncommented", func() {
		// An example is a "# " line (one space; the grammar notes in the
		// header use more) whose whole body is one token of the grammar.
		example := regexp.MustCompile(`^# (strict(?: = (?:on|off))?|\[allow\]|\[group [a-z0-9-]+\]|-?@[a-z0-9-]+|-?(?:\*\.)?[a-z0-9][a-z0-9.-]*\.[a-z]+(?::[0-9]+)?)$`)
		var uncommented []string
		for _, line := range strings.Split(string(data), "\n") {
			if m := example.FindStringSubmatch(line); m != nil {
				uncommented = append(uncommented, m[1])
			}
		}
		Expect(uncommented).To(Equal([]string{
			"strict", "[group mirrors]", "mirror.corp.example:8443", "*.pkg.corp.example",
			"[allow]", "@agent", "@mirrors", "@containers", "@centos",
		}))
		c, err := policy.ParseFile("egress.conf", []byte(strings.Join(uncommented, "\n")))
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Strict).To(Equal(policy.StrictOn))
		r, err := policy.Resolve(policy.Sources{User: c})
		Expect(err).NotTo(HaveOccurred())
		for _, g := range []string{"mirrors", "containers", "centos"} {
			Expect(r.Groups[g].Members).NotTo(BeEmpty(), g)
			for _, e := range r.Groups[g].Members {
				Expect(r.Entries).To(ContainElement(e), g)
			}
		}
	})

	It("names in its header exactly the groups @registries is made of", func() {
		m := regexp.MustCompile(`(?m)^#\s+@registries\s+the package registries: (.*)$`).FindStringSubmatch(string(data))
		Expect(m).NotTo(BeNil())
		table := policy.Groups(nil, policy.Conf{}, policy.Conf{})
		var union []policy.Entry
		for _, ref := range strings.Fields(m[1]) {
			name, isRef := strings.CutPrefix(ref, "@")
			Expect(isRef).To(BeTrue(), ref)
			Expect(table).To(HaveKey(name))
			union = append(union, table[name].Members...)
		}
		Expect(union).To(ConsistOf(table["registries"].Members))
	})
})

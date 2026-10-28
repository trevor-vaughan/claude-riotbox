package policy_test

import (
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
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

	It("is version 4", func() {
		first, _, _ := strings.Cut(string(data), "\n")
		Expect(first).To(Equal("# riotbox-config-version: 4"))
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
			"[allow]", "@agent", "@mirrors", "@containers", "@forges", "@centos",
		}))
		c, err := policy.ParseFile("egress.conf", []byte(strings.Join(uncommented, "\n")))
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Strict).To(Equal(policy.StrictOn))
		osGroups, err := state.LoadOS(filepath.Join("..", "..", "..", "os"))
		Expect(err).NotTo(HaveOccurred())
		r, err := policy.Resolve(policy.Sources{User: c, OS: osGroups})
		Expect(err).NotTo(HaveOccurred())
		for _, g := range []string{"mirrors", "containers", "forges", "centos"} {
			Expect(r.Groups[g].Members).NotTo(BeEmpty(), g)
			for _, e := range r.Groups[g].Members {
				Expect(r.Entries).To(ContainElement(e), g)
			}
		}
	})

	It("names every group in its catalogue, so users know what each is for", func() {
		_, rest, found := strings.Cut(string(data), "\n# Groups you can allow")
		Expect(found).To(BeTrue())
		// The catalogue runs from the line after the heading's "#" to the
		// next "#" line on its own.
		lines := strings.Split(rest, "\n")
		Expect(len(lines)).To(BeNumerically(">", 2))
		Expect(lines[1]).To(Equal("#"))
		var block strings.Builder
		for _, l := range lines[2:] {
			if l == "#" {
				break
			}
			block.WriteString(l + "\n")
		}
		named := map[string]bool{}
		for _, m := range regexp.MustCompile(`@([a-z0-9-]+)`).FindAllStringSubmatch(block.String(), -1) {
			named[m[1]] = true
		}
		osGroups, err := state.LoadOS(filepath.Join("..", "..", "..", "os"))
		Expect(err).NotTo(HaveOccurred())
		table := policy.Groups(nil, osGroups, policy.Conf{}, policy.Conf{})
		var want []string
		for name := range table {
			if name != policy.AgentGroup && name != "registries" {
				want = append(want, name)
			}
		}
		Expect(slices.Sorted(maps.Keys(named))).To(Equal(slices.Sorted(slices.Values(want))))
	})

	It("names in its header exactly the groups @registries is made of", func() {
		m := regexp.MustCompile(`(?m)^#\s+@registries\s+the package registries: (.*)$`).FindStringSubmatch(string(data))
		Expect(m).NotTo(BeNil())
		table := policy.Groups(nil, nil, policy.Conf{}, policy.Conf{})
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

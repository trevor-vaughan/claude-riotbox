package policy_test

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

var _ = Describe("OSGroup", func() {
	It("reads an OS plugin's egress-hosts as the group of its name", func() {
		g, err := policy.OSGroup("fedora", "/os/fedora/egress-hosts", []byte("# Source: x\ndl.fedoraproject.org\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(g).To(Equal(policy.GroupDef{Name: "fedora", Members: []policy.Entry{entry("dl.fedoraproject.org", 443)}}))
	})

	DescribeTable("refuses, naming the file",
		func(name, data, reason string) {
			_, err := policy.OSGroup(name, "/os/x/egress-hosts", []byte(data))
			Expect(err).To(MatchError(And(HavePrefix("/os/x/egress-hosts"), ContainSubstring(reason))))
		},
		Entry("an invalid name", "Fedora", "a.example\n", "not a group name"),
		Entry("the reserved agent", "agent", "a.example\n", "already a group"),
		Entry("the built-in os", "os", "a.example\n", "already a group"),
		Entry("a built-in's name", "pypi", "a.example\n", "already a group"),
		Entry("no hosts", "fedora", "# only a comment\n", "lists no hosts"),
		Entry("an invalid entry", "fedora", "10.0.0.1\n", "invalid egress entry"),
		Entry("a group reference", "fedora", "@pypi\n", "only host entries"),
	)
})

var _ = Describe("OS groups in the group table", func() {
	osGroups := []policy.GroupDef{{Name: "fedora", Members: []policy.Entry{entry("dl.fedoraproject.org", 443)}}}

	It("adds them with source os", func() {
		g := policy.Groups(nil, osGroups, policy.Conf{}, policy.Conf{})["fedora"]
		Expect(g).To(Equal(policy.Group{Name: "fedora", Source: policy.SourceOS, Members: osGroups[0].Members}))
	})

	It("replace a built-in of the same name", func() {
		npm := []policy.GroupDef{{Name: "npm", Members: []policy.Entry{entry("npm.os.example", 443)}}}
		g := policy.Groups(nil, npm, policy.Conf{}, policy.Conf{})["npm"]
		Expect(g).To(Equal(policy.Group{Name: "npm", Source: policy.SourceOS, Members: npm[0].Members}))
	})

	It("lets the system conf replace them, and the user conf replace that", func() {
		sys := policy.Conf{Groups: []policy.GroupDef{{Name: "fedora", Members: []policy.Entry{entry("sys.example", 443)}}}}
		g := policy.Groups(nil, osGroups, sys, policy.Conf{})["fedora"]
		Expect(g.Source).To(Equal(policy.SourceSystem))
		Expect(hosts(g.Members)).To(Equal([]string{"sys.example"}))
		user := policy.Conf{Groups: []policy.GroupDef{{Name: "fedora", Members: []policy.Entry{entry("user.example", 443)}}}}
		g = policy.Groups(nil, osGroups, sys, user)["fedora"]
		Expect(g.Source).To(Equal(policy.SourceUser))
		Expect(hosts(g.Members)).To(Equal([]string{"user.example"}))
	})

	It("resolves an @ reference to one, and fails on one without it", func() {
		user := policy.Conf{Name: "user.conf", Items: []policy.Item{{Group: "fedora", Line: 1}}}
		r, err := policy.Resolve(policy.Sources{OS: osGroups, User: user})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).To(ContainElement(entry("dl.fedoraproject.org", 443)))
		_, err = policy.Resolve(policy.Sources{User: user})
		Expect(err).To(MatchError(ContainSubstring("user.conf:1: no group named @fedora")))
	})
})

var _ = Describe("the @os built-in", func() {
	fedora := policy.GroupDef{Name: "fedora", Members: []policy.Entry{entry("dl.fedoraproject.org", 443)}}
	debian := policy.GroupDef{Name: "debian", Members: []policy.Entry{entry("deb.debian.org", 443), entry("dl.fedoraproject.org", 443)}}
	osGroups := []policy.GroupDef{fedora, debian}

	It("is the union of every OS plugin's hosts, with source built-in", func() {
		g := policy.Groups(nil, osGroups, policy.Conf{}, policy.Conf{})["os"]
		Expect(g.Name).To(Equal("os"))
		Expect(g.Source).To(Equal(policy.SourceBuiltin))
		Expect(hosts(g.Members)).To(Equal([]string{"deb.debian.org", "dl.fedoraproject.org"}))
	})

	It("follows a conf's override of an OS group", func() {
		user := policy.Conf{Groups: []policy.GroupDef{{Name: "fedora", Members: []policy.Entry{entry("user.example", 443)}}}}
		g := policy.Groups(nil, osGroups, policy.Conf{}, user)["os"]
		Expect(hosts(g.Members)).To(Equal([]string{"deb.debian.org", "dl.fedoraproject.org", "user.example"}))
		user = policy.Conf{Groups: []policy.GroupDef{{Name: "fedora", Members: []policy.Entry{entry("user.example", 443)}}, {Name: "debian", Members: []policy.Entry{entry("d.example", 443)}}}}
		g = policy.Groups(nil, osGroups, policy.Conf{}, user)["os"]
		Expect(hosts(g.Members)).To(Equal([]string{"d.example", "user.example"}))
	})

	It("reflects a system conf's override of an OS group", func() {
		sys := policy.Conf{Groups: []policy.GroupDef{{Name: "fedora", Members: []policy.Entry{entry("sys.example", 443)}}}}
		g := policy.Groups(nil, osGroups, sys, policy.Conf{})["os"]
		Expect(hosts(g.Members)).To(Equal([]string{"deb.debian.org", "dl.fedoraproject.org", "sys.example"}))
	})

	It("leaves out a conf group that is not an OS plugin's", func() {
		user := policy.Conf{Groups: []policy.GroupDef{{Name: "mine", Members: []policy.Entry{entry("mine.example", 443)}}}}
		g := policy.Groups(nil, osGroups, policy.Conf{}, user)["os"]
		Expect(hosts(g.Members)).To(Equal([]string{"deb.debian.org", "dl.fedoraproject.org"}))
	})

	It("exists and is empty without OS plugins, and then allows nothing", func() {
		g := policy.Groups(nil, nil, policy.Conf{}, policy.Conf{})["os"]
		Expect(g).To(Equal(policy.Group{Name: "os", Source: policy.SourceBuiltin}))
		user := policy.Conf{Name: "user.conf", Items: []policy.Item{{Group: "os", Line: 1}}}
		base, err := policy.Resolve(policy.Sources{})
		Expect(err).NotTo(HaveOccurred())
		r, err := policy.Resolve(policy.Sources{User: user})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).To(Equal(base.Entries))
	})

	It("is replaced by a user's [group os]", func() {
		user := policy.Conf{Groups: []policy.GroupDef{{Name: "os", Members: []policy.Entry{entry("mine.example", 443)}}}}
		g := policy.Groups(nil, osGroups, policy.Conf{}, user)["os"]
		Expect(g.Source).To(Equal(policy.SourceUser))
		Expect(hosts(g.Members)).To(Equal([]string{"mine.example"}))
	})

	It("allows every OS host when a conf references it, and is not allowed by default", func() {
		user := policy.Conf{Name: "user.conf", Items: []policy.Item{{Group: "os", Line: 1}}}
		r, err := policy.Resolve(policy.Sources{OS: osGroups, User: user})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).To(ContainElements(entry("dl.fedoraproject.org", 443), entry("deb.debian.org", 443)))
		r, err = policy.Resolve(policy.Sources{OS: osGroups})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).NotTo(ContainElement(entry("dl.fedoraproject.org", 443)))
		Expect(r.Groups["registries"].Members).NotTo(ContainElement(entry("dl.fedoraproject.org", 443)))
	})
})

package state_test

import (
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

var _ = Describe("OS plugins", func() {
	var osDir string

	plugin := func(name string, files map[string]string) {
		Expect(os.MkdirAll(filepath.Join(osDir, name), 0o755)).To(Succeed())
		for f, data := range files {
			Expect(os.WriteFile(filepath.Join(osDir, name, f), []byte(data), 0o644)).To(Succeed())
		}
	}

	BeforeEach(func() { osDir = GinkgoT().TempDir() })

	Describe("LoadOS", func() {
		It("reads every plugin in name order, skipping helpers and hidden or template dirs", func() {
			plugin("fedora", map[string]string{"egress-hosts": "dl.fedoraproject.org\n", "manifest.sh": ""})
			plugin("arch", map[string]string{"egress-hosts": "# Source: x\ngeo.mirror.pkgbuild.com\n"})
			plugin("lib", map[string]string{"dnf.sh": ""})
			plugin("_template", map[string]string{"egress-hosts": "x.example\n"})
			plugin(".hidden", map[string]string{"egress-hosts": "x.example\n"})
			Expect(os.WriteFile(filepath.Join(osDir, "registry.sh"), nil, 0o644)).To(Succeed())
			groups, err := state.LoadOS(osDir)
			Expect(err).NotTo(HaveOccurred())
			Expect(groups).To(HaveLen(2))
			Expect(groups[0].Name).To(Equal("arch"))
			Expect(groups[1].Name).To(Equal("fedora"))
		})

		It("follows a plugin directory that is a symlink, as the shell registry's glob does", func() {
			target := filepath.Join(GinkgoT().TempDir(), "real")
			Expect(os.MkdirAll(target, 0o755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(target, "egress-hosts"), []byte("mirror.example\n"), 0o644)).To(Succeed())
			Expect(os.Symlink(target, filepath.Join(osDir, "linked"))).To(Succeed())
			groups, err := state.LoadOS(osDir)
			Expect(err).NotTo(HaveOccurred())
			Expect(groups).To(HaveLen(1))
			Expect(groups[0].Name).To(Equal("linked"))
		})

		It("has no plugins for an empty path", func() {
			Expect(state.LoadOS("")).To(BeEmpty())
		})

		It("refuses a manifest.sh without egress-hosts, naming it", func() {
			plugin("fedora", map[string]string{"manifest.sh": ""})
			_, err := state.LoadOS(osDir)
			Expect(err).To(MatchError(ContainSubstring(filepath.Join(osDir, "fedora", "egress-hosts") + ": an OS plugin needs egress-hosts")))
		})

		It("refuses a plugin policy.OSGroup refuses", func() {
			plugin("pypi", map[string]string{"egress-hosts": "a.example\n"})
			_, err := state.LoadOS(osDir)
			Expect(err).To(MatchError(ContainSubstring("@pypi is already a group")))
		})

		It("fails on a missing directory", func() {
			missing := filepath.Join(osDir, "nope")
			_, err := state.LoadOS(missing)
			Expect(err).To(MatchError(ContainSubstring(missing)))
		})

		It("skips a dangling symlink", func() {
			Expect(os.Symlink(filepath.Join(osDir, "gone"), filepath.Join(osDir, "dangling"))).To(Succeed())
			groups, err := state.LoadOS(osDir)
			Expect(err).NotTo(HaveOccurred())
			Expect(groups).To(BeEmpty())
		})

		It("loads the repo's own plugins", func() {
			groups, err := state.LoadOS(filepath.Join("..", "..", "..", "os"))
			Expect(err).NotTo(HaveOccurred())
			var names []string
			for _, g := range groups {
				names = append(names, g.Name)
			}
			Expect(names).To(Equal([]string{"arch", "centos", "debian", "fedora", "rhel", "ubuntu"}))
		})
	})

	Describe("the os.conf snapshot", func() {
		It("round-trips, and is empty when missing", func() {
			dir, err := state.Open(filepath.Join(GinkgoT().TempDir(), "riotbox-egress"), "s1")
			Expect(err).NotTo(HaveOccurred())
			Expect(dir.Create()).To(Succeed())
			Expect(dir.OSGroups()).To(BeEmpty())
			groups := []policy.GroupDef{
				{Name: "arch", Members: []policy.Entry{{Host: "geo.mirror.pkgbuild.com", Port: 443}}},
				{Name: "centos", Members: []policy.Entry{{Host: "mirror.stream.centos.org", Port: 443}, {Host: "dl.fedoraproject.org", Port: 443}}},
				{Name: "wild", Members: []policy.Entry{{Host: "*.mirror.example", Port: 443}, {Host: "a.example", Port: 8443}}},
			}
			Expect(dir.WriteOSGroups(groups)).To(Succeed())
			Expect(os.ReadFile(dir.OSConf())).To(Equal([]byte(
				"[group arch]\ngeo.mirror.pkgbuild.com\n[group centos]\nmirror.stream.centos.org\ndl.fedoraproject.org\n[group wild]\n*.mirror.example\na.example:8443\n")))
			got, err := dir.OSGroups()
			Expect(err).NotTo(HaveOccurred())
			Expect(got).To(HaveLen(3))
			Expect(got[1].Members).To(Equal(groups[1].Members))
			Expect(got[2].Members).To(Equal(groups[2].Members))
		})

		It("refuses an os.conf holding anything but groups", func() {
			dir, err := state.Open(filepath.Join(GinkgoT().TempDir(), "riotbox-egress"), "s1")
			Expect(err).NotTo(HaveOccurred())
			Expect(dir.Create()).To(Succeed())
			Expect(os.WriteFile(dir.OSConf(), []byte("a.example\n"), 0o600)).To(Succeed())
			_, err = dir.OSGroups()
			Expect(err).To(MatchError(ContainSubstring(dir.OSConf() + ": only [group] sections")))
		})

		It("refuses an os.conf with a strict setting before a group", func() {
			dir, err := state.Open(filepath.Join(GinkgoT().TempDir(), "riotbox-egress"), "s1")
			Expect(err).NotTo(HaveOccurred())
			Expect(dir.Create()).To(Succeed())
			Expect(os.WriteFile(dir.OSConf(), []byte("strict = on\n[group a]\na.example\n"), 0o600)).To(Succeed())
			_, err = dir.OSGroups()
			Expect(err).To(MatchError(ContainSubstring(dir.OSConf() + ": only [group] sections")))
		})

		It("feeds the session's policy", func() {
			dir, err := state.Open(filepath.Join(GinkgoT().TempDir(), "riotbox-egress"), "s1")
			Expect(err).NotTo(HaveOccurred())
			Expect(dir.Create()).To(Succeed())
			Expect(dir.WriteOSGroups([]policy.GroupDef{{Name: "fedora", Members: []policy.Entry{{Host: "dl.fedoraproject.org", Port: 443}}}})).To(Succeed())
			user := filepath.Join(GinkgoT().TempDir(), "user.conf")
			Expect(os.WriteFile(user, []byte("@fedora\n"), 0o600)).To(Succeed())
			r, err := dir.Policy(filepath.Join(GinkgoT().TempDir(), "none"), user)
			Expect(err).NotTo(HaveOccurred())
			Expect(r.Groups["fedora"].Source).To(Equal(policy.SourceOS))
			Expect(r.Entries).To(ContainElement(policy.Entry{Host: "dl.fedoraproject.org", Port: 443}))
		})
	})
})

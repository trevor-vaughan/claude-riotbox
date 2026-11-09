package policy_test

import (
	"maps"
	"slices"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// conf parses text as the file name.
func conf(name, text string) policy.Conf {
	c, err := policy.ParseFile(name, []byte(text))
	ExpectWithOffset(1, err).NotTo(HaveOccurred())
	return c
}

func hosts(entries []policy.Entry) []string {
	var out []string
	for _, e := range entries {
		out = append(out, e.String())
	}
	return out
}

var _ = Describe("the built-in groups", func() {
	table := policy.Groups(nil, nil, policy.Conf{}, policy.Conf{})

	It("are the documented groups, each built-in and non-empty", func() {
		Expect(slices.Sorted(maps.Keys(table))).To(Equal([]string{
			"agent", "containers", "crates", "docs", "forges", "github", "gitlab", "go",
			"huggingface", "maven", "npm", "os", "pypi", "registries", "rubygems", "search", "wikipedia",
		}))
		for name, g := range table {
			Expect(g.Name).To(Equal(name))
			if name == policy.AgentGroup {
				continue
			}
			if name == "os" {
				Expect(g.Source).To(Equal(policy.SourceBuiltin))
				continue
			}
			Expect(g.Source).To(Equal(policy.SourceBuiltin), name)
			Expect(g.Members).NotTo(BeEmpty(), name)
		}
	})

	It("make @registries exactly the package hosts every session allows outside strict mode", func() {
		Expect(hosts(table["registries"].Members)).To(ConsistOf(
			"registry.npmjs.org", "pypi.org", "files.pythonhosted.org", "proxy.golang.org", "sum.golang.org",
			"vuln.go.dev", "index.crates.io", "static.crates.io", "github.com", "api.github.com",
			"codeload.github.com", "*.githubusercontent.com"))
	})

	It("make @docs exactly the vendor documentation and Q&A sites", func() {
		Expect(hosts(table["docs"].Members)).To(ConsistOf(
			"developer.mozilla.org", "docs.python.org", "go.dev", "pkg.go.dev", "docs.github.com", "docs.rs",
			"stackoverflow.com", "*.stackexchange.com", "*.readthedocs.io"))
	})

	It("make @registries the union of @npm @pypi @go @crates @github", func() {
		var union []policy.Entry
		for _, name := range []string{"npm", "pypi", "go", "crates", "github"} {
			union = append(union, table[name].Members...)
		}
		Expect(table["registries"].Members).To(ConsistOf(union))
	})

	It("make @forges the hosted forges, @github and @gitlab included", func() {
		want := slices.Concat(table["github"].Members, table["gitlab"].Members)
		for _, h := range []string{
			"bitbucket.org", "api.bitbucket.org", "codeberg.org", "gitea.com", "git.sr.ht", "hg.sr.ht",
			"dev.azure.com", "git.launchpad.net", "code.launchpad.net",
		} {
			want = append(want, entry(h, 443))
		}
		Expect(table["forges"].Members).To(ConsistOf(want))
	})

	It("cover the template's container-registry example", func() {
		Expect(hosts(table["containers"].Members)).To(ContainElements(
			"quay.io", "*.quay.io", "registry-1.docker.io", "auth.docker.io", "production.cloudfront.docker.com"))
	})

	It("make @agent the agent's hosts, and nothing without an agent", func() {
		Expect(table[policy.AgentGroup]).To(Equal(policy.Group{Name: "agent", Source: policy.SourceAgent}))
		t := policy.Groups([]policy.Entry{entry("api.agent.example", 443)}, nil, policy.Conf{}, policy.Conf{})
		Expect(t[policy.AgentGroup].Members).To(Equal([]policy.Entry{entry("api.agent.example", 443)}))
	})
})

var _ = Describe("Groups", func() {
	It("lets the system file replace a built-in, and the user file replace the system's", func() {
		sys := conf("sys", "[group npm]\nnpm.sys.example\n[group corp]\ncorp.sys.example\n")
		user := conf("user", "[group corp]\ncorp.user.example\n")
		t := policy.Groups(nil, nil, sys, user)
		Expect(t["npm"]).To(Equal(policy.Group{Name: "npm", Source: policy.SourceSystem, Members: []policy.Entry{entry("npm.sys.example", 443)}}))
		Expect(t["corp"]).To(Equal(policy.Group{Name: "corp", Source: policy.SourceUser, Members: []policy.Entry{entry("corp.user.example", 443)}}))
	})

	It("expands @registries against the final table, so a user's pypi mirror replaces pypi there too", func() {
		t := policy.Groups(nil, nil, policy.Conf{}, conf("user", "[group pypi]\npypi.corp.example\n"))
		Expect(hosts(t["registries"].Members)).To(ContainElement("pypi.corp.example"))
		Expect(hosts(t["registries"].Members)).NotTo(ContainElements("pypi.org", "files.pythonhosted.org"))
		Expect(hosts(t["registries"].Members)).To(ContainElement("registry.npmjs.org"))
	})

	It("lets a user replace @registries itself with hosts", func() {
		t := policy.Groups(nil, nil, policy.Conf{}, conf("user", "[group registries]\nmirror.corp.example\n"))
		Expect(t["registries"]).To(Equal(policy.Group{Name: "registries", Source: policy.SourceUser, Members: []policy.Entry{entry("mirror.corp.example", 443)}}))
	})
})

var _ = Describe("Resolve", func() {
	agent := []policy.Entry{entry("api.agent.example", 443)}

	It("allows exactly @registries and @agent, strict off by default, when no file says anything", func() {
		r, err := policy.Resolve(policy.Sources{Agent: agent})
		Expect(err).NotTo(HaveOccurred())
		want := append(slices.Clone(r.Groups["registries"].Members), agent...)
		Expect(r.Entries).To(ConsistOf(want))
		Expect(r.Entries).To(HaveLen(13))
		Expect(r.Strict).To(BeFalse())
		Expect(r.StrictFrom).To(Equal(policy.SourceDefault))
		Expect(r.StrictLabel()).To(Equal("off (default)"))
	})

	DescribeTable("takes strict from the session, else the user file, else the system file, else off",
		func(sys, user, overlay, label string) {
			r, err := policy.Resolve(policy.Sources{System: conf("sys", sys), User: conf("user", user), Overlay: conf("session", overlay)})
			Expect(err).NotTo(HaveOccurred())
			Expect(r.StrictLabel()).To(Equal(label))
		},
		Entry("the system file alone", "strict\n", "", "", "on (system conf)"),
		Entry("the user file over the system file", "strict\n", "strict = off\n", "", "off (user conf)"),
		Entry("the session over both", "strict = off\n", "strict\n", "strict = off\n", "off (session)"),
		Entry("the session alone", "", "", "strict = on\n", "on (session)"),
		Entry("nothing", "", "", "", "off (default)"),
	)

	It("allows only what the files list when strict is on: not even @registries or @agent", func() {
		r, err := policy.Resolve(policy.Sources{Agent: agent, User: conf("user", "strict\na.example\n")})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).To(Equal([]policy.Entry{entry("a.example", 443)}))
	})

	It("adds every file's entries and groups, then removes every file's removals, whichever file a removal is in", func() {
		r, err := policy.Resolve(policy.Sources{
			System: conf("sys", "a.example\n-b.example\n-@github\n"),
			User:   conf("user", "b.example\n@wikipedia\n"),
		})
		Expect(err).NotTo(HaveOccurred())
		Expect(hosts(r.Entries)).To(ContainElements("a.example", "*.wikipedia.org", "pypi.org"))
		Expect(hosts(r.Entries)).NotTo(ContainElement("b.example"))
		for _, e := range r.Groups["github"].Members {
			Expect(r.Entries).NotTo(ContainElement(e))
		}
	})

	It("lets a user file name a group the system file defines, and the reverse", func() {
		r, err := policy.Resolve(policy.Sources{
			System: conf("sys", "@mine\n[group corp]\ncorp.example\n"),
			User:   conf("user", "@corp\n[group mine]\nmine.example\n"),
		})
		Expect(err).NotTo(HaveOccurred())
		Expect(hosts(r.Entries)).To(ContainElements("corp.example", "mine.example"))
	})

	It("fails on an @ reference to no group, naming the file and line", func() {
		_, err := policy.Resolve(policy.Sources{User: conf("/home/u/.config/riotbox/egress.conf", "a.example\n@nosuch\n")})
		Expect(err).To(MatchError(HavePrefix("/home/u/.config/riotbox/egress.conf:2: no group named @nosuch")))
		_, err = policy.Resolve(policy.Sources{Overlay: conf("session.conf", "-@nosuch\n")})
		Expect(err).To(MatchError(HavePrefix("session.conf:1: no group named @nosuch")))
	})

	It("fails on a group defined in the session overlay", func() {
		_, err := policy.Resolve(policy.Sources{Overlay: conf("session.conf", "[group a]\na.example\n")})
		Expect(err).To(MatchError(HavePrefix("session.conf:1: a session overlay cannot define groups")))
	})

	It("applies the overlay after the files, so it can re-allow what a file removed", func() {
		r, err := policy.Resolve(policy.Sources{System: conf("sys", "-pypi.org\n"), Overlay: conf("session.conf", "pypi.org\n")})
		Expect(err).NotTo(HaveOccurred())
		Expect(hosts(r.Entries)).To(ContainElement("pypi.org"))
	})

	It("applies the overlay in order, so the latest allow or deny of a host wins", func() {
		strict := conf("user", "strict\n")
		r, err := policy.Resolve(policy.Sources{User: strict, Overlay: conf("session.conf", "@pypi\n-pypi.org\n")})
		Expect(err).NotTo(HaveOccurred())
		Expect(hosts(r.Entries)).To(Equal([]string{"files.pythonhosted.org"}))
		r, err = policy.Resolve(policy.Sources{User: strict, Overlay: conf("session.conf", "-pypi.org\n@pypi\n")})
		Expect(err).NotTo(HaveOccurred())
		Expect(hosts(r.Entries)).To(Equal([]string{"files.pythonhosted.org", "pypi.org"}))
	})

	It("removes each member of a group with -@g in the overlay", func() {
		r, err := policy.Resolve(policy.Sources{Overlay: conf("session.conf", "-@npm\n")})
		Expect(err).NotTo(HaveOccurred())
		Expect(hosts(r.Entries)).NotTo(ContainElement("registry.npmjs.org"))
		Expect(hosts(r.Entries)).To(ContainElement("pypi.org"))
	})

	const nvidia = "[inject]\nNVIDIA_API_KEY integrate.api.nvidia.com authorization prefix=Bearer\n"

	It("allows each [inject] row's host on port 443", func() {
		r, err := policy.Resolve(policy.Sources{Agent: agent, User: conf("user", nvidia)})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).To(ContainElement(entry("integrate.api.nvidia.com", 443)))
	})

	It("allows a row's host under strict too, as a line in the file", func() {
		r, err := policy.Resolve(policy.Sources{Agent: agent, System: conf("sys", "strict\n"), User: conf("user", nvidia)})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).To(Equal([]policy.Entry{entry("integrate.api.nvidia.com", 443)}))
	})

	It("allows only the host of the row that survives the user file's replacement", func() {
		r, err := policy.Resolve(policy.Sources{
			System: conf("sys", "strict\n[inject]\nK old.example x-api-key\n"),
			User:   conf("user", "[inject]\nK new.example x-api-key\n"),
		})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).To(Equal([]policy.Entry{entry("new.example", 443)}))
	})

	It("reports the surviving [inject] rows, the user's replacing the system's", func() {
		r, err := policy.Resolve(policy.Sources{
			System: conf("sys", "[inject]\nK old.example x-api-key\n"),
			User:   conf("user", "[inject]\nK new.example x-api-key\n"),
		})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Inject).To(Equal([]policy.InjectRow{{Env: "K", Host: "new.example", Header: "x-api-key", File: "user", Line: 2}}))
	})

	DescribeTable("refuses a row whose host a file removal takes away, at the row's line",
		func(sys, user string) {
			_, err := policy.Resolve(policy.Sources{System: conf("sys", sys), User: conf("user", user)})
			Expect(err).To(MatchError("user:3: integrate.api.nvidia.com is removed from the allowlist, so NVIDIA_API_KEY could not be injected; drop the removal or this row"))
		},
		Entry("in the same file", "", "-integrate.api.nvidia.com\n"+nvidia),
		Entry("in the other file", "-integrate.api.nvidia.com\n", "\n"+nvidia),
		Entry("through a group", "[group nv]\nintegrate.api.nvidia.com\n[allow]\n-@nv\n", "\n"+nvidia),
	)

	It("does not count a wildcard or other-port removal as taking the row's host", func() {
		r, err := policy.Resolve(policy.Sources{User: conf("user", "-*.nvidia.com\n-integrate.api.nvidia.com:8443\n"+nvidia)})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).To(ContainElement(entry("integrate.api.nvidia.com", 443)))
	})

	It("lets a live deny in the overlay block a row's host, without an error", func() {
		r, err := policy.Resolve(policy.Sources{User: conf("user", nvidia), Overlay: conf("session", "-integrate.api.nvidia.com\n")})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).NotTo(ContainElement(entry("integrate.api.nvidia.com", 443)))
	})

	It("refuses an [inject] row in the overlay", func() {
		_, err := policy.Resolve(policy.Sources{Overlay: conf("session", "[inject]\nK a.k.example x-api-key\n")})
		Expect(err).To(MatchError("session:2: a session overlay cannot inject keys"))
	})

	It("refuses two rows for one host, as Providers does", func() {
		_, err := policy.Resolve(policy.Sources{User: conf("user", "[inject]\nMY_KEY api.openai.com authorization\n")})
		Expect(err).To(MatchError(ContainSubstring("user:2: MY_KEY injects a key for api.openai.com")))
	})

	It("does not guard the host of a system row the user file replaced", func() {
		r, err := policy.Resolve(policy.Sources{
			System: conf("sys", "[inject]\nK old.example x-api-key\n"),
			User:   conf("user", "-old.example\n[inject]\nK new.example x-api-key\n"),
		})
		Expect(err).NotTo(HaveOccurred())
		Expect(r.Entries).NotTo(ContainElement(entry("old.example", 443)))
		Expect(r.Entries).To(ContainElement(entry("new.example", 443)))
	})

	Describe("plain HTTP", func() {
		files := func(sys, user string) policy.Sources {
			return policy.Sources{Agent: agent, System: conf("sys", sys), User: conf("user", user), Overlay: conf("session.conf", "")}
		}

		It("allows no plain HTTP when nothing asks for it", func() {
			r, err := policy.Resolve(files("a.example\n", ""))
			Expect(err).NotTo(HaveOccurred())
			Expect(r.AllowPlain).To(BeFalse())
			for _, e := range r.Entries {
				Expect(e.Plain).To(BeFalse(), e.String())
			}
		})

		It("allows an http:// entry exactly, without its tunnel", func() {
			r, err := policy.Resolve(files("strict\nhttp://a.example:8080\n", ""))
			Expect(err).NotTo(HaveOccurred())
			Expect(r.Entries).To(Equal([]policy.Entry{plain("a.example", 8080)}))
		})

		It("adds http://host on port 80 for every tunnel entry when allow_plain is on, wildcards too", func() {
			r, err := policy.Resolve(files("strict\nallow_plain = on\na.example\n*.b.example\nc.example:8443\n", ""))
			Expect(err).NotTo(HaveOccurred())
			Expect(r.AllowPlain).To(BeTrue())
			Expect(r.Entries).To(Equal([]policy.Entry{
				plain("*.b.example", 80), entry("*.b.example", 443),
				plain("a.example", 80), entry("a.example", 443),
				plain("c.example", 80), entry("c.example", 8443),
			}))
		})

		DescribeTable("takes allow_plain from the user file, else the system file, else off",
			func(sys, user string, want bool) {
				r, err := policy.Resolve(files(sys, user))
				Expect(err).NotTo(HaveOccurred())
				Expect(r.AllowPlain).To(Equal(want))
			},
			Entry("neither", "", "", false),
			Entry("system on", "allow_plain = on\n", "", true),
			Entry("user off over system on", "allow_plain = on\n", "allow_plain = off\n", false),
			Entry("user on over system off", "allow_plain = off\n", "allow_plain = on\n", true),
		)

		It("lets a file's -http://host keep one host off plain HTTP under allow_plain", func() {
			r, err := policy.Resolve(files("strict\nallow_plain = on\na.example\nb.example\n", "-http://b.example\n"))
			Expect(err).NotTo(HaveOccurred())
			Expect(r.Entries).To(Equal([]policy.Entry{plain("a.example", 80), entry("a.example", 443), entry("b.example", 443)}))
		})

		It("derives after the overlay, so a live allow or deny of a host covers its plain HTTP too", func() {
			s := files("strict\nallow_plain = on\na.example\n", "")
			s.Overlay = conf("session.conf", "-a.example\nb.example\n")
			r, err := policy.Resolve(s)
			Expect(err).NotTo(HaveOccurred())
			Expect(r.Entries).To(Equal([]policy.Entry{plain("b.example", 80), entry("b.example", 443)}))
		})

		It("lets a live -http://host win over allow_plain", func() {
			s := files("strict\nallow_plain = on\na.example\n", "")
			s.Overlay = conf("session.conf", "-http://a.example\n")
			r, err := policy.Resolve(s)
			Expect(err).NotTo(HaveOccurred())
			Expect(r.Entries).To(Equal([]policy.Entry{entry("a.example", 443)}))
		})

		It("lets a later live allow of the host undo an earlier live -http://host, and not the reverse", func() {
			for _, tc := range []struct {
				overlay string
				want    []policy.Entry
			}{
				{"-http://a.example\na.example\n", []policy.Entry{plain("a.example", 80), entry("a.example", 443)}},
				{"a.example\n-http://a.example\n", []policy.Entry{entry("a.example", 443)}},
				{"-http://a.example\nhttp://a.example\n", []policy.Entry{plain("a.example", 80), entry("a.example", 443)}},
				{"-http://a.example\nb.example\n", []policy.Entry{entry("a.example", 443), plain("b.example", 80), entry("b.example", 443)}},
			} {
				s := files("strict\nallow_plain = on\na.example\n", "")
				s.Overlay = conf("session.conf", tc.overlay)
				r, err := policy.Resolve(s)
				Expect(err).NotTo(HaveOccurred(), tc.overlay)
				Expect(r.Entries).To(Equal(tc.want), tc.overlay)
			}
		})

		It("refuses allow_plain in the session overlay, naming the line", func() {
			s := files("", "")
			s.Overlay = conf("session.conf", "allow_plain = on\n")
			_, err := policy.Resolve(s)
			Expect(err).To(MatchError("session.conf:1: allow_plain is set only in egress.conf, not in a session"))
		})
	})
})

var _ = Describe("Allows", func() {
	entries := []policy.Entry{entry("a.example", 443), entry("*.b.example", 443)}

	It("allows an entry on the list, or under a wildcard on its port", func() {
		Expect(policy.Allows(entries, entry("a.example", 443))).To(BeTrue())
		Expect(policy.Allows(entries, entry("x.b.example", 443))).To(BeTrue())
	})

	It("does not allow another port, the wildcard's bare domain, or an unlisted host", func() {
		Expect(policy.Allows(entries, entry("a.example", 8443))).To(BeFalse())
		Expect(policy.Allows(entries, entry("b.example", 443))).To(BeFalse())
		Expect(policy.Allows(entries, entry("c.example", 443))).To(BeFalse())
	})
})

var _ = Describe("LockoutWarning", func() {
	agent := []policy.Entry{entry("api.agent.example", 443), entry("login.agent.example", 443)}
	resolve := func(user string) policy.Resolved {
		r, err := policy.Resolve(policy.Sources{Agent: agent, User: conf("user", user)})
		ExpectWithOffset(1, err).NotTo(HaveOccurred())
		return r
	}

	It("names the agent hosts strict mode leaves out", func() {
		Expect(resolve("strict\napi.agent.example\n").LockoutWarning()).To(Equal(
			"WARNING: strict mode does not allow the agent's own API hosts (login.agent.example); add @agent"))
		Expect(resolve("strict\n").LockoutWarning()).To(Equal(
			"WARNING: strict mode does not allow the agent's own API hosts (api.agent.example, login.agent.example); add @agent"))
	})

	It("is empty when strict mode allows every agent host, by name or wildcard, and when strict is off", func() {
		Expect(resolve("strict\n@agent\n").LockoutWarning()).To(BeEmpty())
		Expect(resolve("strict\n*.agent.example\n").LockoutWarning()).To(BeEmpty())
		Expect(resolve("-@agent\n").LockoutWarning()).To(BeEmpty())
	})
})

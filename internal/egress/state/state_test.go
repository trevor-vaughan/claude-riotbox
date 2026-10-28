package state_test

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

// syncBuffer lets a spec read what Lock wrote from another goroutine.
type syncBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func mustOpen(root, name string) state.Dir {
	d, err := state.Open(root, name)
	ExpectWithOffset(1, err).NotTo(HaveOccurred())
	return d
}

func perm(path string) os.FileMode {
	info, err := os.Stat(path)
	ExpectWithOffset(1, err).NotTo(HaveOccurred())
	return info.Mode().Perm()
}

var _ = Describe("Open", func() {
	DescribeTable("refuses a name that is not one safe path component",
		func(name string) {
			_, err := state.Open("/r", name)
			Expect(err).To(MatchError(ContainSubstring("is not a session name")))
		},
		Entry("empty", ""),
		Entry("dot", "."),
		Entry("dot-dot", ".."),
		Entry("a slash", "a/b"),
		Entry("a leading dash", "-x"),
		Entry("a space", "a b"),
		Entry("129 characters", strings.Repeat("a", 129)),
	)

	It("lays a session out under root/name", func() {
		d := mustOpen("/r", "riotbox-proj-1a2b3c4d")
		Expect(d.Name()).To(Equal("riotbox-proj-1a2b3c4d"))
		Expect(d.Path()).To(Equal("/r/riotbox-proj-1a2b3c4d"))
		Expect(d.ConfigDir()).To(Equal("/r/riotbox-proj-1a2b3c4d/config"))
		Expect(d.AccessLog()).To(Equal("/r/riotbox-proj-1a2b3c4d/log/access.log"))
		Expect(d.EnvoyLog()).To(Equal("/r/riotbox-proj-1a2b3c4d/log/envoy.log"))
		Expect(d.AgentConf()).To(Equal("/r/riotbox-proj-1a2b3c4d/agent.conf"))
		Expect(d.SessionConf()).To(Equal("/r/riotbox-proj-1a2b3c4d/session.conf"))
	})
})

var _ = Describe("Dir", func() {
	var root string
	var d state.Dir

	BeforeEach(func() {
		root = filepath.Join(GinkgoT().TempDir(), "share", "riotbox-egress")
		d = mustOpen(root, "s1")
	})

	Describe("Create", func() {
		It("makes root, the dir, config and log, each 0700", func() {
			Expect(d.Create()).To(Succeed())
			for _, p := range []string{root, d.Path(), d.ConfigDir(), d.LogDir()} {
				Expect(perm(p)).To(Equal(os.FileMode(0o700)), p)
			}
		})

		It("tightens root, the dir, config and log when they already exist with looser permissions", func() {
			paths := []string{root, d.Path(), d.ConfigDir(), d.LogDir()}
			Expect(os.MkdirAll(d.ConfigDir(), 0o755)).To(Succeed())
			Expect(os.MkdirAll(d.LogDir(), 0o755)).To(Succeed())
			for _, p := range paths {
				Expect(os.Chmod(p, 0o755)).To(Succeed())
			}
			Expect(d.Create()).To(Succeed())
			for _, p := range paths {
				Expect(perm(p)).To(Equal(os.FileMode(0o700)), p)
			}
		})
	})

	Describe("Create refusing planted links", func() {
		for _, which := range []string{"session dir", "config dir", "log dir"} {
			It("refuses a symlink as the "+which, func() {
				Expect(os.MkdirAll(d.Path(), 0o700)).To(Succeed())
				planted := map[string]string{"session dir": d.Path(), "config dir": d.ConfigDir(), "log dir": d.LogDir()}[which]
				target := GinkgoT().TempDir()
				Expect(os.Chmod(target, 0o755)).To(Succeed())
				if which == "session dir" {
					Expect(os.Remove(d.Path())).To(Succeed())
				}
				Expect(os.Symlink(target, planted)).To(Succeed())
				err := d.Create()
				Expect(err).To(MatchError(ContainSubstring(planted)))
				Expect(os.ReadDir(target)).To(BeEmpty())
				Expect(perm(target)).To(Equal(os.FileMode(0o755)), "must not chmod through the link")
			})
		}
	})

	Describe("Policy", func() {
		var sys, user string

		BeforeEach(func() {
			Expect(d.Create()).To(Succeed())
			sys = filepath.Join(GinkgoT().TempDir(), "sys.conf")
			user = filepath.Join(GinkgoT().TempDir(), "user.conf")
		})

		It("is @registries and @agent, strict off, when only the agent's hosts exist", func() {
			Expect(os.WriteFile(d.AgentConf(), []byte("api.agent.example\n"), 0o600)).To(Succeed())
			got, err := d.Policy(sys, user)
			Expect(err).NotTo(HaveOccurred())
			Expect(got.StrictLabel()).To(Equal("off (default)"))
			Expect(got.Entries).To(ContainElements(policy.Entry{Host: "api.agent.example", Port: 443}, policy.Entry{Host: "pypi.org", Port: 443}))
			Expect(got.Entries).To(HaveLen(12))
		})

		It("merges agent, system and user files, then applies the session overlay on top", func() {
			Expect(os.WriteFile(d.AgentConf(), []byte("api.agent.example\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(sys, []byte("sys.example\n-pypi.org\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(user, []byte("user.example\n-api.agent.example\n-sum.golang.org\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(d.SessionConf(), []byte("api.agent.example\nlive.example:8443\n-user.example\n-static.crates.io\n"), 0o600)).To(Succeed())
			// Flat conf files, as every egress.conf was before sections: the
			// allowlist they enforce must not change.
			want := []policy.Entry{
				{Host: "*.githubusercontent.com", Port: 443},
				{Host: "api.agent.example", Port: 443}, // removed by the user conf, re-added by the overlay
				{Host: "api.github.com", Port: 443},
				{Host: "codeload.github.com", Port: 443},
				{Host: "files.pythonhosted.org", Port: 443},
				{Host: "github.com", Port: 443},
				{Host: "index.crates.io", Port: 443},
				{Host: "live.example", Port: 8443},
				{Host: "proxy.golang.org", Port: 443},
				{Host: "registry.npmjs.org", Port: 443},
				{Host: "sys.example", Port: 443},
			}
			got, err := d.Policy(sys, user)
			Expect(err).NotTo(HaveOccurred())
			Expect(got.Entries).To(Equal(want))
			_, err = d.Reload(sys, user)
			Expect(err).NotTo(HaveOccurred())
			Expect(d.Applied()).To(Equal(want))
		})

		It("applies a group's new definition on the next reload", func() {
			Expect(os.WriteFile(user, []byte("strict\n[group corp]\na.corp.example\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(d.SessionConf(), []byte("@corp\n"), 0o600)).To(Succeed())
			_, err := d.Reload(sys, user)
			Expect(err).NotTo(HaveOccurred())
			Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "a.corp.example", Port: 443}}))

			Expect(os.WriteFile(user, []byte("strict\n[group corp]\nb.corp.example\nc.corp.example:8443\n"), 0o600)).To(Succeed())
			_, err = d.Reload(sys, user)
			Expect(err).NotTo(HaveOccurred())
			Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "b.corp.example", Port: 443}, {Host: "c.corp.example", Port: 8443}}))
		})

		It("takes groups and strict from the files and the overlay", func() {
			Expect(os.WriteFile(d.AgentConf(), []byte("api.agent.example\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(sys, []byte("[group corp]\nmirror.corp.example\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(user, []byte("strict\n[allow]\n@corp\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(d.SessionConf(), []byte("@agent\n"), 0o600)).To(Succeed())
			got, err := d.Policy(sys, user)
			Expect(err).NotTo(HaveOccurred())
			Expect(got.StrictLabel()).To(Equal("on (user conf)"))
			Expect(got.Entries).To(Equal([]policy.Entry{{Host: "api.agent.example", Port: 443}, {Host: "mirror.corp.example", Port: 443}}))
		})

		It("reports a bad entry with the file and line", func() {
			Expect(os.WriteFile(user, []byte("ok.example\n10.1.2.3\n"), 0o600)).To(Succeed())
			_, err := d.Policy(sys, user)
			Expect(err).To(MatchError(HavePrefix(user + ":2: invalid egress entry")))
		})

		It("reports anything but a bare host in agent.conf with the file and line", func() {
			Expect(os.WriteFile(d.AgentConf(), []byte("-api.agent.example\n"), 0o600)).To(Succeed())
			_, err := d.Policy(sys, user)
			Expect(err).To(MatchError(HavePrefix(d.AgentConf() + ":1: only host entries are allowed here")))
		})

		It("reports an @ reference to no group with the file and line", func() {
			Expect(os.WriteFile(d.SessionConf(), []byte("@nosuch\n"), 0o600)).To(Succeed())
			_, err := d.Policy(sys, user)
			Expect(err).To(MatchError(HavePrefix(d.SessionConf() + ":1: no group named @nosuch")))
		})

		It("fails, rather than skipping, a conf path it cannot read", func() {
			Expect(os.Mkdir(user, 0o700)).To(Succeed()) // a dir where a file should be
			_, err := d.Policy(sys, user)
			Expect(err).To(HaveOccurred())
		})
	})

	Describe("ReadConf and AgentHosts", func() {
		It("reads a missing conf as an empty one carrying its path, and missing agent hosts as none", func() {
			path := filepath.Join(GinkgoT().TempDir(), "none.conf")
			Expect(state.ReadConf(path)).To(Equal(policy.Conf{Name: path}))
			Expect(d.AgentHosts()).To(BeEmpty())
		})

		It("reads the agent's saved hosts", func() {
			Expect(d.Create()).To(Succeed())
			Expect(os.WriteFile(d.AgentConf(), []byte("api.agent.example\n*.agent.example:8443\n"), 0o600)).To(Succeed())
			Expect(d.AgentHosts()).To(Equal([]policy.Entry{{Host: "api.agent.example", Port: 443}, {Host: "*.agent.example", Port: 8443}}))
		})
	})

	Describe("SetOverlay and SetOverlayStrict", func() {
		BeforeEach(func() { Expect(d.Create()).To(Succeed()) })

		It("keeps one line per entry or group, the latest allow or deny last", func() {
			a := policy.Item{Entry: policy.Entry{Host: "a.example", Port: 443}}
			Expect(d.SetOverlay(a)).To(Succeed())
			Expect(d.SetOverlay(policy.Item{Entry: policy.Entry{Host: "b.example", Port: 8443}})).To(Succeed())
			Expect(d.SetOverlay(policy.Item{Group: "pypi"})).To(Succeed())
			a.Remove = true
			Expect(d.SetOverlay(a)).To(Succeed())
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("b.example:8443\n@pypi\n-a.example\n")))
			Expect(d.SetOverlay(policy.Item{Group: "pypi", Remove: true})).To(Succeed())
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("b.example:8443\n-a.example\n-@pypi\n")))
		})

		It("sets, replaces and clears the strict setting, keeping the lines", func() {
			Expect(d.SetOverlay(policy.Item{Group: "npm"})).To(Succeed())
			Expect(d.SetOverlayStrict(policy.StrictOn)).To(Succeed())
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("strict = on\n@npm\n")))
			Expect(d.SetOverlayStrict(policy.StrictOff)).To(Succeed())
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("strict = off\n@npm\n")))
			Expect(d.SetOverlayStrict(policy.StrictUnset)).To(Succeed())
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("@npm\n")))
		})

		It("leaves an overlay it cannot read as it was, and says why", func() {
			Expect(os.WriteFile(d.SessionConf(), []byte("[bogus]\n"), 0o600)).To(Succeed())
			Expect(d.SetOverlay(policy.Item{Group: "npm"})).To(MatchError(ContainSubstring("unknown section")))
			Expect(d.SetOverlayStrict(policy.StrictOn)).To(MatchError(ContainSubstring("unknown section")))
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("[bogus]\n")))
		})
	})

	Describe("WriteConfig, Reload and Applied", func() {
		BeforeEach(func() { Expect(d.Create()).To(Succeed()) })

		It("has applied nothing before any config is written", func() {
			Expect(d.Applied()).To(BeEmpty())
			Expect(d.AppliedStrict()).To(BeEmpty())
		})

		It("writes the four Envoy files, 0600, and records what was applied", func() {
			r := policy.Resolved{Entries: []policy.Entry{{Host: "a.example", Port: 443}}, Strict: true, StrictFrom: policy.SourceUser}
			Expect(d.WriteConfig(r)).To(Succeed())
			for _, name := range []string{"bootstrap.json", "cds.json", "lds.json", "rds.json"} {
				Expect(perm(filepath.Join(d.ConfigDir(), name))).To(Equal(os.FileMode(0o600)), name)
			}
			Expect(d.Applied()).To(Equal(r.Entries))
			Expect(d.AppliedStrict()).To(Equal("on (user conf)"))
			Expect(perm(filepath.Join(d.Path(), "applied-strict"))).To(Equal(os.FileMode(0o600)))
		})

		It("rewrites only rds.json on reload, and returns the new policy", func() {
			Expect(d.WriteConfig(policy.Resolved{StrictFrom: policy.SourceDefault})).To(Succeed())
			lds := filepath.Join(d.ConfigDir(), "lds.json")
			before, err := os.Stat(lds)
			Expect(err).NotTo(HaveOccurred())
			Expect(os.WriteFile(d.SessionConf(), []byte("strict = on\nnew.example\n"), 0o600)).To(Succeed())
			got, err := d.Reload("/nonexistent/sys", "/nonexistent/user")
			Expect(err).NotTo(HaveOccurred())
			Expect(got.Entries).To(Equal([]policy.Entry{{Host: "new.example", Port: 443}}))
			rds, err := os.ReadFile(filepath.Join(d.ConfigDir(), "rds.json"))
			Expect(err).NotTo(HaveOccurred())
			Expect(string(rds)).To(ContainSubstring(`"new.example:443"`))
			after, err := os.Stat(lds)
			Expect(err).NotTo(HaveOccurred())
			Expect(os.SameFile(before, after)).To(BeTrue(), "lds.json must not be replaced")
			Expect(d.Applied()).To(Equal(got.Entries))
			Expect(d.AppliedStrict()).To(Equal("on (session)"))
		})

		It("fails a reload of an unreadable overlay without touching rds.json", func() {
			Expect(d.WriteConfig(policy.Resolved{StrictFrom: policy.SourceDefault})).To(Succeed())
			rds := filepath.Join(d.ConfigDir(), "rds.json")
			before, err := os.ReadFile(rds)
			Expect(err).NotTo(HaveOccurred())
			Expect(os.WriteFile(d.SessionConf(), []byte("@nosuch\n"), 0o600)).To(Succeed())
			_, err = d.Reload("/nonexistent/sys", "/nonexistent/user")
			Expect(err).To(MatchError(ContainSubstring("no group named @nosuch")))
			Expect(os.ReadFile(rds)).To(Equal(before))
		})

		It("leaves no temporary files behind", func() {
			Expect(d.WriteConfig(policy.Resolved{StrictFrom: policy.SourceDefault})).To(Succeed())
			_, err := d.Reload("/nonexistent/sys", "/nonexistent/user")
			Expect(err).NotTo(HaveOccurred())
			names, err := os.ReadDir(d.ConfigDir())
			Expect(err).NotTo(HaveOccurred())
			for _, n := range names {
				Expect(n.Name()).NotTo(HavePrefix("."), n.Name())
			}
		})
	})

	Describe("WriteProjects and Projects", func() {
		BeforeEach(func() { Expect(d.Create()).To(Succeed()) })

		It("reads back the project dirs written, in order, from a 0600 file in the session dir", func() {
			dirs := []string{"/home/u/b", "/home/u/a"}
			Expect(d.WriteProjects(dirs)).To(Succeed())
			Expect(d.Projects()).To(Equal(dirs))
			Expect(perm(filepath.Join(d.Path(), "projects.json"))).To(Equal(os.FileMode(0o600)))
		})

		It("keeps a path holding a newline or a control character whole", func() {
			dirs := []string{"/p/a\nb", "/p/\x1b[31mred"}
			Expect(d.WriteProjects(dirs)).To(Succeed())
			Expect(d.Projects()).To(Equal(dirs))
		})

		It("reads a session that recorded none, as an older release's, as none", func() {
			got, err := d.Projects()
			Expect(err).NotTo(HaveOccurred())
			Expect(got).To(BeEmpty())
		})

		It("fails on a file that is not a JSON list of paths", func() {
			Expect(os.WriteFile(filepath.Join(d.Path(), "projects.json"), []byte(`{"a":1}`), 0o600)).To(Succeed())
			_, err := d.Projects()
			Expect(err).To(MatchError(ContainSubstring("projects.json")))
		})

		It("says which file it was reading when the file cannot be read", func() {
			path := filepath.Join(d.Path(), "projects.json")
			Expect(os.Mkdir(path, 0o700)).To(Succeed())
			_, err := d.Projects()
			Expect(err).To(MatchError(HavePrefix("reading " + display.Quote(path) + ": ")))
		})
	})

	Describe("EnvoyLogTail", func() {
		BeforeEach(func() { Expect(d.Create()).To(Succeed()) })

		It("returns the log", func() {
			Expect(os.WriteFile(d.EnvoyLog(), []byte("hello\n"), 0o600)).To(Succeed())
			Expect(d.EnvoyLogTail()).To(Equal([]byte("hello\n")))
		})

		It("returns only the last 1 MiB of a larger log", func() {
			big := append(bytes.Repeat([]byte("a"), 1<<20), bytes.Repeat([]byte("b"), 1<<20)...)
			Expect(os.WriteFile(d.EnvoyLog(), big, 0o600)).To(Succeed())
			got, err := d.EnvoyLogTail()
			Expect(err).NotTo(HaveOccurred())
			Expect(got).To(Equal(bytes.Repeat([]byte("b"), 1<<20)))
		})

		It("is empty, without error, when there is no log yet", func() {
			got, err := d.EnvoyLogTail()
			Expect(err).NotTo(HaveOccurred())
			Expect(got).To(BeEmpty())
		})

		It("refuses a symlink, without reading its target", func() {
			target := filepath.Join(GinkgoT().TempDir(), "target")
			Expect(os.WriteFile(target, []byte("secret"), 0o600)).To(Succeed())
			Expect(os.Symlink(target, d.EnvoyLog())).To(Succeed())
			got, err := d.EnvoyLogTail()
			Expect(err).To(MatchError(ContainSubstring(d.EnvoyLog())))
			Expect(got).To(BeEmpty())
		})

		It("refuses a FIFO promptly instead of hanging", func() {
			Expect(syscall.Mkfifo(d.EnvoyLog(), 0o600)).To(Succeed())
			errc := make(chan error, 1)
			go func() {
				_, err := d.EnvoyLogTail()
				errc <- err
			}()
			var err error
			Eventually(errc, 2*time.Second).Should(Receive(&err))
			Expect(err).To(MatchError(ContainSubstring(d.EnvoyLog())))
		})
	})

	Describe("Remove", func() {
		It("removes only a symlinked session dir's link, not its target", func() {
			Expect(os.MkdirAll(root, 0o700)).To(Succeed())
			target := GinkgoT().TempDir()
			Expect(os.WriteFile(filepath.Join(target, "keep"), []byte("x"), 0o600)).To(Succeed())
			Expect(os.Symlink(target, d.Path())).To(Succeed())
			Expect(d.Remove()).To(Succeed())
			Expect(d.Path()).NotTo(BeAnExistingFile())
			Expect(filepath.Join(target, "keep")).To(BeARegularFile())
		})
	})

	Describe("Lock", func() {
		It("takes the session's lock file", func() {
			Expect(d.Create()).To(Succeed())
			release, err := d.Lock(GinkgoWriter)
			Expect(err).NotTo(HaveOccurred())
			Expect(filepath.Join(d.Path(), ".lock")).To(BeARegularFile())
			Expect(release()).To(Succeed())
		})

		It("makes a second holder wait, saying so, until the first releases", func() {
			Expect(d.Create()).To(Succeed())
			firstRelease, err := d.Lock(GinkgoWriter)
			Expect(err).NotTo(HaveOccurred())
			var once sync.Once
			first := func() (err error) {
				once.Do(func() { err = firstRelease() })
				return err
			}
			DeferCleanup(first) // a failed assertion must not leave the goroutine blocked
			var out syncBuffer
			acquired := make(chan func() error, 1)
			go func() {
				defer GinkgoRecover()
				second, err := d.Lock(&out)
				Expect(err).NotTo(HaveOccurred())
				acquired <- second
			}()
			Eventually(out.String, 10*time.Second).Should(ContainSubstring("s1"))
			Consistently(acquired, 300*time.Millisecond).ShouldNot(Receive())
			Expect(first()).To(Succeed())
			var second func() error
			Eventually(acquired, 10*time.Second).Should(Receive(&second))
			Expect(second()).To(Succeed())
		})
	})
})

var _ = Describe("WriteAtomic", func() {
	It("replaces the file whole, mode 0600", func() {
		path := filepath.Join(GinkgoT().TempDir(), "f.json")
		Expect(os.WriteFile(path, []byte("old"), 0o644)).To(Succeed())
		Expect(state.WriteAtomic(path, []byte("new"))).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("new")))
		Expect(perm(path)).To(Equal(os.FileMode(0o600)))
	})

	It("fails, leaving nothing, when the directory is missing", func() {
		dir := filepath.Join(GinkgoT().TempDir(), "missing")
		Expect(state.WriteAtomic(filepath.Join(dir, "f"), []byte("x"))).NotTo(Succeed())
		Expect(dir).NotTo(BeADirectory())
	})

	It("removes its temporary file when the rename fails", func() {
		parent := GinkgoT().TempDir()
		path := filepath.Join(parent, "f.json")
		Expect(os.MkdirAll(filepath.Join(path, "x"), 0o700)).To(Succeed())
		Expect(state.WriteAtomic(path, []byte("x"))).NotTo(Succeed())
		left, err := filepath.Glob(filepath.Join(parent, ".*.tmp-*"))
		Expect(err).NotTo(HaveOccurred())
		Expect(left).To(BeEmpty())
	})
})

var _ = Describe("SaveItem", func() {
	var path string
	a := policy.Item{Entry: policy.Entry{Host: "a.example", Port: 443}}
	denyA := policy.Item{Entry: a.Entry, Remove: true}
	denyB := policy.Item{Entry: policy.Entry{Host: "b.example", Port: 443}, Remove: true}

	write := func(text string) {
		ExpectWithOffset(1, os.MkdirAll(filepath.Dir(path), 0o700)).To(Succeed())
		ExpectWithOffset(1, os.WriteFile(path, []byte(text), 0o600)).To(Succeed())
	}

	BeforeEach(func() { path = filepath.Join(GinkgoT().TempDir(), "riotbox", "egress.conf") })

	It("creates the file 0600, as a bare line with no section, and its parent dir 0700", func() {
		Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("a.example\n")))
		Expect(perm(path)).To(Equal(os.FileMode(0o600)))
		Expect(perm(filepath.Dir(path))).To(Equal(os.FileMode(0o700)))
	})

	It("saves a removal and a group as the conf grammar spells them", func() {
		Expect(state.SaveItem(path, denyA, GinkgoWriter)).To(Succeed())
		Expect(state.SaveItem(path, policy.Item{Group: "npm", Remove: true}, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("-a.example\n-@npm\n")))
	})

	It("starts a new line when the file does not end with one, keeping the rest verbatim", func() {
		write("# mine\n  old.example  # why\n\nnot an entry\nc.example")
		Expect(state.SaveItem(path, denyB, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("# mine\n  old.example  # why\n\nnot an entry\nc.example\n-b.example\n")))
	})

	It("replaces an earlier line for the same entry of either sign, so it appears once", func() {
		write("a.example\nb.example\n -a.example # no\n")
		Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("b.example\na.example # no\n")))
	})

	It("replaces an earlier line for the same group, and leaves an entry of another kind alone", func() {
		write("@npm\nnpm.example\n")
		Expect(state.SaveItem(path, policy.Item{Group: "npm", Remove: true}, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("npm.example\n-@npm\n")))
	})

	It("keeps the trailing comment of the line it replaces", func() {
		write("a.example  # why\n")
		Expect(state.SaveItem(path, denyA, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("-a.example  # why\n")))
	})

	It("replaces lines in the preamble and in any [allow] section, and appends to the last [allow] section", func() {
		write("strict\na.example\n" +
			"[allow]\n-a.example # old\nx.example\n\n" +
			"[group corp]\na.example\n" +
			"[allow]\ny.example\n\n# trailing note\n" +
			"[group last]\nl.example\n")
		Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("strict\n" +
			"[allow]\nx.example\n\n" +
			"[group corp]\na.example\n" +
			"[allow]\ny.example\na.example # old\n\n# trailing note\n" +
			"[group last]\nl.example\n")))
	})

	It("appends right after the header of an empty last [allow] section", func() {
		write("[allow]\n# nothing yet\n")
		Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("[allow]\na.example\n# nothing yet\n")))
	})

	DescribeTable("inserts into the only [allow] section when it holds just comments and blanks, adding no second header",
		func(before, after string) {
			write(before)
			Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
			Expect(os.ReadFile(path)).To(Equal([]byte(after)))
			Expect(strings.Count(after, "[allow]")).To(Equal(1))
			_, err := state.ReadConf(path)
			Expect(err).NotTo(HaveOccurred())
		},
		Entry("before a group", "[allow]\n# mine\n\n[group corp]\ncorp.example\n", "[allow]\na.example\n# mine\n\n[group corp]\ncorp.example\n"),
		Entry("after a group", "[group corp]\ncorp.example\n[allow]\n\n# later\n", "[group corp]\ncorp.example\n[allow]\na.example\n\n# later\n"),
		Entry("with a comment on its header", "strict\n[allow] # hosts\n\n", "strict\n[allow] # hosts\na.example\n\n"),
	)

	It("adds an [allow] section to a file that has only groups", func() {
		write("[group corp]\ncorp.example\n")
		Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
		Expect(os.ReadFile(path)).To(Equal([]byte("[group corp]\ncorp.example\n\n[allow]\na.example\n")))
		_, err := state.ReadConf(path)
		Expect(err).NotTo(HaveOccurred())
	})

	It("keeps an existing file's permissions", func() {
		write("b.example\n")
		Expect(os.Chmod(path, 0o640)).To(Succeed())
		Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
		Expect(perm(path)).To(Equal(os.FileMode(0o640)))
	})

	It("writes through a symlinked conf file, leaving the link in place", func() {
		dir := filepath.Dir(path)
		real := filepath.Join(GinkgoT().TempDir(), "real.conf")
		Expect(os.MkdirAll(dir, 0o700)).To(Succeed())
		Expect(os.WriteFile(real, []byte("b.example\n"), 0o600)).To(Succeed())
		Expect(os.Symlink(real, path)).To(Succeed())
		Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
		info, err := os.Lstat(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode() & os.ModeSymlink).NotTo(BeZero())
		Expect(os.ReadFile(real)).To(Equal([]byte("b.example\na.example\n")))
	})

	It("loses no entry when saves to one file run concurrently", func() {
		const each = 50
		var wg sync.WaitGroup
		for _, prefix := range []string{"one", "two"} {
			wg.Add(1)
			go func() {
				defer GinkgoRecover()
				defer wg.Done()
				for i := range each {
					it := policy.Item{Entry: policy.Entry{Host: fmt.Sprintf("%s%d.example", prefix, i), Port: 443}}
					Expect(state.SaveItem(path, it, GinkgoWriter)).To(Succeed())
				}
			}()
		}
		wg.Wait()
		c, err := state.ReadConf(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Items).To(HaveLen(2 * each))
	})

	It("makes a deny-save then an allow-save of one entry add it", func() {
		Expect(state.SaveItem(path, denyA, GinkgoWriter)).To(Succeed())
		Expect(state.SaveItem(path, a, GinkgoWriter)).To(Succeed())
		c, err := state.ReadConf(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Items).To(Equal([]policy.Item{{Entry: a.Entry, Line: 1}}))
	})
})

var _ = Describe("SaveStrict", func() {
	var path string

	write := func(text string) {
		ExpectWithOffset(1, os.MkdirAll(filepath.Dir(path), 0o700)).To(Succeed())
		ExpectWithOffset(1, os.WriteFile(path, []byte(text), 0o600)).To(Succeed())
	}

	BeforeEach(func() { path = filepath.Join(GinkgoT().TempDir(), "riotbox", "egress.conf") })

	It("creates the file with the setting", func() {
		Expect(state.SaveStrict(path, policy.StrictOn, GinkgoWriter)).To(BeTrue())
		Expect(os.ReadFile(path)).To(Equal([]byte("strict = on\n")))
		Expect(perm(path)).To(Equal(os.FileMode(0o600)))
	})

	It("puts a new setting after the leading comments, still in the preamble", func() {
		write("# my egress.conf\n\n# more\na.example\n[allow]\nb.example\n")
		Expect(state.SaveStrict(path, policy.StrictOff, GinkgoWriter)).To(BeTrue())
		Expect(os.ReadFile(path)).To(Equal([]byte("# my egress.conf\n\n# more\nstrict = off\na.example\n[allow]\nb.example\n")))
		c, err := state.ReadConf(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(c.Strict).To(Equal(policy.StrictOff))
	})

	It("replaces every strict line in place of the first, keeping its comment", func() {
		write("a.example\nstrict  # mine\nstrict = off\n[allow]\nb.example\n")
		Expect(state.SaveStrict(path, policy.StrictOff, GinkgoWriter)).To(BeTrue())
		Expect(os.ReadFile(path)).To(Equal([]byte("a.example\nstrict = off  # mine\n[allow]\nb.example\n")))
	})

	It("removes the setting on clear, and reports nothing to remove", func() {
		write("strict = on\na.example\n")
		Expect(state.SaveStrict(path, policy.StrictUnset, GinkgoWriter)).To(BeTrue())
		Expect(os.ReadFile(path)).To(Equal([]byte("a.example\n")))
		Expect(state.SaveStrict(path, policy.StrictUnset, GinkgoWriter)).To(BeFalse())
		Expect(os.ReadFile(path)).To(Equal([]byte("a.example\n")))
	})

	It("does not create a missing file to clear it", func() {
		Expect(state.SaveStrict(path, policy.StrictUnset, GinkgoWriter)).To(BeFalse())
		Expect(path).NotTo(BeAnExistingFile())
		Expect(filepath.Dir(path)).NotTo(BeADirectory())
	})

	It("leaves a strict line inside a section alone, setting strict in the preamble", func() {
		write("[allow]\nstrict = on\n")
		Expect(state.SaveStrict(path, policy.StrictOn, GinkgoWriter)).To(BeTrue())
		Expect(os.ReadFile(path)).To(Equal([]byte("strict = on\n[allow]\nstrict = on\n")))
	})

	It("leaves a host that starts with strict alone", func() {
		write("[allow]\nstrict.example.com\n")
		Expect(state.SaveStrict(path, policy.StrictOn, GinkgoWriter)).To(BeTrue())
		Expect(os.ReadFile(path)).To(Equal([]byte("strict = on\n[allow]\nstrict.example.com\n")))
	})
})

var _ = Describe("CountDenied", func() {
	var path string

	BeforeEach(func() { path = filepath.Join(GinkgoT().TempDir(), "access.log") })

	It("counts none for a missing log", func() {
		Expect(state.CountDenied(path)).To(Equal(0))
	})

	It("counts the 403s", func() {
		Expect(os.WriteFile(path, []byte(`{"status":200,"authority":"a:443"}`+"\n"+`{"status":403,"authority":"b:443"}`+"\n\n"+`{"status":403,"authority":"c"}`+"\n"), 0o600)).To(Succeed())
		Expect(state.CountDenied(path)).To(Equal(2))
	})

	It("names a terminated line it cannot read", func() {
		Expect(os.WriteFile(path, []byte(`{"status":403}`+"\n"+`{"status":`+"\n"), 0o600)).To(Succeed())
		_, err := state.CountDenied(path)
		Expect(err).To(MatchError(HavePrefix(path + ":2: ")))
	})

	It("skips an unterminated final line, which Envoy was killed while writing", func() {
		Expect(os.WriteFile(path, []byte(`{"status":403}`+"\n"+`{"status":`), 0o600)).To(Succeed())
		Expect(state.CountDenied(path)).To(Equal(1))
	})

	It("counts an unterminated final line that is whole", func() {
		Expect(os.WriteFile(path, []byte(`{"status":403}`+"\n"+`{"status":403}`), 0o600)).To(Succeed())
		Expect(state.CountDenied(path)).To(Equal(2))
	})

	It("names a line whose status is not an integer", func() {
		Expect(os.WriteFile(path, []byte(`{"status":"403"}`+"\n"), 0o600)).To(Succeed())
		_, err := state.CountDenied(path)
		Expect(err).To(MatchError(HavePrefix(path + ":1: ")))
	})

	It("refuses a line over 1 MiB rather than buffering it", func() {
		long := `{"status":403,"pad":"` + strings.Repeat("a", 1<<20) + `"}` + "\n"
		Expect(os.WriteFile(path, []byte(long), 0o600)).To(Succeed())
		_, err := state.CountDenied(path)
		Expect(err).To(MatchError(HavePrefix(path + ":1: ")))
	})

	It("refuses a symlink, without reading its target", func() {
		target := filepath.Join(GinkgoT().TempDir(), "target")
		Expect(os.WriteFile(target, []byte(`{"status":403}`+"\n"), 0o600)).To(Succeed())
		Expect(os.Symlink(target, path)).To(Succeed())
		_, err := state.CountDenied(path)
		Expect(err).To(MatchError(ContainSubstring(path)))
	})

	It("refuses a FIFO promptly instead of hanging", func() {
		Expect(syscall.Mkfifo(path, 0o600)).To(Succeed())
		errc := make(chan error, 1)
		go func() {
			_, err := state.CountDenied(path)
			errc <- err
		}()
		var err error
		Eventually(errc, 2*time.Second).Should(Receive(&err))
		Expect(err).To(MatchError(ContainSubstring(path)))
	})
})

var _ = Describe("Stale", func() {
	var root string
	now := time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)
	week := 7 * 24 * time.Hour

	age := func(path string, d time.Duration) {
		t := now.Add(-d)
		ExpectWithOffset(1, os.Chtimes(path, t, t)).To(Succeed())
	}

	BeforeEach(func() { root = GinkgoT().TempDir() })

	It("finds unused dirs whose Envoy log, else the dir itself, is older than maxAge", func() {
		for _, name := range []string{"old-logged", "old-bare", "fresh", "live"} {
			Expect(mustOpen(root, name).Create()).To(Succeed())
		}
		Expect(os.WriteFile(mustOpen(root, "old-logged").EnvoyLog(), nil, 0o600)).To(Succeed())
		age(mustOpen(root, "old-logged").EnvoyLog(), 8*24*time.Hour)
		age(mustOpen(root, "old-bare").Path(), 8*24*time.Hour)
		age(mustOpen(root, "fresh").Path(), time.Hour)
		age(mustOpen(root, "live").Path(), 30*24*time.Hour)
		got, err := state.Stale(root, map[string]bool{"live": true}, week, now)
		Expect(err).NotTo(HaveOccurred())
		Expect(got).To(ConsistOf("old-logged", "old-bare"))
	})

	It("reports the other stale sessions, and an error, when one session cannot be examined", func() {
		if os.Geteuid() == 0 {
			Skip("root reads a mode-000 dir")
		}
		for _, name := range []string{"unreadable", "old"} {
			Expect(mustOpen(root, name).Create()).To(Succeed())
			age(mustOpen(root, name).Path(), 30*24*time.Hour)
		}
		bad := mustOpen(root, "unreadable")
		Expect(os.Chmod(bad.LogDir(), 0o000)).To(Succeed())
		DeferCleanup(func() { _ = os.Chmod(bad.LogDir(), 0o700) })
		got, err := state.Stale(root, nil, week, now)
		Expect(err).To(HaveOccurred())
		Expect(got).To(ContainElement("old"))
	})

	It("ignores an envoy.log that is not a regular file, using the dir's age", func() {
		d := mustOpen(root, "linked")
		Expect(d.Create()).To(Succeed())
		Expect(os.Symlink("/dev/null", d.EnvoyLog())).To(Succeed())
		age(d.Path(), 30*24*time.Hour)
		got, err := state.Stale(root, nil, week, now)
		Expect(err).NotTo(HaveOccurred())
		Expect(got).To(ConsistOf("linked"))
	})

	It("does not report a live name that has no dir", func() {
		got, err := state.Stale(root, map[string]bool{"ghost": true}, week, now)
		Expect(err).NotTo(HaveOccurred())
		Expect(got).To(BeEmpty())
	})

	It("ignores symlinks and invalid names, and a missing root", func() {
		Expect(os.Symlink("/", filepath.Join(root, "link"))).To(Succeed())
		Expect(os.Mkdir(filepath.Join(root, "-bad"), 0o700)).To(Succeed())
		age(filepath.Join(root, "-bad"), 30*24*time.Hour)
		Expect(state.Stale(root, nil, week, now)).To(BeEmpty())
		Expect(state.Stale(filepath.Join(root, "nope"), nil, week, now)).To(BeEmpty())
	})
})

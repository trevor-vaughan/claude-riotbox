package state_test

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

var _ = Describe("RuntimeBase", func() {
	var (
		tmp, xdg, runUser, systemd string
		env                        map[string]string
		tmpfs                      map[string]bool
		host                       state.RuntimeHost
	)
	uid := os.Getuid()

	BeforeEach(func() {
		tmp = GinkgoT().TempDir()
		xdg = filepath.Join(tmp, "xdg")
		runUser = filepath.Join(tmp, "run-user")
		systemd = filepath.Join(runUser, strconv.Itoa(uid))
		for _, d := range []string{xdg, systemd} {
			Expect(os.MkdirAll(d, 0o700)).To(Succeed())
			Expect(os.Chmod(d, 0o700)).To(Succeed())
		}
		env = map[string]string{"XDG_RUNTIME_DIR": xdg}
		tmpfs = map[string]bool{xdg: true, systemd: true}
		host = state.RuntimeHost{
			Getenv:  func(k string) string { return env[k] },
			UID:     uid,
			RunUser: runUser,
			IsTmpfs: func(p string) (bool, error) { return tmpfs[p], nil },
		}
	})

	It("is riotbox-egress under $XDG_RUNTIME_DIR when that is private tmpfs", func() {
		Expect(state.RuntimeBase(host)).To(Equal(filepath.Join(xdg, "riotbox-egress")))
	})

	DescribeTable("falls back to /run/user/<uid> when $XDG_RUNTIME_DIR does not qualify, saying nothing",
		func(spoil func()) {
			spoil()
			Expect(state.RuntimeBase(host)).To(Equal(filepath.Join(systemd, "riotbox-egress")))
		},
		Entry("unset", func() { delete(env, "XDG_RUNTIME_DIR") }),
		Entry("relative", func() { env["XDG_RUNTIME_DIR"] = "run/xdg" }),
		Entry("missing", func() { env["XDG_RUNTIME_DIR"] = filepath.Join(tmp, "absent") }),
		Entry("group-readable", func() { Expect(os.Chmod(xdg, 0o750)).To(Succeed()) }),
		Entry("not on tmpfs", func() { tmpfs[xdg] = false }),
	)

	It("follows a $XDG_RUNTIME_DIR that is a link to a private tmpfs dir", func() {
		link := filepath.Join(tmp, "link")
		Expect(os.Symlink(xdg, link)).To(Succeed())
		env["XDG_RUNTIME_DIR"] = link
		tmpfs[link] = true
		Expect(state.RuntimeBase(host)).To(Equal(filepath.Join(link, "riotbox-egress")))
	})

	DescribeTable("fails, saying what to do and why each candidate was refused, when neither qualifies",
		func(spoil func(), why ...string) {
			spoil()
			base, err := state.RuntimeBase(host)
			Expect(base).To(BeEmpty())
			Expect(err).To(MatchError(state.ErrNoRuntimeDir))
			Expect(err).To(MatchError(ContainSubstring("credential injection needs a private tmpfs runtime dir ($XDG_RUNTIME_DIR or /run/user/<uid>) so keys never reach disk; none found")))
			Expect(err).To(MatchError(ContainSubstring("unset the keys to run without injection, or start the session from a login session")))
			for _, w := range why {
				Expect(err).To(MatchError(ContainSubstring(w)))
			}
		},
		Entry("both missing", func() {
			delete(env, "XDG_RUNTIME_DIR")
			Expect(os.Remove(systemd)).To(Succeed())
		}, "$XDG_RUNTIME_DIR is unset", "does not exist"),
		Entry("a relative $XDG_RUNTIME_DIR and a world-readable /run/user/<uid>", func() {
			env["XDG_RUNTIME_DIR"] = "rel"
			Expect(os.Chmod(systemd, 0o755)).To(Succeed())
		}, "$XDG_RUNTIME_DIR is not an absolute path", "is mode 0755, not 0700"),
		Entry("neither on tmpfs", func() {
			tmpfs = map[string]bool{}
		}, "is not on tmpfs"),
		Entry("both owned by another uid", func() {
			host.UID = uid + 1
			Expect(os.Rename(systemd, filepath.Join(runUser, strconv.Itoa(uid+1)))).To(Succeed())
			tmpfs[filepath.Join(runUser, strconv.Itoa(uid+1))] = true
		}, "is owned by uid "+strconv.Itoa(uid)+", not "+strconv.Itoa(uid+1)),
		Entry("files, not dirs", func() {
			Expect(os.Remove(xdg)).To(Succeed())
			Expect(os.WriteFile(xdg, nil, 0o700)).To(Succeed())
			Expect(os.Remove(systemd)).To(Succeed())
			Expect(os.WriteFile(systemd, nil, 0o700)).To(Succeed())
		}, "is not a directory"),
	)

	It("fails when the filesystem cannot be identified, saying why", func() {
		host.IsTmpfs = func(string) (bool, error) { return false, errors.New("statfs: boom") }
		_, err := state.RuntimeBase(host)
		Expect(err).To(MatchError(state.ErrNoRuntimeDir))
		Expect(err).To(MatchError(ContainSubstring("statfs: boom")))
	})

	Describe("RuntimeBases", func() {
		It("is riotbox-egress under each candidate that qualifies, $XDG_RUNTIME_DIR first", func() {
			Expect(state.RuntimeBases(host)).To(Equal([]string{
				filepath.Join(xdg, "riotbox-egress"), filepath.Join(systemd, "riotbox-egress"),
			}))
		})

		It("leaves out a candidate that does not qualify", func() {
			Expect(os.Chmod(xdg, 0o755)).To(Succeed())
			Expect(state.RuntimeBases(host)).To(Equal([]string{filepath.Join(systemd, "riotbox-egress")}))
			tmpfs[systemd] = false
			Expect(state.RuntimeBases(host)).To(BeEmpty())
		})

		It("names a dir once when $XDG_RUNTIME_DIR is /run/user/<uid>", func() {
			env["XDG_RUNTIME_DIR"] = systemd + "/"
			Expect(state.RuntimeBases(host)).To(Equal([]string{filepath.Join(systemd, "riotbox-egress")}))
		})
	})

	Describe("HostRuntime", func() {
		It("reads this process's environment and uid, and /run/user", func() {
			h := state.HostRuntime()
			Expect(h.UID).To(Equal(uid))
			Expect(h.RunUser).To(Equal("/run/user"))
			GinkgoT().Setenv("XDG_RUNTIME_DIR", "/x")
			Expect(h.Getenv("XDG_RUNTIME_DIR")).To(Equal("/x"))
		})

		It("tells tmpfs from other filesystems", func() {
			if ok, err := state.HostRuntime().IsTmpfs("/dev/shm"); err != nil || !ok {
				Skip("no tmpfs at /dev/shm here")
			}
			Expect(state.HostRuntime().IsTmpfs("/proc")).To(BeFalse())
			_, err := state.HostRuntime().IsTmpfs(filepath.Join(tmp, "absent"))
			Expect(err).To(HaveOccurred())
		})
	})
})

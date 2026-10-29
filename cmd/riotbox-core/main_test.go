package main_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"

	"github.com/trevor-vaughan/claude-riotbox/internal/sessionkey"
)

func run(args ...string) *gexec.Session {
	session, err := gexec.Start(exec.Command(binary, args...), GinkgoWriter, GinkgoWriter)
	Expect(err).NotTo(HaveOccurred())
	Eventually(session).Should(gexec.Exit())
	return session
}

var _ = Describe("riotbox-core", func() {
	It("prints the version baked in at build time", func() {
		s := run("version")
		Expect(s.ExitCode()).To(Equal(0))
		Expect(string(s.Out.Contents())).To(Equal("9.9.9-test\n"))
		Expect(s.Err.Contents()).To(BeEmpty())
	})

	It("prints the session key of a set", func() {
		s := run("session-key", "/home/me/b", "/home/me/a")
		Expect(s.ExitCode()).To(Equal(0))
		Expect(string(s.Out.Contents())).To(Equal(sessionkey.Key([]string{"/home/me/a", "/home/me/b"}) + "\n"))
		Expect(s.Err.Contents()).To(BeEmpty())
	})

	It("reads every argument after -- as a positional, even one that starts with a dash", func() {
		s := run("session-key", "--", "-a", "--")
		Expect(s.ExitCode()).To(Equal(0))
		Expect(string(s.Out.Contents())).To(Equal(sessionkey.Key([]string{"-a", "--"}) + "\n"))
		Expect(s.Err.Contents()).To(BeEmpty())
	})

	It("prints a set's identity as three lines", func() {
		s := run("set-identity", "/x/app", "/y/lib")
		first, nMore, hash := sessionkey.Identity([]string{"/x/app", "/y/lib"})
		Expect(nMore).To(Equal(1))
		Expect(s.ExitCode()).To(Equal(0))
		Expect(string(s.Out.Contents())).To(Equal(fmt.Sprintf("%s\n%d\n%s\n", first, nMore, hash)))
		Expect(s.Err.Contents()).To(BeEmpty())
	})

	Describe("recorded-projects", func() {
		var dir string

		BeforeEach(func() { dir = GinkgoT().TempDir() })

		It("prints the record's non-empty lines", func() {
			Expect(os.WriteFile(filepath.Join(dir, "projects"), []byte("/a b\n\n/c\n"), 0o600)).To(Succeed())
			s := run("recorded-projects", dir)
			Expect(s.ExitCode()).To(Equal(0))
			Expect(string(s.Out.Contents())).To(Equal("/a b\n/c\n"))
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("exits 1 silently without a record", func() {
			s := run("recorded-projects", dir)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("exits 1 silently for an empty record", func() {
			Expect(os.WriteFile(filepath.Join(dir, "projects"), nil, 0o600)).To(Succeed())
			s := run("recorded-projects", dir)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("exits 1 and says why when the record cannot be read", func() {
			if os.Geteuid() == 0 {
				Skip("root reads a mode-000 file")
			}
			Expect(os.WriteFile(filepath.Join(dir, "projects"), []byte("/a\n"), 0o000)).To(Succeed())
			s := run("recorded-projects", dir)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(ContainSubstring("permission denied"))
		})
	})

	Describe("session-projects", func() {
		var dir string

		BeforeEach(func() { dir = GinkgoT().TempDir() })

		It("prints the non-empty lines of .projects", func() {
			Expect(os.WriteFile(filepath.Join(dir, ".projects"), []byte("/a\x00b\n\n/c"), 0o600)).To(Succeed())
			s := run("session-projects", dir)
			Expect(s.ExitCode()).To(Equal(0))
			Expect(string(s.Out.Contents())).To(Equal("/ab\n/c\n"))
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("exits 1 silently for a link", func() {
			target := filepath.Join(dir, "real")
			Expect(os.WriteFile(target, []byte("/a\n"), 0o600)).To(Succeed())
			Expect(os.Symlink(target, filepath.Join(dir, ".projects"))).To(Succeed())
			s := run("session-projects", dir)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("exits 1 silently when .projects cannot be read, as the bash discards dd's message", func() {
			if os.Geteuid() == 0 {
				Skip("root reads a mode-000 file")
			}
			Expect(os.WriteFile(filepath.Join(dir, ".projects"), []byte("/a\n"), 0o000)).To(Succeed())
			s := run("session-projects", dir)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		})
	})

	Describe("the running-container verbs", func() {
		var dir, engine, libDir string

		// fakeEngine writes an engine that lists the container abc when ps is
		// asked and prints inspect, a shell printf format, for inspect; with
		// rc non-zero every call fails.
		fakeEngine := func(inspect string, rc int) {
			script := fmt.Sprintf("#!/bin/sh\n[ %d -eq 0 ] || { echo engine down >&2; exit %d; }\n"+
				"case \"$1\" in ps) echo abc ;; container) printf '%s' ;; esac\n", rc, rc, inspect)
			Expect(os.WriteFile(engine, []byte(script), 0o700)).To(Succeed())
		}

		BeforeEach(func() {
			var err error
			dir, err = filepath.EvalSymlinks(GinkgoT().TempDir())
			Expect(err).NotTo(HaveOccurred())
			engine = filepath.Join(dir, "engine")
			libDir, err = filepath.Abs(filepath.Join("..", "..", "scripts", "lib"))
			Expect(err).NotTo(HaveOccurred())
			Expect(os.MkdirAll(filepath.Join(dir, "session"), 0o700)).To(Succeed())
			Expect(os.MkdirAll(filepath.Join(dir, "state"), 0o700)).To(Succeed())
		})

		It("overlay-scan prints holders and sharers as NUL-terminated records", func() {
			fakeEngine(`abc\0web\0`+dir+`/ov\0true\0abc\0web\0`+dir+`/proj\0true\0\n`, 0)
			s := run("overlay-scan", "--engine", engine, "--lib-dir", libDir, "--", dir+"/ov", dir+"/proj")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(string(s.Out.Contents())).To(Equal("holder\x00web\x00sharer\x00web " + dir + "/proj\x00"))
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("overlay-scan cleans a sharer's mount source with the filter in --lib-dir", func() {
			fakeEngine(`abc\0web\0`+dir+`/proj/\033[31mx\0true\0\n`, 0)
			s := run("overlay-scan", "--engine", engine, "--lib-dir", libDir, dir+"/ov", dir+"/proj")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(string(s.Out.Contents())).To(Equal("sharer\x00web " + dir + "/proj/?[31mx\x00"))
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("overlay-scan exits 1, saying why, when the engine's answer is malformed", func() {
			fakeEngine(`abc\0web\0`, 0)
			s := run("overlay-scan", "--lib-dir", libDir, "--engine", engine, dir+"/ov", dir+"/proj")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(Equal("riotbox-core: malformed container inspect output\n"))
		})

		It("overlay-scan exits 1, printing nothing on stdout, when the engine cannot answer", func() {
			fakeEngine("", 125)
			s := run("overlay-scan", "--lib-dir", libDir, "--engine", engine, dir+"/ov", dir+"/proj")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(Equal("engine down\n"))
		})

		It("session-busy exits 0, silently, when no container reaches the session or state dir", func() {
			fakeEngine(`abc\0web\0`+dir+`/elsewhere\0true\0\n`, 0)
			s := run("session-busy", "--engine", engine, "--lib-dir", libDir, "--", dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("session-busy exits 1, saying why, when a container mounts the session read-write", func() {
			fakeEngine(`abc\0web\0`+dir+`/session\0true\0\n`, 0)
			s := run("session-busy", "--engine", engine, "--lib-dir", libDir, "--", dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(ContainSubstring("container web mounts " + dir + "/session read-write"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("is still running"))
		})

		It("session-busy exits 0, silently, when a container mounts the session read-only", func() {
			fakeEngine(`abc\0web\0`+dir+`/session\0false\0\n`, 0)
			s := run("session-busy", "--engine", engine, "--lib-dir", libDir, "--", dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("session-busy exits 1, saying why, when a container mounts the state dir read-write", func() {
			fakeEngine(`abc\0web\0`+dir+`/state\0true\0\n`, 0)
			s := run("session-busy", "--engine", engine, "--lib-dir", libDir, "--", dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(ContainSubstring("is still running"))
		})

		It("session-busy exits 3, saying why, when the session dir is empty and cannot be resolved", func() {
			fakeEngine(`abc\0web\0`+dir+`/elsewhere\0true\0\n`, 0)
			s := run("session-busy", "--engine", engine, "--lib-dir", libDir, "--", "", dir+"/state")
			Expect(s.ExitCode()).To(Equal(3))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).NotTo(BeEmpty())
		})

		It("session-busy exits 3, saying why, when the engine cannot answer", func() {
			fakeEngine(``, 125)
			s := run("session-busy", "--engine", engine, "--lib-dir", libDir, "--", dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(3))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(ContainSubstring("could not ask"))
		})
	})

	Describe("the migration verbs", func() {
		var dir, libDir string

		BeforeEach(func() {
			var err error
			dir, err = filepath.EvalSymlinks(GinkgoT().TempDir())
			Expect(err).NotTo(HaveOccurred())
			libDir, err = filepath.Abs(filepath.Join("..", "..", "scripts", "lib"))
			Expect(err).NotTo(HaveOccurred())
		})

		It("migrate-state moves a legacy dir, saying so on stderr, and exits 0", func() {
			Expect(os.MkdirAll(dir+"/session/headroom", 0o700)).To(Succeed())
			s := run("migrate-state", "--lib-dir", libDir, dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(Equal("Notice: moved " + dir + "/session/headroom to " + dir + "/state/headroom\n"))
			Expect(filepath.Join(dir, "state", ".migrated")).To(BeARegularFile())
		})

		It("migrate-state exits 1 when a step fails", func() {
			Expect(os.MkdirAll(dir+"/session/headroom", 0o700)).To(Succeed())
			Expect(os.WriteFile(dir+"/state", nil, 0o600)).To(Succeed())
			s := run("migrate-state", "--lib-dir", libDir, dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(HavePrefix("riotbox-core: "))
		})

		It("migrate-failed prints Nothing to migrate. on stdout and exits 0", func() {
			s := run("migrate-failed", "--engine", "podman", "--lib-dir", libDir, dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(string(s.Out.Contents())).To(Equal("Nothing to migrate.\n"))
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("migrate-failed exits 1 when the engine cannot confirm nothing runs", func() {
			Expect(os.MkdirAll(dir+"/session/headroom", 0o700)).To(Succeed())
			Expect(os.WriteFile(dir+"/session/headroom/mem", nil, 0o600)).To(Succeed())
			Expect(os.MkdirAll(dir+"/state", 0o700)).To(Succeed())
			Expect(os.WriteFile(dir+"/state/.migrated", []byte("headroom\nfailed:headroom\n"), 0o600)).To(Succeed())
			s := run("migrate-failed", "--lib-dir", libDir, "--engine", dir+"/no-such-engine", "--", dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(ContainSubstring("ERROR: could not ask"))
			Expect(dir + "/session/headroom/mem").To(BeARegularFile())
		})

		It("migrate-key moves an old-key session, taking every value as given, and exits 0", func() {
			engine := dir + "/engine"
			Expect(os.WriteFile(engine, []byte("#!/bin/sh\nexit 0\n"), 0o700)).To(Succeed())
			Expect(os.MkdirAll(dir+"/data/-p-app", 0o700)).To(Succeed())
			Expect(os.WriteFile(dir+"/data/-p-app/.projects", []byte("--\n"), 0o600)).To(Succeed())
			newSession := dir + "/data/" + sessionkey.Key([]string{"--"})
			s := run("migrate-key", "--lib-dir", libDir, "--engine", engine, "--data-dir", dir+"/data",
				"--state-root", dir+"/state", "--legacy-key", "--other", "--legacy-key", "-p-app", "--", "--")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(Equal("Notice: moved " + dir + "/data/-p-app to " + newSession +
				" (matched by its .projects: an older RiotBox left no record)\n"))
		})

		It("migrate-key exits 1 when the engine cannot confirm nothing runs", func() {
			Expect(os.MkdirAll(dir+"/data/-p-app", 0o700)).To(Succeed())
			Expect(os.WriteFile(dir+"/data/-p-app/.projects", []byte("/p/app\n"), 0o600)).To(Succeed())
			s := run("migrate-key", "--lib-dir", libDir, "--engine", dir+"/no-such-engine", "--data-dir", dir+"/data",
				"--state-root", dir+"/state", "--legacy-key", "-p-app", "--", "/p/app")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(ContainSubstring("Nothing was moved: "))
			Expect(dir + "/data/-p-app/.projects").To(BeARegularFile())
		})

		It("migrate-key with no legacy key moves nothing and exits 0", func() {
			s := run("migrate-key", "--lib-dir", libDir, "--engine", "podman", "--data-dir", dir+"/data",
				"--state-root", dir+"/state", "--", "/p/app")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Err.Contents()).To(BeEmpty())
			Expect(dir + "/state").NotTo(BeADirectory())
		})

		It("migrate-all migrates every session under the data dir and exits 0", func() {
			for _, name := range []string{"a", "b"} {
				Expect(os.MkdirAll(dir+"/data/"+name+"/headroom", 0o700)).To(Succeed())
				Expect(os.WriteFile(dir+"/data/"+name+"/.projects", []byte("/p\n"), 0o600)).To(Succeed())
			}
			Expect(os.MkdirAll(dir+"/data/plain/headroom", 0o700)).To(Succeed())
			s := run("migrate-all", "--lib-dir", libDir, dir+"/data", dir+"/state")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(Equal(
				"Notice: moved " + dir + "/data/a/headroom to " + dir + "/state/a/headroom\n" +
					"Notice: moved " + dir + "/data/b/headroom to " + dir + "/state/b/headroom\n"))
			Expect(dir + "/data/plain/headroom").To(BeADirectory())
		})

		It("migrate-all exits 1 when a session fails", func() {
			Expect(os.MkdirAll(dir+"/data/a/headroom", 0o700)).To(Succeed())
			Expect(os.WriteFile(dir+"/data/a/.projects", []byte("/p\n"), 0o600)).To(Succeed())
			Expect(os.MkdirAll(dir+"/state", 0o700)).To(Succeed())
			Expect(os.WriteFile(dir+"/state/a", nil, 0o600)).To(Succeed())
			s := run("migrate-all", "--lib-dir", libDir, dir+"/data", dir+"/state")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(HavePrefix("riotbox-core: "))
		})

		It("headroom-notice prints the notice on stderr and exits 0", func() {
			Expect(os.MkdirAll(dir+"/proj/.headroom", 0o700)).To(Succeed())
			Expect(os.MkdirAll(dir+"/state", 0o700)).To(Succeed())
			s := run("headroom-notice", "--lib-dir", libDir, dir+"/proj", dir+"/state")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(HavePrefix("Notice: " + dir + "/proj/.headroom may hold headroom memory"))
		})

		It("headroom-notice exits 1 when the check cannot be recorded", func() {
			s := run("headroom-notice", "--lib-dir", libDir, dir+"/proj", dir+"/missing")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(HavePrefix("riotbox-core: "))
		})
	})

	Describe("is-session", func() {
		var dir string

		BeforeEach(func() {
			dir = GinkgoT().TempDir()
			Expect(os.MkdirAll(dir+"/session", 0o700)).To(Succeed())
		})

		It("exits 0, silently, for a session", func() {
			Expect(os.WriteFile(dir+"/session/.projects", []byte("/p\n"), 0o600)).To(Succeed())
			s := run("is-session", dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(0))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		})

		It("exits 1, silently, for a dir that is not one", func() {
			s := run("is-session", dir+"/session", dir+"/state")
			Expect(s.ExitCode()).To(Equal(1))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		})
	})

	DescribeTable("same-project-set exits 0 for the same set and 1 for another, silently",
		func(a, b string, want int) {
			s := run("same-project-set", "--", a, b)
			Expect(s.ExitCode()).To(Equal(want))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(s.Err.Contents()).To(BeEmpty())
		},
		Entry("the same paths in another order", "/b\n/a\n/a", "/a\n/b", 0),
		Entry("another set", "/a\n/b", "/a", 1),
		Entry("lists that start with a dash", "-a", "-a", 0),
		Entry("lists that are --", "--", "--", 0),
	)

	DescribeTable("migrate-key rejects a legacy key that is not one path component, touching nothing",
		func(key, shown string) {
			dir := GinkgoT().TempDir()
			s := run("migrate-key", "--lib-dir", "/l", "--engine", "e", "--data-dir", dir+"/data",
				"--state-root", dir+"/state", "--legacy-key", "ok", "--legacy-key", key, "--", "/p")
			Expect(s.ExitCode()).To(Equal(2))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(HavePrefix("riotbox-core: migrate-key: --legacy-key " + shown +
				" is not a session key: it must be one path component, not empty, . or ..\nusage: riotbox-core"))
			entries, err := os.ReadDir(dir)
			Expect(err).NotTo(HaveOccurred())
			Expect(entries).To(BeEmpty(), "it touched the filesystem")
		},
		Entry("empty, which names the data dir itself", "", "''"),
		Entry(".", ".", "."),
		Entry("..", "..", ".."),
		Entry("a key with a slash", "a/b", "a/b"),
		Entry("a key leading outside", "../x", "../x"),
		Entry("an absolute path", "/etc", "/etc"),
		Entry("a trailing slash", "key/", "key/"),
	)

	DescribeTable("rejects bad usage with exit 2 and usage on stderr",
		func(args ...string) {
			s := run(args...)
			Expect(s.ExitCode()).To(Equal(2))
			Expect(s.Out.Contents()).To(BeEmpty())
			Expect(string(s.Err.Contents())).To(ContainSubstring("usage: riotbox-core"))
		},
		Entry("no verb"),
		Entry("unknown verb", "frobnicate"),
		Entry("session-key without dirs", "session-key"),
		Entry("set-identity without dirs", "set-identity"),
		Entry("version with arguments", "version", "extra"),
		Entry("recorded-projects without a dir", "recorded-projects"),
		Entry("recorded-projects with two dirs", "recorded-projects", "/a", "/b"),
		Entry("session-projects without a dir", "session-projects"),
		Entry("session-projects with two dirs", "session-projects", "/a", "/b"),
		Entry("overlay-scan without --engine", "overlay-scan", "--lib-dir", "/l", "/o", "/p"),
		Entry("overlay-scan without --lib-dir", "overlay-scan", "--engine", "podman", "/o", "/p"),
		Entry("overlay-scan with the engine as a positional", "overlay-scan", "--lib-dir", "/l", "podman", "/o", "/p"),
		Entry("overlay-scan with one dir", "overlay-scan", "--lib-dir", "/l", "--engine", "podman", "/o"),
		Entry("overlay-scan with three dirs", "overlay-scan", "--lib-dir", "/l", "--engine", "podman", "/o", "/p", "/q"),
		Entry("migrate-state without --lib-dir", "migrate-state", "/s", "/t"),
		Entry("migrate-state with one dir", "migrate-state", "--lib-dir", "/l", "/s"),
		Entry("migrate-state with three dirs", "migrate-state", "--lib-dir", "/l", "/s", "/t", "/u"),
		Entry("migrate-state with an option it does not take", "migrate-state", "--engine", "e", "--lib-dir", "/l", "/s", "/t"),
		Entry("migrate-state with an option after the dirs", "migrate-state", "/s", "/t", "--lib-dir", "/l"),
		Entry("migrate-state with an option missing its value", "migrate-state", "--lib-dir"),
		Entry("migrate-failed without --lib-dir", "migrate-failed", "--engine", "podman", "/s", "/t"),
		Entry("migrate-failed without --engine", "migrate-failed", "--lib-dir", "/l", "/s", "/t"),
		Entry("migrate-failed with the engine as a positional", "migrate-failed", "--lib-dir", "/l", "podman", "/s", "/t"),
		Entry("migrate-failed with --engine twice", "migrate-failed", "--lib-dir", "/l", "--engine", "e", "--engine", "f", "/s", "/t"),
		Entry("migrate-failed with one dir", "migrate-failed", "--lib-dir", "/l", "--engine", "podman", "/s"),
		Entry("session-busy without --engine", "session-busy", "--lib-dir", "/l", "/s", "/t"),
		Entry("session-busy without --lib-dir", "session-busy", "--engine", "podman", "/s", "/t"),
		Entry("session-busy with one dir", "session-busy", "--lib-dir", "/l", "--engine", "podman", "/s"),
		Entry("session-busy with three dirs", "session-busy", "--lib-dir", "/l", "--engine", "podman", "/s", "/t", "/u"),
		Entry("same-project-set with one list", "same-project-set", "/a"),
		Entry("same-project-set with three lists", "same-project-set", "/a", "/a", "/a"),
		Entry("same-project-set with dash-led lists and no --", "same-project-set", "-a", "-a"),
		Entry("session-key with a dash-led dir and no --", "session-key", "-a"),
		Entry("version with an option", "version", "--lib-dir", "/l"),
		Entry("migrate-key without --lib-dir", "migrate-key", "--engine", "e", "--data-dir", "/d", "--state-root", "/r", "--", "/p"),
		Entry("migrate-key without --engine", "migrate-key", "--lib-dir", "/l", "--data-dir", "/d", "--state-root", "/r", "--", "/p"),
		Entry("migrate-key without --data-dir", "migrate-key", "--lib-dir", "/l", "--engine", "e", "--state-root", "/r", "--", "/p"),
		Entry("migrate-key without --state-root", "migrate-key", "--lib-dir", "/l", "--engine", "e", "--data-dir", "/d", "--", "/p"),
		Entry("migrate-key with an option twice", "migrate-key", "--lib-dir", "/l", "--engine", "e", "--data-dir", "/d", "--data-dir", "/x", "--state-root", "/r", "--", "/p"),
		Entry("migrate-key with an unknown option", "migrate-key", "--lib-dir", "/l", "--engine", "e", "--data-dir", "/d", "--state-root", "/r", "--given", "/p", "--", "/p"),
		Entry("migrate-key with an option missing its value", "migrate-key", "--lib-dir", "/l", "--engine", "e", "--data-dir", "/d", "--state-root"),
		Entry("migrate-key with a dash-led set dir and no --", "migrate-key", "--lib-dir", "/l", "--engine", "e", "--data-dir", "/d", "--state-root", "/r", "-p"),
		Entry("migrate-key without set dirs", "migrate-key", "--lib-dir", "/l", "--engine", "e", "--data-dir", "/d", "--state-root", "/r", "--"),
		Entry("is-session with one dir", "is-session", "/s"),
		Entry("is-session with three dirs", "is-session", "/s", "/t", "/u"),
		Entry("migrate-all without --lib-dir", "migrate-all", "/d", "/r"),
		Entry("migrate-all with one dir", "migrate-all", "--lib-dir", "/l", "/d"),
		Entry("migrate-all with three dirs", "migrate-all", "--lib-dir", "/l", "/d", "/r", "/u"),
		Entry("headroom-notice without --lib-dir", "headroom-notice", "/p", "/t"),
		Entry("headroom-notice with one dir", "headroom-notice", "--lib-dir", "/l", "/p"),
		Entry("headroom-notice with three dirs", "headroom-notice", "--lib-dir", "/l", "/p", "/t", "/u"),
	)
})

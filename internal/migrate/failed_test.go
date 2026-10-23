package migrate_test

import (
	"bytes"
	"fmt"
	"os"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/migrate"
)

var _ = Describe("FailedState (migrate_failed_state)", func() {
	var out *bytes.Buffer
	var eng string

	// fakeEngine writes an engine that lists the container abc and prints
	// inspect, a shell printf format, for its mounts; with rc non-zero every
	// call fails. Each call is logged to <tmp>/engine.calls.
	fakeEngine := func(inspect string, rc int) {
		script := fmt.Sprintf("#!/bin/sh\necho \"$1\" >>\"$(dirname \"$0\")/engine.calls\"\n"+
			"[ %d -eq 0 ] || { echo engine down >&2; exit %d; }\n"+
			"case \"$1\" in ps) echo abc ;; container) printf '%s' ;; esac\n", rc, rc, inspect)
		Expect(os.WriteFile(eng, []byte(script), 0o700)).To(Succeed())
	}

	BeforeEach(func() {
		out = &bytes.Buffer{}
		eng = tmp + "/engine"
		fakeEngine(`abc\0web\0/elsewhere\0true\0\n`, 0)
	})

	It("prints Nothing to migrate. without a marker, and creates nothing", func() {
		Expect(migrate.FailedState(out, errOut, eng, libDir, session, state)).To(Succeed())
		Expect(out.String()).To(Equal("Nothing to migrate.\n"))
		Expect(errOut.String()).To(BeEmpty())
		Expect(exists(state)).To(BeFalse())
	})

	It("prints Nothing to migrate. when no pair is failed, without asking the engine", func() {
		write(state+"/.migrated", "headroom\nfailed:headroom\nheadroom\ngit-ai\n")
		write(session+"/headroom/mem.db", "planted")
		Expect(migrate.FailedState(out, errOut, eng, libDir, session, state)).To(Succeed())
		Expect(out.String()).To(Equal("Nothing to migrate.\n"))
		Expect(errOut.String()).To(BeEmpty())
		Expect(exists(tmp+"/engine.calls")).To(BeFalse(), "the engine was asked")
		Expect(read(session + "/headroom/mem.db")).To(Equal("planted"))
	})

	It("records a failed pair whose legacy path holds nothing done, without a retry", func() {
		mkdirs(session + "/headroom")
		write(state+"/.migrated", "headroom\nfailed:headroom\n")
		Expect(migrate.FailedState(out, errOut, eng, libDir, session, state)).To(Succeed())
		Expect(out.String()).To(Equal("Nothing to migrate.\n"))
		Expect(read(state + "/.migrated")).To(Equal("headroom\nfailed:headroom\nheadroom\n"))
		Expect(exists(tmp+"/engine.calls")).To(BeFalse(), "the engine was asked")
	})

	It("moves a failed pair over the empty new dir a launch made, and records it done", func() {
		write(session+"/git-ai/config.json", "keep")
		mkdirs(state + "/git-ai")
		write(state+"/.migrated", "git-ai\nfailed:git-ai\n")
		Expect(migrate.FailedState(out, errOut, eng, libDir, session, state)).To(Succeed())
		Expect(out.String()).To(BeEmpty())
		Expect(errOut.String()).To(Equal("Notice: moved " + session + "/git-ai to " + state + "/git-ai\n"))
		Expect(read(state + "/git-ai/config.json")).To(Equal("keep"))
		Expect(read(state + "/.migrated")).To(Equal("git-ai\nfailed:git-ai\ngit-ai\n"))
	})

	It("leaves a non-empty new dir alone, explains how to resolve two copies, and keeps the pair failed", func() {
		write(session+"/git-ai/config.json", "keep")
		write(state+"/git-ai/written-by-a-session", "session")
		write(state+"/.migrated", "git-ai\nfailed:git-ai\n")
		Expect(migrate.FailedState(out, errOut, eng, libDir, session, state)).NotTo(Succeed())
		Expect(out.String()).To(BeEmpty())
		Expect(errOut.String()).To(Equal(
			"Warning: both " + session + "/git-ai and " + state + "/git-ai exist; left both untouched.\n" +
				"         RiotBox now uses " + state + "/git-ai. Move anything you need out of " + session + "/git-ai, then delete it.\n" +
				"         RiotBox cannot merge the two copies. Exit every session of this project, then compare them:\n" +
				"           diff -rq " + session + "/git-ai " + state + "/git-ai\n" +
				"         Keep what you need, then delete one side (deleting " + session + "/git-ai keeps " + state + "/git-ai; delete or move aside " + state + "/git-ai to use " + session + "/git-ai instead) and run riotbox session-migrate again.\n" +
				"         See README.md, \"Upgrading from a release that kept state in the session directory\", for how to read the diff.\n"))
		Expect(read(session + "/git-ai/config.json")).To(Equal("keep"))
		Expect(read(state + "/git-ai/written-by-a-session")).To(Equal("session"))
		Expect(read(state + "/.migrated")).To(Equal("git-ai\nfailed:git-ai\n"))
	})

	It("keeps the pair failed, without the two-copies text, when the move fails again", func() {
		write(session+"/headroom/mem", "keep")
		write(state+"/.migrated", "headroom\nfailed:headroom\n")
		shim("mv", "#!/bin/sh\necho \"mv: simulated failure\" >&2\nexit 1\n")
		Expect(migrate.FailedState(out, errOut, eng, libDir, session, state)).NotTo(Succeed())
		Expect(errOut.String()).To(HavePrefix("Warning: could not move " + session + "/headroom"))
		Expect(errOut.String()).NotTo(ContainSubstring("cannot merge"))
		Expect(read(state + "/.migrated")).To(Equal("headroom\nfailed:headroom\n"))
	})

	It("never follows a link planted at a failed pair's legacy path", func() {
		mkdirs(session)
		Expect(os.Symlink(victim, session+"/headroom")).To(Succeed())
		write(state+"/.migrated", "headroom\nfailed:headroom\n")
		Expect(migrate.FailedState(out, errOut, eng, libDir, session, state)).To(Succeed())
		Expect(exists(state + "/headroom")).To(BeFalse())
		Expect(read(state + "/.migrated")).To(Equal("headroom\nfailed:headroom\nheadroom\n"))
		expectVictimIntact()
	})

	DescribeTable("refuses, moving nothing, unless the engine confirms nothing can write the session",
		func(inspect string, rc int, want string) {
			write(session+"/git-ai/config.json", "keep")
			mkdirs(state + "/git-ai")
			write(state+"/.migrated", "git-ai\nfailed:git-ai\n")
			fakeEngine(strings.ReplaceAll(inspect, "STATE", state), rc)
			Expect(migrate.FailedState(out, errOut, eng, libDir, session, state)).NotTo(Succeed())
			Expect(out.String()).To(BeEmpty())
			Expect(errOut.String()).To(ContainSubstring(want))
			Expect(errOut.String()).NotTo(ContainSubstring("Notice: moved"))
			Expect(read(session + "/git-ai/config.json")).To(Equal("keep"))
			Expect(os.ReadDir(state + "/git-ai")).To(BeEmpty())
			Expect(read(state + "/.migrated")).To(Equal("git-ai\nfailed:git-ai\n"))
		},
		Entry("a container mounts the state", `abc\0web\0STATE/git-ai\0true\0\n`, 0, "ERROR: container web mounts"),
		Entry("the engine cannot answer", "", 125, "ERROR: could not ask"),
	)
})

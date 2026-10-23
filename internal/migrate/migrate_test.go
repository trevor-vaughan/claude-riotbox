package migrate_test

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/migrate"
)

// Each spec stages a session dir and its state dir the way a launch lays
// them out, plus a victim dir that stands for any host path a planted link
// could name: a helper that follows such a link changes the victim.
var (
	tmp, session, state, victim string
	libDir                      string
	errOut                      *bytes.Buffer
)

var _ = BeforeEach(func() {
	var err error
	tmp, err = filepath.EvalSymlinks(GinkgoT().TempDir())
	Expect(err).NotTo(HaveOccurred())
	session = tmp + "/data/riotbox/key"
	state = tmp + "/data/riotbox-state/key"
	victim = tmp + "/victim"
	Expect(os.MkdirAll(victim, 0o700)).To(Succeed())
	write(victim+"/keep", "precious")
	errOut = &bytes.Buffer{}
	libDir, err = filepath.Abs(filepath.Join("..", "..", "scripts", "lib"))
	Expect(err).NotTo(HaveOccurred())
	DeferCleanup(func() {
		// Specs make dirs unwritable; give TempDir's cleanup its way back.
		_ = filepath.Walk(tmp, func(p string, info os.FileInfo, err error) error {
			if err == nil && info.IsDir() {
				_ = os.Chmod(p, 0o700)
			}
			return nil
		})
	})
})

func write(path, content string) {
	Expect(os.MkdirAll(filepath.Dir(path), 0o700)).To(Succeed())
	Expect(os.WriteFile(path, []byte(content), 0o600)).To(Succeed())
}

func mkdirs(paths ...string) {
	for _, p := range paths {
		Expect(os.MkdirAll(p, 0o700)).To(Succeed())
	}
}

func read(path string) string {
	content, err := os.ReadFile(path)
	Expect(err).NotTo(HaveOccurred())
	return string(content)
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func expectVictimIntact() {
	Expect(read(victim + "/keep")).To(Equal("precious"))
	entries, err := os.ReadDir(victim)
	Expect(err).NotTo(HaveOccurred())
	Expect(entries).To(HaveLen(1), "something was written into the victim")
}

// shim puts an executable <name> holding script first on PATH.
func shim(name, script string) {
	dir := tmp + "/shim"
	mkdirs(dir)
	Expect(os.WriteFile(dir+"/"+name, []byte(script), 0o700)).To(Succeed())
	GinkgoT().Setenv("PATH", dir+":"+os.Getenv("PATH"))
}

func skipIfRoot() {
	if os.Geteuid() == 0 {
		Skip("root ignores directory permissions")
	}
}

func lineCount(text, substr string) int {
	n := 0
	for line := range strings.SplitSeq(text, "\n") {
		if strings.Contains(line, substr) {
			n++
		}
	}
	return n
}

const fallbackHint = "riotbox session-migrate from the project's directory (pass every project of a multi-project session)"

var _ = Describe("one legacy pair (migrate_legacy_state)", func() {
	It("does nothing, and creates nothing, when no legacy entry exists", func() {
		mkdirs(session)
		for _, name := range []string{"headroom", "git-ai"} {
			stranded, err := migrate.MoveLegacy(errOut, session, state, false, name, name)
			Expect(err).NotTo(HaveOccurred())
			Expect(stranded).To(BeFalse())
		}
		Expect(errOut.String()).To(BeEmpty())
		Expect(exists(state)).To(BeFalse())
	})

	It("moves a real legacy dir once with one notice, and a second run is a no-op", func() {
		write(session+"/.pi-agent/sessions/one.jsonl", "history")
		stranded, err := migrate.MoveLegacy(errOut, session, state, false, ".pi-agent", "pi-agent")
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeFalse())
		Expect(read(state + "/pi-agent/sessions/one.jsonl")).To(Equal("history"))
		Expect(exists(session + "/.pi-agent")).To(BeFalse())
		Expect(errOut.String()).To(Equal("Notice: moved " + session + "/.pi-agent to " + state + "/pi-agent\n"))
		for _, dir := range []string{state, filepath.Dir(state)} {
			info, err := os.Stat(dir)
			Expect(err).NotTo(HaveOccurred())
			Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o700)), dir)
		}

		errOut.Reset()
		stranded, err = migrate.MoveLegacy(errOut, session, state, false, ".pi-agent", "pi-agent")
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeFalse())
		Expect(errOut.String()).To(BeEmpty())
		Expect(read(state + "/pi-agent/sessions/one.jsonl")).To(Equal("history"))
	})

	It("removes legacy links and files without following them", func() {
		mkdirs(session)
		// session is <tmp>/data/riotbox/key, so ../../../victim is the victim.
		Expect(os.Symlink("../../../victim", session+"/headroom")).To(Succeed())
		Expect(os.Symlink(victim, session+"/git-ai")).To(Succeed())
		Expect(os.Symlink("../nowhere", session+"/overlay")).To(Succeed())
		write(session+"/.pi-agent", "junk")
		resolved, err := filepath.EvalSymlinks(session + "/headroom")
		Expect(err).NotTo(HaveOccurred())
		Expect(resolved).To(Equal(victim), "fixture link is wrong")

		for _, pair := range [][2]string{{"headroom", "headroom"}, {"git-ai", "git-ai"}, {"overlay", "overlay"}, {".pi-agent", "pi-agent"}} {
			stranded, err := migrate.MoveLegacy(errOut, session, state, false, pair[0], pair[1])
			Expect(err).NotTo(HaveOccurred())
			Expect(stranded).To(BeFalse())
			Expect(exists(session+"/"+pair[0])).To(BeFalse(), pair[0]+" not removed")
		}
		Expect(errOut.String()).To(Equal(
			"Warning: " + session + "/headroom is not a real directory; removed it without following it.\n" +
				"Warning: " + session + "/git-ai is not a real directory; removed it without following it.\n" +
				"Warning: " + session + "/overlay is not a real directory; removed it without following it.\n" +
				"Warning: " + session + "/.pi-agent is not a real directory; removed it without following it.\n"))
		Expect(exists(state)).To(BeFalse(), "a planted entry was migrated")
		expectVictimIntact()
	})

	It("removes FIFO and socket legacy entries", func() {
		mkdirs(session)
		Expect(syscall.Mkfifo(session+"/headroom", 0o600)).To(Succeed())
		l, err := net.ListenUnix("unix", &net.UnixAddr{Name: session + "/git-ai", Net: "unix"})
		Expect(err).NotTo(HaveOccurred())
		l.SetUnlinkOnClose(false)
		Expect(l.Close()).To(Succeed())

		for _, name := range []string{"headroom", "git-ai"} {
			_, err := migrate.MoveLegacy(errOut, session, state, false, name, name)
			Expect(err).NotTo(HaveOccurred())
			Expect(exists(session+"/"+name)).To(BeFalse(), name+" not removed")
		}
		Expect(lineCount(errOut.String(), "not a real directory")).To(Equal(2))
		Expect(exists(state)).To(BeFalse(), "a special file was migrated")
	})

	It("fails, touching nothing else, when a legacy entry cannot be removed", func() {
		skipIfRoot()
		mkdirs(session)
		Expect(os.Symlink(victim, session+"/headroom")).To(Succeed())
		Expect(os.Chmod(session, 0o500)).To(Succeed())
		_, err := migrate.MoveLegacy(errOut, session, state, false, "headroom", "headroom")
		Expect(err).To(HaveOccurred())
		Expect(errOut.String()).To(HavePrefix("Warning: " + session + "/headroom is not a real directory; removed it without following it.\nriotbox-core: "))
		expectVictimIntact()
	})

	It("never merges when both the legacy and the new dir exist, and never follows a link at the new path", func() {
		write(session+"/headroom/mem", "old")
		write(state+"/headroom/mem", "new")
		write(session+"/git-ai/config.json", "old")
		Expect(os.Symlink(victim, state+"/git-ai")).To(Succeed())
		// A dangling link counts as present too.
		write(session+"/opencode/data", "old")
		Expect(os.Symlink(tmp+"/nowhere", state+"/opencode")).To(Succeed())

		for _, name := range []string{"headroom", "git-ai", "opencode"} {
			stranded, err := migrate.MoveLegacy(errOut, session, state, false, name, name)
			Expect(err).NotTo(HaveOccurred())
			Expect(stranded).To(BeTrue(), name+" was not left stranded")
		}
		Expect(read(session + "/opencode/data")).To(Equal("old"))
		Expect(exists(tmp + "/nowhere")).To(BeFalse())
		Expect(read(session + "/headroom/mem")).To(Equal("old"))
		Expect(read(state + "/headroom/mem")).To(Equal("new"))
		Expect(exists(state+"/headroom/headroom")).To(BeFalse(), "legacy was moved into new")
		Expect(read(session + "/git-ai/config.json")).To(Equal("old"))
		info, err := os.Lstat(state + "/git-ai")
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode()&os.ModeSymlink).NotTo(BeZero(), "the new-path link was replaced")
		Expect(errOut.String()).To(Equal(
			"Warning: both " + session + "/headroom and " + state + "/headroom exist; left both untouched.\n" +
				"         RiotBox now uses " + state + "/headroom. Move anything you need out of " + session + "/headroom, then delete it.\n" +
				"Warning: both " + session + "/git-ai and " + state + "/git-ai exist; left both untouched.\n" +
				"         RiotBox now uses " + state + "/git-ai. Move anything you need out of " + session + "/git-ai, then delete it.\n" +
				"Warning: both " + session + "/opencode and " + state + "/opencode exist; left both untouched.\n" +
				"         RiotBox now uses " + state + "/opencode. Move anything you need out of " + session + "/opencode, then delete it.\n"))
		expectVictimIntact()
	})

	It("leaves an empty new dir alone without --replace-empty, and moves over it with it", func() {
		write(session+"/headroom/mem", "old")
		mkdirs(state + "/headroom")
		stranded, err := migrate.MoveLegacy(errOut, session, state, false, "headroom", "headroom")
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeTrue())
		Expect(read(session + "/headroom/mem")).To(Equal("old"))

		errOut.Reset()
		stranded, err = migrate.MoveLegacy(errOut, session, state, true, "headroom", "headroom")
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeFalse())
		Expect(read(state + "/headroom/mem")).To(Equal("old"))
		Expect(errOut.String()).To(Equal("Notice: moved " + session + "/headroom to " + state + "/headroom\n"))
	})

	It("with --replace-empty, still leaves a non-empty new dir or a link at the new path alone", func() {
		write(session+"/headroom/mem", "old")
		write(state+"/headroom/other", "new")
		write(session+"/git-ai/config.json", "old")
		Expect(os.Symlink(tmp+"/empty", state+"/git-ai")).To(Succeed())
		mkdirs(tmp + "/empty")
		for _, name := range []string{"headroom", "git-ai"} {
			stranded, err := migrate.MoveLegacy(errOut, session, state, true, name, name)
			Expect(err).NotTo(HaveOccurred())
			Expect(stranded).To(BeTrue(), name)
		}
		Expect(read(session + "/headroom/mem")).To(Equal("old"))
		Expect(read(session + "/git-ai/config.json")).To(Equal("old"))
		Expect(os.ReadDir(tmp + "/empty")).To(BeEmpty())
	})

	It("leaves the legacy dir in place, with the recovery text, when the move fails", func() {
		write(session+"/headroom/mem", "keep")
		write(state+"/projects", "/p q\n")
		shim("mv", "#!/bin/sh\necho \"mv: simulated failure\" >&2\nexit 1\n")
		stranded, err := migrate.MoveLegacy(errOut, session, state, false, "headroom", "headroom")
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeTrue())
		Expect(read(session + "/headroom/mem")).To(Equal("keep"))
		info, err := os.Lstat(session + "/headroom")
		Expect(err).NotTo(HaveOccurred())
		Expect(info.IsDir()).To(BeTrue(), "legacy dir is no longer a real dir")
		Expect(errOut.String()).To(Equal(
			"Warning: could not move " + session + "/headroom to " + state + "/headroom; left it in place:\n" +
				"mv: simulated failure\n" +
				"         RiotBox will not retry this move on its own. Once the cause is fixed, run riotbox session-migrate /p\\ q, or move it by hand:\n" +
				"           mv -T -- " + session + "/headroom " + state + "/headroom\n" +
				"         If " + state + "/headroom exists by then (empty, partly copied from another disk, or written by a later launch), move it aside first.\n"))
	})

	It("quotes the hand-move command", func() {
		odd := tmp + "/my sess $(x);y"
		write(odd+"/headroom/mem", "keep")
		shim("mv", "#!/bin/sh\nexit 1\n")
		_, err := migrate.MoveLegacy(errOut, odd, state, false, "headroom", "headroom")
		Expect(err).NotTo(HaveOccurred())
		Expect(errOut.String()).To(ContainSubstring("\n           mv -T -- " + tmp + "/my\\ sess\\ \\$\\(x\\)\\;y/headroom " + state + "/headroom\n"))
	})

	It("leaves the legacy dir in place when the state dir cannot be created", func() {
		skipIfRoot()
		write(session+"/headroom/mem", "keep")
		mkdirs(tmp + "/ro")
		Expect(os.Chmod(tmp+"/ro", 0o500)).To(Succeed())
		roState := tmp + "/ro/root/key"
		stranded, err := migrate.MoveLegacy(errOut, session, roState, false, "headroom", "headroom")
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeTrue())
		Expect(read(session + "/headroom/mem")).To(Equal("keep"))
		Expect(errOut.String()).To(Equal(
			"Warning: could not prepare " + roState + "; left " + session + "/headroom in place:\n" +
				"mkdir " + tmp + "/ro/root: permission denied\n" +
				"         Once the cause is fixed, run " + fallbackHint + ".\n"))
	})

	It("discards a legacy dir swapped for a link during the move", func() {
		write(session+"/headroom/mem", "mem")
		GinkgoT().Setenv("VICTIM", victim)
		// Stands for a container swapping the entry between the type check
		// and the rename: it plants a link, then really moves it.
		shim("mv", "#!/bin/sh\nrm -rf \"$3\"\nln -s \"$VICTIM\" \"$3\"\nexec /usr/bin/mv \"$@\"\n")
		stranded, err := migrate.MoveLegacy(errOut, session, state, false, "headroom", "headroom")
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeFalse())
		Expect(exists(state+"/headroom")).To(BeFalse(), "the swapped-in link reached the state dir")
		Expect(exists(session+"/headroom")).To(BeFalse(), "legacy entry left behind")
		Expect(errOut.String()).To(Equal("Warning: " + session + "/headroom changed during the move; discarded it.\n"))
		expectVictimIntact()
	})
})

var _ = Describe("the overlay pair (migrate_overlay_state)", func() {
	It("moves overlay/ and removes every entry under it that is not a real directory", func() {
		write(session+"/overlay/project/upper/f.txt", "change")
		Expect(os.Symlink(victim, session+"/overlay/planted")).To(Succeed())
		write(session+"/overlay/file", "junk")
		stranded, err := migrate.MoveOverlay(errOut, libDir, session, state, false)
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeFalse())
		Expect(read(state + "/overlay/project/upper/f.txt")).To(Equal("change"))
		Expect(exists(state + "/overlay/planted")).To(BeFalse())
		Expect(exists(state + "/overlay/file")).To(BeFalse())
		Expect(errOut.String()).To(HavePrefix("Notice: moved " + session + "/overlay to " + state + "/overlay\n"))
		Expect(errOut.String()).To(ContainSubstring("Warning: " + state + "/overlay/planted is not a real directory; removed it without following it.\n"))
		Expect(errOut.String()).To(ContainSubstring("Warning: " + state + "/overlay/file is not a real directory; removed it without following it.\n"))
		expectVictimIntact()
	})

	It("cleans the state-dir overlay even with no legacy overlay, and keeps the stranded result", func() {
		write(session+"/overlay/project/upper/f.txt", "legacy")
		mkdirs(state + "/overlay/project")
		Expect(os.Symlink(victim, state+"/overlay/linked")).To(Succeed())
		stranded, err := migrate.MoveOverlay(errOut, libDir, session, state, false)
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeTrue())
		Expect(exists(state + "/overlay/linked")).To(BeFalse())
		Expect(exists(state + "/overlay/project")).To(BeTrue())
		expectVictimIntact()
	})

	It("fails, leaving the pair unrecorded, when the moved overlay cannot be listed", func() {
		skipIfRoot()
		mkdirs(session+"/overlay/project/upper", state)
		Expect(os.Symlink(victim, session+"/overlay/planted")).To(Succeed())
		// Search and write but no read: the container's way to hide what
		// it planted from the cleanup.
		Expect(os.Chmod(session+"/overlay", 0o300)).To(Succeed())
		Expect(migrate.SessionState(errOut, libDir, session, state)).NotTo(Succeed())
		Expect(errOut.String()).To(ContainSubstring(
			"ERROR: could not list " + state + "/overlay to remove what is not a real directory in it:\n" +
				"open " + state + "/overlay: permission denied\n" +
				"       RiotBox will not use it until it can. Make it readable (chmod u+rwx -- " + state + "/overlay), then run the command again.\n"))
		Expect(strings.Split(read(state+"/.migrated"), "\n")).NotTo(ContainElement("overlay"))

		Expect(os.Chmod(state+"/overlay", 0o700)).To(Succeed())
		errOut.Reset()
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(errOut.String()).To(Equal("Warning: " + state + "/overlay/planted is not a real directory; removed it without following it.\n"))
		Expect(exists(state + "/overlay/planted")).To(BeFalse())
		Expect(strings.Split(read(state+"/.migrated"), "\n")).To(ContainElement("overlay"))
		expectVictimIntact()
	})

	It("cleans a container-chosen name before printing it", func() {
		mkdirs(state + "/overlay")
		Expect(os.Symlink(victim, state+"/overlay/\x1b[31mred\nx")).To(Succeed())
		_, err := migrate.MoveOverlay(errOut, libDir, session, state, false)
		Expect(err).NotTo(HaveOccurred())
		Expect(errOut.String()).To(Equal("Warning: " + state + "/overlay/?[31mred?x is not a real directory; removed it without following it.\n"))
		Expect(os.ReadDir(state + "/overlay")).To(BeEmpty())
	})

	It("prints a placeholder, never the raw name, when the name cannot be cleaned", func() {
		mkdirs(state + "/overlay")
		Expect(os.Symlink(victim, state+"/overlay/\x1b[31mred")).To(Succeed())
		_, err := migrate.MoveOverlay(errOut, tmp+"/no-lib", session, state, false)
		Expect(err).NotTo(HaveOccurred())
		Expect(errOut.String()).NotTo(ContainSubstring("\x1b"))
		Expect(errOut.String()).To(HaveSuffix("Warning: " + state + "/overlay/(name not shown) is not a real directory; removed it without following it.\n"))
		Expect(os.ReadDir(state + "/overlay")).To(BeEmpty())
		expectVictimIntact()
	})

	It("prints the placeholder when jq is missing", func() {
		mkdirs(state+"/overlay", tmp+"/empty-path")
		Expect(os.Symlink(victim, state+"/overlay/\x1b[31mred")).To(Succeed())
		GinkgoT().Setenv("PATH", tmp+"/empty-path")
		_, err := migrate.MoveOverlay(errOut, libDir, session, state, false)
		Expect(err).NotTo(HaveOccurred())
		Expect(errOut.String()).To(Equal(
			"riotbox-core: exec: \"jq\": executable file not found in $PATH\n" +
				"Warning: " + state + "/overlay/(name not shown) is not a real directory; removed it without following it.\n"))
		Expect(os.ReadDir(state + "/overlay")).To(BeEmpty())
	})

	It("leaves a link at the state-dir overlay itself alone", func() {
		mkdirs(state)
		Expect(os.Symlink(victim, state+"/overlay")).To(Succeed())
		stranded, err := migrate.MoveOverlay(errOut, libDir, session, state, false)
		Expect(err).NotTo(HaveOccurred())
		Expect(stranded).To(BeFalse())
		Expect(errOut.String()).To(BeEmpty())
		expectVictimIntact()
	})
})

var _ = Describe("SessionState (migrate_session_state)", func() {
	It("returns without creating the state dir when there is nothing to migrate", func() {
		mkdirs(session)
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(exists(state)).To(BeFalse())
		Expect(errOut.String()).To(BeEmpty())
	})

	It("creates a private state dir, migrates every pair and records each in order", func() {
		for _, name := range []string{"headroom", "git-ai", ".config-opencode", ".local-share-opencode", ".pi-agent"} {
			write(session+"/"+name+"/data", name)
		}
		write(session+"/overlay/project/upper/f.txt", "change")
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		for legacy, newName := range map[string]string{
			"headroom": "headroom", "git-ai": "git-ai", ".config-opencode": "opencode-config",
			".local-share-opencode": "opencode-data", ".pi-agent": "pi-agent",
		} {
			Expect(read(state + "/" + newName + "/data")).To(Equal(legacy))
		}
		Expect(read(state + "/overlay/project/upper/f.txt")).To(Equal("change"))
		Expect(read(state + "/.migrated")).To(Equal(strings.Join(migrate.LegacyNames(), "\n") + "\n"))
		Expect(migrate.LegacyNames()).To(Equal([]string{"headroom", "git-ai", ".config-opencode", ".local-share-opencode", ".pi-agent", "overlay"}))
		info, err := os.Stat(state + "/.migrated")
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o600)))
		matches, err := filepath.Glob(state + "/.migrated.*")
		Expect(err).NotTo(HaveOccurred())
		Expect(matches).To(BeEmpty(), "a temp file was left behind")
	})

	It("does not record a pair that failed hard, so the next run retries it", func() {
		skipIfRoot()
		mkdirs(session, state)
		Expect(os.Symlink(victim, session+"/headroom")).To(Succeed())
		Expect(os.Chmod(session, 0o500)).To(Succeed())
		Expect(migrate.SessionState(errOut, libDir, session, state)).NotTo(Succeed())
		Expect(exists(state+"/.migrated")).To(BeFalse(), "the failed pair was recorded")

		Expect(os.Chmod(session, 0o700)).To(Succeed())
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(exists(session+"/headroom")).To(BeFalse(), "the retry did not remove the link")
		Expect(strings.Split(read(state+"/.migrated"), "\n")).To(ContainElement("headroom"))
		expectVictimIntact()
	})

	It("migrates a pair added after the session was marked once, and never re-imports the old pairs", func() {
		mkdirs(session, state)
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		// Planted after marking: an old pair, and the legacy path of a pair a
		// later release adds.
		write(session+"/headroom/mem.db", "planted")
		write(session+"/.newlegacy/data", "legacy")
		errOut.Reset()
		Expect(migrate.SessionStateWith(errOut, libDir, session, state, ".newlegacy", "newstate")).To(Succeed())
		Expect(read(state + "/newstate/data")).To(Equal("legacy"))
		Expect(exists(state+"/headroom")).To(BeFalse(), "an old pair was re-imported")
		Expect(read(session + "/headroom/mem.db")).To(Equal("planted"))
		Expect(strings.Split(read(state+"/.migrated"), "\n")).To(ContainElement(".newlegacy"))
		Expect(lineCount(errOut.String(), "Notice: moved")).To(Equal(1))

		write(session+"/.newlegacy/again", "again")
		errOut.Reset()
		Expect(migrate.SessionStateWith(errOut, libDir, session, state, ".newlegacy", "newstate")).To(Succeed())
		Expect(exists(state+"/newstate/again")).To(BeFalse(), "the new pair was imported twice")
		Expect(errOut.String()).To(BeEmpty())
	})

	It("counts a last marker line without a newline, and the append keeps one name per line", func() {
		write(session+"/headroom/mem.db", "planted")
		write(session+"/overlay/project/upper/injected.sh", "planted")
		write(session+"/.newlegacy/data", "legacy")
		write(state+"/.migrated", strings.Join(migrate.LegacyNames(), "\n"))
		Expect(migrate.SessionStateWith(errOut, libDir, session, state, ".newlegacy", "newstate")).To(Succeed())
		Expect(exists(state+"/overlay")).To(BeFalse(), "the unterminated last entry ran again")
		Expect(exists(state+"/headroom")).To(BeFalse(), "a recorded pair was re-imported")
		Expect(read(state + "/newstate/data")).To(Equal("legacy"))
		Expect(read(state + "/.migrated")).To(Equal(strings.Join(append(migrate.LegacyNames(), ".newlegacy"), "\n") + "\n"))
	})

	It("records a run that left both dirs in place, warns only once, then notices on later runs", func() {
		write(session+"/git-ai/config.json", "old")
		mkdirs(state + "/git-ai")
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(errOut.String()).To(ContainSubstring("both " + session + "/git-ai and " + state + "/git-ai exist"))
		Expect(errOut.String()).NotTo(ContainSubstring("Notice:"))
		Expect(read(state + "/.migrated")).To(Equal("headroom\ngit-ai\nfailed:git-ai\n.config-opencode\n.local-share-opencode\n.pi-agent\noverlay\n"))

		// The new dir is still empty: a retry could move over it.
		errOut.Reset()
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(errOut.String()).To(Equal("Notice: legacy data is still at " + session + "/git-ai; once the cause is fixed, run " + fallbackHint + ".\n"))

		write(state+"/git-ai/written-by-a-session", "session")
		errOut.Reset()
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(errOut.String()).To(Equal("Notice: two copies of legacy session data need resolving, " + session + "/git-ai and " + state + "/git-ai; run " + fallbackHint + " to see how.\n"))
		Expect(read(session + "/git-ai/config.json")).To(Equal("old"))
		Expect(read(state + "/git-ai/written-by-a-session")).To(Equal("session"))
	})

	It("never replaces an existing new dir on a launch, even an empty one", func() {
		write(session+"/headroom/mem.db", "old")
		mkdirs(state + "/headroom")
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(errOut.String()).To(ContainSubstring("both " + session + "/headroom and " + state + "/headroom exist"))
		Expect(read(session + "/headroom/mem.db")).To(Equal("old"))
	})

	It("notices a failed pair with the recorded projects, quoted, and falls back without a record", func() {
		write(session+"/headroom/mem.db", "keep")
		write(state+"/.migrated", "headroom\nfailed:headroom\n")
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(errOut.String()).To(Equal("Notice: legacy data is still at " + session + "/headroom; once the cause is fixed, run " + fallbackHint + ".\n"))

		write(state+"/projects", "/a/app\n/b/my lib\n")
		errOut.Reset()
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(errOut.String()).To(Equal("Notice: legacy data is still at " + session + "/headroom; once the cause is fixed, run riotbox session-migrate /a/app /b/my\\ lib.\n"))
		Expect(read(session + "/headroom/mem.db")).To(Equal("keep"))
	})

	DescribeTable("records a failed pair done, quietly, once its legacy path holds nothing",
		func(plant func(legacy string)) {
			mkdirs(session)
			write(state+"/.migrated", "headroom\nfailed:headroom\n")
			plant(session + "/headroom")
			Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
			Expect(errOut.String()).To(BeEmpty())
			Expect(read(state + "/.migrated")).To(Equal(
				"headroom\nfailed:headroom\ngit-ai\n.config-opencode\n.local-share-opencode\n.pi-agent\noverlay\nheadroom\n"))
			expectVictimIntact()
		},
		Entry("gone", func(string) {}),
		Entry("empty", func(legacy string) { mkdirs(legacy) }),
		Entry("a link to a dir with data", func(legacy string) { Expect(os.Symlink(victim, legacy)).To(Succeed()) }),
	)

	It("does not take an unreadable legacy dir for empty", func() {
		skipIfRoot()
		mkdirs(session+"/headroom", state)
		write(state+"/.migrated", "headroom\nfailed:headroom\n")
		Expect(os.Chmod(session+"/headroom", 0o000)).To(Succeed())
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(errOut.String()).To(ContainSubstring("Notice: legacy data is still at " + session + "/headroom"))
		Expect(read(state + "/.migrated")).To(HaveSuffix("failed:headroom\ngit-ai\n.config-opencode\n.local-share-opencode\n.pi-agent\noverlay\n"))
	})

	It("works through a state dir the user linked to another disk", func() {
		mkdirs(tmp+"/disk/key", filepath.Dir(state))
		Expect(os.Symlink(tmp+"/disk/key", state)).To(Succeed())
		write(session+"/headroom/mem", "m")
		Expect(migrate.SessionState(errOut, libDir, session, state)).To(Succeed())
		Expect(read(tmp + "/disk/key/headroom/mem")).To(Equal("m"))
		Expect(read(tmp + "/disk/key/.migrated")).To(HavePrefix("headroom\n"))
		Expect(exists(tmp + "/disk/key/.migrate.lock")).To(BeTrue())
	})
})

var _ = Describe("the listing behind dirHasData", func() {
	It("returns promptly, as no data, for a FIFO swapped in after the type check", func() {
		mkdirs(session)
		Expect(syscall.Mkfifo(session+"/headroom", 0o600)).To(Succeed())
		done := make(chan bool, 1)
		go func() { done <- migrate.ListsEntries(session + "/headroom") }()
		// An open that waited for a writer would hang every later launch
		// behind .migrate.lock.
		Eventually(done, "2s").Should(Receive(BeFalse()))
	})

	It("does not follow a link swapped in after the type check", func() {
		mkdirs(session)
		Expect(os.Symlink(victim, session+"/headroom")).To(Succeed())
		Expect(migrate.ListsEntries(session + "/headroom")).To(BeFalse())
	})

	It("counts a real dir with an entry, and one it cannot list, as data", func() {
		write(session+"/headroom/mem", "m")
		Expect(migrate.ListsEntries(session + "/headroom")).To(BeTrue())
		mkdirs(session + "/empty")
		Expect(migrate.ListsEntries(session + "/empty")).To(BeFalse())
		if os.Geteuid() != 0 {
			Expect(os.Chmod(session+"/empty", 0o000)).To(Succeed())
			Expect(migrate.ListsEntries(session + "/empty")).To(BeTrue())
		}
	})
})

package migrate_test

import (
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/migrate"
)

var _ = Describe("AllSessions (riotbox overlays' migration pass)", func() {
	const (
		rootWait    = "Waiting for another RiotBox command to finish moving sessions to their new keys…\n"
		sessionWait = "Waiting for another RiotBox command on this session to finish migrating its state…\n"
	)
	var dataDir, stateRoot string

	BeforeEach(func() {
		dataDir = tmp + "/data/riotbox"
		stateRoot = tmp + "/data/riotbox-state"
	})

	// legacySession stages a session dir with .projects and a headroom dir an
	// older RiotBox left in it.
	legacySession := func(name string) string {
		write(dataDir+"/"+name+"/.projects", "/p/"+name+"\n")
		write(dataDir+"/"+name+"/headroom/mem", name)
		return dataDir + "/" + name
	}
	moved := func(name string) string {
		return "Notice: moved " + dataDir + "/" + name + "/headroom to " + stateRoot + "/" + name + "/headroom\n"
	}

	It("migrates every session, in name order, and creates the state root mode 0700", func() {
		legacySession("b-key")
		legacySession("a-key")
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(Equal(moved("a-key") + moved("b-key")))
		Expect(read(stateRoot + "/a-key/headroom/mem")).To(Equal("a-key"))
		Expect(read(stateRoot + "/b-key/headroom/mem")).To(Equal("b-key"))
		info, err := os.Stat(stateRoot)
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o700)))
	})

	It("creates the state root mode 0700 even when no session has anything to migrate", func() {
		write(dataDir+"/key/.projects", "/p\n")
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(BeEmpty())
		info, err := os.Stat(stateRoot)
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o700)))
		Expect(exists(stateRoot + "/key")).To(BeFalse())
	})

	It("counts a dir as a session by the launch's record alone", func() {
		write(dataDir+"/key/headroom/mem", "m")
		write(stateRoot+"/key/projects", "/p/key\n")
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(Equal(moved("key")))
	})

	It("skips what is not a session: a dir with no marker, a hidden dir with no marker, a file", func() {
		write(dataDir+"/plain/headroom/mem", "m")
		write(dataDir+"/.hidden/headroom/mem", "m")
		write(dataDir+"/file", "x")
		legacySession("key")
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(Equal(moved("key")))
		Expect(exists(dataDir + "/plain/headroom/mem")).To(BeTrue())
		Expect(exists(dataDir + "/.hidden/headroom/mem")).To(BeTrue())
		Expect(exists(stateRoot + "/plain")).To(BeFalse())
		Expect(exists(stateRoot + "/.hidden")).To(BeFalse())
	})

	It("migrates a session whose key starts with a dot", func() {
		legacySession(".dotfiles-1more-0123456789abcdef")
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(Equal(moved(".dotfiles-1more-0123456789abcdef")))
	})

	It("does nothing, creating no state root, when there is no session", func() {
		write(dataDir+"/plain/headroom/mem", "m")
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(BeEmpty())
		Expect(exists(stateRoot)).To(BeFalse())
	})

	It("does nothing when the data dir is missing", func() {
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(BeEmpty())
		Expect(exists(stateRoot)).To(BeFalse())
	})

	It("migrates a link to a session dir through the link, as the bash glob and -d follow it", func() {
		write(tmp+"/elsewhere/.projects", "/p\n")
		write(tmp+"/elsewhere/headroom/mem", "m")
		mkdirs(dataDir)
		Expect(os.Symlink(tmp+"/elsewhere", dataDir+"/key")).To(Succeed())
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(Equal(moved("key")))
		Expect(read(stateRoot + "/key/headroom/mem")).To(Equal("m"))
	})

	It("stops at the first session that fails, leaving the rest, and returns its error", func() {
		legacySession("a-key")
		legacySession("b-key")
		write(stateRoot+"/a-key", "a file where the state dir goes")
		err := migrate.AllSessions(errOut, libDir, dataDir, stateRoot)
		Expect(err).To(HaveOccurred())
		Expect(errOut.String()).To(HavePrefix("riotbox-core: mkdir " + stateRoot + "/a-key: "))
		Expect(errOut.String()).NotTo(ContainSubstring("b-key"))
		Expect(exists(dataDir + "/b-key/headroom/mem")).To(BeTrue())
		Expect(exists(stateRoot + "/b-key")).To(BeFalse())
	})

	It("fails, migrating nothing, when the state root cannot be made", func() {
		legacySession("key")
		write(stateRoot, "a file where the state root goes")
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).NotTo(Succeed())
		Expect(errOut.String()).To(HavePrefix("riotbox-core: mkdir " + stateRoot + ": "))
		Expect(exists(dataDir + "/key/headroom/mem")).To(BeTrue())
	})

	// holdWithFlock holds <path> with flock(1) in another process, as a bash
	// _with_migrate_lock would, until the returned func is called.
	holdWithFlock := func(path string) func() {
		holder := exec.Command("flock", "-x", path, "cat")
		stdin, err := holder.StdinPipe()
		Expect(err).NotTo(HaveOccurred())
		Expect(holder.Start()).To(Succeed())
		Eventually(func() error { return exec.Command("flock", "-n", path, "true").Run() }, 10*time.Second).
			Should(HaveOccurred(), "flock(1) never took the lock")
		released := false
		release := func() {
			if !released {
				released = true
				Expect(stdin.Close()).To(Succeed())
				Expect(holder.Wait()).To(Succeed())
			}
		}
		DeferCleanup(release)
		return release
	}

	run := func(w io.Writer) chan error {
		done := make(chan error, 1)
		go func() { done <- migrate.AllSessions(w, libDir, dataDir, stateRoot) }()
		return done
	}

	It("takes the state root's lock first, saying so while it waits", func() {
		legacySession("key")
		mkdirs(stateRoot)
		release := holdWithFlock(stateRoot + "/.migrate.lock")
		out := &syncBuffer{}
		done := run(out)
		Eventually(out.String, 10*time.Second).Should(Equal(rootWait))
		Consistently(done, 200*time.Millisecond).ShouldNot(Receive())
		Expect(exists(stateRoot+"/key")).To(BeFalse(), "it migrated without the root lock")
		release()
		Eventually(done, 10*time.Second).Should(Receive(BeNil()))
		Expect(out.String()).To(Equal(rootWait + moved("key")))
	})

	It("holds the root lock while it waits for a session's, never deadlocking", func() {
		legacySession("key")
		mkdirs(stateRoot + "/key")
		release := holdWithFlock(stateRoot + "/key/.migrate.lock")
		out := &syncBuffer{}
		done := run(out)
		Eventually(out.String, 10*time.Second).Should(Equal(sessionWait))
		err := exec.Command("flock", "-n", stateRoot+"/.migrate.lock", "true").Run()
		var exitErr *exec.ExitError
		Expect(err).To(BeAssignableToTypeOf(exitErr), "the root lock is free while it waits for the session's")
		Consistently(done, 200*time.Millisecond).ShouldNot(Receive())
		release()
		Eventually(done, 10*time.Second).Should(Receive(BeNil()))
		Expect(out.String()).To(Equal(sessionWait + moved("key")))
		Expect(exec.Command("flock", "-n", stateRoot+"/.migrate.lock", "true").Run()).To(Succeed())
	})

	It("skips a dir a launch has not made a session yet even when its state dir is locked", func() {
		write(dataDir+"/plain/headroom/mem", "m")
		legacySession("key")
		mkdirs(stateRoot + "/plain")
		holdWithFlock(stateRoot + "/plain/.migrate.lock")
		Expect(migrate.AllSessions(errOut, libDir, dataDir, stateRoot)).To(Succeed())
		Expect(errOut.String()).To(Equal(moved("key")))
		Expect(syscall.Access(dataDir+"/plain/headroom/mem", 0)).To(Succeed())
	})
})

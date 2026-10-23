package migrate_test

import (
	"bytes"
	"fmt"
	"os"
	"sync"
	"syscall"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/migrate"
	"github.com/trevor-vaughan/claude-riotbox/internal/sessionkey"
)

var _ = Describe("SessionKey (migrate_session_key)", func() {
	const oldKey = "-p-app"
	const mover = "RiotBox's move to the new session key"
	var dataDir, stateRoot, eng string
	var oldSession, oldState, newSession, newState string
	var set []string

	// fakeEngine writes an engine that lists the container abc and prints
	// inspect, a shell printf format, for its mounts; with rc non-zero every
	// call fails.
	fakeEngine := func(inspect string, rc int) {
		script := fmt.Sprintf("#!/bin/sh\n[ %d -eq 0 ] || { echo engine down >&2; exit %d; }\n"+
			"case \"$1\" in ps) echo abc ;; container) printf '%s' ;; esac\n", rc, rc, inspect)
		Expect(os.WriteFile(eng, []byte(script), 0o700)).To(Succeed())
	}

	// mvShim puts an mv on PATH that logs each source (mv -T -- <src> <dst>)
	// to <tmp>/mv.calls and fails its call number failOn (0: never) with
	// "mv: shim refused".
	mvShim := func(failOn int) {
		shim("mv", fmt.Sprintf("#!/bin/sh\nlog=%q\nprintf '%%s\\n' \"$3\" >>\"$log\"\n"+
			"n=$(wc -l <\"$log\")\n[ \"$n\" -ne %d ] || { echo 'mv: shim refused' >&2; exit 1; }\n"+
			"PATH=/usr/bin:/bin exec mv \"$@\"\n", tmp+"/mv.calls", failOn))
	}

	moveKey := func(keys ...string) error {
		if len(keys) == 0 {
			keys = []string{oldKey}
		}
		return migrate.SessionKey(errOut, eng, libDir, dataDir, stateRoot, keys, set)
	}

	BeforeEach(func() {
		dataDir = tmp + "/data/riotbox"
		stateRoot = tmp + "/data/riotbox-state"
		eng = tmp + "/engine"
		fakeEngine(`abc\0web\0/elsewhere\0true\0\n`, 0)
		set = []string{"/p/app"}
		key := sessionkey.Key(set)
		oldSession, oldState = dataDir+"/"+oldKey, stateRoot+"/"+oldKey
		newSession, newState = dataDir+"/"+key, stateRoot+"/"+key
	})

	Describe("the evidence that the old session is this set's", func() {
		It("moves both dirs, the state dir last, when the record names this set", func() {
			mvShim(0)
			write(oldSession+"/.projects", "/elsewhere\n")
			write(oldSession+"/data", "s")
			write(oldState+"/projects", "/p/app\n")
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(Equal(
				"Notice: moved " + oldSession + " to " + newSession + "\n" +
					"Notice: moved " + oldState + " to " + newState + "\n"))
			Expect(read(tmp + "/mv.calls")).To(Equal(oldSession + "\n" + oldState + "\n"))
			Expect(read(newSession + "/data")).To(Equal("s"))
			Expect(read(newState + "/projects")).To(Equal("/p/app\n"))
			Expect(exists(oldSession) || exists(oldState)).To(BeFalse())
		})

		It("moves by .projects, the session dir last, with a note, when there is no record", func() {
			mvShim(0)
			write(oldSession+"/.projects", "/p/app\n")
			mkdirs(oldState + "/headroom")
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(Equal(
				"Notice: moved " + oldState + " to " + newState + "\n" +
					"Notice: moved " + oldSession + " to " + newSession +
					" (matched by its .projects: an older RiotBox left no record)\n"))
			Expect(read(tmp + "/mv.calls")).To(Equal(oldState + "\n" + oldSession + "\n"))
			Expect(exists(newState+"/projects")).To(BeFalse(), "a record was written")
		})

		It("moves a session an older release left without a state dir by its .projects", func() {
			write(oldSession+"/.projects", "/p/app\n")
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(Equal("Notice: moved " + oldSession + " to " + newSession +
				" (matched by its .projects: an older RiotBox left no record)\n"))
			Expect(exists(newState)).To(BeFalse())
			Expect(read(newSession + "/.projects")).To(Equal("/p/app\n"))
		})

		DescribeTable("a run that stops between the two moves leaves the evidence for the next run",
			func(byRecord bool) {
				write(oldSession+"/.projects", "/p/app\n")
				mkdirs(oldState)
				evidence, first, firstNew := oldSession, oldState, newState
				if byRecord {
					write(oldState+"/projects", "/p/app\n")
					evidence, first, firstNew = oldState, oldSession, newSession
				}
				mvShim(2)
				err := moveKey()
				Expect(err).To(HaveOccurred())
				Expect(exists(evidence)).To(BeTrue(), "the evidence moved first")
				Expect(exists(first)).To(BeFalse())
				Expect(exists(firstNew)).To(BeTrue())
				Expect(errOut.String()).To(HaveSuffix("mv: shim refused\n" +
					"       Fix the cause and run the command again; the next run finishes the move.\n"))
				Expect(errOut.String()).To(ContainSubstring("Error: could not move " + evidence + " to "))

				By("the next run finishing the move by the same evidence")
				errOut.Reset()
				Expect(os.Remove(tmp + "/shim/mv")).To(Succeed())
				Expect(moveKey()).To(Succeed())
				Expect(errOut.String()).To(HavePrefix("Notice: moved " + evidence + " to "))
				Expect(exists(oldSession) || exists(oldState)).To(BeFalse())
			},
			Entry("by the record: the state dir is last", true),
			Entry("by .projects: the session dir is last", false),
		)

		It("refuses an old state dir whose record cannot be read, never taking it for no record", func() {
			skipIfRoot()
			write(oldSession+"/.projects", "/p/app\n")
			write(oldState+"/projects", "/p/app\n")
			Expect(os.Chmod(oldState+"/projects", 0o000)).To(Succeed())
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(Equal(
				"riotbox-core: open " + oldState + "/projects: permission denied\n" +
					"Warning: " + oldState + "/projects is not a readable project record, so " + oldSession +
					" cannot be shown to be this set's; left it in place. This set uses " + newSession + ".\n"))
			Expect(exists(oldSession) && exists(oldState)).To(BeTrue())
			Expect(exists(newSession) || exists(newState)).To(BeFalse())
		})

		DescribeTable("refuses a record that is there but names no set",
			func(plant func(path string)) {
				write(oldSession+"/.projects", "/p/app\n")
				mkdirs(oldState)
				plant(oldState + "/projects")
				Expect(moveKey()).To(Succeed())
				Expect(errOut.String()).To(Equal(
					"Warning: " + oldState + "/projects is not a readable project record, so " + oldSession +
						" cannot be shown to be this set's; left it in place. This set uses " + newSession + ".\n"))
				Expect(exists(newSession) || exists(newState)).To(BeFalse())
			},
			Entry("an empty record", func(p string) { write(p, "") }),
			Entry("a directory", func(p string) { mkdirs(p) }),
			Entry("a link to a record naming this set", func(p string) {
				write(tmp+"/elsewhere", "/p/app\n")
				Expect(os.Symlink(tmp+"/elsewhere", p)).To(Succeed())
			}),
			Entry("a dangling link", func(p string) { Expect(os.Symlink(tmp+"/nowhere", p)).To(Succeed()) }),
		)

		It("leaves a state dir with no record and no session dir, with a notice", func() {
			mkdirs(oldState + "/headroom")
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(Equal("Notice: " + oldState + " is under this project set's old key, " +
				"with no record and no session dir to show whose it is; left it in place. This set uses " + newState + ".\n"))
			Expect(exists(oldState + "/headroom")).To(BeTrue())
			Expect(exists(newState)).To(BeFalse())
		})

		DescribeTable("never trusts .projects under an old key shaped like a current one",
			func(withState bool) {
				const crafted = "app-0123456789abcdef"
				session, state := dataDir+"/"+crafted, stateRoot+"/"+crafted
				write(session+"/.projects", "/p/app\n")
				want := "Warning: " + session + " has no record and a name a current session key can have, " +
					"so its .projects is not trusted; left it in place. This set uses " + newSession + ".\n" +
					"         If it is this set's session (check what " + session + "/.projects names first), " +
					"exit every session using it and move it by hand:\n" +
					"           mv -T -- " + session + " " + newSession + "\n"
				if withState {
					mkdirs(state)
					want += "           mv -T -- " + state + " " + newState + "\n"
				}
				Expect(moveKey(crafted)).To(Succeed())
				Expect(errOut.String()).To(Equal(want))
				Expect(exists(newSession) || exists(newState)).To(BeFalse())
			},
			Entry("without a state dir", false),
			Entry("with a state dir", true),
		)

		It("quotes the hand-move commands so a pasted path is exactly that path", func() {
			crafted := "a b$'x-0123456789abcdef"
			write(dataDir+"/"+crafted+"/.projects", "/p/app\n")
			Expect(moveKey(crafted)).To(Succeed())
			Expect(errOut.String()).To(ContainSubstring(`           mv -T -- ` + dataDir + `/a\ b\$\'x-0123456789abcdef ` + newSession + "\n"))
		})

		DescribeTable("leaves a session whose .projects names no readable set, with a notice",
			func(plant func(path string)) {
				mkdirs(oldSession)
				plant(oldSession + "/.projects")
				Expect(moveKey()).To(Succeed())
				Expect(errOut.String()).To(Equal("Notice: " + oldSession + " is under this project set's old key, " +
					"but its .projects names no readable set; left it in place. This set uses " + newSession + ".\n"))
				Expect(exists(newSession)).To(BeFalse())
			},
			Entry("no .projects", func(string) {}),
			Entry("an empty .projects", func(p string) { write(p, "\n\n") }),
			Entry("a link to a list naming this set", func(p string) {
				write(tmp+"/elsewhere", "/p/app\n")
				Expect(os.Symlink(tmp+"/elsewhere", p)).To(Succeed())
			}),
			Entry("a directory", func(p string) { mkdirs(p) }),
			Entry("a FIFO, which must not block the read", func(p string) {
				Expect(syscall.Mkfifo(p, 0o600)).To(Succeed())
			}),
		)

		It("leaves an unreadable .projects with the same notice", func() {
			skipIfRoot()
			write(oldSession+"/.projects", "/p/app\n")
			Expect(os.Chmod(oldSession+"/.projects", 0o000)).To(Succeed())
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(Equal("Notice: " + oldSession + " is under this project set's old key, " +
				"but its .projects names no readable set; left it in place. This set uses " + newSession + ".\n"))
		})

		It("leaves a session whose evidence names another set, showing that set cleaned", func() {
			write(oldSession+"/.projects", "/p/app\n")
			write(oldState+"/projects", "/p-app\n/evil\x1b[2Jpath\n")
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(Equal(
				"Warning: " + oldSession + " is the session an older RiotBox kept under this project\n" +
					"         set's old key, but it belongs to another project set; left it in place.\n" +
					"         This set uses " + newSession + ". The old session's set:\n" +
					"           /p-app\n" +
					"           /evil?[2Jpath\n"))
			Expect(exists(newSession) || exists(newState)).To(BeFalse())
		})

		It("prints no raw byte of the other set when jq cannot clean it", func() {
			shim("jq", "#!/bin/sh\necho 'jq: broken' >&2\nexit 3\n")
			write(oldSession+"/.projects", "/evil\x1b[2Jpath\n")
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(HaveSuffix("The old session's set:\njq: broken\n"))
			Expect(errOut.String()).NotTo(ContainSubstring("\x1b"))
		})
	})

	Describe("the moves", func() {
		BeforeEach(func() {
			write(oldSession+"/.projects", "/p/app\n")
			write(oldState+"/projects", "/p/app\n")
		})

		It("does nothing, silently, once both of the set's own dirs exist", func() {
			mkdirs(newSession, newState)
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(BeEmpty())
			Expect(exists(oldSession) && exists(oldState)).To(BeTrue())
		})

		It("leaves both and warns when the set's own session dir exists, moving the state dir alone", func() {
			mkdirs(newSession)
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(Equal(
				"Warning: both " + oldSession + " and " + newSession + " exist; left both untouched.\n" +
					"         RiotBox now uses " + newSession + ". Move anything you need out of " + oldSession + ", then delete it.\n" +
					"Notice: moved " + oldState + " to " + newState + "\n"))
			Expect(exists(oldSession)).To(BeTrue())
		})

		It("takes a dangling link at the new path for an existing entry, never writing through it", func() {
			Expect(os.Symlink(victim+"/new", newSession)).To(Succeed())
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(HavePrefix("Warning: both " + oldSession + " and " + newSession + " exist;"))
			expectVictimIntact()
		})

		It("moves an old session dir that is a link as the link, without following it", func() {
			Expect(os.Rename(oldSession, victim+"/session")).To(Succeed())
			Expect(os.Symlink(victim+"/session", oldSession)).To(Succeed())
			Expect(moveKey()).To(Succeed())
			target, err := os.Readlink(newSession)
			Expect(err).NotTo(HaveOccurred())
			Expect(target).To(Equal(victim + "/session"))
			Expect(read(victim + "/session/.projects")).To(Equal("/p/app\n"))
		})

		It("creates the state root mode 0700 before taking its lock", func() {
			Expect(os.RemoveAll(stateRoot)).To(Succeed())
			Expect(moveKey()).To(Succeed())
			info, err := os.Stat(stateRoot)
			Expect(err).NotTo(HaveOccurred())
			Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o700)))
			Expect(exists(stateRoot + "/.migrate.lock")).To(BeTrue())
		})

		It("refuses, moving nothing, while a running container can write the old dirs", func() {
			fakeEngine(`abc\0web\0`+oldState+`/headroom\0true\0\n`, 0)
			err := moveKey()
			Expect(err).To(HaveOccurred())
			Expect(errOut.String()).To(Equal(
				"ERROR: container web mounts " + oldState + "/headroom read-write, which reaches the session of /p/app, and is still running.\n" +
					"       It can still write to what " + mover + " would move. Stop that container (exit its session), then launch again.\n" +
					"       Nothing was moved: " + newSession + " gets the session once nothing runs on " + oldSession + ".\n"))
			Expect(exists(oldSession) && exists(oldState)).To(BeTrue())
			Expect(exists(newSession) || exists(newState)).To(BeFalse())
		})

		It("refuses, failing closed, when the engine cannot answer", func() {
			fakeEngine("", 125)
			err := moveKey()
			Expect(err).To(HaveOccurred())
			Expect(errOut.String()).To(Equal(
				"engine down\n" +
					"ERROR: could not ask '" + eng + "' whether a running container mounts the session of /p/app.\n" +
					"       " + mover + " refuses while it cannot tell: a running session can still write to what it would move.\n" +
					"       Make sure the container engine works (and that the session has exited), then retry.\n" +
					"       Nothing was moved: " + newSession + " gets the session once nothing runs on " + oldSession + ".\n"))
			Expect(exists(newSession) || exists(newState)).To(BeFalse())
		})

		It("does not ask the engine when there is nothing to move", func() {
			mkdirs(newSession, newState)
			fakeEngine("", 125)
			Expect(moveKey()).To(Succeed())
			Expect(errOut.String()).To(BeEmpty())
		})

		// holdRootLock takes the state root's lock as another RiotBox command
		// would, and returns the call that releases it.
		holdRootLock := func() func() {
			mkdirs(stateRoot)
			f, err := os.OpenFile(stateRoot+"/.migrate.lock", os.O_WRONLY|os.O_CREATE, 0o600)
			Expect(err).NotTo(HaveOccurred())
			Expect(syscall.Flock(int(f.Fd()), syscall.LOCK_EX)).To(Succeed())
			return func() { Expect(f.Close()).To(Succeed()) }
		}

		It("says, while it waits, that it waits for the state root's lock", func() {
			release := holdRootLock()
			out := &syncBuffer{}
			done := make(chan error)
			go func() {
				done <- migrate.SessionKey(out, eng, libDir, dataDir, stateRoot, []string{oldKey}, set)
			}()
			Eventually(out.String).Should(Equal(
				"Waiting for another RiotBox command to finish moving sessions to their new keys…\n"))
			Consistently(done, 200*time.Millisecond).ShouldNot(Receive())
			Expect(exists(newSession)).To(BeFalse(), "it moved without the lock")
			release()
			Eventually(done).Should(Receive(BeNil()))
			Expect(exists(newSession) && exists(newState)).To(BeTrue())
		})

		It("re-checks under the lock, and moves nothing once a concurrent run created the set's dirs", func() {
			release := holdRootLock()
			out := &syncBuffer{}
			done := make(chan error)
			go func() {
				done <- migrate.SessionKey(out, eng, libDir, dataDir, stateRoot, []string{oldKey}, set)
			}()
			Eventually(out.String).ShouldNot(BeEmpty())
			mkdirs(newSession, newState)
			release()
			Eventually(done).Should(Receive(BeNil()))
			Expect(out.String()).To(Equal("Waiting for another RiotBox command to finish moving sessions to their new keys…\n"))
			Expect(exists(oldSession) && exists(oldState)).To(BeTrue())
		})
	})

	Describe("two old keys (a project named twice)", func() {
		const twice = "-p-app-p-app"

		It("moves the first, then warns once about a second whose evidence names this set too", func() {
			write(dataDir+"/"+twice+"/.projects", "/p/app\n/p/app\n")
			mkdirs(stateRoot + "/" + twice)
			write(oldSession+"/.projects", "/p/app\n")
			mkdirs(oldState)
			Expect(moveKey(twice, oldKey)).To(Succeed())
			Expect(errOut.String()).To(Equal(
				"Notice: moved " + stateRoot + "/" + twice + " to " + newState + "\n" +
					"Notice: moved " + dataDir + "/" + twice + " to " + newSession +
					" (matched by its .projects: an older RiotBox left no record)\n" +
					"Warning: both " + oldSession + " and " + newSession + " hold a session of this project set; left " + oldSession + " untouched.\n" +
					"         RiotBox now uses " + newSession + ". Move anything you need out of " + oldSession + " and " + oldState + ", then delete them.\n"))
			Expect(exists(oldSession) && exists(oldState)).To(BeTrue())
		})

		It("names only the session dir when the second has no state dir", func() {
			write(dataDir+"/"+twice+"/.projects", "/p/app\n")
			mkdirs(stateRoot + "/" + twice)
			write(oldSession+"/.projects", "/p/app\n")
			Expect(moveKey(twice, oldKey)).To(Succeed())
			Expect(lineCount(errOut.String(), "Warning: both")).To(Equal(1))
			Expect(errOut.String()).To(HaveSuffix("Move anything you need out of " + oldSession + ", then delete it.\n"))
		})

		It("says nothing of a second whose evidence names another set", func() {
			write(dataDir+"/"+twice+"/.projects", "/p/app\n")
			mkdirs(stateRoot + "/" + twice)
			write(oldSession+"/.projects", "/p-app\n")
			Expect(moveKey(twice, oldKey)).To(Succeed())
			Expect(lineCount(errOut.String(), "Warning")).To(BeZero())
		})

		It("says nothing of a second when the first moved nothing in this run", func() {
			mkdirs(newSession, newState)
			write(oldSession+"/.projects", "/p/app\n")
			Expect(moveKey(twice, oldKey)).To(Succeed())
			Expect(errOut.String()).To(BeEmpty())
		})

		It("holds the second to the both-exist rule when the first moved one dir only", func() {
			write(dataDir+"/"+twice+"/.projects", "/p/app\n")
			write(oldSession+"/.projects", "/p/app\n")
			write(oldState+"/projects", "/p/app\n")
			Expect(moveKey(twice, oldKey)).To(Succeed())
			Expect(errOut.String()).To(ContainSubstring(
				"Warning: both " + oldSession + " and " + newSession + " exist; left both untouched.\n"))
			Expect(errOut.String()).To(HaveSuffix("Notice: moved " + oldState + " to " + newState + "\n"))
			Expect(exists(oldSession)).To(BeTrue())
		})
	})
})

// syncBuffer lets a spec read what another goroutine wrote.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
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

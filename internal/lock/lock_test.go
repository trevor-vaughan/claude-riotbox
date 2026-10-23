package lock_test

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/lock"
)

// waitMsg is the first wait message from _with_migrate_lock in
// scripts/lib/session-state.sh, including its non-ASCII ellipsis.
const waitMsg = "Waiting for another RiotBox command to finish moving sessions to their new keys…"

// syncBuffer lets a spec read what Acquire wrote from another goroutine.
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

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("write failed") }

var _ = Describe("Acquire", func() {
	var path string

	BeforeEach(func() {
		path = filepath.Join(GinkgoT().TempDir(), ".migrate.lock")
	})

	It("prints nothing when uncontended", func() {
		var out syncBuffer
		release, err := lock.Acquire(path, waitMsg, &out)
		Expect(err).NotTo(HaveOccurred())
		Expect(out.String()).To(BeEmpty())
		Expect(release()).To(Succeed())
	})

	It("creates the file with 0666 minus the umask, as bash's exec >file does", func() {
		old := syscall.Umask(0o027)
		DeferCleanup(func() { syscall.Umask(old) })
		release, err := lock.Acquire(path, waitMsg, &syncBuffer{})
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(release)
		info, err := os.Stat(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o640)))
	})

	It("truncates an existing lock file, as bash's > does", func() {
		Expect(os.WriteFile(path, []byte("stale"), 0o600)).To(Succeed())
		release, err := lock.Acquire(path, waitMsg, &syncBuffer{})
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(release)
		info, err := os.Stat(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Size()).To(BeZero())
	})

	It("still takes the lock when the wait message cannot be written", func() {
		first, err := lock.Acquire(path, waitMsg, &syncBuffer{})
		Expect(err).NotTo(HaveOccurred())
		acquired := make(chan func() error, 1)
		go func() {
			defer GinkgoRecover()
			second, err := lock.Acquire(path, waitMsg, failingWriter{})
			Expect(err).NotTo(HaveOccurred())
			acquired <- second
		}()
		Consistently(acquired, 300*time.Millisecond).ShouldNot(Receive())
		Expect(first()).To(Succeed())
		var second func() error
		Eventually(acquired, 10*time.Second).Should(Receive(&second))
		Expect(second()).To(Succeed())
	})

	It("fails when the lock file cannot be created", func() {
		_, err := lock.Acquire(filepath.Join(path, "missing", "lock"), waitMsg, &syncBuffer{})
		Expect(err).To(HaveOccurred())
	})

	It("lets the lock be taken again after release", func() {
		release, err := lock.Acquire(path, waitMsg, &syncBuffer{})
		Expect(err).NotTo(HaveOccurred())
		Expect(release()).To(Succeed())
		var out syncBuffer
		release, err = lock.Acquire(path, waitMsg, &out)
		Expect(err).NotTo(HaveOccurred())
		Expect(out.String()).To(BeEmpty())
		Expect(release()).To(Succeed())
	})

	It("blocks a second acquirer, announces the wait, and proceeds on release", func() {
		first, err := lock.Acquire(path, waitMsg, &syncBuffer{})
		Expect(err).NotTo(HaveOccurred())

		var out syncBuffer
		acquired := make(chan func() error, 1)
		go func() {
			defer GinkgoRecover()
			second, err := lock.Acquire(path, waitMsg, &out)
			Expect(err).NotTo(HaveOccurred())
			acquired <- second
		}()

		Eventually(out.String, 10*time.Second).Should(Equal(waitMsg + "\n"))
		Consistently(acquired, 300*time.Millisecond).ShouldNot(Receive())

		Expect(first()).To(Succeed())
		var second func() error
		Eventually(acquired, 10*time.Second).Should(Receive(&second))
		Expect(second()).To(Succeed())
	})

	It("waits for a lock held by flock(1) in another process", func() {
		holder := exec.Command("flock", "-x", path, "sleep", "2")
		Expect(holder.Start()).To(Succeed())
		DeferCleanup(func() { _ = holder.Wait() })
		// flock(1) creates the file before locking; wait until it holds the lock.
		// A probe that wins the race briefly holds the lock; it is released on
		// Close, so flock(1) still ends up holding it.
		Eventually(func() error {
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			defer func() { _ = f.Close() }()
			return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		}, 10*time.Second, 20*time.Millisecond).Should(MatchError(syscall.EWOULDBLOCK))

		var out syncBuffer
		start := time.Now()
		release, err := lock.Acquire(path, waitMsg, &out)
		Expect(err).NotTo(HaveOccurred())
		Expect(time.Since(start)).To(BeNumerically(">=", 500*time.Millisecond))
		Expect(out.String()).To(Equal(waitMsg + "\n"))
		Expect(release()).To(Succeed())
	})

	It("is seen as held by flock(1) in another process", func() {
		release, err := lock.Acquire(path, waitMsg, &syncBuffer{})
		Expect(err).NotTo(HaveOccurred())

		err = exec.Command("flock", "-n", path, "true").Run()
		var exitErr *exec.ExitError
		Expect(err).To(BeAssignableToTypeOf(exitErr))
		Expect(err.(*exec.ExitError).ExitCode()).To(Equal(1))

		Expect(release()).To(Succeed())
		Expect(exec.Command("flock", "-n", path, "true").Run()).To(Succeed())
	})
})

package records_test

import (
	"bytes"
	"os"
	"path/filepath"
	"syscall"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/records"
)

var _ = Describe("Recorded", func() {
	var dir, file string

	BeforeEach(func() {
		dir = GinkgoT().TempDir()
		file = filepath.Join(dir, "projects")
	})

	It("returns the non-empty lines of the record", func() {
		Expect(os.WriteFile(file, []byte("/a\n\n/b c\n"), 0o600)).To(Succeed())
		Expect(records.Recorded(dir)).To(Equal([]string{"/a", "/b c"}))
	})

	It("returns nothing when there is no record", func() {
		Expect(records.Recorded(dir)).To(BeEmpty())
	})

	It("returns nothing for an empty record", func() {
		Expect(os.WriteFile(file, nil, 0o600)).To(Succeed())
		Expect(records.Recorded(dir)).To(BeEmpty())
	})

	It("returns nothing for a record of blank lines", func() {
		Expect(os.WriteFile(file, []byte("\n\n"), 0o600)).To(Succeed())
		Expect(records.Recorded(dir)).To(BeEmpty())
	})

	// bash's `while read` stops at an unterminated last line without
	// running the body, so recorded_projects never printed it.
	It("drops an unterminated last line, as bash's read loop does", func() {
		Expect(os.WriteFile(file, []byte("/a\n/b"), 0o600)).To(Succeed())
		Expect(records.Recorded(dir)).To(Equal([]string{"/a"}))
	})

	It("drops NUL bytes, as bash's read does", func() {
		Expect(os.WriteFile(file, []byte("/x\x00y\n\x00\n/z\n"), 0o600)).To(Succeed())
		Expect(records.Recorded(dir)).To(Equal([]string{"/xy", "/z"}))
	})

	It("refuses a symlink, even to a valid record", func() {
		target := filepath.Join(dir, "real")
		Expect(os.WriteFile(target, []byte("/a\n"), 0o600)).To(Succeed())
		Expect(os.Symlink(target, file)).To(Succeed())
		Expect(records.Recorded(dir)).To(BeEmpty())
	})

	It("refuses a directory", func() {
		Expect(os.Mkdir(file, 0o700)).To(Succeed())
		Expect(records.Recorded(dir)).To(BeEmpty())
	})

	It("reports an unreadable record as an error", func() {
		if os.Geteuid() == 0 {
			Skip("root reads a mode-000 file")
		}
		Expect(os.WriteFile(file, []byte("/a\n"), 0o000)).To(Succeed())
		lines, err := records.Recorded(dir)
		Expect(err).To(HaveOccurred())
		Expect(lines).To(BeEmpty())
	})
})

var _ = Describe("SessionProjects", func() {
	var dir, file string

	BeforeEach(func() {
		dir = GinkgoT().TempDir()
		file = filepath.Join(dir, ".projects")
	})

	It("returns the non-empty lines of .projects", func() {
		Expect(os.WriteFile(file, []byte("/a\n\n/b c\n"), 0o600)).To(Succeed())
		Expect(records.SessionProjects(dir)).To(Equal([]string{"/a", "/b c"}))
	})

	// The bash reads through a here-string, which terminates the last line.
	It("keeps an unterminated last line", func() {
		Expect(os.WriteFile(file, []byte("/a\n/b"), 0o600)).To(Succeed())
		Expect(records.SessionProjects(dir)).To(Equal([]string{"/a", "/b"}))
	})

	It("returns nothing when .projects is absent", func() {
		Expect(records.SessionProjects(dir)).To(BeEmpty())
	})

	It("returns nothing for an empty .projects", func() {
		Expect(os.WriteFile(file, nil, 0o600)).To(Succeed())
		Expect(records.SessionProjects(dir)).To(BeEmpty())
	})

	It("strips NUL bytes", func() {
		Expect(os.WriteFile(file, []byte("/x\x00y\n\x00\n/z\n"), 0o600)).To(Succeed())
		Expect(records.SessionProjects(dir)).To(Equal([]string{"/xy", "/z"}))
	})

	It("reads at most 64 KiB of an oversized .projects", func() {
		content := make([]byte, 64<<10+10)
		copy(content, "/proj\n")
		for i := 64<<10 - 3; i < len(content); i++ {
			content[i] = 'x'
		}
		Expect(os.WriteFile(file, content, 0o600)).To(Succeed())
		Expect(os.Truncate(file, 200<<20)).To(Succeed())
		lines, err := records.SessionProjects(dir)
		Expect(err).NotTo(HaveOccurred())
		Expect(lines).To(Equal([]string{"/proj", "xxx"}))
	})

	It("refuses a symlink, even to a valid list", func() {
		target := filepath.Join(dir, "real")
		Expect(os.WriteFile(target, []byte("/a\n"), 0o600)).To(Succeed())
		Expect(os.Symlink(target, file)).To(Succeed())
		Expect(records.SessionProjects(dir)).To(BeEmpty())
	})

	It("refuses a directory", func() {
		Expect(os.Mkdir(file, 0o700)).To(Succeed())
		Expect(records.SessionProjects(dir)).To(BeEmpty())
	})

	It("refuses a FIFO without opening it", func() {
		Expect(syscall.Mkfifo(file, 0o600)).To(Succeed())
		done := make(chan []string, 1)
		go func() {
			defer GinkgoRecover()
			lines, _ := records.SessionProjects(dir)
			done <- lines
		}()
		Eventually(done, 5*time.Second).Should(Receive(BeEmpty()))
	})

	It("fails when the read fails, unlike an absent file", func() {
		if os.Geteuid() == 0 {
			Skip("root reads a mode-000 file")
		}
		Expect(os.WriteFile(file, []byte("/a\n"), 0o000)).To(Succeed())
		lines, err := records.SessionProjects(dir)
		Expect(err).To(HaveOccurred())
		Expect(lines).To(BeEmpty())
	})

	// The Lstat check runs first, so these reach the open only in a race
	// where the container swaps the entry. The open must hold on its own.
	Describe("the guarded open", func() {
		It("fails on a symlink (O_NOFOLLOW)", func() {
			target := filepath.Join(dir, "real")
			Expect(os.WriteFile(target, []byte("/a\n"), 0o600)).To(Succeed())
			Expect(os.Symlink(target, file)).To(Succeed())
			_, err := records.ReadNoFollow(file)
			Expect(err).To(MatchError(syscall.ELOOP))
		})

		It("returns at once with no data on a FIFO instead of blocking (O_NONBLOCK)", func() {
			Expect(syscall.Mkfifo(file, 0o600)).To(Succeed())
			done := make(chan []byte, 1)
			go func() {
				got, _ := records.ReadNoFollow(file)
				done <- got
			}()
			Eventually(done, 5*time.Second).Should(Receive(BeEmpty()))
		})

		It("fails on a directory", func() {
			Expect(os.Mkdir(file, 0o700)).To(Succeed())
			_, err := records.ReadNoFollow(file)
			Expect(err).To(MatchError(syscall.EISDIR))
		})

		It("returns exactly the first 64 KiB of a large file", func() {
			content := bytes.Repeat([]byte("0123456789abcdef"), 8<<10)
			Expect(os.WriteFile(file, content, 0o600)).To(Succeed())
			got, err := records.ReadNoFollow(file)
			Expect(err).NotTo(HaveOccurred())
			Expect(got).To(Equal(content[:64<<10]))
		})
	})
})

var _ = Describe("SameSet (same_project_set)", func() {
	DescribeTable("compares two newline-separated lists as sets",
		func(a, b string, want bool) {
			Expect(records.SameSet(a, b)).To(Equal(want))
			Expect(records.SameSet(b, a)).To(Equal(want))
		},
		Entry("identical lists", "/a\n/b", "/a\n/b", true),
		Entry("the same paths in another order", "/b\n/a", "/a\n/b", true),
		Entry("a repeated path", "/a\n/a\n/b", "/b\n/a", true),
		Entry("one path more", "/a\n/b", "/a", false),
		Entry("different paths", "/a", "/b", false),
		Entry("a path that differs by a trailing slash", "/a", "/a/", false),
		Entry("a path that differs by case", "/a", "/A", false),
		Entry("a blank line counts as a member", "/a\n\n/b", "/a\n/b", false),
		Entry("a trailing newline is a blank member too", "/a\n", "/a", false),
		Entry("two empty lists", "", "", true),
		Entry("an empty list against a blank line", "", "\n", true),
		Entry("an empty list against a path", "", "/a", false),
		Entry("bytewise, not by locale, so case and accents never fold", "/café\n/Z", "/Z\n/café", true),
	)
})

var _ = Describe("IsSession (is_session)", func() {
	var tmp, session, state string

	BeforeEach(func() {
		tmp = GinkgoT().TempDir()
		session = filepath.Join(tmp, "data", "key")
		state = filepath.Join(tmp, "state", "key")
	})

	mkdir := func(p string) { Expect(os.MkdirAll(p, 0o700)).To(Succeed()) }
	touch := func(p string) {
		mkdir(filepath.Dir(p))
		Expect(os.WriteFile(p, []byte("/p\n"), 0o600)).To(Succeed())
	}
	link := func(target, p string) {
		mkdir(filepath.Dir(p))
		Expect(os.Symlink(target, p)).To(Succeed())
	}

	DescribeTable("decides from the session dir, its .projects and the launch's record",
		func(stage func(), want bool) {
			stage()
			Expect(records.IsSession(session, state)).To(Equal(want))
		},
		Entry("a dir with .projects", func() { touch(session + "/.projects") }, true),
		Entry("a dir whose state dir has the record", func() { mkdir(session); touch(state + "/projects") }, true),
		Entry("a dir with neither", func() { mkdir(session); mkdir(state) }, false),
		Entry("no session dir, though the record exists", func() { touch(state + "/projects") }, false),
		Entry("a regular file in place of the session dir", func() { touch(session); touch(state + "/projects") }, false),
		Entry("a link to a session dir, as -d follows it", func() {
			touch(tmp + "/elsewhere/.projects")
			link(tmp+"/elsewhere", session)
		}, true),
		Entry("a dangling link in place of the session dir", func() {
			link(tmp+"/nowhere", session)
			touch(state + "/projects")
		}, false),
		Entry("a .projects that is a directory", func() { mkdir(session + "/.projects") }, false),
		Entry("a .projects that links to a file, as -f follows it", func() {
			touch(tmp + "/list")
			link(tmp+"/list", session+"/.projects")
		}, true),
		Entry("a .projects that is a dangling link", func() { link(tmp+"/nowhere", session+"/.projects") }, false),
		Entry("a record that is a directory", func() { mkdir(session); mkdir(state + "/projects") }, false),
		Entry("a record that is a link to a file, which -L refuses", func() {
			mkdir(session)
			touch(tmp + "/list")
			link(tmp+"/list", state+"/projects")
		}, false),
	)
})

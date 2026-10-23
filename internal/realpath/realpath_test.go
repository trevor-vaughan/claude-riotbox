package realpath_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/realpath"
)

// gnu runs GNU realpath with flag on path, as the bash did, and returns its
// output without the newline, or an error when it fails.
func gnu(flag, path string) (string, error) {
	out, err := exec.Command("realpath", flag, "--", path).Output()
	return strings.TrimSuffix(string(out), "\n"), err
}

// tree builds the fixture the differential specs resolve paths in, and
// returns its canonical root.
func tree() string {
	dir, err := filepath.EvalSymlinks(GinkgoT().TempDir())
	Expect(err).NotTo(HaveOccurred())
	Expect(os.MkdirAll(filepath.Join(dir, "real", "sub", "deep"), 0o700)).To(Succeed())
	Expect(os.WriteFile(filepath.Join(dir, "f"), nil, 0o600)).To(Succeed())
	links := map[string]string{
		"L":             "real/sub",
		"abs":           filepath.Join(dir, "real"),
		"dang":          "/nonexistent-riotbox/q",
		"rel":           "../" + filepath.Base(dir) + "/real/missing",
		"c1":            "c2",
		"c2":            "real",
		"self":          "self",
		"a":             "b",
		"b":             "a",
		"x":             "y",
		"y":             "z",
		"z":             "x",
		"up":            "..",
		"real/sub/back": "../../L",
	}
	for name, target := range links {
		Expect(os.Symlink(target, filepath.Join(dir, name))).To(Succeed())
	}
	for i := 1; i <= 6; i++ {
		next := i%6 + 1
		Expect(os.Symlink("p"+string(rune('0'+next)), filepath.Join(dir, "p"+string(rune('0'+i))))).To(Succeed())
	}
	Expect(os.Symlink("p6", filepath.Join(dir, "p7"))).To(Succeed())
	return dir
}

var suffixes = []string{
	"", "/", "//", "/.", "/./real/./sub/", "/real//sub///deep",
	"/L", "/L/", "/L/..", "/L/../x", "/L/deep/../../y",
	"/abs/sub", "/abs/..", "/dang", "/dang/../z", "/rel", "/rel/../w",
	"/c1/sub/deep", "/f/x", "/f/../g", "/missing/../L", "/missing/../L/..",
	"/missing/more/../..", "/L/sub2/../..", "/up/up/up", "/real/sub/back/deep",
	"/self", "/self/y", "/a", "/a/x", "/b", "/x", "/y/q", "/p1", "/p7", "/p1/z",
	"/../../..", "/real/../../..",
}

var _ = Describe("Canonical and Lexical, against GNU realpath", func() {
	var dir string

	BeforeEach(func() {
		_, err := exec.LookPath("realpath")
		Expect(err).NotTo(HaveOccurred(), "the differential specs need GNU realpath")
		dir = tree()
	})

	It("matches realpath -m and -ms for every fixture path", func() {
		for _, suffix := range suffixes {
			path := dir + suffix
			want, err := gnu("-m", path)
			Expect(err).NotTo(HaveOccurred(), path)
			Expect(realpath.Canonical(path)).To(Equal(want), "realpath -m %s", path)
			want, err = gnu("-ms", path)
			Expect(err).NotTo(HaveOccurred(), path)
			Expect(realpath.Lexical(path)).To(Equal(want), "realpath -ms %s", path)
		}
	})

	It("matches them for absolute paths outside the fixture", func() {
		for _, path := range []string{"/", "//", "///x//y/", "/..", "/../tmp/./x"} {
			want, err := gnu("-m", path)
			Expect(err).NotTo(HaveOccurred())
			Expect(realpath.Canonical(path)).To(Equal(want), path)
			want, err = gnu("-ms", path)
			Expect(err).NotTo(HaveOccurred())
			Expect(realpath.Lexical(path)).To(Equal(want), path)
		}
	})

	It("resolves a relative path against the physical working directory", func() {
		old, err := os.Getwd()
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(os.Chdir, old)
		DeferCleanup(os.Setenv, "PWD", os.Getenv("PWD"))
		// Through the link, so a logical cwd ($PWD) would differ.
		Expect(os.Chdir(filepath.Join(dir, "L"))).To(Succeed())
		Expect(os.Setenv("PWD", filepath.Join(dir, "L"))).To(Succeed())
		for _, path := range []string{".", "..", "deep/../x", "../../L", "missing"} {
			cmd := exec.Command("realpath", "-m", "--", path)
			out, err := cmd.Output()
			Expect(err).NotTo(HaveOccurred())
			Expect(realpath.Canonical(path)).To(Equal(strings.TrimSuffix(string(out), "\n")), path)
			out, err = exec.Command("realpath", "-ms", "--", path).Output()
			Expect(err).NotTo(HaveOccurred())
			Expect(realpath.Lexical(path)).To(Equal(strings.TrimSuffix(string(out), "\n")), path)
		}
	})

	It("fails on an empty path, as realpath does", func() {
		_, err := gnu("-m", "")
		Expect(err).To(HaveOccurred())
		_, err = realpath.Canonical("")
		Expect(err).To(MatchError("realpath: '': No such file or directory"))
		_, err = realpath.Lexical("")
		Expect(err).To(MatchError("realpath: '': No such file or directory"))
	})

	// GNU realpath -m never returns on these: each expansion makes the
	// remaining path longer, so its cycle check never sees a repeat. A
	// container can plant one under a mount source, so Canonical stops after
	// as many links as the kernel follows in one lookup. Run in a goroutine
	// so a regression fails the spec instead of hanging the suite.
	DescribeTable("fails on a self-growing link instead of looping forever",
		func(target string) {
			Expect(os.Symlink(target, filepath.Join(dir, "grow"))).To(Succeed())
			done := make(chan error, 1)
			go func() {
				_, err := realpath.Canonical(dir + "/grow/x")
				done <- err
			}()
			var err error
			Eventually(done).WithTimeout(5 * time.Second).Should(Receive(&err))
			Expect(err).To(MatchError(fmt.Sprintf("realpath: %s/grow/x: Too many levels of symbolic links", dir)))
		},
		Entry("grow -> grow/../grow", "grow/../grow"),
		Entry("grow -> grow/.", "grow/."),
	)

	It("follows a chain of 40 links, the kernel's limit, and fails on 41", func() {
		Expect(os.Symlink("real", filepath.Join(dir, "chain40"))).To(Succeed())
		for i := 39; i >= 1; i-- {
			Expect(os.Symlink(fmt.Sprintf("chain%d", i+1), filepath.Join(dir, fmt.Sprintf("chain%d", i)))).To(Succeed())
		}
		Expect(realpath.Canonical(dir + "/chain1/sub")).To(Equal(dir + "/real/sub"))
		Expect(os.Symlink("chain1", filepath.Join(dir, "chain0"))).To(Succeed())
		_, err := realpath.Canonical(dir + "/chain0/sub")
		Expect(err).To(MatchError(fmt.Sprintf("realpath: %s/chain0/sub: Too many levels of symbolic links", dir)))
	})
})

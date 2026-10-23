package sessionkey_test

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/sessionkey"
)

type golden struct {
	desc     string
	dirs     []string
	key      string
	identity string // "" when the bash output is not a contract
}

func unhex(s string) string {
	b, err := hex.DecodeString(s)
	Expect(err).NotTo(HaveOccurred(), "bad hex %q", s)
	return string(b)
}

func loadGolden() []golden {
	f, err := os.Open("testdata/keys.tsv")
	Expect(err).NotTo(HaveOccurred())
	DeferCleanup(f.Close)

	var cases []golden
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		cols := strings.Split(sc.Text(), "\t")
		Expect(cols).To(HaveLen(4), "line %q", sc.Text())
		c := golden{desc: cols[0], key: unhex(cols[2])}
		for _, d := range strings.Split(cols[1], ",") {
			c.dirs = append(c.dirs, unhex(d))
		}
		if cols[3] != "-" {
			c.identity = unhex(cols[3])
		}
		cases = append(cases, c)
	}
	Expect(sc.Err()).NotTo(HaveOccurred())
	Expect(cases).NotTo(BeEmpty())
	return cases
}

var _ = Describe("against the v0.7.0 bash golden vectors", func() {
	It("reproduces session_key byte for byte", func() {
		for _, c := range loadGolden() {
			Expect(sessionkey.Key(c.dirs)+"\n").To(Equal(c.key), "case %q", c.desc)
		}
	})

	It("reproduces compute_multi_project_identity byte for byte", func() {
		checked := 0
		for _, c := range loadGolden() {
			if c.identity == "" {
				continue
			}
			first, nMore, hash := sessionkey.Identity(c.dirs)
			Expect(fmt.Sprintf("%s\n%d\n%s\n", first, nMore, hash)).To(Equal(c.identity), "case %q", c.desc)
			checked++
		}
		Expect(checked).To(BeNumerically(">", 0))
	})
})

var _ = Describe("Key", func() {
	It("depends on the set, not the argument order or repeats", func() {
		Expect(sessionkey.Key([]string{"/b", "/a", "/b"})).To(Equal(sessionkey.Key([]string{"/a", "/b"})))
	})

	It("truncates to exactly NAME_MAX", func() {
		// "/a/..." sorts before "/b", so the long path is the set's first.
		long := "/a/" + strings.Repeat("x", 600)
		Expect(sessionkey.Key([]string{long})).To(HaveLen(255))
		Expect(sessionkey.Key([]string{long, "/b"})).To(HaveLen(255))
	})

	It("is only the hash when no readable prefix survives", func() {
		key := sessionkey.Key([]string{"/" + strings.Repeat("!", 300)})
		Expect(key).To(MatchRegexp(`^[0-9a-f]{16}$`))
	})

	It("keeps distinct sets distinct where the pre-0.6 keys aliased them", func() {
		Expect(sessionkey.Key([]string{"/t/a-b/app"})).NotTo(Equal(sessionkey.Key([]string{"/t-a/b/app"})))
	})
})

var _ = Describe("Identity", func() {
	It("maps a newline in the first basename to '-' like any other disallowed byte", func() {
		// v0.7.0's sed worked per line, so this basename split across its
		// three-line output and broke the contract. Go treats '\n' as the
		// disallowed byte it is. Golden vectors mark this case "-".
		first, nMore, _ := sessionkey.Identity([]string{"/tmp/a\n-b", "/z"})
		Expect(first).To(Equal("a-b"))
		Expect(nMore).To(Equal(1))
	})

	It("counts distinct members after the first", func() {
		_, nMore, _ := sessionkey.Identity([]string{"/a", "/b", "/a", "/c"})
		Expect(nMore).To(Equal(2))
	})
})

var _ = Describe("SetHash", func() {
	It("is 16 lowercase hex characters", func() {
		Expect(sessionkey.SetHash([]string{"/a"})).To(MatchRegexp(`^[0-9a-f]{16}$`))
	})

	It("separates members, so a split path hashes differently from its parts", func() {
		Expect(sessionkey.SetHash([]string{"/a", "/b"})).NotTo(Equal(sessionkey.SetHash([]string{"/a/b"})))
	})
})

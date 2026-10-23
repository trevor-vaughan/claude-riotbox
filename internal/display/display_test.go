package display_test

import (
	"bytes"
	"os/exec"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
)

// bashQuote runs bash's `LC_ALL=C printf %q` on each word, which is what
// quote_words in scripts/lib/session-state.sh does per word.
func bashQuote(words []string) []string {
	cmd := exec.Command("bash", "-c", `for w; do LC_ALL=C printf '%q\0' "$w"; done`, "_")
	cmd.Args = append(cmd.Args, words...)
	out, err := cmd.Output()
	Expect(err).NotTo(HaveOccurred())
	got := strings.Split(string(out), "\x00")
	return got[:len(got)-1]
}

// bashQuoteWords runs the real quote_words on the words.
func bashQuoteWords(words ...string) string {
	cmd := exec.Command("bash", "-c", `source "$1/session-state.sh"; shift; quote_words "$@"`, "_", libDir)
	cmd.Args = append(cmd.Args, words...)
	out, err := cmd.Output()
	Expect(err).NotTo(HaveOccurred())
	return string(out)
}

// roundTrip evaluates a quoted word in bash and returns what it denotes.
func roundTrip(quoted string) string {
	out, err := exec.Command("bash", "-c", `eval "set -- $1"; printf %s "$1"`, "_", quoted).Output()
	Expect(err).NotTo(HaveOccurred())
	return string(out)
}

// awkward holds words whose quoting matters: shell metacharacters, quotes,
// the tilde and comment rules, control and non-ASCII bytes.
var awkward = []string{
	"", " ", "a b", "it's", `say "hi"`, "$HOME", "$(id)", "`id`", "a\\b",
	"~", "~user", "a~b", "a:~b", "a=~b", "#a", "a#b", "=a", "a,b", "!x",
	"*?[]", "{a,b}", "a|b&c;d", "<in>out", "(x)", "^x", "%x", "@x",
	"tab\there", "new\nline", "esc\x1b[31m", "bell\a", "del\x7f",
	"caf\xc3\xa9", "\xff\xfe", "it's\ta\\b", "/home/me/my project",
}

var _ = Describe("Quote", func() {
	DescribeTable("leaves a plain path unchanged, as printf %q does",
		func(path string) {
			Expect(display.Quote(path)).To(Equal(path))
			Expect(bashQuote([]string{path})).To(Equal([]string{path}))
		},
		Entry("absolute", "/home/me/proj"),
		Entry("every plain class", "/a-Z_0.9+x/y-z"),
		Entry("relative", "proj.d/v1+2"),
	)

	It("matches bash's printf %q under LC_ALL=C on awkward words", func() {
		got := make([]string, len(awkward))
		for i, w := range awkward {
			got[i] = display.Quote(w)
		}
		Expect(got).To(Equal(bashQuote(awkward)))
	})

	It("matches bash's printf %q for every byte, alone, first and inside a word", func() {
		var words []string
		for b := 1; b < 256; b++ {
			c := string([]byte{byte(b)})
			words = append(words, c, c+"x", "x"+c+"y", ":"+c, "\t"+c)
		}
		got := make([]string, len(words))
		for i, w := range words {
			got[i] = display.Quote(w)
		}
		Expect(got).To(Equal(bashQuote(words)))
	})

	It("round-trips every awkward word through eval", func() {
		for _, w := range awkward {
			Expect(roundTrip(display.Quote(w))).To(Equal(w), "word %q", w)
		}
	})
})

var _ = Describe("QuoteWords", func() {
	It("joins the quoted words with spaces, as quote_words does", func() {
		words := []string{"/home/me/a b", "/plain", "it's", "esc\x1b"}
		Expect(display.QuoteWords(words...) + "\n").To(Equal(bashQuoteWords(words...)))
	})

	It("returns an empty string for no words, as quote_words prints an empty line", func() {
		Expect(display.QuoteWords()).To(BeEmpty())
		Expect(bashQuoteWords()).To(Equal("\n"))
	})
})

var _ = Describe("CleanLines", func() {
	// Bytes a terminal acts on, the bidi and zero-width code points, a tab
	// (kept by clean_text only, so replaced here), a NUL, invalid UTF-8 and
	// an unterminated last line.
	input := "/home/me/\x1b]0;pwned\x07proj\n" +
		"tab\there\r\x00del\x7f\n" +
		"c1\u0085\u009b31m bidi\u202eevil\u2066 zw\u200b\ufeff ls\u2028ps\u2029\n" +
		"\xff\xfe raw\n" +
		"plain/path\n" +
		"last"

	It("cleans the same bytes exactly as bash's terminal_clean line", func() {
		cmd := exec.Command("bash", "-c", `source "$1/session-state.sh"; terminal_clean line`, "_", libDir)
		cmd.Stdin = strings.NewReader(input)
		want, err := cmd.Output()
		Expect(err).NotTo(HaveOccurred())

		var stderr bytes.Buffer
		got, err := display.CleanLines(libDir, input, &stderr)
		Expect(err).NotTo(HaveOccurred())
		Expect(got).To(Equal(string(want)))
		Expect(stderr.String()).To(BeEmpty())
		Expect(got).NotTo(ContainSubstring("\x1b"))
		Expect(got).To(ContainSubstring("plain/path\n"))
	})

	It("fails, printing nothing, when the filter cannot be loaded", func() {
		var stderr bytes.Buffer
		got, err := display.CleanLines(GinkgoT().TempDir(), "x\n", &stderr)
		Expect(err).To(HaveOccurred())
		Expect(got).To(BeEmpty())
		Expect(stderr.String()).NotTo(BeEmpty())
	})

	It("fails, printing nothing, when jq is not on PATH", func() {
		GinkgoT().Setenv("PATH", GinkgoT().TempDir())
		got, err := display.CleanLines(libDir, "x\n", &bytes.Buffer{})
		Expect(err).To(MatchError(exec.ErrNotFound))
		Expect(got).To(BeEmpty())
	})
})

var _ = Describe("CleanName", func() {
	It("cleans a name as terminal_clean line does, showing a newline as ?", func() {
		var stderr bytes.Buffer
		Expect(display.CleanName(&stderr, libDir, "/a/\x1b[31mred\nx")).To(Equal("/a/?[31mred?x"))
		Expect(stderr.String()).To(BeEmpty())
	})

	It("returns the placeholder, never the raw name, and says why, when it cannot be cleaned", func() {
		var stderr bytes.Buffer
		Expect(display.CleanName(&stderr, GinkgoT().TempDir(), "\x1b[31mred")).To(Equal("(name not shown)"))
		Expect(stderr.String()).To(ContainSubstring("riotbox-core: exit status"))
		Expect(stderr.String()).NotTo(ContainSubstring("\x1b"))
	})
})

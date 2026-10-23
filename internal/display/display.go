// Package display makes text safe to print: Quote and QuoteWords port
// quote_words in scripts/lib/session-state.sh (bash's printf %q under
// LC_ALL=C), and CleanLines and CleanName run terminal_clean's jq filter.
package display

import (
	"bytes"
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// backslashed are the bytes bash's sh_backslash_quote always escapes (its
// bstab table, plus the blanks printf %q adds).
const backslashed = " \t\n!\"$&'()*,;<>?[\\]^`{|}"

// Quote returns word as bash's `LC_ALL=C printf %q` does, so the result
// pasted into a shell is exactly word.
//
//   - The empty word is two single quotes.
//   - A word with a byte outside printable ASCII (0x20-0x7e) is ANSI-C
//     quoted, $'...', with \E, \a, \b, \f, \n, \r, \t, \v, \\, \' and a
//     three-digit octal escape for any other unprintable byte.
//   - Otherwise each byte in backslashed is escaped with a backslash, as is
//     a leading #, and a ~ that is leading or follows : or =.
//
// A word of [A-Za-z0-9_./+-] is returned unchanged.
func Quote(word string) string {
	if word == "" {
		return "''"
	}
	for i := 0; i < len(word); i++ {
		if !printable(word[i]) {
			return ansiC(word)
		}
	}
	var b strings.Builder
	for i := 0; i < len(word); i++ {
		c := word[i]
		switch {
		case strings.IndexByte(backslashed, c) >= 0,
			c == '#' && i == 0,
			c == '~' && (i == 0 || word[i-1] == ':' || word[i-1] == '='):
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}

// QuoteWords returns the words quoted by Quote and joined by single spaces:
// quote_words' line without its newline.
func QuoteWords(words ...string) string {
	quoted := make([]string, len(words))
	for i, w := range words {
		quoted[i] = Quote(w)
	}
	return strings.Join(quoted, " ")
}

func printable(c byte) bool {
	return c >= 0x20 && c <= 0x7e
}

// ansiC is bash's ansic_quote in the C locale.
func ansiC(word string) string {
	var b strings.Builder
	b.WriteString("$'")
	for i := 0; i < len(word); i++ {
		c := word[i]
		switch c {
		case 0x1b:
			b.WriteString(`\E`)
		case '\a':
			b.WriteString(`\a`)
		case '\v':
			b.WriteString(`\v`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\\', '\'':
			b.WriteByte('\\')
			b.WriteByte(c)
		default:
			if printable(c) {
				b.WriteByte(c)
			} else {
				b.WriteByte('\\')
				b.WriteByte('0' + c>>6&7)
				b.WriteByte('0' + c>>3&7)
				b.WriteByte('0' + c&7)
			}
		}
	}
	b.WriteByte('\'')
	return b.String()
}

// CleanLines runs `terminal_clean line` on text: jq -Rr with the clean
// filter of <libDir>/terminal-clean.jq, the same invocation as the bash.
// Every line comes back newline-terminated with each terminal control, bidi
// and zero-width code point replaced by "?". jq's own messages go to stderr.
//
// When jq is missing or fails, it returns "" and the error. That matches the
// bash, whose pipeline then prints nothing; the caller decides whether to go
// on, as the bash callers do.
func CleanLines(libDir, text string, stderr io.Writer) (string, error) {
	cmd := exec.Command("jq", "-Rr", "-L", libDir, `include "terminal-clean"; clean`)
	cmd.Stdin = strings.NewReader(text)
	cmd.Stderr = stderr
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return out.String(), nil
}

// CleanName returns a name or path a container chose (or could influence),
// made safe to print as terminal_clean line does, with every newline shown
// as "?" so it stays on its message's line. When jq cannot clean it, it
// reports why on w and returns the placeholder "(name not shown)": the raw
// bytes never reach the terminal.
func CleanName(w io.Writer, libDir, name string) string {
	cleaned, err := CleanLines(libDir, name+"\n", w)
	if err != nil {
		_, _ = fmt.Fprintf(w, "riotbox-core: %v\n", err)
		return "(name not shown)"
	}
	return strings.ReplaceAll(strings.TrimSuffix(cleaned, "\n"), "\n", "?")
}

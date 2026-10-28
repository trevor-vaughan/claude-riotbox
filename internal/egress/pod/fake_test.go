package pod_test

import (
	"os"
	"strings"
)

// fakeEngine records every engine call and answers through respond, which
// receives the argv. For Exists, respond returning the output "absent"
// means exit 1 (not there); any other output means exit 0.
type fakeEngine struct {
	calls   [][]string
	respond func(args []string) ([]byte, error)
}

func (f *fakeEngine) answer(args []string) ([]byte, error) {
	f.calls = append(f.calls, args)
	if f.respond == nil {
		return nil, nil
	}
	return f.respond(args)
}

func (f *fakeEngine) Output(args ...string) ([]byte, error) { return f.answer(args) }

func (f *fakeEngine) Stream(args ...string) error {
	_, err := f.answer(args)
	return err
}

func (f *fakeEngine) Exists(args ...string) (bool, error) {
	out, err := f.answer(args)
	if err != nil {
		return false, err
	}
	return string(out) != "absent", nil
}

// lines is each call as one space-joined string, in order.
func (f *fakeEngine) lines() []string {
	var out []string
	for _, c := range f.calls {
		out = append(out, strings.Join(c, " "))
	}
	return out
}

// index is the position of the first call starting with prefix, or -1.
func (f *fakeEngine) index(prefix string) int {
	for i, l := range f.lines() {
		if strings.HasPrefix(l, prefix) {
			return i
		}
	}
	return -1
}

// appendFile adds text to the file at path, creating it.
func appendFile(path, text string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(text); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

package state

// FailWriting makes WriteInjection's write of path fail with err, so
// specs can check what a failure after the secrets are written leaves
// behind. The returned func restores the real write.
func FailWriting(path string, err error) (restore func()) {
	real := writeFile
	writeFile = func(p string, data []byte) error {
		if p == path {
			return err
		}
		return real(p, data)
	}
	return func() { writeFile = real }
}

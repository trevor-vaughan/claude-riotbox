package inject

// NewCA and NewLeaf let specs sign a leaf for a host outside a CA's list,
// which NewCerts never does, to prove the name constraints hold.
var (
	NewCA   = newCA
	NewLeaf = newLeaf
)

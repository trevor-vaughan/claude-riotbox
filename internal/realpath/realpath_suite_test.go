package realpath_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestRealpath(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "realpath")
}

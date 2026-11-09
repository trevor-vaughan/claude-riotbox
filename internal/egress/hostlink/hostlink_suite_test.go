package hostlink_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestHostlink(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Hostlink Suite")
}

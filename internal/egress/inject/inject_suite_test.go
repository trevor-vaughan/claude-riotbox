package inject_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestInject(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "egress/inject")
}

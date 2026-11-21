package workflow

import (
	"strings"
	"testing"
)

// pull-request 種類の action: ensure-base（§5.6.3）の定義の検査。

const ensureBaseWF = `schema: harness.workflow/v1
id: w
steps:
  integration:
    kind: pull-request
    action: ensure-base
    with: { branch: integration/c-1, from: main }
    on:
      created: { done: created }
      existing: { done: existing }
      refused: { fail: integration_create_failed }
      unavailable: { fail: remote_unavailable }
`

func TestEnsureBaseDefinition(t *testing.T) {
	if err := check(t, ensureBaseWF); err != nil {
		t.Fatalf("a valid ensure-base step was rejected: %v", err)
	}
	for _, c := range []struct{ name, old, new, want string }{
		{"from is required", ", from: main", "", "from is required"},
		{"branch is required", "branch: integration/c-1, ", "", "branch is required"},
		{"unknown input", "from: main }", "from: main, base: main }", `"base" is not an input of kind pull-request:ensure-base`},
		{"every outcome needs a transition", "      unavailable: { fail: remote_unavailable }\n", "", "unavailable"},
		{"an outcome the action does not return", "      created:", "      pushed: { done: pushed }\n      created:", "pushed"},
	} {
		t.Run(c.name, func(t *testing.T) {
			err := check(t, strings.Replace(ensureBaseWF, c.old, c.new, 1))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
}

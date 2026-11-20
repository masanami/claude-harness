package workflow

import (
	"path/filepath"
	"strings"
	"testing"
)

// reflect（§5.6.2）の定義の文法: 最上位の release_on・workspace の with.mode・pull-request の action: adopt。

func withReleaseOn(t *testing.T, line string) string {
	t.Helper()
	return mutate(t, "steps:\n  a:\n", line+"\nsteps:\n  a:\n")
}

func TestReleaseOnIsLoaded(t *testing.T) {
	path, scripts := setup(t, "w", withReleaseOn(t, "release_on: [cancelled, failed]"))
	wf, err := LoadAndValidate(path, Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(wf.ReleaseOn, ",") != "cancelled,failed" {
		t.Fatalf("release_on = %v", wf.ReleaseOn)
	}
	// 書かなければ片付けない（ticket のいまの動き）。
	path, scripts = setup(t, "w", base)
	if wf, err = LoadAndValidate(path, Options{ScriptsDir: scripts}); err != nil || len(wf.ReleaseOn) != 0 {
		t.Fatalf("err %v release_on %v", err, wf.ReleaseOn)
	}
}

func TestReleaseOnIsRejected(t *testing.T) {
	cases := []struct{ name, line, want string }{
		{"succeeded", "release_on: [succeeded]", "succeeded cannot be listed"},
		{"succeeded among others", "release_on: [failed, succeeded]", "succeeded cannot be listed"},
		{"unknown", "release_on: [aborted]", `"aborted" must be cancelled or failed`},
		{"duplicate", "release_on: [failed, failed]", `duplicate value "failed"`},
		{"empty", "release_on: []", "must be a non-empty list"},
		{"scalar", "release_on: failed", "must be a non-empty list"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := check(t, withReleaseOn(t, c.line))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want it to contain %q", err, c.want)
			}
		})
	}
}

// release_on は上書きに書けない。
func TestOverrideCannotWriteReleaseOn(t *testing.T) {
	_, err := loadTicket(t, ov(LayerArg, "release_on: [failed]\n"))
	if err == nil || !strings.Contains(err.Error(), `key "release_on" cannot be overridden`) {
		t.Fatalf("err = %v", err)
	}
}

func TestWorkspaceModeDetached(t *testing.T) {
	detached := strings.Replace(kindsBase, ", provided: $inputs.s }", ", mode: detached }", 1)
	if err := check(t, detached); err != nil {
		t.Fatalf("mode: detached: %v", err)
	}
	for _, c := range []struct{ name, with, want string }{
		{"another mode", ", mode: shallow }", `must be the literal "detached"`},
		{"a reference", ", mode: $inputs.s }", `must be the literal "detached"`},
		{"together with provided", ", mode: detached, provided: $inputs.s }", "cannot be used together with provided"},
	} {
		t.Run(c.name, func(t *testing.T) {
			err := check(t, strings.Replace(kindsBase, ", provided: $inputs.s }", c.with, 1))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want it to contain %q", err, c.want)
			}
		})
	}
}

const adoptBase = `schema: harness.workflow/v1
id: w
inputs:
  ref: { type: string, required: true }
steps:
  adopt:
    kind: pull-request
    action: adopt
    with: { ref: $inputs.ref }
    on:
      adopted: { done: ok }
      unsupported_ref: { fail: unsupported_ref }
      not_open: { fail: not_open }
      not_default_base: { fail: not_default_base }
      fork: { fail: fork }
      draft: { fail: draft }
      other_repo: { fail: other_repo }
`

func TestPullRequestAdopt(t *testing.T) {
	if err := check(t, adoptBase); err != nil {
		t.Fatalf("adopt: %v", err)
	}
	for _, c := range []struct{ name, old, new, want string }{
		{"without ref", "with: { ref: $inputs.ref }", "with: { }", "ref is required for kind pull-request:adopt"},
		{"an optional input for ref", "ref: { type: string, required: true }", "ref: { type: string }", "is an optional input, but kind pull-request:adopt requires ref"},
		{"an unknown input", "with: { ref: $inputs.ref }", "with: { ref: $inputs.ref, base: main }", `"base" is not an input of kind pull-request:adopt`},
		{"a missing outcome", "      draft: { fail: draft }\n", "", `outcome "draft" is not covered`},
		{"an outcome adopt does not return", "      draft: { fail: draft }\n", "      draft: { fail: draft }\n      landed: { fail: landed }\n", `"landed" is not an outcome of this step`},
	} {
		t.Run(c.name, func(t *testing.T) {
			if n := strings.Count(adoptBase, c.old); n != 1 {
				t.Fatalf("fragment %q occurs %d times", c.old, n)
			}
			err := check(t, strings.Replace(adoptBase, c.old, c.new, 1))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want it to contain %q", err, c.want)
			}
		})
	}
}

// 同梱の reflect: release_on は [cancelled, failed]、facts は宣言しない、review は land だけを受ける。ticket は release_on を書かない。
func TestBundledReflectAndTicket(t *testing.T) {
	scripts := "../../../plugin/scripts"
	dir := filepath.Join("..", "..", "workflows")
	reflect, err := LoadAndValidate(filepath.Join(dir, "reflect.yaml"), Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(reflect.ReleaseOn, ",") != "cancelled,failed" || len(reflect.Facts) != 0 {
		t.Fatalf("release_on %v facts %v", reflect.ReleaseOn, reflect.Facts)
	}
	review := reflect.Step("review")
	if review == nil || strings.Join(review.GateInputs, ",") != "land" || review.ContractKind != "review" || review.Refresh != RefreshPRHead {
		t.Fatalf("review = %+v", review)
	}
	if got := PRAction(reflect.Step("adopt")); got != PRActionAdopt {
		t.Fatalf("adopt action = %q", got)
	}
	if w := reflect.Step("workspace"); w == nil || w.Kind != "workspace" {
		t.Fatalf("workspace = %+v", w)
	}
	ticket, err := LoadAndValidate(filepath.Join(dir, "ticket.yaml"), Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	if len(ticket.ReleaseOn) != 0 {
		t.Fatalf("ticket must not release the worktree when it is cancelled or fails: release_on %v", ticket.ReleaseOn)
	}
}

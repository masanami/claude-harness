package workflow

import (
	"strings"
	"testing"
)

// pull-request 種類の action（sync・push・land。§5.6.2）と、入れる段の規則 7（元の定義の検査。overrides.md §6.2）。

const landBase = `schema: harness.workflow/v1
id: w
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: { gate: review }
      bad: { fail: bad }
  review:
    kind: gate
    type: input
    decider: any
    requested_action: wait
    inputs: [land, stop]
    on:
      land: { goto: land, with: { approved_ref: $gate.approved_ref }, interrupted: { fail: interrupted_after_land } }
      stop: { done: stopped }
  land:
    kind: pull-request
    action: land
    with: { pr: 7, base: main, approved_ref: $edge.approved_ref }
    on:
      landed: { done: landed }
      behind: sync
      mismatch: { gate: review, detail: $steps.land.detail }
      blocked: { gate: review, detail: $steps.land.detail }
      closed: { fail: closed }
      merged_other: { fail: merged_other }
      base_changed: { fail: base_changed }
      not_confirmed: { fail: not_confirmed }
  sync:
    kind: pull-request
    action: sync
    with: { base: main, expect_head: $steps.land.head_sha }
    on:
      current: push
      synced: push
      conflict: { fail: conflict }
      unresolved: { fail: unresolved }
      not_merge_only: { fail: not_merge_only }
      diverged: { fail: diverged }
      head_moved: { fail: head_moved }
      unavailable: { gate: review, detail: $steps.sync.detail }
  push:
    kind: pull-request
    action: push
    with: { pr: 7, base: main }
    on:
      pushed: { gate: review, detail: $steps.push.detail }
      unchanged: { gate: review, detail: $steps.push.detail }
      rejected: { fail: rejected }
      unavailable: { fail: unavailable }
`

func TestPullRequestActionsAreAccepted(t *testing.T) {
	if err := check(t, landBase); err != nil {
		t.Fatalf("a definition with sync, push and land: %v", err)
	}
	// 書かなければ publish（いまの動き）。
	if PRAction(&Step{Kind: "pull-request"}) != PRActionPublish || PRAction(&Step{Kind: "command"}) != "" {
		t.Fatal("PRAction must default to publish for pull-request and be empty for other kinds")
	}
}

func TestPullRequestActionRejects(t *testing.T) {
	for _, c := range []struct{ name, old, new, want string }{
		{"unknown action", "    action: push\n", "    action: rebase\n", `action "rebase" must be publish, sync, push, land, adopt, ensure-base, open or retire`},
		{"land without pr", "with: { pr: 7, base: main, approved_ref: $edge.approved_ref }", "with: { base: main, approved_ref: $edge.approved_ref }", "pr is required for kind pull-request:land"},
		{"land without approved_ref", "with: { pr: 7, base: main, approved_ref: $edge.approved_ref }", "with: { pr: 7, base: main }", "approved_ref is required for kind pull-request:land"},
		{"land takes no title", "with: { pr: 7, base: main, approved_ref: $edge.approved_ref }", "with: { pr: 7, base: main, approved_ref: $edge.approved_ref, title: x }", `"title" is not an input of kind pull-request:land`},
		{"sync takes no pr", "with: { base: main, expect_head: $steps.land.head_sha }", "with: { base: main, pr: 7 }", `"pr" is not an input of kind pull-request:sync`},
		{"land misses an outcome", "      not_confirmed: { fail: not_confirmed }\n", "", `outcome "not_confirmed" is not covered`},
		{"sync does not return landed", "      current: push\n", "      current: push\n      landed: push\n", `"landed" is not an outcome of this step`},
		{"push pr must be an integer", "with: { pr: 7, base: main }", `with: { pr: "7", base: main }`, "takes pr as integer"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if n := strings.Count(landBase, c.old); n != 1 {
				t.Fatalf("fragment %q occurs %d times", c.old, n)
			}
			err := check(t, strings.Replace(landBase, c.old, c.new, 1))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
}

// 規則 7: 通した中身の識別は、ゲートの解決（$gate.approved_ref）からしか入れる段へ届かない。
func TestLandStepReadsTheApprovedRefOnlyFromAGateResolution(t *testing.T) {
	for _, c := range []struct{ name, old, new, want string }{
		{"a literal", "approved_ref: $edge.approved_ref }", `approved_ref: "abc" }`, "must read it as $edge.<name>"},
		{"another step's output", "approved_ref: $edge.approved_ref }", "approved_ref: $steps.a.outcome }", "must read it as $edge.<name>"},
		{"an edge value not passed by a gate", "land: { goto: land, with: { approved_ref: $gate.approved_ref }, interrupted: { fail: interrupted_after_land } }",
			`land: { goto: land, with: { approved_ref: "abc" }, interrupted: { fail: interrupted_after_land } }`, "must pass approved_ref as $gate.approved_ref"},
		{"a transition that passes nothing", "land: { goto: land, with: { approved_ref: $gate.approved_ref }, interrupted: { fail: interrupted_after_land } }",
			"land: { goto: land }", "must pass approved_ref as $gate.approved_ref"},
		{"a second way in", "      ok: { gate: review }\n", "      ok: { gate: review }\n      other: land\n", `"other" is not an outcome`},
		{"without interrupted", ", interrupted: { fail: interrupted_after_land } }\n      stop", " }\n      stop", "must write interrupted: { fail: <reason> }"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if n := strings.Count(landBase, c.old); n != 1 {
				t.Fatalf("fragment %q occurs %d times", c.old, n)
			}
			err := check(t, strings.Replace(landBase, c.old, c.new, 1))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
}

// $gate.approved_ref を渡せる先は、入れる段の with.approved_ref だけ。別の種類の段・別の action の pull-request・別の名前での受け取りは拒否する。
func TestApprovedRefCanOnlyGoToTheLandStep(t *testing.T) {
	const anotherGateTarget = `  other:
    kind: pull-request
    action: push
    with: { pr: 7, base: main }
    on:
      pushed: { done: ok }
      unchanged: { done: ok }
      rejected: { fail: rejected }
      unavailable: { fail: unavailable }
`
	y := strings.Replace(landBase, "      stop: { done: stopped }\n", "      stop: { goto: other, with: { x: $gate.approved_ref }, interrupted: { fail: interrupted_after_land } }\n", 1) + anotherGateTarget
	err := check(t, y)
	if err == nil || !strings.Contains(err.Error(), "$gate.approved_ref can be passed only to the with.approved_ref of a step that lands the pull request") {
		t.Fatalf("err = %v", err)
	}
}

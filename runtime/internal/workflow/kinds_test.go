package workflow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// kindsBase は select・workspace・pull-request（PR-4）を使う、検証を通るワークフロー。拒否のケースは 1 か所だけを書き換えて作る。
const kindsBase = `schema: harness.workflow/v1
id: w
inputs:
  n: { type: integer, required: true }
  s: { type: string }
steps:
  a:
    kind: command
    run: tool
    output: schemas/route.json
    on:
      ok: ws
      bad: { fail: bad }
  ws:
    kind: workspace
    action: acquire
    with: { issue: $inputs.n, branch: $steps.a.branch, base: $steps.a.base, provided: $inputs.s }
    on:
      provided: route
      created: route
      reused: route
      conflict: { fail: conflict }
  route:
    kind: select
    value: $steps.a.kind
    on: { yes: pr, no: back }
  back:
    kind: select
    value: $steps.route.outcome
    on: { yes: pr, no: pr }
  pr:
    kind: pull-request
    with: { base: $steps.a.base, closes: $inputs.n, title: $steps.a.branch, summary: $steps.a.branch, residual_findings: $steps.a.items }
    on: { opened: merged, updated: merged }
  merged:
    kind: gate
    type: observe
    decider: human
    observe: needs-pr
    with: { pr: $steps.pr.pr_number }
    requested_action: a person merges
    on:
      merged: done
      open: { gate: merged }
  done:
    kind: workspace
    action: release
    on: { released: { done: ok }, kept: { done: ok }, dirty: { done: dirty } }
`

func init() {
	RegisterObservation("needs-pr", []string{"merged", "open"})
	RegisterObservationInputs("needs-pr", "pr")
	schemas["route.json"] = `{"type":"object","required":["outcome","branch","base","kind"],"properties":{
		"outcome":{"type":"string","enum":["ok","bad"]},
		"branch":{"type":"string"},
		"base":{"type":"string"},
		"kind":{"type":"string","enum":["yes","no"]},
		"free":{"type":"string"},
		"items":{"type":"array","items":{"type":"object"}},
		"clash":{"type":"string","enum":["yes","step_error"]}}}`
}

// select の値が後ろで宣言された select の outcome を指していても解決できる（宣言の順に依らない）。
func TestChainedSelectsInAnyOrder(t *testing.T) {
	y := strings.Replace(kindsBase, "  route:\n    kind: select\n    value: $steps.a.kind\n    on: { yes: pr, no: back }\n  back:\n    kind: select\n    value: $steps.route.outcome\n    on: { yes: pr, no: pr }\n",
		"  route:\n    kind: select\n    value: $steps.a.kind\n    on: { yes: back, no: back }\n  back:\n    kind: select\n    value: $steps.last.outcome\n    on: { yes: pr, no: pr }\n  last:\n    kind: select\n    value: $steps.a.kind\n    on: { yes: pr, no: pr }\n", 1)
	if y == kindsBase {
		t.Fatal("fixture did not change")
	}
	err := check(t, y)
	// back は last の outcome を読むが、last は back より前に必ず成功するわけではない（到達の検査で拒否される）。
	// ここで確かめたいのは「enum が解決できない」誤りが出ないこと。
	if err != nil && strings.Contains(err.Error(), "no enum values") {
		t.Fatalf("a select referring to a later select must resolve its enum: %v", err)
	}
	cyc := strings.Replace(kindsBase, "    value: $steps.a.kind\n    on: { yes: pr, no: back }\n", "    value: $steps.back.outcome\n    on: { yes: pr, no: back }\n", 1)
	if err := check(t, cyc); err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("select cycle: %v", err)
	}
}

func TestKindsBaseIsValid(t *testing.T) {
	if err := check(t, kindsBase); err != nil {
		t.Fatalf("kindsBase must be valid: %v", err)
	}
}

func TestRejectsKinds(t *testing.T) {
	cases := []struct {
		name     string
		old, new string
		want     string
	}{
		// select（§3.2・Q12）: 参照 1 つの enum 値がそのまま outcome。比較・リテラル・enum の無い値は選べない
		{"select misses an enum value", "    on: { yes: pr, no: back }\n", "    on: { yes: pr }\n", `outcome "no" is not covered`},
		{"select has an unknown value", "    on: { yes: pr, no: back }\n", "    on: { yes: pr, no: back, maybe: pr }\n", `"maybe" is not an outcome of this step`},
		{"select on a literal", "    value: $steps.a.kind\n", "    value: yes\n", "must be exactly one reference"},
		{"select on an input", "    value: $steps.a.kind\n", "    value: $inputs.s\n", "select takes a step's output field"},
		{"select on a field without enum", "    value: $steps.a.kind\n", "    value: $steps.a.free\n", "declares no enum"},
		{"select on a missing field", "    value: $steps.a.kind\n", "    value: $steps.a.nope\n", `no field "nope"`},
		{"select on a reserved enum value", "    value: $steps.a.kind\n    on: { yes: pr, no: back }\n", "    value: $steps.a.clash\n    on: { yes: pr, step_error: back }\n", "collides with a reserved value"},
		{"select with a comparison", "    value: $steps.a.kind\n", "    value: \"$steps.a.kind == yes\"\n", "is not a reference"},
		{"select without value", "    value: $steps.a.kind\n", "", "value is required for kind select"},
		{"select with a when key", "    value: $steps.a.kind\n", "    value: $steps.a.kind\n    when: $inputs.n\n", `key "when" is a condition/expression`},
		{"select with output", "    value: $steps.a.kind\n", "    value: $steps.a.kind\n    output: schemas/route.json\n", `unknown key "output"`},
		{"select on a step not always run", "    value: $steps.route.outcome\n    on: { yes: pr, no: pr }\n", "    value: $steps.pr.outcome\n    on: { opened: pr, updated: pr }\n", `step "pr" has not necessarily succeeded`},

		// workspace（§3.2・§5.4）
		{"workspace without action", "    action: acquire\n", "", "action is required for kind workspace"},
		{"workspace with an unknown action", "    action: acquire\n", "    action: grab\n", `action "grab" must be acquire or release`},
		{"acquire without branch", ", branch: $steps.a.branch, base:", ", base:", "branch is required for kind workspace:acquire"},
		{"acquire with an unknown input", "provided: $inputs.s }", "provided: $inputs.s, force: yes }", `"force" is not an input of kind workspace:acquire`},
		{"acquire with a wrong type", "with: { issue: $inputs.n, branch:", "with: { issue: $inputs.s, branch:", "takes issue as integer, not string"},
		{"acquire with an optional input for a required one", "base: $steps.a.base, provided", "base: $inputs.s, provided", "is an optional input, but kind workspace:acquire requires base"},
		{"acquire misses an outcome", "      conflict: { fail: conflict }\n", "", `outcome "conflict" is not covered`},
		{"release with inputs", "    action: release\n", "    action: release\n    with: { issue: $inputs.n }\n", `"issue" is not an input of kind workspace:release`},
		{"workspace with output", "    action: release\n", "    action: release\n    output: schemas/route.json\n", `unknown key "output"`},
		{"release misses dirty", ", dirty: { done: dirty } }", " }", `outcome "dirty" is not covered`},

		// pull-request（§3.2）
		{"pull-request without title", "closes: $inputs.n, title: $steps.a.branch, summary", "closes: $inputs.n, summary", "title is required for kind pull-request"},
		{"pull-request with an unknown input", "residual_findings: $steps.a.items }", "residual_findings: $steps.a.items, body: $steps.a.free }", `"body" is not an input of kind pull-request`},
		{"pull-request findings of a wrong type", "residual_findings: $steps.a.items }", "residual_findings: $steps.a.free }", "takes residual_findings as array, not string"},
		{"pull-request misses updated", "    on: { opened: merged, updated: merged }\n", "    on: { opened: merged }\n", `outcome "updated" is not covered`},
		{"reference to a missing pull-request field", "with: { pr: $steps.pr.pr_number }", "with: { pr: $steps.pr.number }", `no field "number"`},

		// observe 型ゲートの観測が要る with（pr-state の pr）
		{"observe gate without its with", "    with: { pr: $steps.pr.pr_number }\n", "", "observation needs-pr needs with.pr"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if n := strings.Count(kindsBase, c.old); n != 1 {
				t.Fatalf("fragment %q occurs %d times in kindsBase", c.old, n)
			}
			err := check(t, strings.Replace(kindsBase, c.old, c.new, 1))
			if err == nil {
				t.Fatalf("expected rejection containing %q, but the workflow was accepted", c.want)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("expected rejection containing %q, got:\n%v", c.want, err)
			}
		})
	}
}

// ワークフローに付属するスクリプト（<workflow-dir>/scripts）とプラグインのスクリプトは、同じ名前を両方に持てない。
func TestScriptPath(t *testing.T) {
	wfDir, plugin := t.TempDir(), t.TempDir()
	write := func(p string) {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("#!/bin/bash\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(wfDir, "scripts", "own.sh"))
	write(filepath.Join(plugin, "shared.sh"))
	write(filepath.Join(wfDir, "scripts", "both.sh"))
	write(filepath.Join(plugin, "both.sh"))
	if p, err := ScriptPath(wfDir, plugin, "own"); err != nil || p != filepath.Join(wfDir, "scripts", "own.sh") {
		t.Errorf("own: %s %v", p, err)
	}
	if p, err := ScriptPath(wfDir, plugin, "shared"); err != nil || p != filepath.Join(plugin, "shared.sh") {
		t.Errorf("shared: %s %v", p, err)
	}
	if _, err := ScriptPath(wfDir, plugin, "both"); err == nil || !strings.Contains(err.Error(), "must be unique") {
		t.Errorf("both: %v", err)
	}
	if _, err := ScriptPath(wfDir, plugin, "none"); err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Errorf("none: %v", err)
	}
}

// 同梱の ticket ワークフロー（runtime/workflows/ticket.yaml）が harness validate を通る。
func TestShippedTicketWorkflowIsValid(t *testing.T) {
	RegisterObservation("pr-state", []string{"merged", "open", "closed"}) // 実体は engine が登録する（workflow は engine に依存しない）
	RegisterObservationInputs("pr-state", "pr")
	wf, err := LoadAndValidate("../../workflows/ticket.yaml", Options{ScriptsDir: "../../../plugin/scripts"})
	if err != nil {
		t.Fatalf("ticket.yaml must be valid: %v", err)
	}
	if got := wf.Step("e2e-route").Outcomes(); strings.Join(got, ",") != "yes,no" {
		t.Errorf("e2e-route outcomes = %v", got)
	}
	if got := wf.Step("merge-route").Outcomes(); strings.Join(got, ",") != "integration,default" {
		t.Errorf("merge-route outcomes = %v", got)
	}
}

package workflow

import (
	"strings"
	"testing"
)

// 規則 8（docs/harness-runtime-overrides.md §6.2）: origin のブランチを作る・消す・PR を作る段（pull-request の action: ensure-base・open・retire）の
// キーと、そこへ入る・そこから出る遷移は上書きで変えられず、overridable.skips にも挙げられない。

const guardBase = `schema: harness.workflow/v1
id: w
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: open
      bad: { fail: bad }
  open:
    kind: pull-request
    action: open
    with: { head: x, base: main, title: t, summary: s }
    on: { opened: retire, existing: retire }
  retire:
    kind: pull-request
    action: retire
    with: { pr: 7, branch: x, base: main, head: abc }
    on: { deleted: b, absent: b, kept: b }
  b:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: { done: ok }
      bad: { fail: bad }
`

func TestBranchGuardStepsAreRecognized(t *testing.T) {
	if err := check(t, guardBase); err != nil {
		t.Fatalf("a definition with open and retire: %v", err)
	}
	for _, c := range []struct {
		action string
		want   bool
	}{{PRActionOpen, true}, {PRActionRetire, true}, {PRActionEnsureBase, true}, {PRActionLand, false}, {PRActionAdopt, false}, {PRActionPush, false}, {PRActionSync, false}} {
		if got := IsBranchGuardStep(&Step{Kind: "pull-request", Action: c.action}); got != c.want {
			t.Errorf("IsBranchGuardStep(%s) = %v, want %v", c.action, got, c.want)
		}
	}
	if IsBranchGuardStep(&Step{Kind: "command", Action: PRActionRetire}) || IsBranchGuardStep(nil) || IsBranchGuardStep(&Step{Kind: "pull-request"}) {
		t.Error("only a pull-request step with action ensure-base, open or retire is a branch guard step")
	}
}

// 宣言そのものの検査: 3 つの段は overridable.skips に挙げられず、そこへ入る・そこから出る遷移は overridable.routes に宣言できない。
func TestBranchGuardStepsCannotBeDeclaredOverridable(t *testing.T) {
	withOverridable := func(block string) string {
		return strings.Replace(guardBase, "steps:\n", "overridable:\n"+block+"steps:\n", 1)
	}
	for _, c := range []struct{ name, block, want string }{
		{"skip open", "  skips: [open]\n", "step \"open\" creates or deletes a branch or opens a pull request (pull-request action: open); it can never be skipped by an override (§6.2 rule 8)"},
		{"skip retire", "  skips: [retire]\n", "step \"retire\" creates or deletes a branch or opens a pull request (pull-request action: retire); it can never be skipped by an override (§6.2 rule 8)"},
		{"leave retire", "  routes:\n    retire.kept: [b, a]\n", "the transition leaves step \"retire\""},
		{"leave open", "  routes:\n    open.opened: [retire, b]\n", "the transition leaves step \"open\""},
		{"enter open", "  routes:\n    a.ok: [open, b]\n", "the transition leads to step \"open\""},
		{"a candidate that is retire", "  routes:\n    open.existing: [retire, b]\n", "rule 8"},
	} {
		t.Run(c.name, func(t *testing.T) {
			err := check(t, withOverridable(c.block))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want it to contain %q", err, c.want)
			}
		})
	}
}

// 上書きでは、3 つの段の遷移は付け替えられず、キーも書けない（宣言が無いので、規則 8 の理由で拒否される）。
func TestBranchGuardStepsCannotBeOverridden(t *testing.T) {
	for _, c := range []struct{ name, body, want string }{
		{"retire.kept", "steps: { retire: { on: { kept: b } } }\n", "steps.retire.on.kept cannot be overridden: the transition leaves step \"retire\""},
		{"retire.deleted", "steps: { retire: { on: { deleted: b } } }\n", "steps.retire.on.deleted cannot be overridden"},
		{"open.opened", "steps: { open: { on: { opened: b } } }\n", "steps.open.on.opened cannot be overridden: the transition leaves step \"open\""},
		{"a transition into open", "steps: { a: { on: { ok: b } } }\n", "steps.a.on.ok cannot be overridden: the transition leads to step \"open\""},
		{"a key of retire", "steps: { retire: { timeout: 1m } }\n", "retire"},
		{"a key of open", "steps: { open: { budget_usd: 1 } }\n", "open"},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadRoutes2(t, guardBase, "w", c.body)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want it to contain %q", err, c.want)
			}
		})
	}
}

func registerPRState() {
	RegisterObservation("pr-state", []string{"merged", "open", "closed"}) // 実体は engine が登録する
	RegisterObservationInputs("pr-state", "pr")
}

func loadRoutes2(t *testing.T, yaml, id, body string) (*Workflow, error) {
	t.Helper()
	path, scripts := setup(t, id, yaml)
	return LoadWithOverrides(path, Options{ScriptsDir: scripts}, []OverrideSource{{Layer: LayerRepo, Path: "/ov/1.yaml",
		Data: []byte("schema: harness.workflow-override/v1\nworkflow: " + id + "\n" + body)}})
}

// 同梱の ticket・reflect: 3 つの段は overridable.skips に無く、overridable.routes の宣言（段・候補）に出てこない。
func TestBundledWorkflowsDeclareNothingAroundBranchGuardSteps(t *testing.T) {
	registerPRState()
	scripts := "../../../plugin/scripts"
	for _, id := range []string{"ticket", "reflect"} {
		wf, err := LoadAndValidate("../../workflows/"+id+".yaml", Options{ScriptsDir: scripts})
		if err != nil {
			t.Fatal(err)
		}
		guards := 0
		for _, s := range wf.Steps {
			if IsBranchGuardStep(s) {
				guards++
				for _, sk := range wf.Skips {
					if sk == s.ID {
						t.Errorf("%s: %s is listed in overridable.skips", id, s.ID)
					}
				}
			}
		}
		if want := map[string]int{"ticket": 1, "reflect": 2}[id]; guards != want {
			t.Errorf("%s: %d branch guard steps, want %d", id, guards, want)
		}
		for _, d := range wf.Routes {
			if IsBranchGuardStep(wf.Step(d.Step)) {
				t.Errorf("%s: a route is declared from %s", id, d.Step)
			}
			for _, c := range append([]string{d.Step}, d.Candidates...) {
				if IsBranchGuardStep(wf.Step(c)) {
					t.Errorf("%s: route %s mentions %s", id, d.Key(), c)
				}
			}
			if t0 := wf.Step(d.Step).OnFor(d.Outcome); t0 != nil && IsBranchGuardStep(wf.Step(t0.Target)) {
				t.Errorf("%s: route %s leads into %s", id, d.Key(), t0.Target)
			}
		}
	}
}

// 同梱の reflect の open・retire・retire-route・adopt の遷移は、上書きで付け替えられない。ticket の integration（ensure-base）も同じ。
func TestBundledBranchGuardTransitionsCannotBeOverridden(t *testing.T) {
	registerPRState()
	for _, c := range []struct{ wf, body, want string }{
		{"reflect", "steps: { retire: { on: { kept: cleanup } } }\n", "steps.retire.on.kept cannot be overridden"},
		{"reflect", "steps: { retire: { on: { deleted: cleanup-kept } } }\n", "steps.retire.on.deleted cannot be overridden"},
		{"reflect", "steps: { open: { on: { opened: workspace } } }\n", "steps.open.on.opened cannot be overridden"},
		{"reflect", "steps: { retire-route: { on: { integration: cleanup } } }\n", "steps.retire-route.on.integration cannot be overridden"},
		{"reflect", "steps: { land: { on: { landed: retire } } }\n", "steps.land.on.landed cannot be overridden"},
		{"reflect", "steps: { adopt: { on: { no_pr: workspace } } }\n", "steps.adopt.on.no_pr cannot be overridden"},
		{"ticket", "steps: { integration: { on: { created: implement } } }\n", "steps.integration.on.created cannot be overridden"},
		{"ticket", "steps: { integration-route: { on: { create: analyze } } }\n", "steps.integration-route.on.create cannot be overridden"},
	} {
		t.Run(c.wf+" "+c.body, func(t *testing.T) {
			_, err := LoadWithOverrides("../../workflows/"+c.wf+".yaml", Options{ScriptsDir: "../../../plugin/scripts"}, []OverrideSource{{Layer: LayerRepo, Path: "/ov/1.yaml",
				Data: []byte("schema: harness.workflow-override/v1\nworkflow: " + c.wf + "\n" + c.body)}})
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want it to contain %q", err, c.want)
			}
		})
	}
}

// 同梱の reflect の遷移（統合ブランチの名前を受ける道）。
func TestBundledReflectIntegrationRoute(t *testing.T) {
	wf, err := LoadAndValidate("../../workflows/reflect.yaml", Options{ScriptsDir: "../../../plugin/scripts"})
	if err != nil {
		t.Fatal(err)
	}
	if len(wf.Steps) != 17 {
		t.Fatalf("%d steps, want 17", len(wf.Steps))
	}
	for _, c := range []struct{ step, outcome, target string }{
		{"adopt", "adopted", "workspace"}, {"land", "landed", "retire-route"}, {"retire", "deleted", "cleanup"}, {"retire", "absent", "cleanup"},
		{"retire", "kept", "cleanup-kept"}, {"open", "opened", "adopt"}, {"open", "existing", "adopt"}, {"describe", "ok", "open"},
	} {
		if tr := wf.Step(c.step).OnFor(c.outcome); tr == nil || tr.Target != c.target {
			t.Errorf("%s.%s = %+v, want %s", c.step, c.outcome, tr, c.target)
		}
	}
	if tr := wf.Step("adopt").OnFor("no_pr"); tr == nil || tr.Target != "describe" || tr.Limit != "open_pr" || tr.Exhausted == nil || tr.Exhausted.Reason != "pr_not_found" {
		t.Errorf("adopt.no_pr = %+v", tr)
	}
	for outcome, reason := range map[string]string{"unsupported_ref": "artifact_ref_invalid", "branch_missing": "integration_missing", "empty": "integration_empty"} {
		if tr := wf.Step("adopt").OnFor(outcome); tr == nil || tr.Kind != TFail || tr.Reason != reason {
			t.Errorf("adopt.%s = %+v, want fail %s", outcome, tr, reason)
		}
	}
	if len(wf.Facts) != 0 || strings.Join(wf.ReleaseOn, ",") != "cancelled,failed" {
		t.Errorf("facts %v release_on %v", wf.Facts, wf.ReleaseOn)
	}
	if rs := wf.Step("retire-route"); rs == nil || rs.Kind != "select" {
		t.Errorf("retire-route = %+v", rs)
	}
}

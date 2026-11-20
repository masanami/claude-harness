package cli

import (
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// 遷移の付け替え（docs/harness-runtime-overrides.md §5.2・§6.2。#313）の CLI の面: validate の skipped_steps、run の記録、
// 付け替えた定義での resume、拒否される上書きで run を始めないこと。

// routeWorkflow は first → extra → ask（input × any のゲート）→ done。first.ok は [extra, ask] を候補に宣言している。
// first.ok を ask へ付け替えると、extra は到達できなくなる（skipped_steps）。
const routeWorkflow = `schema: harness.workflow/v1
id: rte
limits:
  rework: 1
overridable:
  routes:
    first.ok: [extra, ask]
steps:
  first:
    kind: command
    run: emit
    with: { json: "{}" }
    exit: { 0: ok }
    on: { ok: extra }
  extra:
    kind: command
    run: emit
    with: { json: "{}" }
    exit: { 0: ok }
    on: { ok: ask }
  ask:
    kind: gate
    type: input
    decider: any
    requested_action: say go
    inputs: [go]
    on: { go: { done: finished } }
`

const routeOverride = "schema: harness.workflow-override/v1\nworkflow: rte\nsteps: { first: { on: { ok: ask } } }\n"

// validate は付け替えで到達できなくなったステップを skipped_steps として出し、誤りにしない。
func TestValidateOverrideShowsSkippedSteps(t *testing.T) {
	h := newHarness(t)
	ov := writeFile(t, filepath.Join(t.TempDir(), "ov.yaml"), "schema: harness.workflow-override/v1\nworkflow: ticket\nsteps: { merge-route: { on: { integration: human-merge } } }\n")
	out, errOut, code := h.run("validate", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--override", ov, "ticket")
	if code != ExitOK {
		t.Fatalf("validate exit %d\n%s\n%s", code, out, errOut)
	}
	want := "  changes:\n    steps.merge-route.on.integration: merge -> human-merge (arg)\n  skipped_steps: merge\n"
	if !strings.Contains(out, want) {
		t.Fatalf("validate output lacks\n%s\ngot\n%s", want, out)
	}
}

// 人のゲートへ向かう遷移を付け替える上書きは validate が拒否する（§6.2 の規則 2）。
func TestValidateOverrideRejectsHumanGateRoute(t *testing.T) {
	h := newHarness(t)
	ov := writeFile(t, filepath.Join(t.TempDir(), "ov.yaml"), "schema: harness.workflow-override/v1\nworkflow: ticket\nsteps: { merge-route: { on: { default: merge } } }\n")
	out, errOut, code := h.run("validate", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--override", ov, "ticket")
	if code != ExitFailed || !strings.Contains(errOut, ov+`:3: steps.merge-route.on.default cannot be overridden: the transition leads to the human gate "human-merge"`) {
		t.Fatalf("validate exit %d\n%s\n%s", code, out, errOut)
	}
}

// run は付け替えた定義で進み、skipped_steps と changes を run_started に残す。resume は写しから同じ定義を組み立て直す。
func TestRunRecordsSkippedSteps(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "rte.yaml"), routeWorkflow)
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), routeOverride)
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, errOut, code := h.run("run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", arg, "rte")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	w := runStarted(t, v.RunDir).Workflow
	if strings.Join(w.SkippedSteps, ",") != "extra" {
		t.Fatalf("run_started.workflow.skipped_steps = %v, want [extra]", w.SkippedSteps)
	}
	changes, _ := json.Marshal(w.Changes)
	if want := `[{"key":"steps.first.on.ok","from":"extra","to":"ask","layer":"arg"}]`; string(changes) != want {
		t.Fatalf("changes = %s, want %s", changes, want)
	}
	if steps := stepsStarted(t, v.RunDir); steps != "first" {
		t.Fatalf("steps run before the gate = %q, want only first (extra is skipped)", steps)
	}
	out, errOut, code = h.run("resume", v.RunID, "--input", "go")
	if code != ExitOK {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	if st := decode[runstate.State](t, out); st.Reason != "finished" {
		t.Fatalf("reason %q", st.Reason)
	}
}

// gateBeforeRoute は付け替える辺（mid.ok）より手前にゲート（wait）を置いた定義。wait から resume した後に付け替えた
// 辺を通るので、resume が上書きの写しから定義を組み立て直さなければ（元の遷移を使えば）extra が実行される。
const gateBeforeRoute = `schema: harness.workflow/v1
id: rtg
overridable:
  routes:
    mid.ok: [extra, ask]
steps:
  first:
    kind: command
    run: emit
    with: { json: "{}" }
    exit: { 0: ok }
    on: { ok: wait }
  wait:
    kind: gate
    type: input
    decider: any
    requested_action: say go
    inputs: [go]
    on: { go: mid }
  mid:
    kind: command
    run: emit
    with: { json: "{}" }
    exit: { 0: ok }
    on: { ok: extra }
  extra:
    kind: command
    run: emit
    with: { json: "{}" }
    exit: { 0: ok }
    on: { ok: ask }
  ask:
    kind: gate
    type: input
    decider: any
    requested_action: say go
    inputs: [go]
    on: { go: { done: finished } }
`

// 付け替えた辺より手前のゲートから resume しても、付け替えた定義で進む（extra は実行されない）。
func TestResumeBeforeRerouteUsesOverride(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "rtg.yaml"), gateBeforeRoute)
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), "schema: harness.workflow-override/v1\nworkflow: rtg\nsteps: { mid: { on: { ok: ask } } }\n")
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, errOut, code := h.run("run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", arg, "rtg")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if steps := stepsStarted(t, v.RunDir); steps != "first" {
		t.Fatalf("steps before the first gate = %q, want first", steps)
	}
	out, errOut, code = h.run("resume", v.RunID, "--input", "go")
	if code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	if steps := stepsStarted(t, v.RunDir); steps != "first,mid" {
		t.Fatalf("steps after resuming before the rerouted edge = %q, want first,mid (extra is skipped)", steps)
	}
	out, errOut, code = h.run("resume", v.RunID, "--input", "go")
	if code != ExitOK {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	if st := decode[runstate.State](t, out); st.Reason != "finished" {
		t.Fatalf("reason %q", st.Reason)
	}
}

// 人のゲートを外す上書きでは run を始めない（§6.2 の規則 1。run の開始時にも検査する）。
func TestRunRefusesHumanGateOverride(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	// 宣言を外す（extra は人のゲート ask へ入るので、first.ok を ask へ付け替える宣言は規則 6 で拒否される）。
	human := strings.Replace(strings.Replace(routeWorkflow, "decider: any", "decider: human", 1), "overridable:\n  routes:\n    first.ok: [extra, ask]\n", "", 1)
	writeFile(t, filepath.Join(wd, "rte.yaml"), human)
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), "schema: harness.workflow-override/v1\nworkflow: rte\nsteps: { ask: { on: { go: first } } }\n")
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, errOut, code := h.run("run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", arg, "rte")
	if code != ExitUsage || !strings.Contains(errOut, "no run was started") || !strings.Contains(errOut, "steps.ask is a human gate (decider: human)") {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	if ids, _ := runstate.List(filepath.Join(state, "runs")); len(ids) != 0 {
		t.Fatalf("runs = %v", ids)
	}
}

// stepsStarted は run の events.jsonl に記録された step_started のステップ id を順に返す。
func stepsStarted(t *testing.T, runDir string) string {
	t.Helper()
	evs, _, err := runstate.ReadEvents(filepath.Join(runDir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, e := range evs {
		if e.StepStarted != nil {
			ids = append(ids, e.StepStarted.Step)
		}
	}
	return strings.Join(ids, ",")
}

// §6.2 の規則 7（#388 の S3-3）: 一致を確かめて入れる段（pull-request の action: land）は、外せず、迂回できず、付け替えられない。
// 上書きは land の段のどのキーも書けず、land から出る遷移と、通した中身（$gate.approved_ref）を渡す遷移も付け替えられない。
func TestValidateOverrideRejectsTheLandStep(t *testing.T) {
	h := newHarness(t)
	for _, c := range []struct{ name, body, want string }{
		{"a transition leaving land", "steps: { land: { on: { landed: human-merge } } }",
			`steps.land.on.landed cannot be overridden: the transition leaves step "land", which lands the pull request (pull-request action: land) (§6.2 rule 7)`},
		{"every outcome of land is locked", "steps: { land: { on: { behind: cleanup } } }", `steps.land.on.behind cannot be overridden`},
		{"the transition that passes the approved ref", "steps: { review: { on: { land: cleanup } } }",
			"steps.review.on.land cannot be overridden: the transition passes $gate.approved_ref to a step that lands the pull request (§6.2 rule 7)"},
		{"the with of land", "steps: { land: { with: { approved_ref: x } } }", "steps.land.with cannot be overridden"},
		{"the action of land", "steps: { land: { action: sync } }", "steps.land.action cannot be overridden"},
		{"a timeout on land", "steps: { land: { timeout: 5m } }", "steps.land.timeout: a pull-request step has no timeout"},
	} {
		t.Run(c.name, func(t *testing.T) {
			ov := writeFile(t, filepath.Join(t.TempDir(), "ov.yaml"), "schema: harness.workflow-override/v1\nworkflow: ticket\n"+c.body+"\n")
			out, errOut, code := h.run("validate", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--override", ov, "ticket")
			if code != ExitFailed || !strings.Contains(errOut, c.want) {
				t.Fatalf("validate exit %d, want a rejection containing %q\n%s\n%s", code, c.want, out, errOut)
			}
		})
	}
}

// 元の定義の検査: land を overridable.skips に挙げる・land の遷移を overridable.routes に宣言する・通した中身をゲートの解決以外から渡す
// 定義は、--workflow-dir の定義でも validate が拒否する（`$gate.approved_ref` の行き先と interrupted の検査は定義そのものの規則）。
func TestValidateRejectsDefinitionsThatLoosenTheLandStep(t *testing.T) {
	h := newHarness(t)
	base := readFile(t, filepath.Join(repoWorkflows, "ticket.yaml"))
	for _, c := range []struct{ name, old, new, want string }{
		{"land in skips", "  skips: [quality]", "  skips: [quality, land]", `overridable.skips: step "land" lands the pull request into its base (pull-request action: land); it can never be skipped by an override (§6.2 rule 7)`},
		{"a land outcome declared overridable", "    respond.pushed: [quality, ci]", "    respond.pushed: [quality, ci]\n    land.landed: [cleanup, human-merge]",
			`overridable.routes.land.landed: the transition leaves step "land", which lands the pull request (pull-request action: land); it cannot be declared overridable (§6.2 rule 7)`},
		{"the approved ref from an input", "approved_ref: $edge.approved_ref }", "approved_ref: $inputs.task_id }", "optional input"},
		{"the approved ref as a literal", "approved_ref: $edge.approved_ref }", `approved_ref: "abc" }`, "must read it as $edge.<name>"},
		{"the approved ref not passed by a gate transition", "land: { goto: land, with: { approved_ref: $gate.approved_ref }, interrupted: { fail: interrupted_after_land } }",
			"land: { goto: land, with: { approved_ref: $steps.publish.pr_url } }", "must pass approved_ref as $gate.approved_ref"},
		{"the approved ref without interrupted", ", interrupted: { fail: interrupted_after_land } }", " }", "must write interrupted: { fail: <reason> }"},
		{"the approved ref to another step", "ready: merge-route                            # 変えない（land とは別の道）",
			"ready: { goto: respond, with: { note: $gate.approved_ref }, interrupted: { fail: x } }",
			"$gate.approved_ref can be passed only to the with.approved_ref of a step that lands the pull request"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if strings.Count(base, c.old) != 1 {
				t.Fatalf("%q occurs %d times in ticket.yaml", c.old, strings.Count(base, c.old))
			}
			dir := copyWorkflowDir(t)
			writeFile(t, filepath.Join(dir, "ticket.yaml"), strings.Replace(base, c.old, c.new, 1))
			out, errOut, code := h.run("validate", "--workflow-dir", dir, "--scripts-dir", abs(t, repoScripts), "ticket")
			if code != ExitFailed || !strings.Contains(errOut, c.want) {
				t.Fatalf("validate exit %d, want a rejection containing %q\n%s\n%s", code, c.want, out, errOut)
			}
		})
	}
}

// copyWorkflowDir は runtime/workflows を一時ディレクトリへ写す（定義を書き換えた写しで validate を試す）。
func copyWorkflowDir(t *testing.T) string {
	t.Helper()
	dst := filepath.Join(t.TempDir(), "workflows")
	if out, err := exec.Command("cp", "-R", abs(t, repoWorkflows), dst).CombinedOutput(); err != nil {
		t.Fatalf("cp: %v\n%s", err, out)
	}
	return dst
}

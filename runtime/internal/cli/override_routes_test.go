package cli

import (
	"encoding/json"
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

// 人のゲートを外す上書きでは run を始めない（§6.2 の規則 1。run の開始時にも検査する）。
func TestRunRefusesHumanGateOverride(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "rte.yaml"), strings.Replace(routeWorkflow, "decider: any", "decider: human", 1))
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

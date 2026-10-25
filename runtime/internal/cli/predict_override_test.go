package cli

import (
	"path/filepath"
	"testing"
)

// predict-conflicts もリポジトリの上書き（.claude-harness/overrides/conflict-predict-issue.yaml）を重ねて予測の run を
// 起動する（validate が「効いた」と出す値と、予測の run が走る値を揃える。#313 で段 1 の食い違いを直した）。
func TestPredictConflictsAppliesRepoOverride(t *testing.T) {
	f := newPredictFixture(t)
	ov := writeFile(t, filepath.Join(f.repo, RepoOverrideDir, predictWorkflow+".yaml"),
		"schema: harness.workflow-override/v1\nworkflow: conflict-predict-issue\nlimits: { budget_usd: 2 }\n")
	f.issue(t, 10, "a")
	f.issue(t, 11, "b")
	f.predicts(t, 10, []string{"a.go"}, []int{}, 0.25)
	f.predicts(t, 11, []string{"b.go"}, []int{}, 0.25)

	d, raw := f.predict(t, false, "10", "11")
	if d.Error != nil || !d.Complete {
		t.Fatalf("error %v complete %v\n%s", d.Error, d.Complete, raw)
	}
	if d.Budget.PerIssueUSD != 2 || d.Budget.LimitUSD != 4 {
		t.Fatalf("budget %+v: the repository override (limits.budget_usd: 2) must be the share of one issue", d.Budget)
	}
	runs := f.runs(t)
	if len(runs) != 2 {
		t.Fatalf("runs = %v", runs)
	}
	for _, id := range runs {
		w := runStarted(t, filepath.Join(f.state, "runs", id)).Workflow
		if len(w.Overrides) != 1 || w.Overrides[0].Layer != "repo" || w.Overrides[0].Path != ov {
			t.Fatalf("run %s: run_started.workflow.overrides = %+v", id, w.Overrides)
		}
	}
}

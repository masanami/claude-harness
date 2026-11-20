package runstate

import (
	"encoding/json"
	"strings"
	"testing"
)

// 統合ブランチの記録（workspace イベントの action: integration。docs/harness-runtime-design.md §5.6.3）の畳み込み。

func integrationEvents(extra ...Event) []Event {
	evs := []Event{
		{Type: EvRunStarted, RunStarted: &RunStarted{RunID: "r1", Workflow: WorkflowRecord{WorkflowRef: WorkflowRef{ID: "w"}}, Inputs: map[string]json.RawMessage{}, Units: []string{"main"}, EntryStep: "integ"}},
		{Type: EvRoundStarted, RoundStarted: &RoundStarted{Unit: "main", Round: 1, Trigger: Trigger{Kind: "start"}}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "integ", Attempt: 1}},
		{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceIntegration, Branch: "integration/c-12", HeadSHA: "aaa"}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "integ", Attempt: 1, Outcome: "created"}},
		{Type: EvTransition, Transition: &Transition{Unit: "main", From: "integ", Outcome: "created", Action: "step", To: "ws"}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "ws", Attempt: 1}},
	}
	return withSeq(append(evs, extra...))
}

func acquired(path string) Event {
	return Event{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceAcquired, WorktreePath: path, Branch: "feature/task-1-x", Base: "integration/c-12", ProvidedBy: "runtime", Created: true}}
}

// 名前と先頭を記録する（Workspace が無ければ作る。作業ツリーの前なので、作業ツリーの場所は空）。
func TestFoldIntegrationCreatesTheWorkspaceRecord(t *testing.T) {
	st, err := Fold(integrationEvents())
	if err != nil {
		t.Fatal(err)
	}
	u := st.Unit("main")
	if u.Workspace == nil || u.Workspace.IntegrationBranch != "integration/c-12" || u.Workspace.IntegrationHead != "aaa" || u.ActiveWorkspace() != "" {
		t.Fatalf("workspace = %+v", u.Workspace)
	}
}

// 作業ツリーを払い出しても（acquired）、取り直しても（別の場所になっても）持ち越す。PR の記録の持ち越しの条件は変わらない。
func TestFoldIntegrationSurvivesAcquired(t *testing.T) {
	for _, paths := range [][]string{{"/wt/task-1"}, {"/wt/task-1", "/wt/task-1"}, {"/wt/task-1", "/elsewhere/task-1"}} {
		var extra []Event
		for _, p := range paths {
			extra = append(extra, acquired(p))
		}
		st, err := Fold(integrationEvents(extra...))
		if err != nil {
			t.Fatal(err)
		}
		w := st.Unit("main").Workspace
		if w.IntegrationBranch != "integration/c-12" || w.IntegrationHead != "aaa" || w.WorktreePath != paths[len(paths)-1] {
			t.Fatalf("paths %v: workspace = %+v", paths, w)
		}
	}
}

// 同じ名前の integration は先頭を置き換える。名前が違えば誤り。名前か先頭が空でも誤り。
func TestFoldIntegrationReplacesTheHeadAndRejectsAnotherName(t *testing.T) {
	again := Event{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceIntegration, Branch: "integration/c-12", HeadSHA: "bbb"}}
	st, err := Fold(integrationEvents(acquired("/wt/task-1"), again))
	if err != nil {
		t.Fatal(err)
	}
	if h := st.Unit("main").Workspace.IntegrationHead; h != "bbb" {
		t.Fatalf("head = %q, want bbb", h)
	}
	for name, ev := range map[string]WorkspaceEvent{
		"another name": {Unit: "main", Action: WorkspaceIntegration, Branch: "integration/c-13", HeadSHA: "ccc"},
		"no branch":    {Unit: "main", Action: WorkspaceIntegration, HeadSHA: "ccc"},
		"no head":      {Unit: "main", Action: WorkspaceIntegration, Branch: "integration/c-12"},
	} {
		ev := ev
		if _, err := Fold(integrationEvents(Event{Type: EvWorkspace, Workspace: &ev})); err == nil {
			t.Errorf("%s: the fold accepted it", name)
		} else if name == "another name" && !strings.Contains(err.Error(), "differs from the recorded integration branch") {
			t.Errorf("%s: err = %v", name, err)
		}
	}
}

// 実行中の段の外では書けない（待っている間の取り直しは、この PR の範囲外）。
func TestFoldIntegrationOutsideAStepIsRejected(t *testing.T) {
	evs := integrationEvents()
	evs = withSeq(append(evs[:5], Event{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceIntegration, Branch: "integration/c-12", HeadSHA: "bbb"}}))
	if _, err := Fold(evs); err == nil || !strings.Contains(err.Error(), "outside a running step") {
		t.Fatalf("err = %v", err)
	}
}

// イベントは JSON を往復しても変わらない（古い記録には欄が無く、そのまま畳める）。
func TestIntegrationEventRoundTrips(t *testing.T) {
	data, err := json.Marshal(integrationEvents()[3])
	if err != nil {
		t.Fatal(err)
	}
	var back Event
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatal(err)
	}
	if w := back.Workspace; w == nil || w.Action != WorkspaceIntegration || w.Branch != "integration/c-12" || w.HeadSHA != "aaa" {
		t.Fatalf("round trip = %s", data)
	}
	if st, err := Fold(workspaced(true, true)); err != nil || st.Unit("main").Workspace.IntegrationBranch != "" {
		t.Fatalf("a log without the integration action: %v %+v", err, st.Unit("main").Workspace)
	}
}

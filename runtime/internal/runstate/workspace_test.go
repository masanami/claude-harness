package runstate

import (
	"encoding/json"
	"strings"
	"testing"
)

// workspaced は作業ツリーの払い出し・PR・返却を含む列（PR-4・§4.1 Workspace）。
func workspaced(created bool, removed bool) []Event {
	return withSeq([]Event{
		{Type: EvRunStarted, RunStarted: &RunStarted{RunID: "r1", Workflow: WorkflowRecord{WorkflowRef: WorkflowRef{ID: "w"}}, Inputs: map[string]json.RawMessage{}, Units: []string{"main"}, EntryStep: "ws"}},
		{Type: EvRoundStarted, RoundStarted: &RoundStarted{Unit: "main", Round: 1, Trigger: Trigger{Kind: "start"}}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "ws", Attempt: 1}},
		{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceAcquired, WorktreePath: "/wt/issue-7", Branch: "feature/issue-7-x", Base: "main",
			ProvidedBy: map[bool]string{true: "runtime", false: "caller"}[created], Created: created}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "ws", Attempt: 1, Outcome: "created"}},
		{Type: EvTransition, Transition: &Transition{Unit: "main", From: "ws", Outcome: "created", Action: "step", To: "pr"}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "pr", Attempt: 1}},
		{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspacePR, Branch: "feature/issue-7-x", PRNumber: 7, PRURL: "u", HeadSHA: "abc"}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "pr", Attempt: 1, Outcome: "opened"}},
		{Type: EvTransition, Transition: &Transition{Unit: "main", From: "pr", Outcome: "opened", Action: "step", To: "rel"}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "rel", Attempt: 1}},
		{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceReleased, Removed: removed, Detail: "d"}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "rel", Attempt: 1, Outcome: "released"}},
	})
}

func TestFoldWorkspace(t *testing.T) {
	st, err := Fold(workspaced(true, true)[:9])
	if err != nil {
		t.Fatal(err)
	}
	u := st.Unit("main")
	if u.ActiveWorkspace() != "/wt/issue-7" || u.Workspace.PRNumber != 7 || u.Workspace.HeadSHAs["1"] != "abc" || !u.Workspace.Created {
		t.Fatalf("workspace = %+v", u.Workspace)
	}
	st, err = Fold(workspaced(true, true))
	if err != nil {
		t.Fatal(err)
	}
	if u := st.Unit("main"); u.ActiveWorkspace() != "" || !u.Workspace.Released || !u.Workspace.Removed || u.Workspace.PRNumber != 7 {
		t.Fatalf("workspace after release = %+v", u.Workspace)
	}
}

// 呼び出し元が渡した作業ツリーを「消した」記録は、畳み込みが拒否する（§5.4: release は自分が作ったものだけを消す）。
func TestFoldRejectsRemovingAWorktreeTheRunDidNotCreate(t *testing.T) {
	if _, err := Fold(workspaced(false, true)); err == nil || !strings.Contains(err.Error(), "did not create") {
		t.Fatalf("err = %v", err)
	}
	if _, err := Fold(workspaced(false, false)); err != nil {
		t.Fatalf("keeping a provided worktree must fold: %v", err)
	}
}

func TestFoldRejectsInconsistentWorkspace(t *testing.T) {
	cases := map[string]func([]Event) []Event{
		"outside a running step": func(evs []Event) []Event {
			return withSeq(append(append([]Event{}, evs[:2]...), evs[3]))
		},
		"caller-provided but created": func(evs []Event) []Event {
			evs[3].Workspace.ProvidedBy, evs[3].Workspace.Created = "caller", true
			return evs
		},
		"release without a workspace": func(evs []Event) []Event {
			out := append([]Event{}, evs[:3]...)
			return withSeq(append(out, evs[11]))
		},
		"pr without a number": func(evs []Event) []Event {
			evs[7].Workspace.PRNumber = 0
			return evs
		},
		"unknown action": func(evs []Event) []Event {
			evs[3].Workspace.Action = "borrowed"
			return evs
		},
	}
	for name, mut := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Fold(mut(workspaced(true, true))); err == nil {
				t.Fatal("expected the fold to reject the log")
			}
		})
	}
}

// PR のいまの先頭（head_sha）と、入れた後のコミット（merge_commit）。publish の記録はラウンドごとの先頭（head_sha_by_round）も書き、
// push・land の記録（head_only）は PR のいまの先頭だけを書く。URL を省いた記録（land）は、記録済みの URL を消さない。
// どちらの記録も、この版より前の記録（head_sha だけ）と同じ畳み込みで読める。
func TestFoldPRHeadAndMergeCommit(t *testing.T) {
	evs := workspaced(true, true)[:9]
	st, err := Fold(evs)
	if err != nil {
		t.Fatal(err)
	}
	if ws := st.Unit("main").Workspace; ws.HeadSHA != "abc" || ws.HeadSHAs["1"] != "abc" || ws.MergeCommit != "" {
		t.Fatalf("after publish = %+v", ws)
	}
	// 同じラウンドで、push の記録が先頭を更新しても、ラウンドごとの記録は publish のまま。
	out := append(append([]Event{}, evs[:8]...),
		Event{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspacePR, PRNumber: 7, HeadSHA: "def", HeadOnly: true}},
		Event{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspacePR, PRNumber: 7, HeadSHA: "def", MergeCommit: "mmm", HeadOnly: true}},
		evs[8])
	st, err = Fold(withSeq(out))
	if err != nil {
		t.Fatal(err)
	}
	ws := st.Unit("main").Workspace
	if ws.HeadSHA != "def" || ws.MergeCommit != "mmm" || ws.HeadSHAs["1"] != "abc" || len(ws.HeadSHAs) != 1 || ws.PRURL != "u" || ws.Branch != "feature/issue-7-x" {
		t.Fatalf("workspace = %+v", ws)
	}
	// 往復: 記録のイベントは JSON を経ても同じ状態になる。
	data, err := json.Marshal(withSeq(out)[8])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"head_only":true`) || !strings.Contains(string(data), `"head_sha":"def"`) {
		t.Fatalf("event = %s", data)
	}
	var back Event
	if err := json.Unmarshal(data, &back); err != nil || back.Workspace == nil || !back.Workspace.HeadOnly || back.Workspace.HeadSHA != "def" {
		t.Fatalf("round trip = %+v %v", back.Workspace, err)
	}
}

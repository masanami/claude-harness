package runstate

import (
	"encoding/json"
	"strings"
	"testing"
)

// 終わりの片付け（release_on。§5.6.2）の released を、実行中の段の外で許す状態と、許さない例。

// acquiredThenWaiting は、作業ツリーを払い出し（この run が作った）、ゲートで待っている列。
func acquiredThenWaiting(created bool) []Event {
	return []Event{
		{Type: EvRunStarted, RunStarted: &RunStarted{RunID: "r1", Workflow: WorkflowRecord{WorkflowRef: WorkflowRef{ID: "w"}}, Inputs: map[string]json.RawMessage{}, Units: []string{"main"}, EntryStep: "ws", ReleaseOn: []string{"cancelled", "failed"}}},
		{Type: EvRoundStarted, RoundStarted: &RoundStarted{Unit: "main", Round: 1, Trigger: Trigger{Kind: "start"}}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "ws", Attempt: 1}},
		{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceAcquired, WorktreePath: "/w/pr-7", Branch: "b", Base: "main", ProvidedBy: "runtime", Created: created}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "ws", Attempt: 1, Outcome: "created"}},
		{Type: EvTransition, Transition: &Transition{Unit: "main", From: "ws", Outcome: "created", Action: "gate", To: "review"}},
		{Type: EvGateOpened, GateOpened: &GateOpened{Unit: "main", Gate: "review", Type: "input", Decider: "any", RequestedAction: "r", Inputs: []string{"land"}}},
	}
}

func releasedAtEnd(removed bool) Event {
	return Event{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceReleased, Removed: removed, Detail: "removed"}}
}

func cancelRequested() Event {
	return Event{Type: EvCancelRequested, CancelRequested: &CancelRequested{Actor: "cli", Channel: "non-tty"}}
}

func TestFoldReleasedAtEndWhenCancelRequestedAtAGate(t *testing.T) {
	evs := append(acquiredThenWaiting(true), cancelRequested(), releasedAtEnd(true),
		Event{Type: EvRunCancelled, RunCancelled: &RunCancelled{Actor: "cli", Channel: "non-tty"}})
	s, err := Fold(withSeq(evs))
	if err != nil {
		t.Fatal(err)
	}
	ws := s.Unit("main").Workspace
	if !ws.Released || !ws.Removed || s.Status != StatusCancelled || len(s.ReleaseOn) != 2 || s.ReleaseOn[0] != "cancelled" {
		t.Fatalf("workspace %+v status %s release_on %v", ws, s.Status, s.ReleaseOn)
	}
	// 往復: JSON を経ても同じ。
	var back []Event
	for _, ev := range withSeq(evs) {
		data, err := json.Marshal(ev)
		if err != nil {
			t.Fatal(err)
		}
		var b Event
		if err := json.Unmarshal(data, &b); err != nil {
			t.Fatal(err)
		}
		back = append(back, b)
	}
	if s2, err := Fold(back); err != nil || !s2.Unit("main").Workspace.Released || len(s2.ReleaseOn) != 2 {
		t.Fatalf("round trip: %v", err)
	}
}

func TestFoldReleasedAtEndAfterTheUnitFailed(t *testing.T) {
	evs := append(acquiredThenWaiting(true),
		Event{Type: EvGateResolved, GateResolved: &GateResolved{Unit: "main", Gate: "review", Outcome: "land", Actor: "resume", Channel: "non-tty"}},
		Event{Type: EvTransition, Transition: &Transition{Unit: "main", From: "review", Outcome: "land", Action: "fail", Reason: "boom"}},
		releasedAtEnd(true),
		Event{Type: EvRunFinished, RunFinished: &RunFinished{Status: StatusFailed, Reason: "boom"}})
	if s, err := Fold(withSeq(evs)); err != nil || !s.Unit("main").Workspace.Released || s.Status != StatusFailed {
		t.Fatalf("err %v", err)
	}
}

// runner がシグナルで止められ、実行中だった段を打ち切った後（cancel_requested は無い）: unit は running のまま。
func TestFoldReleasedAtEndAfterASignalStoppedTheRunner(t *testing.T) {
	evs := append(acquiredThenWaiting(true)[:5],
		Event{Type: EvTransition, Transition: &Transition{Unit: "main", From: "ws", Outcome: "created", Action: "step", To: "next"}},
		Event{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "next", Attempt: 1}},
		Event{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "next", Attempt: 1, Cancelled: true, Error: "cancelled"}},
		releasedAtEnd(true),
		Event{Type: EvRunCancelled, RunCancelled: &RunCancelled{Actor: "signal", Channel: "signal"}})
	if s, err := Fold(withSeq(evs)); err != nil || !s.Unit("main").Workspace.Released {
		t.Fatalf("err %v", err)
	}
}

// 許さない例（設計の表）: 取り消しの要求が無いままゲートで待っている unit・succeeded の unit・作業ツリーの記録が無い、または
// 返した後の unit・終わった run・この run が作っていないものを消したと記録する released。
func TestFoldReleasedAtEndRejected(t *testing.T) {
	noWorkspace := acquiredThenWaiting(true)
	noWorkspace = append(noWorkspace[:3:3], noWorkspace[4:]...) // 払い出しの記録を除く
	succeeded := append(acquiredThenWaiting(true),
		Event{Type: EvGateResolved, GateResolved: &GateResolved{Unit: "main", Gate: "review", Outcome: "land", Actor: "resume", Channel: "non-tty"}},
		Event{Type: EvTransition, Transition: &Transition{Unit: "main", From: "review", Outcome: "land", Action: "done", Reason: "landed"}},
		releasedAtEnd(true))
	cases := map[string][]Event{
		"waiting at a gate without a cancel request": append(acquiredThenWaiting(true), releasedAtEnd(true)),
		"succeeded unit":                            succeeded,
		"no workspace record":                       append(noWorkspace, cancelRequested(), releasedAtEnd(false)),
		"already released":                          append(acquiredThenWaiting(true), cancelRequested(), releasedAtEnd(true), releasedAtEnd(true)),
		"removed a worktree the run did not create": append(acquiredThenWaiting(false), cancelRequested(), releasedAtEnd(true)),
		"run ended": append(acquiredThenWaiting(true), cancelRequested(),
			Event{Type: EvRunCancelled, RunCancelled: &RunCancelled{Actor: "cli", Channel: "non-tty"}}, releasedAtEnd(true)),
	}
	for name, evs := range cases {
		if _, err := Fold(withSeq(evs)); err == nil {
			t.Errorf("%s: released was accepted", name)
		} else if !strings.Contains(err.Error(), "released") && !strings.Contains(err.Error(), "after the run ended") {
			t.Errorf("%s: rejected for another reason: %v", name, err)
		}
	}
}

// adopt は作業ツリーの払い出しより前に PR を記録する。その後の acquired は、前の記録に作業ツリーの場所が無いときも PR の記録を持ち越す。
func TestFoldAcquireKeepsThePRRecordedBeforeTheWorktree(t *testing.T) {
	evs := []Event{
		{Type: EvRunStarted, RunStarted: &RunStarted{RunID: "r1", Workflow: WorkflowRecord{WorkflowRef: WorkflowRef{ID: "w"}}, Inputs: map[string]json.RawMessage{}, Units: []string{"main"}, EntryStep: "adopt"}},
		{Type: EvRoundStarted, RoundStarted: &RoundStarted{Unit: "main", Round: 1, Trigger: Trigger{Kind: "start"}}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "adopt", Attempt: 1}},
		{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspacePR, Branch: "b", PRNumber: 7, PRURL: "u", HeadSHA: "abc", HeadOnly: true}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "adopt", Attempt: 1, Outcome: "adopted"}},
		{Type: EvTransition, Transition: &Transition{Unit: "main", From: "adopt", Outcome: "adopted", Action: "step", To: "ws"}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "ws", Attempt: 1}},
		{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceAcquired, WorktreePath: "/w/pr-7", Branch: "b", Base: "main", ProvidedBy: "runtime", Created: true}},
	}
	s, err := Fold(withSeq(evs))
	if err != nil {
		t.Fatal(err)
	}
	ws := s.Unit("main").Workspace
	if ws.PRNumber != 7 || ws.PRURL != "u" || ws.HeadSHA != "abc" || ws.WorktreePath != "/w/pr-7" || !ws.Created || len(ws.HeadSHAs) != 0 {
		t.Fatalf("workspace = %+v", ws)
	}
}

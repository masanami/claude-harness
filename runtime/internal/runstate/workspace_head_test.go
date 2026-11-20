package runstate

import (
	"encoding/json"
	"strings"
	"testing"
)

// waitingWithPR は PR を出した後、refresh の印のあるゲートで待っている列（§5.6.2 の head を許す状態）。
func waitingWithPR(refresh string, withPR bool) []Event {
	evs := []Event{
		{Type: EvRunStarted, RunStarted: &RunStarted{RunID: "r1", Workflow: WorkflowRecord{WorkflowRef: WorkflowRef{ID: "w"}}, Inputs: map[string]json.RawMessage{}, Units: []string{"main"}, EntryStep: "pr"}},
		{Type: EvRoundStarted, RoundStarted: &RoundStarted{Unit: "main", Round: 1, Trigger: Trigger{Kind: "start"}}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "pr", Attempt: 1}},
	}
	if withPR {
		evs = append(evs, Event{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspacePR, Branch: "b", PRNumber: 7, PRURL: "u", HeadSHA: "abc"}})
	}
	return append(evs,
		Event{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "pr", Attempt: 1, Outcome: "opened"}},
		Event{Type: EvTransition, Transition: &Transition{Unit: "main", From: "pr", Outcome: "opened", Action: "gate", To: "review"}},
		Event{Type: EvGateOpened, GateOpened: &GateOpened{Unit: "main", Gate: "review", Type: "input", Decider: "any", RequestedAction: "r", Inputs: []string{"land"}, Refresh: refresh}},
	)
}

func headEvent(sha string) Event {
	return Event{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspaceHead, HeadSHA: sha}}
}

func TestFoldHeadAtRefreshGate(t *testing.T) {
	evs := append(waitingWithPR("pr-head", true), headEvent("def"))
	s, err := Fold(withSeq(evs))
	if err != nil {
		t.Fatal(err)
	}
	ws := s.Unit("main").Workspace
	if ws.HeadSHA != "def" || ws.HeadSHAs["1"] != "abc" || len(ws.HeadSHAs) != 1 || ws.PRNumber != 7 {
		t.Fatalf("workspace = %+v", ws)
	}
	if s.Unit("main").Gate == nil || s.Unit("main").Gate.Refresh != "pr-head" {
		t.Fatalf("gate = %+v", s.Unit("main").Gate)
	}
	// 往復: JSON を経ても同じ。
	data, err := json.Marshal(withSeq(evs)[len(evs)-1])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"action":"head"`) {
		t.Fatalf("event = %s", data)
	}
	var back Event
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatal(err)
	}
	evs[len(evs)-1] = back
	if s2, err := Fold(withSeq(evs)); err != nil || s2.Unit("main").Workspace.HeadSHA != "def" {
		t.Fatalf("round trip: %v", err)
	}
}

// 許さない例（設計の表）: 印の無いゲート・PR の記録の無い unit・running の unit・終わった run・段の中。
func TestFoldHeadRejected(t *testing.T) {
	cases := map[string][]Event{
		"gate without refresh":  append(waitingWithPR("", true), headEvent("def")),
		"unit without PR":       append(waitingWithPR("pr-head", false), headEvent("def")),
		"missing head_sha":      append(waitingWithPR("pr-head", true), headEvent("")),
		"running unit":          append(waitingWithPR("pr-head", true)[:3], append([]Event{{Type: EvWorkspace, Workspace: &WorkspaceEvent{Unit: "main", Action: WorkspacePR, PRNumber: 7, HeadSHA: "abc"}}}, headEvent("def"))...),
		"after the gate closes": append(waitingWithPR("pr-head", true), Event{Type: EvGateResolved, GateResolved: &GateResolved{Unit: "main", Gate: "review", Outcome: "land", Actor: "resume", Channel: "non-tty"}}, headEvent("def")),
		"run ended": append(waitingWithPR("pr-head", true),
			Event{Type: EvGateResolved, GateResolved: &GateResolved{Unit: "main", Gate: "review", Outcome: "land", Actor: "resume", Channel: "non-tty"}},
			Event{Type: EvTransition, Transition: &Transition{Unit: "main", From: "review", Outcome: "land", Action: "done", Reason: "merged"}},
			Event{Type: EvRunFinished, RunFinished: &RunFinished{Status: StatusSucceeded, Reason: "merged"}},
			headEvent("def")),
	}
	for name, evs := range cases {
		if _, err := Fold(withSeq(evs)); err == nil {
			t.Errorf("%s: head was accepted", name)
		} else if !strings.Contains(err.Error(), "workspace head") && !strings.Contains(err.Error(), "after the run ended") {
			t.Errorf("%s: rejected for another reason: %v", name, err)
		}
	}
}

package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// 片付けるものがあるか（wantsRelease）は、終わりの手前までのイベントを当てた後の状態で判定する。interrupted のゲートの abort のように、
// unit を待ちから失敗へ送る遷移と run の終わりが 1 回で返る道でも、この run が作った作業ツリーの released が記録される。
func TestAppendEndingReleasesWhenTheUnitFailsInTheSameBatchAsTheEnd(t *testing.T) {
	run, err := runstate.Create(t.TempDir(), "r1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := run.Append(
		runstate.Event{Type: runstate.EvRunStarted, RunStarted: &runstate.RunStarted{RunID: "r1", Workflow: runstate.WorkflowRecord{WorkflowRef: runstate.WorkflowRef{ID: "w"}},
			Inputs: map[string]json.RawMessage{}, Units: []string{"main"}, EntryStep: "ws", ReleaseOn: []string{"cancelled", "failed"}}},
		runstate.Event{Type: runstate.EvRoundStarted, RoundStarted: &runstate.RoundStarted{Unit: "main", Round: 1, Trigger: runstate.Trigger{Kind: "start"}}},
		runstate.Event{Type: runstate.EvStepStarted, StepStarted: &runstate.StepStarted{Unit: "main", Step: "ws", Attempt: 1}},
		runstate.Event{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{Unit: "main", Action: runstate.WorkspaceAcquired,
			WorktreePath: "/nonexistent/pr-7", Branch: "b", Base: "main", ProvidedBy: "runtime", Created: true}},
		runstate.Event{Type: runstate.EvStepFinished, StepFinished: &runstate.StepFinished{Unit: "main", Step: "ws", Attempt: 1, Outcome: "created"}},
		runstate.Event{Type: runstate.EvTransition, Transition: &runstate.Transition{Unit: "main", From: "ws", Outcome: "created", Action: "gate", To: "interrupted"}},
		runstate.Event{Type: runstate.EvGateOpened, GateOpened: &runstate.GateOpened{Unit: "main", Gate: "interrupted", Type: "input", Decider: "any",
			RequestedAction: "r", Inputs: []string{"rerun", "abort"}, Builtin: true}},
	); err != nil {
		t.Fatal(err)
	}
	st, _, err := run.Load()
	if err != nil {
		t.Fatal(err)
	}
	if u := st.Unit("main"); u.Status != runstate.StatusWaiting {
		t.Fatalf("precondition: unit status %s, want waiting", u.Status)
	}

	st, err = AppendEnding(run, func(*runstate.State) ([]runstate.Event, error) {
		return []runstate.Event{
			{Type: runstate.EvGateResolved, GateResolved: &runstate.GateResolved{Unit: "main", Gate: "interrupted", Outcome: "abort", Actor: "resume", Channel: "non-tty"}},
			{Type: runstate.EvTransition, Transition: &runstate.Transition{Unit: "main", From: "interrupted", Outcome: "abort", Action: "fail", Reason: "interrupted"}},
			{Type: runstate.EvRunFinished, RunFinished: &runstate.RunFinished{Status: runstate.StatusFailed, Reason: "interrupted"}},
		}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if ws := st.Unit("main").Workspace; st.Status != runstate.StatusFailed || ws == nil || !ws.Released {
		t.Fatalf("status %s workspace %+v: the worktree this run made must be released when the run fails through the abort", st.Status, ws)
	}
}

// 終わりの手前のイベントを当てた状態を作れないとき（記録を読み直せない・イベントを当てられない）、stateBeforeEnd は黙って cur を
// 返さず、理由を添えて返す（AppendEnding が警告に出す）。返す状態は cur のままで、途中まで当てた状態にはしない。
func TestStateBeforeEndReportsWhyItFellBackToTheCurrentState(t *testing.T) {
	run, err := runstate.Create(t.TempDir(), "r1")
	if err != nil {
		t.Fatal(err)
	}
	cur, err := run.Append(
		runstate.Event{Type: runstate.EvRunStarted, RunStarted: &runstate.RunStarted{RunID: "r1", Workflow: runstate.WorkflowRecord{WorkflowRef: runstate.WorkflowRef{ID: "w"}},
			Inputs: map[string]json.RawMessage{}, Units: []string{"main"}, EntryStep: "ws"}},
		runstate.Event{Type: runstate.EvRoundStarted, RoundStarted: &runstate.RoundStarted{Unit: "main", Round: 1, Trigger: runstate.Trigger{Kind: "start"}}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if st, err := stateBeforeEnd(run, cur, nil); err != nil || st != cur {
		t.Fatalf("no events before the end: %p %v, want cur and no error", st, err)
	}
	ok := runstate.Event{Type: runstate.EvStepStarted, StepStarted: &runstate.StepStarted{Unit: "main", Step: "ws", Attempt: 1}}
	if st, err := stateBeforeEnd(run, cur, []runstate.Event{ok}); err != nil || st == cur {
		t.Fatalf("an event that applies: %v (same state %v), want a new state and no error", err, st == cur)
	}
	// 当てられないイベント（居ない unit の遷移）: 1 つ目を当てた後でも、返すのは cur
	bad := runstate.Event{Type: runstate.EvTransition, Transition: &runstate.Transition{Unit: "nobody", From: "ws", Outcome: "x", Action: "fail"}}
	if st, err := stateBeforeEnd(run, cur, []runstate.Event{ok, bad}); err == nil || st != cur {
		t.Fatalf("an event that does not apply: err %v (cur returned %v), want an error and cur", err, st == cur)
	}
	// 記録を読み直せない
	if err := os.Remove(filepath.Join(run.Dir, runstate.EventsFile)); err != nil {
		t.Fatal(err)
	}
	if st, err := stateBeforeEnd(run, cur, []runstate.Event{ok}); err == nil || st != cur {
		t.Fatalf("an unreadable record: err %v (cur returned %v), want an error and cur", err, st == cur)
	}
}

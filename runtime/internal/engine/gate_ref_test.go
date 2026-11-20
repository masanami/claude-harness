package engine

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

const refJSON = `{"outcome":"back","detail":"the head moved: now abc123"}`

func startRef(t *testing.T, json string) (string, *Engine) {
	t.Helper()
	log := filepath.Join(t.TempDir(), "log")
	st, e := start(t, "gate-ref", map[string]any{"log": log, "json": json})
	if st.Status != runstate.StatusWaiting || st.Unit(MainUnit).Gate.Gate != "review" {
		t.Fatalf("status = %s gate = %+v", st.Status, st.Unit(MainUnit).Gate)
	}
	return log, e
}

func lastRefLine(t *testing.T, log string) string {
	t.Helper()
	data, _ := os.ReadFile(log)
	l := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	return l[len(l)-1]
}

func gateOf(st *runstate.State) *runstate.Gate { return st.Unit(MainUnit).Gate }

// --approved-ref の値は、ゲートの解決の記録（gate_resolved.approved_ref）を経て $gate.approved_ref で次の段へ届く。
// --note は求めない。添えなければ空の文字列を渡す（拒否しない）。
func TestApprovedRefReachesTheNextStep(t *testing.T) {
	log, e := startRef(t, refJSON)
	st := mustResolve(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: "deadbeef"})
	if gateOf(st) == nil || gateOf(st).Gate != "review" {
		t.Fatalf("gate = %+v", gateOf(st))
	}
	if got := lastEdgeFrom(t, e, "review")["ref"]; got != `"deadbeef"` {
		t.Fatalf("edge ref = %s", got)
	}
	if l := lastRefLine(t, log); !strings.Contains(l, "--ref deadbeef") {
		t.Fatalf("the ref did not reach the step: %q", l)
	}
	var resolved *runstate.GateResolved
	for _, ev := range events(t, e) {
		if ev.GateResolved != nil {
			resolved = ev.GateResolved
		}
	}
	if resolved == nil || resolved.ApprovedRef != "deadbeef" || resolved.Note != "" {
		t.Fatalf("gate_resolved = %+v", resolved)
	}
	if g := st.Unit(MainUnit).Gates[0].Resolution; g.ApprovedRef != "deadbeef" {
		t.Fatalf("the folded resolution = %+v", g)
	}

	// 添えなければ空の文字列。
	mustResolve(t, e, Resolution{Input: "land", HasInput: true})
	if got := lastEdgeFrom(t, e, "review")["ref"]; got != `""` {
		t.Fatalf("edge ref = %s, want the empty string", got)
	}
	var last *runstate.GateResolved
	for _, ev := range events(t, e) {
		if ev.GateResolved != nil {
			last = ev.GateResolved
		}
	}
	if last.ApprovedRef != "" {
		t.Fatalf("an empty ref must be left out of the record: %+v", last)
	}
	for _, ev := range events(t, e) {
		if ev.Type == runstate.EvGateResolved && strings.Contains(string(mustJSON(t, ev)), `"approved_ref":""`) {
			t.Fatalf("an empty approved_ref was written: %+v", ev)
		}
	}
}

// $gate.approved_ref を読まない遷移へ添えても拒否せず、記録だけして使わない。
func TestApprovedRefOnATransitionThatDoesNotReadIt(t *testing.T) {
	_, e := startRef(t, refJSON)
	st := mustResolve(t, e, Resolution{Input: "respond", HasInput: true, ApprovedRef: "deadbeef"})
	if gateOf(st) == nil {
		t.Fatalf("status = %s", st.Status)
	}
	if g := st.Unit(MainUnit).Gates[0].Resolution; g.ApprovedRef != "deadbeef" {
		t.Fatalf("not recorded: %+v", g)
	}
	if edge := lastEdgeFrom(t, e, "review"); len(edge) != 0 {
		t.Fatalf("a value was passed: %v", edge)
	}
}

// 戻る遷移の detail は gate_opened.detail に入り、開き直すたびに置き換わる（書かない遷移で開けば、無い）。
func TestGateDetailIsReplacedOnReopen(t *testing.T) {
	_, e := startRef(t, refJSON)
	st := mustResolve(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: "x"})
	if g := gateOf(st); g.Detail != "the head moved: now abc123" {
		t.Fatalf("detail = %q", g.Detail)
	}
	st = mustResolve(t, e, Resolution{Input: "respond", HasInput: true})
	if g := gateOf(st); g == nil || g.Detail != "" {
		t.Fatalf("a gate opened by a transition without detail must have none: %+v", g)
	}
	st = mustResolve(t, e, Resolution{Input: "land", HasInput: true})
	if g := gateOf(st); g.Detail == "" {
		t.Fatalf("detail = %q", g.Detail)
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := jsonMarshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// 遷移の interrupted の印は、その遷移で始まるラウンドの契機（round_started.trigger.interrupted）に理由の語で残る。
// 印の無い遷移で始まるラウンドには付かない。
func TestInterruptedMarkIsRecordedInTheRoundTrigger(t *testing.T) {
	_, e := startRef(t, refJSON)
	mustResolve(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: "x"})
	mustResolve(t, e, Resolution{Input: "respond", HasInput: true})
	var marks []string
	for _, ev := range events(t, e) {
		if ev.RoundStarted != nil {
			marks = append(marks, ev.RoundStarted.Trigger.Interrupted)
		}
	}
	if strings.Join(marks, ",") != ",interrupted_after_land," {
		t.Fatalf("marks = %q", marks)
	}
}

// deadRunner は runner が居なくなったことを記録する（生きていないプロセスの PID を runner として残す）。
func deadRunner(t *testing.T, e *Engine) {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Run.Append(runstate.Event{Type: runstate.EvRunnerStarted, RunnerStarted: &runstate.RunnerStarted{PID: cmd.Process.Pid, Command: "test"}}); err != nil {
		t.Fatal(err)
	}
}

// resolveOnly はゲートの解決だけを記録する（runner は進めない。切り離した再開の同期の部分）。
func resolveOnly(t *testing.T, e *Engine, req Resolution) *runstate.State {
	t.Helper()
	st, _, err := e.Run.Load()
	if err != nil {
		t.Fatal(err)
	}
	e2, err := Reopen(e.Run, st)
	if err != nil {
		t.Fatal(err)
	}
	req.Actor, req.Channel = "resume", "non-tty"
	st, err = e2.ResolveGate(t.Context(), req)
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func hasType(evs []runstate.Event, typ string) bool {
	for _, ev := range evs {
		if ev.Type == typ {
			return true
		}
	}
	return false
}

// 印のあるラウンドで runner が落ちた（段の間）: interrupted ゲートを開かず、失敗への遷移と run_finished（failed・印の理由）を記録する。
func TestMarkedRoundFailsInsteadOfTheInterruptedGateBetweenSteps(t *testing.T) {
	_, e := startRef(t, refJSON)
	resolveOnly(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: "x"})
	deadRunner(t, e)
	st, err := Interrupt(e.Run)
	if err != nil {
		t.Fatal(err)
	}
	if st.Status != runstate.StatusFailed || st.Reason != "interrupted_after_land" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	if u := st.Unit(MainUnit); u.Gate != nil || len(u.Gates) != 1 {
		t.Fatalf("the interrupted gate was opened: %+v", u.Gates)
	}
	// 終わった後の status・resume は何も足さず、終わりの状態を返す（2 度入れない）。
	n := len(events(t, e))
	if _, err := Interrupt(e.Run); err != nil || len(events(t, e)) != n {
		t.Fatalf("a second cleanup recorded events (err %v)", err)
	}
	_, err = resolve(t, e, Resolution{Input: "land", HasInput: true})
	var ref *RefusedError
	if !errorsAs(err, &ref) || !strings.Contains(err.Error(), "already ended as failed") {
		t.Fatalf("err = %v", err)
	}
}

// 印のあるラウンドで、実行中の段のある runner が落ちた: 段を打ち切り（step_finished の interrupted）、同じく失敗で終える。
func TestMarkedRoundFailsInsteadOfTheInterruptedGateDuringAStep(t *testing.T) {
	_, e := startRef(t, refJSON)
	resolveOnly(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: "x"})
	if _, err := e.Run.Append(runstate.Event{Type: runstate.EvStepStarted, StepStarted: &runstate.StepStarted{Unit: MainUnit, Step: "land", Attempt: 1}}); err != nil {
		t.Fatal(err)
	}
	deadRunner(t, e)
	st, err := Interrupt(e.Run)
	if err != nil {
		t.Fatal(err)
	}
	if st.Status != runstate.StatusFailed || st.Reason != "interrupted_after_land" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	u := st.Unit(MainUnit)
	if x := u.Rounds[len(u.Rounds)-1].Steps[0]; x.Step != "land" || x.Status != "interrupted" {
		t.Fatalf("the step = %+v", x)
	}
	if u.Gate != nil || len(u.Gates) != 1 {
		t.Fatalf("the interrupted gate was opened: %+v", u.Gates)
	}
}

// 印の無いラウンドの動きは変わらない: interrupted ゲートで待つ。
func TestUnmarkedRoundStillWaitsAtTheInterruptedGate(t *testing.T) {
	_, e := startRef(t, refJSON)
	resolveOnly(t, e, Resolution{Input: "respond", HasInput: true})
	deadRunner(t, e)
	st, err := Interrupt(e.Run)
	if err != nil {
		t.Fatal(err)
	}
	if g := gateOf(st); st.Status != runstate.StatusWaiting || g == nil || g.Gate != "interrupted" || !g.Builtin {
		t.Fatalf("status = %s gate = %+v", st.Status, g)
	}
}

// rerun でやり直したラウンドには印が付かない。
func TestRerunRoundHasNoMark(t *testing.T) {
	_, e := startRef(t, refJSON)
	resolveOnly(t, e, Resolution{Input: "respond", HasInput: true})
	deadRunner(t, e)
	if _, err := Interrupt(e.Run); err != nil {
		t.Fatal(err)
	}
	mustResolve(t, e, Resolution{Input: InterruptedRerun, HasInput: true})
	for _, ev := range events(t, e) {
		if ev.RoundStarted != nil && ev.RoundStarted.Trigger.Gate == "interrupted" && ev.RoundStarted.Trigger.Interrupted != "" {
			t.Fatalf("a rerun round has a mark: %+v", ev.RoundStarted)
		}
	}
}

// runner を起動できなかった呼び出し元が自分で諦める口: 印のあるラウンドだけ失敗で終え、印の無いラウンドは何も記録しない。
func TestAbandonMarked(t *testing.T) {
	_, e := startRef(t, refJSON)
	resolveOnly(t, e, Resolution{Input: "respond", HasInput: true})
	n := len(events(t, e))
	st, err := AbandonMarked(e.Run)
	if err != nil || st.Status != runstate.StatusRunning || len(events(t, e)) != n {
		t.Fatalf("an unmarked round changed: %v %s", err, st.Status)
	}

	_, e = startRef(t, refJSON)
	resolveOnly(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: "x"})
	st, err = AbandonMarked(e.Run)
	if err != nil {
		t.Fatal(err)
	}
	if st.Status != runstate.StatusFailed || st.Reason != "interrupted_after_land" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	if hasType(events(t, e), runstate.EvGateOpened) && gateOf(st) != nil {
		t.Fatalf("a gate is open: %+v", gateOf(st))
	}
}

// 別のプロセスが runner として生きているときは、諦めない（自分が記録上の runner のときだけ）。
func TestAbandonMarkedLeavesAnotherLiveRunner(t *testing.T) {
	_, e := startRef(t, refJSON)
	resolveOnly(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: "x"})
	if _, err := e.Run.Append(runstate.Event{Type: runstate.EvRunnerStarted, RunnerStarted: &runstate.RunnerStarted{PID: os.Getppid(), Command: "test"}}); err != nil {
		t.Fatal(err)
	}
	st, err := AbandonMarked(e.Run)
	if err != nil || st.Status != runstate.StatusRunning {
		t.Fatalf("status = %s err %v", st.Status, err)
	}
}

var (
	jsonMarshal = json.Marshal
	errorsAs    = errors.As
)

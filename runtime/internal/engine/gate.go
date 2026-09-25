package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// Observer は observe 型ゲート（§3.2）の観測。resume のたびに外部の実状態を確かめ、その結果を outcome として返す
// （人の申告を信じない）。with はゲートの with を解決した値。
type Observer func(ctx context.Context, with map[string]json.RawMessage) (outcome string, observed json.RawMessage, err error)

var observers = map[string]Observer{}

// RegisterObserver は観測を登録する。outcomes は観測が返しうる値（読み込み時に on の網羅を検査する）。
// PR の実状態を見る観測（pr-state）は pull-request 種類と一緒に PR-4 で登録する。
func RegisterObserver(name string, outcomes []string, fn Observer) {
	workflow.RegisterObservation(name, outcomes)
	observers[name] = fn
}

// 組み込みの interrupted ゲート（§4.5）が受け付ける値。
const (
	InterruptedRerun = "rerun"
	InterruptedAbort = "abort"
)

func gateOpenedEvent(unit string, g *workflow.Step) runstate.Event {
	return runstate.Event{Type: runstate.EvGateOpened, GateOpened: &runstate.GateOpened{
		Unit: unit, Gate: g.ID, Type: g.GateType, Decider: g.Decider, RequestedAction: g.RequestedAction,
		Inputs: g.GateInputs, Observe: g.Observe, RequiresTTY: workflow.RequiresTTY(g.GateType, g.Decider),
	}}
}

// InterruptEvents は、runner が生きていない run で running のまま残り、子プロセスも居ないステップ実行を
// interrupted として打ち切り、その unit を組み込みの interrupted ゲートへ送るイベントを作る（§4.5）。
// 自動で再実行はしない（LLM ステップは部分的な変更を残しうるため冪等ではない）。
// 子プロセスのグループがまだ生きている実行は対象にしない（呼び出し元が止めてから呼ぶ）。
func InterruptEvents(st *runstate.State) []runstate.Event {
	if runstate.Terminal(st.Status) || runstate.Alive(st.PID) {
		return nil
	}
	var evs []runstate.Event
	for _, u := range st.Units {
		x := u.Running()
		if x == nil || (x.PID > 0 && groupAlive(x.PID)) {
			continue
		}
		fin := &runstate.StepFinished{Unit: u.Key, Step: x.Step, Attempt: x.Attempt, Interrupted: true,
			Error: fmt.Sprintf("the runner (pid %d) is not alive and the step's process is gone; the step did not finish", st.PID)}
		chargeUnknown(fin, x.BudgetGrantedUSD)
		evs = append(evs,
			runstate.Event{Type: runstate.EvStepFinished, StepFinished: fin},
			runstate.Event{Type: runstate.EvGateOpened, GateOpened: &runstate.GateOpened{
				Unit: u.Key, Gate: workflow.InterruptedGate, Type: workflow.GateInput, Decider: workflow.DeciderAny,
				RequestedAction: fmt.Sprintf("step %s (attempt %d) was interrupted because the runner died; it is not re-run automatically "+
					"(an llm step may have left partial changes). Check the working tree, then resume with %s to run the step again or %s to fail the run",
					x.Step, x.Attempt, InterruptedRerun, InterruptedAbort),
				Inputs:  []string{InterruptedRerun, InterruptedAbort},
				Builtin: true,
			}},
		)
	}
	return evs
}

// Interrupt は InterruptEvents をロックの中で確かめ直して記録する（status / resume が呼ぶ）。
func Interrupt(run *runstate.Run) (*runstate.State, error) {
	return run.AppendIf(func(st *runstate.State) ([]runstate.Event, error) {
		return InterruptEvents(st), nil
	})
}

// StopOrphans は、runner が生きていない run で running のまま残ったステップ実行の子プロセスを止める
// （resume が interrupted へ送る前に行う。記録されない結果を出し続けるプロセスを残さない）。
func StopOrphans(st *runstate.State, grace time.Duration) {
	if runstate.Terminal(st.Status) || runstate.Alive(st.PID) {
		return
	}
	for _, u := range st.Units {
		if x := u.Running(); x != nil && x.PID > 0 {
			StopOrphan(x.PID, grace)
		}
	}
}

// Reopen は run を記録した定義で開き直す。定義が開始時から変わっていれば止める（§7.3: 途中で遷移表が変わった run を
// 黙って続けない）。
func Reopen(run *runstate.Run, st *runstate.State) (*Engine, error) {
	wf, err := workflow.LoadAndValidate(st.Workflow.Path, workflow.Options{ScriptsDir: st.ScriptsDir})
	if err != nil {
		return nil, fmt.Errorf("cannot load the workflow the run started with (%s): %v", st.Workflow.Path, err)
	}
	if wf.Hash != st.Workflow.Hash {
		return nil, fmt.Errorf("workflow %s changed since the run started (sha256 %s, now %s); the run is not continued with a different definition",
			st.Workflow.Path, st.Workflow.Hash, wf.Hash)
	}
	return &Engine{WF: wf, Run: run, ScriptsDir: st.ScriptsDir, Cwd: st.Cwd}, nil
}

// Resolution はゲートの解決の要求（resume / approve）。
type Resolution struct {
	Unit     string // 空なら唯一の unit
	Input    string
	HasInput bool
	Note     string
	HasNote  bool
	Actor    string // resume | approve
	User     string
	Channel  string // tty | non-tty
}

// RefusedError は要求をこの経路では受け付けられないこと（状態は何も変えていない）。
type RefusedError struct{ Msg string }

func (e *RefusedError) Error() string { return e.Msg }

func refused(format string, args ...any) error {
	return &RefusedError{Msg: fmt.Sprintf(format, args...)}
}

// WaitingGate は unit が待っているゲートの定義（組み込みの interrupted は nil）。
func (e *Engine) WaitingGate(u *runstate.Unit) *workflow.Step {
	if u.Gate == nil || u.Gate.Builtin {
		return nil
	}
	return e.WF.Step(u.Gate.Gate)
}

// PickUnit は要求の unit を決める（指定が無ければ唯一の unit）。
func PickUnit(st *runstate.State, key string) (*runstate.Unit, error) {
	if key == "" {
		if len(st.Units) != 1 {
			return nil, refused("the run has %d units; give --unit", len(st.Units))
		}
		return st.Units[0], nil
	}
	u := st.Unit(key)
	if u == nil {
		return nil, refused("unit %q is not in run %s", key, st.RunID)
	}
	return u, nil
}

// CheckResolution は、要求がゲートを解決できるかを状態を変えずに確かめる（approve が確認を求める前に使う）。
func (e *Engine) CheckResolution(st *runstate.State, req Resolution) (*runstate.Unit, error) {
	if runstate.Terminal(st.Status) {
		return nil, refused("run %s already ended as %s", st.RunID, st.Status)
	}
	u, err := PickUnit(st, req.Unit)
	if err != nil {
		return nil, err
	}
	g := u.Gate
	if g == nil {
		if req.HasInput || req.Actor == "approve" {
			return nil, refused("unit %s is %s, not waiting at a gate", u.Key, u.Status)
		}
		return u, nil
	}
	if g.Type == workflow.GateObserve {
		if req.Actor == "approve" {
			return nil, refused("gate %s is an observe gate: the runtime checks the external state itself; use harness resume", g.Gate)
		}
		if req.HasInput || req.HasNote {
			return nil, refused("gate %s is an observe gate: it takes no --input or --note (the outcome is observed, not declared)", g.Gate)
		}
		return u, nil
	}
	if g.RequiresTTY {
		if req.Actor != "approve" {
			return nil, refused("gate %s is decided by a human (decider: human, type: input); resume cannot resolve it. "+
				"A person resolves it from a terminal: harness approve %s --unit %s --input <%s>", g.Gate, st.RunID, u.Key, strings.Join(g.Inputs, "|"))
		}
		if req.Channel != "tty" {
			return nil, refused("gate %s must be approved from a terminal (TTY); approve refuses to run without one", g.Gate)
		}
	}
	if !req.HasInput {
		return nil, refused("gate %s waits for an input: give --input <%s>", g.Gate, strings.Join(g.Inputs, "|"))
	}
	if !contains(g.Inputs, req.Input) {
		return nil, refused("gate %s does not accept %q (accepted: %s)", g.Gate, req.Input, strings.Join(g.Inputs, ", "))
	}
	if step := e.WaitingGate(u); step != nil && !req.HasNote {
		if t := step.OnFor(req.Input); t != nil && readsNote(t) {
			return nil, refused("input %s passes $gate.note to the next step; give --note", req.Input)
		}
	}
	return u, nil
}

func readsNote(t *workflow.Transition) bool {
	for _, b := range t.With {
		if b.Value.Ref != nil && b.Value.Ref.Kind == workflow.RefGate {
			return true
		}
	}
	return t.Exhausted != nil && readsNote(t.Exhausted)
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

// Resolve はゲートを解決して次のラウンドへ進め、run がゲートか終端に達するまで進める（§5.1）。
// 閉じたラウンドのステップ実行は再実行しない: 解決したゲートの遷移先から始める（§4.2）。
// unit がゲートで待っていない（runner が落ちた run）なら、runner を引き継いで現在のステップから進める。
func (e *Engine) Resolve(ctx context.Context, req Resolution) (*runstate.State, error) {
	st, _, err := e.Run.Load()
	if err != nil {
		return nil, err
	}
	u, err := e.CheckResolution(st, req)
	if err != nil {
		return nil, err
	}
	// observe 型は解決の前に外部の実状態を確かめる（ロックの外で。観測は時間がかかりうる）。
	var observed json.RawMessage
	var observedOutcome string
	if u.Gate != nil && u.Gate.Type == workflow.GateObserve {
		step := e.WaitingGate(u)
		if step == nil {
			return nil, fmt.Errorf("gate %s is not in workflow %s", u.Gate.Gate, e.WF.ID)
		}
		observedOutcome, observed, err = e.observe(ctx, st, u, step)
		if err != nil {
			return nil, refused("gate %s: observation %s failed; the gate stays open: %v", step.ID, step.Observe, err)
		}
	}
	gateAt := ""
	if u.Gate != nil {
		gateAt = u.Gate.Gate
	}
	_, err = e.Run.AppendIf(func(cur *runstate.State) ([]runstate.Event, error) {
		cu := cur.Unit(u.Key)
		if runstate.Terminal(cur.Status) {
			return nil, refused("run %s already ended as %s", cur.RunID, cur.Status)
		}
		if (cu.Gate == nil && gateAt != "") || (cu.Gate != nil && cu.Gate.Gate != gateAt) {
			return nil, refused("unit %s changed while resolving (another resume?); nothing was recorded", u.Key)
		}
		// ゲートで待っている run には runner が居ない（run は待機で終わる）。runner が居るのは running の run だけ。
		if cur.Status == runstate.StatusRunning && runstate.Alive(cur.PID) && cur.PID != os.Getpid() {
			return nil, refused("run %s is being advanced by pid %d; nothing to resume", cur.RunID, cur.PID)
		}
		if cu.Gate == nil && cu.Running() != nil {
			return nil, refused("unit %s has a running step whose process is still alive; cancel the run or wait", u.Key)
		}
		evs := []runstate.Event{{Type: runstate.EvRunnerStarted, RunnerStarted: &runstate.RunnerStarted{PID: os.Getpid(), Command: req.Actor}}}
		if cu.Gate == nil {
			return evs, nil
		}
		outcome := req.Input
		if cu.Gate.Type == workflow.GateObserve {
			outcome = observedOutcome
		}
		res := &runstate.GateResolved{Unit: u.Key, Gate: cu.Gate.Gate, Outcome: outcome, Observed: observed,
			Actor: req.Actor, User: req.User, Channel: req.Channel}
		if req.HasNote {
			res.Note = req.Note
		}
		evs = append(evs, runstate.Event{Type: runstate.EvGateResolved, GateResolved: res})
		next, err := e.afterGate(cur, cu, outcome, req)
		if err != nil {
			return nil, err
		}
		return append(evs, next...), nil
	})
	if err != nil {
		return nil, err
	}
	return e.Loop(ctx)
}

// afterGate はゲートを抜けた後のイベント（遷移と、新しいラウンドの開始／次のゲート／終端）を作る。
func (e *Engine) afterGate(st *runstate.State, u *runstate.Unit, outcome string, req Resolution) ([]runstate.Event, error) {
	trigger := runstate.Trigger{Kind: "gate", Gate: u.Gate.Gate, Input: outcome}
	round := runstate.Event{Type: runstate.EvRoundStarted, RoundStarted: &runstate.RoundStarted{Unit: u.Key, Round: len(u.Rounds) + 1, Trigger: trigger}}
	if u.Gate.Builtin {
		switch outcome {
		case InterruptedRerun:
			// 打ち切ったステップを新しいラウンドでやり直す（遷移で渡された $edge の値はそのまま持ち越す）。
			return []runstate.Event{round}, nil
		case InterruptedAbort:
			return []runstate.Event{
				{Type: runstate.EvTransition, Transition: &runstate.Transition{Unit: u.Key, From: u.CurrentStep, Outcome: InterruptedAbort, Action: "fail", Reason: "interrupted"}},
				{Type: runstate.EvRunFinished, RunFinished: &runstate.RunFinished{Status: runstate.StatusFailed, Reason: "interrupted"}},
			}, nil
		}
		return nil, refused("the interrupted gate accepts %s or %s", InterruptedRerun, InterruptedAbort)
	}
	step := e.WaitingGate(u)
	if step == nil {
		return nil, fmt.Errorf("gate %s is not in workflow %s", u.Gate.Gate, e.WF.ID)
	}
	cur := succeeded(u)
	cur.outcomes[step.ID] = outcome
	if req.HasNote {
		note := req.Note
		cur.note = &note
	}
	evs, err := e.transitionEvents(st, u, step, outcome, false, cur)
	if err != nil {
		return nil, err
	}
	if tr := evs[0].Transition; tr.Action == "step" {
		evs = append(evs, round)
	}
	return evs, nil
}

func (e *Engine) observe(ctx context.Context, st *runstate.State, u *runstate.Unit, step *workflow.Step) (string, json.RawMessage, error) {
	fn := observers[step.Observe]
	if fn == nil {
		return "", nil, errors.New("the observation is not registered in this build")
	}
	with := map[string]json.RawMessage{}
	for _, b := range step.With {
		v, err := value(st, succeeded(u), nil, b.Value)
		if err != nil {
			return "", nil, err
		}
		with[b.Name] = v
	}
	outcome, observed, err := fn(ctx, with)
	if err != nil {
		return "", nil, err
	}
	if !contains(step.Outcomes(), outcome) {
		return "", nil, fmt.Errorf("the observation returned %q, which is not one of its outcomes (%s)", outcome, strings.Join(step.Outcomes(), ", "))
	}
	return outcome, observed, nil
}

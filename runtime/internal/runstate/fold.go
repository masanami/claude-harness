package runstate

import (
	"encoding/json"
	"fmt"
)

// Run の汎用状態（§4.1）。waiting はすべての unit がゲートか終端にあり、少なくとも 1 つがゲートで待っている状態。
const (
	StatusRunning   = "running"
	StatusWaiting   = "waiting"
	StatusSucceeded = "succeeded"
	StatusFailed    = "failed"
	StatusCancelled = "cancelled"
)

// Terminal は終端の状態かを返す。
func Terminal(status string) bool {
	return status == StatusSucceeded || status == StatusFailed || status == StatusCancelled
}

// State は events.jsonl を畳み込んだ run の状態。state.json と status --json の中身。
type State struct {
	RunID       string                     `json:"run_id"`
	Workflow    WorkflowRef                `json:"workflow"`
	Inputs      map[string]json.RawMessage `json:"inputs"`
	Limits      map[string]float64         `json:"limits,omitempty"`
	Status      string                     `json:"status"`
	Reason      string                     `json:"reason,omitempty"`
	CreatedAt   string                     `json:"created_at"`
	UpdatedAt   string                     `json:"updated_at"`
	Origin      string                     `json:"origin"`
	Cwd         string                     `json:"cwd"`
	PID         int                        `json:"pid"`
	ScriptsDir  string                     `json:"scripts_dir"`
	WorkflowDir string                     `json:"workflow_dir"`
	LastSeq     int                        `json:"last_seq"`
	Cancel      *CancelRequested           `json:"cancel_requested,omitempty"`
	Cancelled   *RunCancelled              `json:"cancelled,omitempty"`
	Units       []*Unit                    `json:"units"`
}

// Unit は run の 1 単位（fan-out の 1 項目。単独のワークフローでは 1 つ）。
type Unit struct {
	Key         string `json:"key"`
	Status      string `json:"status"`
	Reason      string `json:"reason,omitempty"`
	CurrentStep string `json:"current_step,omitempty"`
	// LimitsUsed は limit ごとに数えた遷移の回数（unit 単位でラウンドをまたいで累計。§3.1・§4.2）。
	LimitsUsed map[string]int `json:"limits_used,omitempty"`
	// Outputs はステップごとの最後に成功した実行の出力（$steps 参照の解決元）。
	Outputs map[string]json.RawMessage `json:"outputs,omitempty"`
	// Outcomes はステップごとの最後に成功した実行の outcome（$steps.<id>.outcome の解決元。exit 表のステップは出力を持たない）。
	Outcomes map[string]string `json:"outcomes,omitempty"`
	// Edge は CurrentStep へ入った遷移が with で渡した値（$edge 参照の解決元）。
	Edge map[string]json.RawMessage `json:"edge,omitempty"`
	// Budget は unit の累計予算（§4.3）。ワークフローが limits.budget_usd を持つときだけ。
	Budget *Budget `json:"budget,omitempty"`
	// Gate はいま待っているゲート（無ければ nil）。Gates は開いたゲートの履歴（解決を含む）。
	Gate   *Gate    `json:"gate,omitempty"`
	Gates  []*Gate  `json:"gates,omitempty"`
	Rounds []*Round `json:"rounds"`
}

// Budget は unit の累計（§4.1）。SpentUSD には費用が得られなかった実行の上限額も含む（fail-closed）。
type Budget struct {
	LimitUSD         float64 `json:"limit_usd"`
	SpentUSD         float64 `json:"spent_usd"`
	RemainingUSD     float64 `json:"remaining_usd"`
	UnknownCostCount int     `json:"unknown_cost_count"`
}

// Gate は unit が止まったゲート（§4.1）。Resolution は解決したときに入る。
type Gate struct {
	GateOpened
	OpenedAt   string          `json:"opened_at"`
	Round      int             `json:"round"`
	Resolution *GateResolution `json:"resolution,omitempty"`
}

// GateResolution はゲートの解決の記録（§5.3: actor・channel を必ず残す）。
type GateResolution struct {
	Outcome  string          `json:"outcome"`
	Note     string          `json:"note,omitempty"`
	Observed json.RawMessage `json:"observed,omitempty"`
	Actor    string          `json:"actor"`
	User     string          `json:"user,omitempty"`
	Channel  string          `json:"channel"`
	At       string          `json:"at"`
}

// Round はゲートとゲートの間（§4.2）。
type Round struct {
	No        int              `json:"no"`
	Trigger   Trigger          `json:"trigger"`
	StartedAt string           `json:"started_at"`
	EndedBy   string           `json:"ended_by,omitempty"` // 終端の理由、または止まったゲート（gate:<id>）
	CostUSD   float64          `json:"cost_usd,omitempty"` // このラウンドで累計へ加えた額
	Retries   map[string]int   `json:"retries,omitempty"`  // ステップごとに使った retry（ラウンド単位で数える。§3.1）
	Steps     []*StepExecution `json:"steps"`
}

// StepExecution はステップの 1 回の実行（§4.1）。
type StepExecution struct {
	Step       string          `json:"step"`
	Attempt    int             `json:"attempt"`
	Status     string          `json:"status"` // running | finished | cancelled | interrupted
	StartedAt  string          `json:"started_at"`
	FinishedAt string          `json:"finished_at,omitempty"`
	PID        int             `json:"pid,omitempty"`
	Argv       []string        `json:"argv,omitempty"`
	StdoutLog  string          `json:"stdout_log,omitempty"`
	StderrLog  string          `json:"stderr_log,omitempty"`
	Outcome    string          `json:"outcome,omitempty"`
	Reserved   bool            `json:"reserved,omitempty"`
	Output     json.RawMessage `json:"output,omitempty"`
	ExitCode   *int            `json:"exit_code,omitempty"`
	Error      string          `json:"error,omitempty"`

	// llm 種類（§4.1 StepExecution の session_id・cost_usd）
	SessionID         string   `json:"session_id,omitempty"`
	Resume            bool     `json:"resume,omitempty"`
	BudgetGrantedUSD  *float64 `json:"budget_granted_usd,omitempty"`
	PromptLog         string   `json:"prompt_log,omitempty"`
	CostUSD           *float64 `json:"cost_usd,omitempty"`
	CostUnknown       bool     `json:"cost_unknown,omitempty"`
	CostReportedUSD   *float64 `json:"cost_reported_usd,omitempty"`
	ReportedSessionID string   `json:"reported_session_id,omitempty"`
}

// Unit は key で unit を引く。
func (s *State) Unit(key string) *Unit {
	for _, u := range s.Units {
		if u.Key == key {
			return u
		}
	}
	return nil
}

// CurrentRound は unit の最新のラウンド。
func (u *Unit) CurrentRound() *Round {
	if len(u.Rounds) == 0 {
		return nil
	}
	return u.Rounds[len(u.Rounds)-1]
}

// Running は実行中のステップ実行（無ければ nil）。
func (u *Unit) Running() *StepExecution {
	r := u.CurrentRound()
	if r == nil || len(r.Steps) == 0 {
		return nil
	}
	last := r.Steps[len(r.Steps)-1]
	if last.Status == "running" {
		return last
	}
	return nil
}

// LastSession は unit の中で step の**最新の**実行が使った Claude の session_id（claude が報告した値を優先）を返す
// （session: continue の引き継ぎ元。§4.4）。最新の実行が claude を起動していなければ（予算切れ等）空を返し、
// それより前のラウンドのセッションへは戻らない（古い文脈で黙って続けない）。起動したとみなすのは、
// 子プロセスの PID が記録されているか、claude が session_id を報告した実行だけ。
func (u *Unit) LastSession(step string) string {
	for i := len(u.Rounds) - 1; i >= 0; i-- {
		r := u.Rounds[i]
		for j := len(r.Steps) - 1; j >= 0; j-- {
			x := r.Steps[j]
			if x.Step != step {
				continue
			}
			if x.ReportedSessionID != "" {
				return x.ReportedSessionID
			}
			if x.PID != 0 {
				return x.SessionID
			}
			return ""
		}
	}
	return ""
}

// SessionReportedCost は、session_id のセッションについて最後に報告された累計費用を返す（無ければ nil）。
// --resume した実行の claude はセッションの累計を報告するため、その実行の費用は前回の報告との差になる。
func (u *Unit) SessionReportedCost(session string) *float64 {
	for i := len(u.Rounds) - 1; i >= 0; i-- {
		r := u.Rounds[i]
		for j := len(r.Steps) - 1; j >= 0; j-- {
			x := r.Steps[j]
			sid := x.ReportedSessionID
			if sid == "" {
				sid = x.SessionID
			}
			if sid == session && x.CostReportedUSD != nil {
				return x.CostReportedUSD
			}
		}
	}
	return nil
}

// Attempts は unit の中で step が実行された回数。
func (u *Unit) Attempts(step string) int {
	n := 0
	for _, r := range u.Rounds {
		for _, x := range r.Steps {
			if x.Step == step {
				n++
			}
		}
	}
	return n
}

// Fold はイベント列を畳み込んで状態を作る。列の整合（seq の連番・最初が run_started・種類とペイロードの一致）が
// 崩れていればエラー。
func Fold(events []Event) (*State, error) {
	var s *State
	for i := range events {
		next, err := Apply(s, &events[i])
		if err != nil {
			return nil, err
		}
		s = next
	}
	if s == nil {
		return nil, fmt.Errorf("no events")
	}
	return s, nil
}

// Apply は 1 イベントを状態へ適用する。s が nil のときは run_started だけを受け付ける。
func Apply(s *State, ev *Event) (*State, error) {
	if err := checkPayload(ev); err != nil {
		return nil, err
	}
	if s == nil {
		if ev.Type != EvRunStarted || ev.Seq != 1 {
			return nil, fmt.Errorf("event log must start with run_started at seq 1 (got %s at seq %d)", ev.Type, ev.Seq)
		}
		p := ev.RunStarted
		s = &State{
			RunID: p.RunID, Workflow: p.Workflow, Inputs: p.Inputs, Limits: p.Limits,
			Status: StatusRunning, CreatedAt: ev.TS, Origin: p.Origin, Cwd: p.Cwd, PID: p.PID,
			ScriptsDir: p.ScriptsDir, WorkflowDir: p.WorkflowDir, Units: []*Unit{},
		}
		for _, k := range p.Units {
			u := &Unit{Key: k, Status: StatusRunning, CurrentStep: p.EntryStep, Rounds: []*Round{}}
			if l, ok := p.Limits[BudgetLimitName]; ok {
				u.Budget = &Budget{LimitUSD: l, RemainingUSD: l}
			}
			s.Units = append(s.Units, u)
		}
		s.LastSeq, s.UpdatedAt = ev.Seq, ev.TS
		return s, nil
	}
	if ev.Seq != s.LastSeq+1 {
		return nil, fmt.Errorf("event seq %d does not follow %d", ev.Seq, s.LastSeq)
	}
	if Terminal(s.Status) {
		return nil, fmt.Errorf("event %s (seq %d) after the run ended as %s", ev.Type, ev.Seq, s.Status)
	}
	unit := func(key string) (*Unit, error) {
		if u := s.Unit(key); u != nil {
			return u, nil
		}
		return nil, fmt.Errorf("event %s (seq %d) refers to unknown unit %q", ev.Type, ev.Seq, key)
	}
	switch ev.Type {
	case EvRunStarted:
		return nil, fmt.Errorf("run_started appears again at seq %d", ev.Seq)
	case EvRoundStarted:
		p := ev.RoundStarted
		u, err := unit(p.Unit)
		if err != nil {
			return nil, err
		}
		if p.Round != len(u.Rounds)+1 {
			return nil, fmt.Errorf("round %d does not follow round %d", p.Round, len(u.Rounds))
		}
		if u.Gate != nil || u.Status != StatusRunning {
			return nil, fmt.Errorf("round_started (seq %d) while unit %q is %s", ev.Seq, u.Key, u.Status)
		}
		u.Rounds = append(u.Rounds, &Round{No: p.Round, Trigger: p.Trigger, StartedAt: ev.TS, Steps: []*StepExecution{}})
	case EvStepStarted:
		p := ev.StepStarted
		u, err := unit(p.Unit)
		if err != nil {
			return nil, err
		}
		r := u.CurrentRound()
		if r == nil {
			return nil, fmt.Errorf("step_started (seq %d) before any round", ev.Seq)
		}
		if u.Running() != nil {
			return nil, fmt.Errorf("step_started (seq %d) while another step is running", ev.Seq)
		}
		if p.Step != u.CurrentStep {
			return nil, fmt.Errorf("step_started for %q (seq %d) but the current step is %q", p.Step, ev.Seq, u.CurrentStep)
		}
		if u.Status != StatusRunning {
			return nil, fmt.Errorf("step_started (seq %d) while unit %q is %s", ev.Seq, u.Key, u.Status)
		}
		r.Steps = append(r.Steps, &StepExecution{
			Step: p.Step, Attempt: p.Attempt, Status: "running", StartedAt: ev.TS,
			PID: p.PID, Argv: p.Argv, StdoutLog: p.StdoutLog, StderrLog: p.StderrLog,
			SessionID: p.SessionID, Resume: p.Resume, BudgetGrantedUSD: p.BudgetGrantedUSD, PromptLog: p.PromptLog,
		})
	case EvStepProcess:
		p := ev.StepProcess
		u, err := unit(p.Unit)
		if err != nil {
			return nil, err
		}
		x := u.Running()
		if x == nil || x.Step != p.Step || x.Attempt != p.Attempt || x.PID != 0 {
			return nil, fmt.Errorf("step_process for %s#%d (seq %d) does not match a running step without a process", p.Step, p.Attempt, ev.Seq)
		}
		x.PID = p.PID
	case EvStepFinished:
		p := ev.StepFinished
		u, err := unit(p.Unit)
		if err != nil {
			return nil, err
		}
		x := u.Running()
		if x == nil || x.Step != p.Step || x.Attempt != p.Attempt {
			return nil, fmt.Errorf("step_finished for %s#%d (seq %d) does not match a running step", p.Step, p.Attempt, ev.Seq)
		}
		x.FinishedAt, x.Outcome, x.Reserved, x.Output, x.ExitCode, x.Error = ev.TS, p.Outcome, p.Reserved, p.Output, p.ExitCode, p.Error
		x.CostUSD, x.CostUnknown, x.CostReportedUSD, x.ReportedSessionID = p.CostUSD, p.CostUnknown, p.CostReportedUSD, p.SessionID
		x.Status = "finished"
		if p.Cancelled && p.Interrupted {
			return nil, fmt.Errorf("step_finished (seq %d) is both cancelled and interrupted", ev.Seq)
		}
		if p.Cancelled {
			x.Status = "cancelled"
		}
		if p.Interrupted {
			x.Status = "interrupted"
		}
		if p.CostUSD != nil {
			if *p.CostUSD < 0 {
				return nil, fmt.Errorf("step_finished (seq %d) has a negative cost", ev.Seq)
			}
			if u.Budget == nil {
				return nil, fmt.Errorf("step_finished (seq %d) has a cost but the unit has no budget", ev.Seq)
			}
			u.Budget.SpentUSD += *p.CostUSD
			u.Budget.RemainingUSD = u.Budget.LimitUSD - u.Budget.SpentUSD
			u.CurrentRound().CostUSD += *p.CostUSD
		}
		if p.CostUnknown {
			if u.Budget == nil {
				return nil, fmt.Errorf("step_finished (seq %d) has an unknown cost but the unit has no budget", ev.Seq)
			}
			u.Budget.UnknownCostCount++
		}
		if !p.Cancelled && !p.Interrupted && !p.Reserved {
			if u.Outcomes == nil {
				u.Outcomes = map[string]string{}
			}
			u.Outcomes[p.Step] = p.Outcome
			if p.Output != nil {
				if u.Outputs == nil {
					u.Outputs = map[string]json.RawMessage{}
				}
				u.Outputs[p.Step] = p.Output
			}
		}
	case EvTransition:
		p := ev.Transition
		u, err := unit(p.Unit)
		if err != nil {
			return nil, err
		}
		if u.Running() != nil || u.CurrentStep != p.From {
			return nil, fmt.Errorf("transition from %q (seq %d) but the unit is at %q", p.From, ev.Seq, u.CurrentStep)
		}
		if u.Status != StatusRunning {
			return nil, fmt.Errorf("transition (seq %d) while unit %q is %s", ev.Seq, u.Key, u.Status)
		}
		r := u.CurrentRound()
		if p.Limit != "" {
			if u.LimitsUsed == nil {
				u.LimitsUsed = map[string]int{}
			}
			u.LimitsUsed[p.Limit]++
		}
		if p.Retry {
			if r.Retries == nil {
				r.Retries = map[string]int{}
			}
			r.Retries[p.From]++
		}
		switch p.Action {
		case "step":
			if !(p.Retry && p.To == p.From) {
				// retry は同じ入力で再実行するので、渡された値を持ち越す。
				u.Edge = p.Edge
			}
			u.CurrentStep = p.To
		case "gate":
			// ゲートへ入る遷移は値を運ばない（ゲートから出る遷移が新しいラウンドの値を渡す）。
			u.Edge = nil
			u.CurrentStep = p.To
		case "fail", "done":
			u.Status = map[string]string{"fail": StatusFailed, "done": StatusSucceeded}[p.Action]
			u.Reason = p.Reason
			u.Edge = nil
			if r.EndedBy == "" { // ゲートを解決して終端へ送った場合、ラウンドはゲートで閉じている
				r.EndedBy = p.Reason
			}
		default:
			return nil, fmt.Errorf("transition action %q (seq %d) is unknown", p.Action, ev.Seq)
		}
	case EvRunFinished:
		p := ev.RunFinished
		if p.Status != StatusSucceeded && p.Status != StatusFailed {
			return nil, fmt.Errorf("run_finished with status %q (seq %d)", p.Status, ev.Seq)
		}
		for _, u := range s.Units {
			if !Terminal(u.Status) {
				return nil, fmt.Errorf("run_finished (seq %d) while unit %q is %s", ev.Seq, u.Key, u.Status)
			}
		}
		s.Status, s.Reason = p.Status, p.Reason
	case EvGateOpened:
		p := ev.GateOpened
		u, err := unit(p.Unit)
		if err != nil {
			return nil, err
		}
		if u.Running() != nil || u.Gate != nil || u.Status != StatusRunning {
			return nil, fmt.Errorf("gate_opened (seq %d) while unit %q is %s", ev.Seq, u.Key, u.Status)
		}
		if !p.Builtin && u.CurrentStep != p.Gate {
			return nil, fmt.Errorf("gate_opened for %q (seq %d) but the unit is at %q", p.Gate, ev.Seq, u.CurrentStep)
		}
		r := u.CurrentRound()
		g := &Gate{GateOpened: *p, OpenedAt: ev.TS}
		if r != nil {
			g.Round = r.No
			r.EndedBy = "gate:" + p.Gate
		}
		u.Gate = g
		u.Gates = append(u.Gates, g)
		u.Status = StatusWaiting
		s.Status = runStatus(s)
	case EvGateResolved:
		p := ev.GateResolved
		u, err := unit(p.Unit)
		if err != nil {
			return nil, err
		}
		if u.Gate == nil || u.Gate.Gate != p.Gate {
			return nil, fmt.Errorf("gate_resolved for %q (seq %d) but unit %q is not waiting at it", p.Gate, ev.Seq, u.Key)
		}
		if p.Channel != "tty" && p.Channel != "non-tty" {
			return nil, fmt.Errorf("gate_resolved (seq %d) has channel %q (want tty or non-tty)", ev.Seq, p.Channel)
		}
		if p.Actor == "" {
			return nil, fmt.Errorf("gate_resolved (seq %d) has no actor", ev.Seq)
		}
		if u.Gate.RequiresTTY && p.Channel != "tty" {
			return nil, fmt.Errorf("gate_resolved (seq %d): gate %q requires a terminal but was resolved over %s", ev.Seq, p.Gate, p.Channel)
		}
		u.Gate.Resolution = &GateResolution{Outcome: p.Outcome, Note: p.Note, Observed: p.Observed, Actor: p.Actor, User: p.User, Channel: p.Channel, At: ev.TS}
		if !u.Gate.Builtin {
			if u.Outcomes == nil {
				u.Outcomes = map[string]string{}
			}
			u.Outcomes[p.Gate] = p.Outcome
		}
		u.Gate = nil
		u.Status = StatusRunning
		s.Status = StatusRunning
	case EvRunnerStarted:
		s.PID = ev.RunnerStarted.PID
	case EvCancelRequested:
		s.Cancel = ev.CancelRequested
	case EvRunCancelled:
		p := ev.RunCancelled
		for _, u := range s.Units {
			if x := u.Running(); x != nil {
				return nil, fmt.Errorf("run_cancelled (seq %d) while step %s is still running", ev.Seq, x.Step)
			}
			if !Terminal(u.Status) {
				u.Status = StatusCancelled
				u.Gate = nil
				if r := u.CurrentRound(); r != nil && r.EndedBy == "" {
					r.EndedBy = "cancelled"
				}
			}
		}
		s.Status, s.Reason, s.Cancelled = StatusCancelled, "cancelled", p
	default:
		return nil, fmt.Errorf("unknown event type %q (seq %d)", ev.Type, ev.Seq)
	}
	s.LastSeq, s.UpdatedAt = ev.Seq, ev.TS
	return s, nil
}

// BudgetLimitName は unit の累計予算を置く limits の名前（workflow.BudgetLimit と同じ値。runstate は workflow に依存しない）。
const BudgetLimitName = "budget_usd"

// runStatus は unit の状態から run の汎用状態を決める: 終端でない unit がすべてゲートで待っていれば waiting。
func runStatus(s *State) string {
	waiting := false
	for _, u := range s.Units {
		switch {
		case u.Status == StatusWaiting:
			waiting = true
		case !Terminal(u.Status):
			return StatusRunning
		}
	}
	if waiting {
		return StatusWaiting
	}
	return s.Status
}

func checkPayload(ev *Event) error {
	set := map[string]bool{
		EvRunStarted: ev.RunStarted != nil, EvRoundStarted: ev.RoundStarted != nil,
		EvStepStarted: ev.StepStarted != nil, EvStepFinished: ev.StepFinished != nil,
		EvTransition: ev.Transition != nil, EvRunFinished: ev.RunFinished != nil,
		EvCancelRequested: ev.CancelRequested != nil, EvRunCancelled: ev.RunCancelled != nil,
		EvStepProcess: ev.StepProcess != nil, EvGateOpened: ev.GateOpened != nil,
		EvGateResolved: ev.GateResolved != nil, EvRunnerStarted: ev.RunnerStarted != nil,
	}
	n := 0
	for _, v := range set {
		if v {
			n++
		}
	}
	has, known := set[ev.Type]
	if !known {
		return fmt.Errorf("unknown event type %q (seq %d)", ev.Type, ev.Seq)
	}
	if !has || n != 1 {
		return fmt.Errorf("event %s (seq %d) must carry exactly its own payload", ev.Type, ev.Seq)
	}
	return nil
}

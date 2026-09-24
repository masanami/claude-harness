package runstate

import (
	"encoding/json"
	"fmt"
)

// Run の汎用状態（§4.1）。waiting は PR-3（gate）で使う。
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
	Edge   map[string]json.RawMessage `json:"edge,omitempty"`
	Rounds []*Round                   `json:"rounds"`
}

// Round はゲートとゲートの間（§4.2）。
type Round struct {
	No        int              `json:"no"`
	Trigger   Trigger          `json:"trigger"`
	StartedAt string           `json:"started_at"`
	EndedBy   string           `json:"ended_by,omitempty"` // 終端の理由（PR-3 で止まったゲートも入る）
	Retries   map[string]int   `json:"retries,omitempty"`  // ステップごとに使った retry（ラウンド単位で数える。§3.1）
	Steps     []*StepExecution `json:"steps"`
}

// StepExecution はステップの 1 回の実行（§4.1）。
type StepExecution struct {
	Step       string          `json:"step"`
	Attempt    int             `json:"attempt"`
	Status     string          `json:"status"` // running | finished | cancelled
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
			s.Units = append(s.Units, &Unit{Key: k, Status: StatusRunning, CurrentStep: p.EntryStep, Rounds: []*Round{}})
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
		r.Steps = append(r.Steps, &StepExecution{
			Step: p.Step, Attempt: p.Attempt, Status: "running", StartedAt: ev.TS,
			PID: p.PID, Argv: p.Argv, StdoutLog: p.StdoutLog, StderrLog: p.StderrLog,
		})
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
		x.Status = "finished"
		if p.Cancelled {
			x.Status = "cancelled"
		}
		if !p.Cancelled && !p.Reserved {
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
		case "fail", "done":
			u.Status = map[string]string{"fail": StatusFailed, "done": StatusSucceeded}[p.Action]
			u.Reason = p.Reason
			u.Edge = nil
			r.EndedBy = p.Reason
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
				if r := u.CurrentRound(); r != nil {
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

func checkPayload(ev *Event) error {
	set := map[string]bool{
		EvRunStarted: ev.RunStarted != nil, EvRoundStarted: ev.RoundStarted != nil,
		EvStepStarted: ev.StepStarted != nil, EvStepFinished: ev.StepFinished != nil,
		EvTransition: ev.Transition != nil, EvRunFinished: ev.RunFinished != nil,
		EvCancelRequested: ev.CancelRequested != nil, EvRunCancelled: ev.RunCancelled != nil,
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

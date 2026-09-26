// Package runstate は run の永続状態（docs/harness-runtime-design.md §4・§4.6 の F1）を持つ。
//
// run ごとのディレクトリに追記専用の events.jsonl（正本）を置き、状態はその畳み込み（Fold）で
// 再構成する。state.json は畳み込んだ結果の写しで、一時ファイル＋rename で原子的に置き換える。
// 同じ run への書き込みは run ディレクトリ内のロック（mkdir 方式）で直列化する。
package runstate

import "encoding/json"

// Event の種類。
const (
	EvRunStarted      = "run_started"
	EvRoundStarted    = "round_started"
	EvStepStarted     = "step_started"
	EvStepFinished    = "step_finished"
	EvTransition      = "transition"
	EvRunFinished     = "run_finished"
	EvCancelRequested = "cancel_requested"
	EvRunCancelled    = "run_cancelled"
	EvStepProcess     = "step_process"   // llm の子プロセスの PID（session_id を記録した step_started の後に起動するため別に記録する）
	EvGateOpened      = "gate_opened"    // unit がゲートで止まり、ラウンドが閉じた（§4.2）
	EvGateResolved    = "gate_resolved"  // resume / approve がゲートを解決した（actor・channel を残す。§5.3）
	EvRunnerStarted   = "runner_started" // resume / approve が run を進めるプロセスになった（runner の生存確認の対象を替える）
)

// Event は events.jsonl の 1 行。Type に対応するペイロードを 1 つだけ持つ。
type Event struct {
	Seq  int    `json:"seq"`
	TS   string `json:"ts"`
	Type string `json:"type"`

	RunStarted      *RunStarted      `json:"run_started,omitempty"`
	RoundStarted    *RoundStarted    `json:"round_started,omitempty"`
	StepStarted     *StepStarted     `json:"step_started,omitempty"`
	StepFinished    *StepFinished    `json:"step_finished,omitempty"`
	Transition      *Transition      `json:"transition,omitempty"`
	RunFinished     *RunFinished     `json:"run_finished,omitempty"`
	CancelRequested *CancelRequested `json:"cancel_requested,omitempty"`
	RunCancelled    *RunCancelled    `json:"run_cancelled,omitempty"`
	StepProcess     *StepProcess     `json:"step_process,omitempty"`
	GateOpened      *GateOpened      `json:"gate_opened,omitempty"`
	GateResolved    *GateResolved    `json:"gate_resolved,omitempty"`
	RunnerStarted   *RunnerStarted   `json:"runner_started,omitempty"`
}

// WorkflowRef は run が開始時に記録するワークフロー定義の同定情報（§7.3 の再開時照合の材料）。
type WorkflowRef struct {
	ID     string `json:"id"`
	Schema string `json:"schema"`
	Hash   string `json:"hash"`
	Path   string `json:"path"`
}

// RunStarted は run の開始。
type RunStarted struct {
	RunID       string                     `json:"run_id"`
	Workflow    WorkflowRef                `json:"workflow"`
	Inputs      map[string]json.RawMessage `json:"inputs"`
	Limits      map[string]float64         `json:"limits,omitempty"`
	Origin      string                     `json:"origin"`
	Cwd         string                     `json:"cwd"`
	PID         int                        `json:"pid"`
	ScriptsDir  string                     `json:"scripts_dir"`
	WorkflowDir string                     `json:"workflow_dir"`
	Units       []string                   `json:"units"`
	EntryStep   string                     `json:"entry_step"`
}

// Trigger はラウンドの開始の契機（§4.1 Round。§5.5 の「中断」と「計画された再開」の区別）。
type Trigger struct {
	Kind  string `json:"kind"`           // start | gate
	Gate  string `json:"gate,omitempty"` // どのゲートを抜けたか
	Input string `json:"input,omitempty"`
}

// RoundStarted はラウンドの開始。
type RoundStarted struct {
	Unit    string  `json:"unit"`
	Round   int     `json:"round"`
	Trigger Trigger `json:"trigger"`
}

// StepStarted はステップ実行の開始。PID は子プロセスのプロセスグループの長。
type StepStarted struct {
	Unit      string   `json:"unit"`
	Step      string   `json:"step"`
	Attempt   int      `json:"attempt"`
	PID       int      `json:"pid,omitempty"`
	Argv      []string `json:"argv,omitempty"`
	StdoutLog string   `json:"stdout_log,omitempty"`
	StderrLog string   `json:"stderr_log,omitempty"`

	// llm 種類: 起動前に採番・決定して記録する（runtime が落ちても失われない。§4.4）。
	SessionID        string   `json:"session_id,omitempty"`
	Resume           bool     `json:"resume,omitempty"` // session_id のセッションを --resume で引き継いだ
	BudgetGrantedUSD *float64 `json:"budget_granted_usd,omitempty"`
	PromptLog        string   `json:"prompt_log,omitempty"`
}

// StepProcess は llm の子プロセスを起動した記録。PID はプロセスグループの長。
type StepProcess struct {
	Unit    string `json:"unit"`
	Step    string `json:"step"`
	Attempt int    `json:"attempt"`
	PID     int    `json:"pid"`
}

// StepFinished はステップ実行の終了。Cancelled なら outcome は持たない。
type StepFinished struct {
	Unit      string          `json:"unit"`
	Step      string          `json:"step"`
	Attempt   int             `json:"attempt"`
	Outcome   string          `json:"outcome,omitempty"`
	Reserved  bool            `json:"reserved,omitempty"`
	Output    json.RawMessage `json:"output,omitempty"`
	ExitCode  *int            `json:"exit_code,omitempty"`
	Error     string          `json:"error,omitempty"`
	Cancelled bool            `json:"cancelled,omitempty"`
	// Interrupted は runner が落ちて running のまま残った実行を、次の status / resume が打ち切った記録（§4.5）。
	Interrupted bool `json:"interrupted,omitempty"`

	// 費用（llm 種類）。CostUSD は unit の累計へ加える額。CostUnknown なら費用が得られず、付与した上限額を
	// 消費したものとして CostUSD に入れている（fail-closed。Q15）。CostReportedUSD は claude が報告した値
	// （--resume ではセッションの累計になる）。
	CostUSD         *float64 `json:"cost_usd,omitempty"`
	CostUnknown     bool     `json:"cost_unknown,omitempty"`
	CostReportedUSD *float64 `json:"cost_reported_usd,omitempty"`
	SessionID       string   `json:"session_id,omitempty"` // claude が結果で報告した session_id
}

// GateOpened は unit がゲートで止まったこと。Builtin は runtime の組み込みゲート（interrupted）。
type GateOpened struct {
	Unit            string   `json:"unit"`
	Gate            string   `json:"gate"`
	Type            string   `json:"type"`
	Decider         string   `json:"decider"`
	RequestedAction string   `json:"requested_action"`
	Inputs          []string `json:"inputs,omitempty"`
	Observe         string   `json:"observe,omitempty"`
	RequiresTTY     bool     `json:"requires_tty"`
	Builtin         bool     `json:"builtin,omitempty"`
}

// GateResolved はゲートの解決。Outcome は input 型なら渡された値、observe 型なら観測の結果。
// Actor は解決したコマンド（resume / approve）、User はそのプロセスの利用者名、Channel は tty / non-tty。
type GateResolved struct {
	Unit     string          `json:"unit"`
	Gate     string          `json:"gate"`
	Outcome  string          `json:"outcome"`
	Note     string          `json:"note,omitempty"`
	Observed json.RawMessage `json:"observed,omitempty"`
	Actor    string          `json:"actor"`
	User     string          `json:"user,omitempty"`
	Channel  string          `json:"channel"`
}

// RunnerStarted は run を進めるプロセスが替わったこと（resume / approve）。
type RunnerStarted struct {
	PID     int    `json:"pid"`
	Command string `json:"command"`
}

// Transition は遷移の決定。Action は step / gate / fail / done（retry は同じステップへの step）。
type Transition struct {
	Unit    string `json:"unit"`
	From    string `json:"from"`
	Outcome string `json:"outcome"`
	Action  string `json:"action"`
	To      string `json:"to,omitempty"`
	Reason  string `json:"reason,omitempty"`
	// Limit は数えた limit の名前（数えたときだけ）。Retry は retry を 1 回使ったか。
	Limit string `json:"limit,omitempty"`
	Retry bool   `json:"retry,omitempty"`
	// Exhausted は上限に達して exhausted の遷移を採ったとき、その上限の種類（limit / retry）。
	Exhausted string `json:"exhausted,omitempty"`
	// Default は予約値が on に無く、既定の fail-closed で run を失敗させたとき真。
	Default bool                       `json:"default,omitempty"`
	Edge    map[string]json.RawMessage `json:"edge,omitempty"`
}

// RunFinished は run の終端（succeeded / failed）。
type RunFinished struct {
	Status string `json:"status"`
	Reason string `json:"reason"`
}

// CancelRequested は cancel の要求（実行中の runner が拾って子プロセスを止める）。
type CancelRequested struct {
	Actor   string `json:"actor"`
	Channel string `json:"channel"`
}

// RunCancelled は停止の記録。
type RunCancelled struct {
	Actor   string `json:"actor"`
	Channel string `json:"channel"`
	Note    string `json:"note,omitempty"`
}

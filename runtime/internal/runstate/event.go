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
	Kind  string `json:"kind"`           // start（PR-3 で gate を足す）
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
}

// Transition は遷移の決定。Action は step / fail / done（retry は同じステップへの step）。
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

// Package engine は run を進める（状態機械）。状態はすべて runstate のイベントとして記録し、
// 次に何をするかは畳み込んだ状態から決める（再開時に同じ判断を再構成できるように、エンジンの中に状態を持たない）。
package engine

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/santhosh-tekuri/jsonschema/v6"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// MainUnit は fan-out を持たない run の唯一の unit の key。
const MainUnit = "main"

// Engine は 1 つの run を進める。
type Engine struct {
	WF         *workflow.Workflow
	Run        *runstate.Run
	ScriptsDir string
	Cwd        string

	// KillGrace は停止時に SIGTERM から SIGKILL までの猶予。PollInterval は cancel の印を見る間隔。
	KillGrace    time.Duration
	PollInterval time.Duration
}

// NewRunID は時刻順に並ぶ run id を作る。
func NewRunID(now time.Time) string {
	var b [3]byte
	_, _ = rand.Read(b[:])
	return now.UTC().Format("20060102-150405") + "-" + hex.EncodeToString(b[:])
}

// StartParams は run の開始に要るもの。
type StartParams struct {
	RunsDir     string
	WF          *workflow.Workflow
	Inputs      map[string]json.RawMessage
	ScriptsDir  string
	WorkflowDir string
	Cwd         string
	Origin      string
}

// Start は run ディレクトリを作り、run_started とラウンド 1 の開始を記録する。
func Start(p StartParams) (*Engine, error) {
	id := NewRunID(time.Now())
	run, err := runstate.Create(p.RunsDir, id)
	if err != nil {
		return nil, err
	}
	limits := map[string]float64{}
	for _, l := range p.WF.Limits {
		limits[l.Name] = l.Value
	}
	if len(limits) == 0 {
		limits = nil
	}
	_, err = run.Append(
		runstate.Event{Type: runstate.EvRunStarted, RunStarted: &runstate.RunStarted{
			RunID:       id,
			Workflow:    runstate.WorkflowRef{ID: p.WF.ID, Schema: p.WF.Schema, Hash: p.WF.Hash, Path: p.WF.Path},
			Inputs:      p.Inputs,
			Limits:      limits,
			Origin:      p.Origin,
			Cwd:         p.Cwd,
			PID:         os.Getpid(),
			ScriptsDir:  p.ScriptsDir,
			WorkflowDir: p.WorkflowDir,
			Units:       []string{MainUnit},
			EntryStep:   p.WF.Steps[0].ID,
		}},
		runstate.Event{Type: runstate.EvRoundStarted, RoundStarted: &runstate.RoundStarted{
			Unit: MainUnit, Round: 1, Trigger: runstate.Trigger{Kind: "start"},
		}},
	)
	if err != nil {
		return nil, err
	}
	return &Engine{WF: p.WF, Run: run, ScriptsDir: p.ScriptsDir, Cwd: p.Cwd}, nil
}

func (e *Engine) grace() time.Duration {
	if e.KillGrace > 0 {
		return e.KillGrace
	}
	return 5 * time.Second
}

func (e *Engine) poll() time.Duration {
	if e.PollInterval > 0 {
		return e.PollInterval
	}
	return 100 * time.Millisecond
}

// Loop は run が終端に達するまでステップを実行する。ctx の取り消し（シグナル）は cancel と同じに扱う。
func (e *Engine) Loop(ctx context.Context) (*runstate.State, error) {
	for {
		st, _, err := e.Run.Load()
		if err != nil {
			return nil, err
		}
		if runstate.Terminal(st.Status) {
			return st, nil
		}
		// cancel の印（ファイル）を置く前に cancel が落ちても、記録された要求は拾う。
		if st.Cancel != nil || e.cancelRequested(ctx) {
			return e.cancel(ctx)
		}
		u := st.Unit(MainUnit)
		step := e.WF.Step(u.CurrentStep)
		if step == nil {
			return nil, fmt.Errorf("current step %q is not in workflow %s", u.CurrentStep, e.WF.ID)
		}
		res := e.execute(ctx, st, u, step)
		if res.err != nil {
			return nil, res.err
		}
		if res.cancelled {
			return e.cancel(ctx)
		}
		evs, err := e.decide(st, u, step, res)
		if err != nil {
			return nil, err
		}
		if _, err := e.Run.Append(evs...); err != nil {
			return nil, err
		}
	}
}

func (e *Engine) cancelRequested(ctx context.Context) bool {
	if ctx.Err() != nil {
		return true
	}
	_, err := os.Stat(filepath.Join(e.Run.Dir, runstate.CancelFile))
	return err == nil
}

// cancel は停止を記録する。実行中のステップ（execute が子プロセスを止めたもの）があれば、その終了も同時に記録する。
func (e *Engine) cancel(ctx context.Context) (*runstate.State, error) {
	st, _, err := e.Run.Load()
	if err != nil {
		return nil, err
	}
	actor, channel := "unknown", "unknown"
	if st.Cancel != nil {
		actor, channel = st.Cancel.Actor, st.Cancel.Channel
	} else if ctx.Err() != nil {
		actor, channel = "signal", "signal"
	}
	return e.Run.Append(CancelEvents(st, actor, channel, "stopped by the runner")...)
}

// CancelEvents は停止の記録に要るイベント（実行中のステップの打ち切り＋run_cancelled）を作る。
func CancelEvents(st *runstate.State, actor, channel, note string) []runstate.Event {
	var evs []runstate.Event
	for _, u := range st.Units {
		if x := u.Running(); x != nil {
			evs = append(evs, runstate.Event{Type: runstate.EvStepFinished, StepFinished: &runstate.StepFinished{
				Unit: u.Key, Step: x.Step, Attempt: x.Attempt, Cancelled: true, Error: "cancelled",
			}})
		}
	}
	return append(evs, runstate.Event{Type: runstate.EvRunCancelled, RunCancelled: &runstate.RunCancelled{
		Actor: actor, Channel: channel, Note: note,
	}})
}

// result はステップ実行 1 回の結果。
type result struct {
	attempt   int
	outcome   string
	reserved  bool
	output    json.RawMessage
	exitCode  *int
	errText   string
	cancelled bool
	err       error // 記録そのものに失敗した（run を進められない）
}

// decide は結果から step_finished と遷移のイベントを作る。予約値が on に無ければ run を失敗にする（fail-closed）。
func (e *Engine) decide(st *runstate.State, u *runstate.Unit, step *workflow.Step, res result) ([]runstate.Event, error) {
	// st は execute の前に読んだ状態なので、この実行の番号は result が持つ。
	attempt := res.attempt
	evs := []runstate.Event{{Type: runstate.EvStepFinished, StepFinished: &runstate.StepFinished{
		Unit: u.Key, Step: step.ID, Attempt: attempt, Outcome: res.outcome, Reserved: res.reserved,
		Output: res.output, ExitCode: res.exitCode, Error: res.errText,
	}}}
	// 遷移の with が $steps.<このステップ> を読むとき、いま得た出力を使う。
	cur := done{outputs: map[string]json.RawMessage{}, outcomes: map[string]string{}}
	for k, v := range u.Outputs {
		cur.outputs[k] = v
	}
	for k, v := range u.Outcomes {
		cur.outcomes[k] = v
	}
	if !res.reserved {
		cur.outcomes[step.ID] = res.outcome
		if res.output != nil {
			cur.outputs[step.ID] = res.output
		}
	}
	tr := &runstate.Transition{Unit: u.Key, From: step.ID, Outcome: res.outcome}
	t := step.OnFor(res.outcome)
	if t == nil {
		if !res.reserved {
			return nil, fmt.Errorf("step %s returned outcome %q with no transition (the workflow was not validated)", step.ID, res.outcome)
		}
		tr.Action, tr.Reason, tr.Default = "fail", res.outcome, true
	} else if err := e.resolve(st, u, step, t, cur, tr); err != nil {
		return nil, err
	}
	evs = append(evs, runstate.Event{Type: runstate.EvTransition, Transition: tr})
	switch tr.Action {
	case "fail":
		evs = append(evs, runstate.Event{Type: runstate.EvRunFinished, RunFinished: &runstate.RunFinished{Status: runstate.StatusFailed, Reason: tr.Reason}})
	case "done":
		evs = append(evs, runstate.Event{Type: runstate.EvRunFinished, RunFinished: &runstate.RunFinished{Status: runstate.StatusSucceeded, Reason: tr.Reason}})
	}
	return evs, nil
}

// resolve は遷移先を決める。limit は unit 単位の累計、retry はラウンド単位で数える（§3.1）。
// done は成功したステップの値（$steps 参照の解決元）。
type done struct {
	outputs  map[string]json.RawMessage
	outcomes map[string]string
}

func (e *Engine) resolve(st *runstate.State, u *runstate.Unit, step *workflow.Step, t *workflow.Transition, cur done, tr *runstate.Transition) error {
	switch t.Kind {
	case workflow.TStep:
		tr.Action, tr.To = "step", t.Target
	case workflow.TFail:
		tr.Action, tr.Reason = "fail", t.Reason
	case workflow.TDone:
		tr.Action, tr.Reason = "done", t.Reason
	case workflow.TRetry:
		used := 0
		if r := u.CurrentRound(); r != nil {
			used = r.Retries[step.ID]
		}
		if used >= t.Retry {
			tr.Exhausted = "retry"
			return e.resolve(st, u, step, t.Exhausted, cur, tr)
		}
		tr.Action, tr.To, tr.Retry = "step", step.ID, true
	case workflow.TGoto:
		if t.Limit != "" {
			max := int(st.Limits[t.Limit])
			if u.LimitsUsed[t.Limit] >= max {
				tr.Exhausted = "limit"
				return e.resolve(st, u, step, t.Exhausted, cur, tr)
			}
			tr.Limit = t.Limit
		}
		tr.Action, tr.To = "step", t.Target
		if len(t.With) > 0 {
			tr.Edge = map[string]json.RawMessage{}
			for _, b := range t.With {
				v, err := value(st, cur, nil, b.Value)
				if err != nil {
					// 検証済みの参照が解決できないのは出力の中身の問題（null 等）。run を失敗で止める。
					tr.Action, tr.To, tr.Limit, tr.Edge = "fail", "", "", nil
					tr.Reason = "reference_unresolved"
					return nil
				}
				tr.Edge[b.Name] = v
			}
		}
	case workflow.TGate:
		return fmt.Errorf("gate transitions are not supported in this version")
	}
	return nil
}

// value は with の値を JSON で返す。
func value(st *runstate.State, cur done, edge map[string]json.RawMessage, v workflow.Value) (json.RawMessage, error) {
	if v.Ref == nil {
		return json.Marshal(v.Literal)
	}
	r := v.Ref
	switch r.Kind {
	case workflow.RefInputs:
		raw, ok := st.Inputs[r.Name]
		if !ok {
			return nil, fmt.Errorf("%s: input not given", r.Raw)
		}
		return raw, nil
	case workflow.RefEdge:
		raw, ok := edge[r.Name]
		if !ok {
			return nil, fmt.Errorf("%s: not passed by the transition", r.Raw)
		}
		return raw, nil
	case workflow.RefSteps:
		if len(r.Path) == 1 && r.Path[0] == "outcome" {
			o, ok := cur.outcomes[r.Step]
			if !ok {
				return nil, fmt.Errorf("%s: step %s has not succeeded", r.Raw, r.Step)
			}
			return json.Marshal(o)
		}
		raw, ok := cur.outputs[r.Step]
		if !ok {
			return nil, fmt.Errorf("%s: step %s has no successful output", r.Raw, r.Step)
		}
		var cur any
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.UseNumber()
		if err := dec.Decode(&cur); err != nil {
			return nil, err
		}
		for _, name := range r.Path {
			m, ok := cur.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("%s: not an object at %s", r.Raw, name)
			}
			if cur, ok = m[name]; !ok {
				return nil, fmt.Errorf("%s: field %s is absent", r.Raw, name)
			}
		}
		if cur == nil {
			return nil, fmt.Errorf("%s: value is null", r.Raw)
		}
		return json.Marshal(cur)
	}
	return nil, fmt.Errorf("%s: not resolvable in this version", r.Raw)
}

// argv は command の with を --<名前> <値> の並びへ写す（YAML に書いた順。配列はフラグを繰り返す）。
func argv(st *runstate.State, u *runstate.Unit, step *workflow.Step) ([]string, error) {
	var args []string
	for _, b := range step.With {
		if r := b.Value.Ref; r != nil && r.Kind == workflow.RefInputs {
			if _, given := st.Inputs[r.Name]; !given {
				// 省略された任意の入力はフラグごと渡さない（必須の入力は run の開始時に検査済み）。
				continue
			}
		}
		raw, err := value(st, done{outputs: u.Outputs, outcomes: u.Outcomes}, u.Edge, b.Value)
		if err != nil {
			return nil, err
		}
		var v any
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.UseNumber()
		if err := dec.Decode(&v); err != nil {
			return nil, err
		}
		items := []any{v}
		if arr, ok := v.([]any); ok {
			items = arr
		}
		for _, it := range items {
			s, err := scalarArg(it)
			if err != nil {
				return nil, fmt.Errorf("with.%s: %v", b.Name, err)
			}
			args = append(args, "--"+b.Name, s)
		}
	}
	return args, nil
}

func scalarArg(v any) (string, error) {
	switch x := v.(type) {
	case string:
		return x, nil
	case json.Number:
		return x.String(), nil
	case bool:
		return strconv.FormatBool(x), nil
	case int64:
		return strconv.FormatInt(x, 10), nil
	}
	return "", fmt.Errorf("value %v cannot be passed as an argument", v)
}

// validateOutput は stdout の JSON を検証し、outcome を取り出す。
func validateOutput(step *workflow.Step, stdout []byte) (json.RawMessage, string, error) {
	inst, err := jsonschema.UnmarshalJSON(bytes.NewReader(stdout))
	if err != nil {
		return nil, "", fmt.Errorf("stdout is not a single JSON value: %v", err)
	}
	if step.OutputSchema != nil {
		if err := step.OutputSchema.Validate(inst); err != nil {
			return nil, "", fmt.Errorf("stdout does not match %s: %v", step.Output, err)
		}
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, bytes.TrimSpace(stdout)); err != nil {
		return nil, "", err
	}
	if len(step.Exit) > 0 {
		return compact.Bytes(), "", nil
	}
	field := step.OutcomeField
	if field == "" {
		field = "outcome"
	}
	obj, ok := inst.(map[string]any)
	if !ok {
		return nil, "", fmt.Errorf("stdout is not a JSON object")
	}
	outcome, ok := obj[field].(string)
	if !ok {
		return nil, "", fmt.Errorf("stdout has no string field %q", field)
	}
	for _, o := range step.Outcomes() {
		if o == outcome {
			return compact.Bytes(), outcome, nil
		}
	}
	return nil, "", fmt.Errorf("outcome %q is not in the enum", outcome)
}

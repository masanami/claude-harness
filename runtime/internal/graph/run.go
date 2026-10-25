package graph

import (
	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// Run は --run を付けたときに形へ重ねる run の現在地（docs/harness-runtime-visualization.md §4）。値はすべて status が
// 使う畳み込んだ状態と status の waiting() から写し、status --json と同じ名前・同じ意味で出す。
//
// RunnerAlive は status --json と同じく running の run についてだけ値を持つ（それ以外は null）。graph は runner の
// 居ない実行中の run を interrupted に記録し直さないので、その run は running のまま runner_alive: false で出る。
type Run struct {
	RunID       string    `json:"run_id"`
	Status      string    `json:"status"`
	Reason      *string   `json:"reason"`
	RunnerAlive *bool     `json:"runner_alive"`
	Units       []RunUnit `json:"units"`
}

// RunUnit は unit 1 つの現在地。Round は rounds[] の数（status のテキスト表示の round N と同じ）。Waiting はゲートで
// 待っているときだけ値を持つ。LimitsUsed と Visited は空でも空のオブジェクト・配列で出す（キーの有無で分岐させない）。
type RunUnit struct {
	Key         string           `json:"key"`
	Status      string           `json:"status"`
	CurrentStep string           `json:"current_step"`
	Round       int              `json:"round"`
	Waiting     *Waiting         `json:"waiting"`
	Visited     []Visit          `json:"visited"`
	LimitsUsed  map[string]int   `json:"limits_used"`
	Budget      *runstate.Budget `json:"budget"`
}

// Waiting は待っているゲート 1 つ。status --json の waiting[] の要素（cli の waitingView）と同じフィールドで、cli は
// 型の変換でそのまま写す（フィールドがずれればコンパイルが通らない）。
type Waiting struct {
	Unit            string   `json:"unit"`
	Gate            string   `json:"gate"`
	Type            string   `json:"type"`
	Decider         string   `json:"decider"`
	RequestedAction string   `json:"requested_action"`
	Inputs          []string `json:"inputs,omitempty"`
	RequiresTTY     bool     `json:"requires_tty"`
	ResumeCommand   string   `json:"resume_command"`
}

// Visit は全ラウンドのステップ実行（rounds[].steps[]）をステップごとに数えたもの。LastOutcome は最後の実行の outcome で、
// 終わっていない・打ち切られた実行は実行の状態（running・interrupted・cancelled）を入れる（status のテキスト表示と同じ）。
// ゲートはステップ実行を持たないので入らない（§4）。
type Visit struct {
	Step        string `json:"step"`
	Executions  int    `json:"executions"`
	LastOutcome string `json:"last_outcome"`
}

// NewRun は畳み込んだ状態から現在地を作る。runnerAlive は status と同じ判定の結果（running でなければ nil）、waiting は
// status の waiting() を写したもの。状態は読むだけで変えない。
func NewRun(st *runstate.State, runnerAlive *bool, waiting func(*runstate.Unit) Waiting) *Run {
	r := &Run{RunID: st.RunID, Status: st.Status, Reason: strOrNil(st.Reason), RunnerAlive: runnerAlive, Units: []RunUnit{}}
	for _, u := range st.Units {
		ru := RunUnit{Key: u.Key, Status: u.Status, CurrentStep: u.CurrentStep, Round: len(u.Rounds), Visited: visited(u),
			LimitsUsed: map[string]int{}, Budget: u.Budget}
		for k, v := range u.LimitsUsed {
			ru.LimitsUsed[k] = v
		}
		// status と同じく、終わった run のゲートは待っているものとして出さない。
		if !runstate.Terminal(st.Status) && u.Gate != nil {
			w := waiting(u)
			ru.Waiting = &w
		}
		r.Units = append(r.Units, ru)
	}
	return r
}

// visited はステップを最初に実行した順に並べる。
func visited(u *runstate.Unit) []Visit {
	out := []Visit{}
	at := map[string]int{}
	for _, r := range u.Rounds {
		for _, x := range r.Steps {
			o := x.Outcome
			if x.Status != "finished" {
				o = x.Status
			}
			i, ok := at[x.Step]
			if !ok {
				i = len(out)
				at[x.Step] = i
				out = append(out, Visit{Step: x.Step})
			}
			out[i].Executions++
			out[i].LastOutcome = o
		}
	}
	return out
}

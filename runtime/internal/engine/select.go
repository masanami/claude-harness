package engine

import (
	"context"
	"fmt"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// executeSelect は select 種類（§3.2・Q12）を 1 回実行する: 参照 1 つが指す enum 値をそのまま outcome にする。
// 副作用は無い。比較・組み合わせは持たない（値が enum に無ければ invalid_output。fail-closed）。
func (e *Engine) executeSelect(_ context.Context, st *runstate.State, u *runstate.Unit, step *workflow.Step, attempt int) result {
	if _, err := e.Run.Append(runstate.Event{Type: runstate.EvStepStarted, StepStarted: &runstate.StepStarted{
		Unit: u.Key, Step: step.ID, Attempt: attempt,
	}}); err != nil {
		return result{err: err}
	}
	raw, err := value(st, succeeded(u), u.Edge, workflow.Value{Ref: step.Value})
	if err != nil {
		return result{outcome: "invalid_output", reserved: true, errText: "value: " + err.Error()}
	}
	v, ok := jsonString(raw)
	if !ok {
		return result{outcome: "invalid_output", reserved: true, errText: fmt.Sprintf("value %s is not a string: %s", step.Value.Raw, raw)}
	}
	if !contains(step.Outcomes(), v) {
		return result{outcome: "invalid_output", reserved: true, errText: fmt.Sprintf("value %s is %q, which is not one of %v", step.Value.Raw, v, step.Outcomes())}
	}
	return result{outcome: v}
}

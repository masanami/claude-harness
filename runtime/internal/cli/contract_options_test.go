package cli

import (
	"encoding/json"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// requested_action.options（#384・masanami/flywheel#592）。ゲートが受け付ける選択肢（resume / approve の --input と照らす
// 一覧＝ゲートの定義の inputs。text の「choices: …」も同じ一覧から作る）を、定義の順の文字列の配列で出す。選択肢の無い待ち
// （observe ゲート・inputs の無いゲート）と requested_action が null の出力では、キーごと出さない。契約の版は 1 のまま。

// optionsOf は requested_action の options を生の値のまま読む（キーが無ければ ok は false）。
func optionsOf(t *testing.T, a map[string]json.RawMessage) ([]string, bool) {
	t.Helper()
	raw, ok := a["options"]
	if !ok {
		return nil, false
	}
	var opts []string
	if err := json.Unmarshal(raw, &opts); err != nil {
		t.Fatalf("options = %s: %v", raw, err)
	}
	return opts, true
}

// ① レビュー待ちのゲート（respond|ready）の実際の run。宣言の有無で kind は answer / review に分かれるが、options は同じ。
func TestContractOptionsForReviewGate(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := runIDOf(t, first2(h.contract(reviewStart(t)...)))
	for _, args := range [][]string{{"status", id}, {"status", "--accept-kind", "review", id}} {
		a := actionKeys(t, h.contractRaw(args...))
		opts, ok := optionsOf(t, a)
		if !ok || !reflect.DeepEqual(opts, []string{"respond", "ready"}) {
			t.Fatalf("%v: options = %v (present %v), want [respond ready] (%v)", args, opts, ok, a)
		}
	}
}

// ② 端末が要るゲート（input × human）の実際の run。approve でも、approve の --input と照らす同じ一覧を出す。
// observe ゲートは選択肢を持たないのでキーを出さない（③）。input × parent・any は定義の順に出す。
func TestContractOptionsPerGate(t *testing.T) {
	for _, c := range []struct {
		outcome string
		want    []string // nil ならキーを出さない
	}{
		{"human", []string{"follow", "abort"}}, {"observe", nil}, {"parent", []string{"go", "stop"}}, {"any", []string{"go"}},
	} {
		t.Run(c.outcome, func(t *testing.T) {
			h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
			id := runIDOf(t, first2(h.contract(gatesStart(t, c.outcome)...)))
			a := actionKeys(t, h.contractRaw("status", id))
			opts, ok := optionsOf(t, a)
			if c.want == nil && ok || c.want != nil && !reflect.DeepEqual(opts, c.want) {
				t.Fatalf("options = %v (present %v), want %v (%v)", opts, ok, c.want, a)
			}
		})
	}
}

// ①② 組み込みの ticket ワークフローの実際のゲートの定義（review: respond|ready、design-deviation: follow-decision|abort）を
// 読み、ゲートを開いたときと同じ写し方（定義の inputs → waiting の inputs）で requested_action へ写す。
func TestContractOptionsFromTicketGates(t *testing.T) {
	wf, err := workflow.Load(filepath.Join(repoWorkflows, "ticket.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	st := &runstate.State{RunID: "R-1", Workflow: runstate.WorkflowRef{ID: "ticket"}, Status: runstate.StatusWaiting}
	for _, c := range []struct {
		gate string
		acc  accepted
		kind string
		want []string
	}{
		{"review", accepted{}, actionAnswer, []string{"respond", "ready", "land"}},
		{"review", accepted{review: true}, actionReview, []string{"respond", "ready", "land"}},
		{"design-deviation", accepted{}, actionApprove, []string{"follow-decision", "abort"}},
		{"human-merge", accepted{}, actionObserve, nil},
	} {
		s := wf.Step(c.gate)
		if s == nil {
			t.Fatalf("ticket has no step %s", c.gate)
		}
		w := waitingView{Unit: "main", Gate: s.ID, Type: s.GateType, Decider: s.Decider, RequestedAction: s.RequestedAction,
			Inputs: s.GateInputs, RequiresTTY: workflow.RequiresTTY(s.GateType, s.Decider), ContractKind: s.ContractKind}
		d := contractFromView(statusView{State: st, Waiting: []waitingView{w}}, "", c.acc)
		b, _ := json.Marshal(d.RequestedAction)
		a := decode[map[string]json.RawMessage](t, string(b))
		opts, ok := optionsOf(t, a)
		if d.RequestedAction.Kind != c.kind || c.want == nil && ok || c.want != nil && !reflect.DeepEqual(opts, c.want) {
			t.Errorf("%s (accept %+v): %s", c.gate, c.acc, b)
		}
	}
}

// ③ 選択肢の一覧を持たない input ゲート（空の inputs）でもキーを出さない。kind・decider・text は今までどおり。
func TestContractOptionsAbsentWithoutInputs(t *testing.T) {
	st := &runstate.State{RunID: "R-1", Workflow: runstate.WorkflowRef{ID: "ticket"}, Status: runstate.StatusWaiting}
	w := waitingView{Unit: "main", Gate: "ask", Type: "input", Decider: "parent", RequestedAction: "ask"}
	d := contractFromView(statusView{State: st, Waiting: []waitingView{w}}, "", accepted{})
	b, _ := json.Marshal(d.RequestedAction)
	a := decode[map[string]json.RawMessage](t, string(b))
	if _, ok := a["options"]; ok || len(a) != 3 {
		t.Fatalf("requested_action = %s, want only kind, decider, text", b)
	}
}

// ③ state が waiting でない出力（終わった run）は requested_action が null で、options はどこにも出ない。
func TestContractOptionsAbsentWhenNotWaiting(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := runIDOf(t, first2(h.contract(gatesStart(t, "parent")...)))
	h.contract("resume", id, "--input", "go")
	raw := h.contractRaw("status", id)
	if string(raw["state"]) != `"succeeded"` || string(raw["requested_action"]) != "null" {
		t.Fatalf("status = %v", raw)
	}
	if _, ok := raw["options"]; ok {
		t.Fatalf("options at the top level: %v", raw)
	}
}

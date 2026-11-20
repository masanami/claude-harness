package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// requested_action.resolvable_by（#378・masanami/flywheel#631）。端末が要るゲート（RequiresTTY。resume では解けない）にだけ
// "terminal" を出し、resume で解けるゲート（answer・review・observe）では項目そのものを出さない（無いときは answer として
// 扱う決まり。既存の出力を変えない）。kind・decider・text は今までと同じ。

// actionKeys は契約の JSON の requested_action を、キーごとの生の値で読む（項目の有無を見るため）。
func actionKeys(t *testing.T, raw map[string]json.RawMessage) map[string]json.RawMessage {
	t.Helper()
	return decode[map[string]json.RawMessage](t, string(raw["requested_action"]))
}

// (a)(b) 実際に止まった run の contract start・status の JSON。
func TestContractResolvableByPerGate(t *testing.T) {
	for _, c := range []struct {
		outcome  string
		terminal bool
	}{
		{"human", true}, {"observe", false}, {"parent", false}, {"any", false},
	} {
		t.Run(c.outcome, func(t *testing.T) {
			h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
			id := runIDOf(t, first2(h.contract(gatesStart(t, c.outcome)...)))
			a := actionKeys(t, h.contractRaw("status", id))
			v, ok := a["resolvable_by"]
			switch {
			case c.terminal && string(v) != `"terminal"`:
				t.Fatalf("resolvable_by = %s, want \"terminal\" (%v)", v, a)
			case !c.terminal && ok:
				t.Fatalf("resolvable_by = %s, want no key (%v)", v, a)
			}
		})
	}
}

// (b) review を受け付けると宣言したときのレビュー待ち（kind: review）でも項目を出さない。
func TestContractResolvableByAbsentForReview(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := runIDOf(t, first2(h.contract(reviewStart(t)...)))
	a := actionKeys(t, h.contractRaw("status", "--accept-kind", "review", id))
	if string(a["kind"]) != `"review"` {
		t.Fatalf("kind = %s, want \"review\" (%v)", a["kind"], a)
	}
	if v, ok := a["resolvable_by"]; ok {
		t.Fatalf("resolvable_by = %s, want no key", v)
	}
}

// 写像の単体テスト: ゲートごとの JSON。terminal は端末が要るゲートだけで、kind・decider・text は項目を足す前と同じ。
func TestContractResolvableByMapping(t *testing.T) {
	gate := func(name, typ, decider string, tty bool, ck string) waitingView {
		return waitingView{Unit: "main", Gate: name, Type: typ, Decider: decider, RequestedAction: "do " + name, Inputs: []string{"a", "b"}, RequiresTTY: tty, ContractKind: ck}
	}
	st := &runstate.State{RunID: "R-1", Workflow: runstate.WorkflowRef{ID: "ticket"}, Status: runstate.StatusWaiting}
	review := accepted{review: true}
	for _, c := range []struct {
		w             waitingView
		acc           accepted
		kind, decider string
		text          string // text の終わり（解決のコマンド）
		terminal      bool
	}{
		{gate("design-deviation", "input", "human", true, ""), accepted{}, "approve", "human",
			"A person resolves it from a terminal: harness approve R-1 --unit main --input <a|b> [--note <text>]", true},
		{gate("review-human", "input", "human", true, ""), review, "approve", "human",
			"A person resolves it from a terminal: harness approve R-1 --unit main --input <a|b> [--note <text>]", true},
		{gate("ask", "input", "parent", false, ""), accepted{}, "answer", "parent",
			"Answer with: harness contract resume R-1 --unit main --input <a|b> [--note <text>]", false},
		{gate("ci-pending", "input", "any", false, ""), review, "answer", "parent",
			"Answer with: harness contract resume R-1 --unit main --input <a|b> [--note <text>]", false},
		{gate("review", "input", "any", false, "review"), review, "review", "parent",
			"Answer with: harness contract resume R-1 --unit main --input <a|b> [--note <text>]", false},
		{gate("review", "input", "any", false, "review"), accepted{}, "answer", "parent",
			"Answer with: harness contract resume R-1 --unit main --input <a|b> [--note <text>]", false},
		{gate("human-merge", "observe", "human", false, ""), accepted{}, "observe", "human",
			"Then resume re-checks the state: harness contract resume R-1 --unit main", false},
		{gate("wait", "observe", "any", false, ""), review, "observe", "parent",
			"Then resume re-checks the state: harness contract resume R-1 --unit main", false},
	} {
		d := contractFromView(statusView{State: st, Waiting: []waitingView{c.w}}, "", c.acc)
		b, err := json.Marshal(d.RequestedAction)
		if err != nil {
			t.Fatal(err)
		}
		a := decode[map[string]json.RawMessage](t, string(b))
		var kind, decider, text string
		_ = json.Unmarshal(a["kind"], &kind)
		_ = json.Unmarshal(a["decider"], &decider)
		_ = json.Unmarshal(a["text"], &text)
		if kind != c.kind || decider != c.decider || !strings.HasPrefix(text, "do "+c.w.Gate+" [gate "+c.w.Gate+", unit main") || !strings.HasSuffix(text, c.text) {
			t.Errorf("%s (accept %+v): %s", c.w.Gate, c.acc, b)
		}
		v, ok := a["resolvable_by"]
		if c.terminal && string(v) != `"terminal"` || !c.terminal && ok {
			t.Errorf("%s (accept %+v): resolvable_by = %s (present %v), want terminal %v", c.w.Gate, c.acc, v, ok, c.terminal)
		}
		// options（#384）は input 型のゲートにだけ足される別の任意項目なので、ここでは数に入れない。
		if _, opt := a["options"]; !c.terminal && len(a) != 3 && !(opt && len(a) == 4) {
			t.Errorf("%s: keys = %s, want only kind, decider, text (and options)", c.w.Gate, b)
		}
	}
}

// (c) 端末が要るゲートと resume で解けるゲートが同時に待つとき、選ばれた approve の項目がそのまま出る。approve 以外が
// 選ばれたときは出ない。
func TestPickActionKeepsResolvableBy(t *testing.T) {
	ans := waitingView{Unit: "ua", Gate: "ask", Type: "input", Decider: "parent", RequestedAction: "ask", Inputs: []string{"go"}}
	rev := waitingView{Unit: "ur", Gate: "review", Type: "input", Decider: "any", RequestedAction: "review", Inputs: []string{"respond", "ready"}, ContractKind: workflow.ContractKindReview}
	apr := waitingView{Unit: "up", Gate: "design-deviation", Type: "input", Decider: "human", RequestedAction: "approve", Inputs: []string{"ok"}, RequiresTTY: true}
	obs := waitingView{Unit: "uo", Gate: "human-merge", Type: "observe", Decider: "human", RequestedAction: "merge"}
	st := &runstate.State{RunID: "R-1", Workflow: runstate.WorkflowRef{ID: "ticket"}, Status: runstate.StatusWaiting}
	for _, acc := range []accepted{{}, {review: true}} {
		for _, c := range []struct {
			ws       []waitingView
			kind, by string
		}{
			{[]waitingView{obs, rev, ans, apr}, "approve", "terminal"},
			{[]waitingView{ans, apr}, "approve", "terminal"},
			{[]waitingView{obs, apr}, "approve", "terminal"},
			{[]waitingView{obs, rev, ans}, "answer", ""},
			{[]waitingView{obs}, "observe", ""},
		} {
			d := contractFromView(statusView{State: st, Waiting: c.ws}, "", acc)
			b, _ := json.Marshal(d)
			a := actionKeys(t, decode[map[string]json.RawMessage](t, string(b)))
			v, ok := a["resolvable_by"]
			if d.RequestedAction.Kind != c.kind || c.by != "" && string(v) != `"`+c.by+`"` || c.by == "" && ok {
				t.Errorf("accept %+v, waiting %d unit(s): %s", acc, len(c.ws), b)
			}
		}
	}
}

// 選択肢に land があるゲートの requested_action.text は、land には承認した先頭のコミット（--approved-ref）が要ること、承認を持つ呼び出し元
// だけが使うことを機械で出す。land を持たないゲートの text には添えない。
func TestContractRequestedActionTextExplainsLandNeedsAnApprovedRef(t *testing.T) {
	st := &runstate.State{RunID: "R-1", Workflow: runstate.WorkflowRef{ID: "ticket"}, Status: runstate.StatusWaiting}
	text := func(inputs ...string) string {
		w := waitingView{Unit: "main", Gate: "review", Type: "input", Decider: "any", RequestedAction: "wait", Inputs: inputs, ContractKind: "review"}
		d := contractFromView(statusView{State: st, Waiting: []waitingView{w}}, "", accepted{review: true})
		return d.RequestedAction.Text
	}
	if got := text("respond", "ready", "land"); !strings.Contains(got, "--approved-ref <the approved leading commit of the PR>") || !strings.Contains(got, "only a caller that holds the approval") {
		t.Errorf("text with land = %q", got)
	}
	if got := text("respond", "ready"); strings.Contains(got, "approved-ref") {
		t.Errorf("text without land mentions --approved-ref: %q", got)
	}
}

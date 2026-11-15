package cli

import (
	"reflect"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// review（レビュー待ち。§5.6.1・#372）の kind は、ゲートの定義の contract_kind: review と、呼び出し元の --accept-kind review の
// 宣言がそろったときだけ出る。宣言が無ければ answer のまま（今の flywheel は知らない kind を不正として扱う）。decider・
// text・解決の仕方（resume --input respond|ready）は answer と同じ。

func reviewStart(t *testing.T) []string {
	return append([]string{"start"}, runArgs(t, "review", `json={"outcome":"ok"}`)[1:]...)
}

// (1) 宣言があれば review、(2) 宣言が無ければ answer。decider と text は同じ。宣言はその呼び出しにだけ効く。
func TestContractReviewKindNeedsTheDeclaration(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	d, _ := h.contract(reviewStart(t)...)
	id := runIDOf(t, d)
	if d.State != runstate.StatusWaiting || d.RequestedAction == nil || d.RequestedAction.Kind != actionAnswer {
		t.Fatalf("start (no declaration) = %+v action = %+v", d, d.RequestedAction)
	}
	plain, _ := h.contract("status", id)
	a := plain.RequestedAction
	if plain.State != runstate.StatusWaiting || a == nil || a.Kind != actionAnswer || a.Decider != contractParent ||
		!strings.Contains(a.Text, "harness contract resume "+id+" --unit main --input <respond|ready>") {
		t.Fatalf("status without --accept-kind = %+v action = %+v", plain, a)
	}
	for _, args := range [][]string{
		{"status", "--accept-kind", "review", id},
		{"status", "--accept-kind=review", id},
		{"status", id, "--accept-kind", "review"},
		{"status", "--accept-kind", "answer", "--accept-kind", "review", id},
	} {
		got, _ := h.contract(args...)
		r := got.RequestedAction
		if got.State != runstate.StatusWaiting || r == nil || r.Kind != actionReview || r.Decider != a.Decider || r.Text != a.Text || got.Summary != plain.Summary {
			t.Fatalf("contract %v = %+v action = %+v (want kind review, the decider and the text of %+v)", args, got, r, a)
		}
	}
	// 宣言は run に記録しない: 宣言した後の、宣言の無い status は answer のまま。
	if again, _ := h.contract("status", id); again.RequestedAction == nil || !reflect.DeepEqual(*again.RequestedAction, *a) {
		t.Fatalf("status without --accept-kind after a declared one = %+v", again.RequestedAction)
	}
	// 契約の kind 以外を宣言すると、引数の誤りとして failed の JSON（run_id は null）を返す。
	for _, args := range [][]string{{"status", "--accept-kind", "bogus", id}, {"resume", "--accept-kind", "approval", id, "--input", "ready"}, {"status", id, "--accept-kind"}} {
		bad, _ := h.contract(args...)
		if bad.State != runstate.StatusFailed || bad.RunID != nil || !strings.Contains(bad.Summary, "--accept-kind") {
			t.Errorf("contract %v = %+v", args, bad)
		}
	}
	// 誤った宣言はゲートを解いていない。
	if s, _ := h.contract("status", id); s.State != runstate.StatusWaiting {
		t.Fatalf("a refused declaration resolved the gate: %+v", s)
	}
}

// (6) review の待ちは resume --input respond|ready で解決できる（answer と同じ）。respond は同じゲートへ戻り、ready で終わる。
func TestContractReviewIsResolvedByResume(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := runIDOf(t, first2(h.contract(reviewStart(t)...)))
	// --note の値が --accept-kind と同じ綴りでも、宣言として取り除かない（note として渡る）。
	d, _ := h.contract("resume", "--accept-kind", "review", id, "--unit", "main", "--input", "respond", "--note", "--accept-kind")
	if d.State != runstate.StatusWaiting {
		t.Fatalf("resume --input respond = %+v", d)
	}
	s, _ := h.contract("status", "--accept-kind", "review", id)
	if s.State != runstate.StatusWaiting || s.RequestedAction == nil || s.RequestedAction.Kind != actionReview || s.RequestedAction.Decider != contractParent {
		t.Fatalf("status after respond = %+v action = %+v", s, s.RequestedAction)
	}
	d, _ = h.contract("resume", "--accept-kind", "review", id, "--input", "ready")
	if d.State != runstate.StatusSucceeded || d.RequestedAction != nil || !strings.Contains(d.Summary, "ready") {
		t.Fatalf("resume --input ready = %+v", d)
	}
	out, _, _ := h.run("status", id, "--json")
	v := decode[statusView](t, out)
	if v.Units[0].Outcomes["review"] != "ready" {
		t.Fatalf("outcomes = %+v", v.Units[0].Outcomes)
	}
	evs, _, err := runstate.ReadEvents(v.EventsFile)
	if err != nil {
		t.Fatal(err)
	}
	var notes []string
	for _, ev := range evs {
		if ev.GateResolved != nil {
			notes = append(notes, ev.GateResolved.Note)
		}
	}
	if len(notes) != 2 || notes[0] != "--accept-kind" {
		t.Fatalf("gate_resolved notes = %q (want the respond note \"--accept-kind\" passed as the note)", notes)
	}
}

// status --json の waiting[] は contract_kind を出す（contract はこの値を読み直して写す）。書かれていないゲートには出さない。
func TestStatusJSONCarriesTheContractKind(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := runIDOf(t, first2(h.contract(reviewStart(t)...)))
	out, _, _ := h.run("status", id, "--json")
	if w := decode[statusView](t, out).Waiting; len(w) != 1 || w[0].ContractKind != workflow.ContractKindReview || !strings.Contains(out, `"contract_kind": "review"`) {
		t.Fatalf("waiting = %+v\n%s", w, out)
	}
	id2 := runIDOf(t, first2(h.contract(gatesStart(t, "any")...)))
	if out, _, _ = h.run("status", id2, "--json"); strings.Contains(out, "contract_kind") {
		t.Fatalf("a gate without contract_kind shows one:\n%s", out)
	}
}

// 写像の単体テスト: (3) ほかの系統（ci-pending・interrupted・human-merge・承認）の kind は宣言しても変わらない。
// contract_kind の無い review という名前のゲートは answer のまま（ゲート名では決めない）。
func TestContractReviewKindMapping(t *testing.T) {
	gate := func(unit, name, typ, decider string, tty bool, ck string) waitingView {
		return waitingView{Unit: unit, Gate: name, Type: typ, Decider: decider, RequestedAction: "do " + name, Inputs: []string{"a", "b"}, RequiresTTY: tty, ContractKind: ck}
	}
	st := &runstate.State{RunID: "R-1", Workflow: runstate.WorkflowRef{ID: "ticket"}, Status: runstate.StatusWaiting}
	review := accepted{review: true}
	for _, c := range []struct {
		w             waitingView
		acc           accepted
		kind, decider string
	}{
		{gate("main", "review", "input", "any", false, "review"), review, "review", "parent"},
		{gate("main", "review", "input", "any", false, "review"), accepted{}, "answer", "parent"},
		{gate("main", "check", "input", "parent", false, "review"), review, "review", "parent"},
		{gate("main", "review", "input", "any", false, ""), review, "answer", "parent"},
		{gate("main", "ci-pending", "input", "any", false, ""), review, "answer", "parent"},
		{gate("main", workflow.InterruptedGate, "input", "any", false, ""), review, "answer", "parent"},
		{gate("main", "human-merge", "observe", "human", false, ""), review, "observe", "human"},
		{gate("main", "design-deviation", "input", "human", true, ""), review, "approve", "human"},
		{gate("main", "review-human", "input", "human", true, ""), review, "approve", "human"},
		{gate("main", "wait", "observe", "any", false, ""), review, "observe", "parent"},
	} {
		d := contractFromView(statusView{State: st, Waiting: []waitingView{c.w}}, "", c.acc)
		a := d.RequestedAction
		plain := contractFromView(statusView{State: st, Waiting: []waitingView{c.w}}, "", accepted{}).RequestedAction
		if a == nil || a.Kind != c.kind || a.Decider != c.decider || a.Text != plain.Text {
			t.Errorf("%s (contract_kind %q, accept %+v): %+v (text without the declaration: %q)", c.w.Gate, c.w.ContractKind, c.acc, a, plain.Text)
		}
	}
}

// (5) 複数の unit が待つとき、review を受け付ける呼び出しは approve → answer → review → observe の順で選ぶ（#374。
// 宣言の無い順に review を answer の直後へ差し込む）。宣言の無い呼び出しは今の順（approve → answer → observe。
// review のゲートは answer として unit の順）のまま。
func TestPickActionOrderWithReview(t *testing.T) {
	ans := waitingView{Unit: "ua", Gate: "ask", Type: "input", Decider: "parent", RequestedAction: "ask", Inputs: []string{"go"}}
	rev := waitingView{Unit: "ur", Gate: "review", Type: "input", Decider: "any", RequestedAction: "review", Inputs: []string{"respond", "ready"}, ContractKind: "review"}
	apr := waitingView{Unit: "up", Gate: "review-human", Type: "input", Decider: "human", RequestedAction: "approve", Inputs: []string{"ok"}, RequiresTTY: true}
	obs := waitingView{Unit: "uo", Gate: "human-merge", Type: "observe", Decider: "human", RequestedAction: "merge"}
	pick := func(acc accepted, ws ...waitingView) *requestedAction { return pickAction("R-1", ws, acc) }

	review := accepted{review: true}
	for _, c := range []struct {
		ws       []waitingView
		kind, at string
	}{
		{[]waitingView{obs, rev, ans, apr}, "approve", "unit up"}, // 宣言しても人の承認が先（#374）
		{[]waitingView{obs, apr, rev, ans}, "approve", "unit up"},
		{[]waitingView{obs, rev, ans}, "answer", "unit ua"}, // answer と review だけなら answer が先
		{[]waitingView{obs, ans, rev}, "answer", "unit ua"},
		{[]waitingView{obs, rev}, "review", "unit ur"},
		{[]waitingView{obs, apr}, "approve", "unit up"},
		{[]waitingView{obs}, "observe", "unit uo"},
	} {
		if a := pick(review, c.ws...); a.Kind != c.kind || !strings.Contains(a.Text, c.at) {
			t.Errorf("declared, waiting %d unit(s): %+v, want %s at %s", len(c.ws), a, c.kind, c.at)
		}
	}
	for _, c := range []struct {
		ws       []waitingView
		kind, at string
	}{
		{[]waitingView{obs, rev, ans, apr}, "approve", "unit up"},
		{[]waitingView{obs, apr, rev, ans}, "approve", "unit up"},
		{[]waitingView{obs, rev, ans}, "answer", "unit ur"}, // review のゲートも answer として、同順位は unit の順
		{[]waitingView{obs, ans, rev}, "answer", "unit ua"},
		{[]waitingView{obs}, "observe", "unit uo"},
	} {
		if a := pick(accepted{}, c.ws...); a.Kind != c.kind || !strings.Contains(a.Text, c.at) {
			t.Errorf("not declared, waiting %d unit(s): %+v, want %s at %s", len(c.ws), a, c.kind, c.at)
		}
	}
	if a := pick(review, obs, apr, rev, ans); !strings.Contains(a.Text, "3 other unit(s)") {
		t.Errorf("text = %q", a.Text)
	}
}

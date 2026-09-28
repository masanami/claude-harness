package cli

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// contractKeys は契約 v1 の JSON が持つキー（過不足なし）。
var contractKeys = "artifacts,contract_version,cost_usd,requested_action,run_id,state,summary"

// contract は harness contract <args> を実行し、終了コード 0 と契約 v1 の形を確かめて返す。
func (h *harness) contract(args ...string) (contractDoc, string) {
	h.t.Helper()
	out, errOut, code := h.run(append([]string{"contract"}, args...)...)
	if code != ExitOK {
		h.t.Fatalf("contract %v: exit %d, want 0\n%s\n%s", args, code, out, errOut)
	}
	raw := decode[map[string]json.RawMessage](h.t, out)
	keys := make([]string, 0, len(raw))
	for k := range raw {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if strings.Join(keys, ",") != contractKeys {
		h.t.Fatalf("contract %v: keys = %v\n%s", args, keys, out)
	}
	if string(raw["artifacts"]) == "null" {
		h.t.Fatalf("contract %v: artifacts must be an array\n%s", args, out)
	}
	d := decode[contractDoc](h.t, out)
	if d.ContractVersion != 1 {
		h.t.Fatalf("contract_version = %d", d.ContractVersion)
	}
	return d, errOut
}

func gatesStart(t *testing.T, outcome string) []string {
	return append([]string{"start"}, runArgs(t, "gates", fmt.Sprintf(`json={"outcome":%q}`, outcome), "log="+filepath.Join(t.TempDir(), "log"), "state=x")[1:]...)
}

func runIDOf(t *testing.T, d contractDoc) string {
	t.Helper()
	if d.RunID == nil || *d.RunID == "" {
		t.Fatalf("run_id is null: %+v", d)
	}
	return *d.RunID
}

// ゲートの種類と decider ごとの requested_action（§5.6 の表）。start は待機でも終了コード 0 で、待機は state で表す。
func TestContractRequestedActionPerGate(t *testing.T) {
	cases := []struct{ outcome, kind, decider, command string }{
		{"human", "approve", "human", "harness approve "},
		{"observe", "observe", "human", "harness contract resume "},
		{"parent", "answer", "parent", "harness contract resume "},
		{"any", "answer", "parent", "harness contract resume "},
	}
	for _, c := range cases {
		t.Run(c.outcome, func(t *testing.T) {
			h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
			d, _ := h.contract(gatesStart(t, c.outcome)...)
			id := runIDOf(t, d)
			a := d.RequestedAction
			if d.State != "waiting" || a == nil || a.Kind != c.kind || a.Decider != c.decider || !strings.Contains(a.Text, c.command+id) {
				t.Fatalf("doc = %+v action = %+v", d, a)
			}
			if d.CostUSD == nil || *d.CostUSD != 0 || len(d.Artifacts) != 0 {
				t.Fatalf("cost = %v artifacts = %v (no llm step and no workspace)", d.CostUSD, d.Artifacts)
			}
			// status も同じ写像を返す。
			s, _ := h.contract("status", id)
			if s.State != "waiting" || *s.RequestedAction != *a {
				t.Fatalf("status = %+v", s)
			}
		})
	}
}

// resume で進めた run は succeeded / failed を state で返し、終了コードは 0 のまま。終わった run の requested_action は null。
func TestContractResumeToTheEnd(t *testing.T) {
	for _, c := range []struct{ input, state, reason string }{{"go", "succeeded", "went"}, {"stop", "failed", "stopped"}} {
		h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
		id := runIDOf(t, first2(h.contract(gatesStart(t, "parent")...)))
		d, _ := h.contract("resume", id, "--input", c.input)
		if d.State != c.state || d.RequestedAction != nil || !strings.Contains(d.Summary, c.reason) {
			t.Fatalf("%s: doc = %+v", c.input, d)
		}
		s, _ := h.contract("status", id)
		if s.State != c.state || s.RequestedAction != nil {
			t.Fatalf("%s: status = %+v", c.input, s)
		}
	}
}

func first2(d contractDoc, _ string) contractDoc { return d }

// human の input ゲートは contract resume でも解決できない。run は待機のままなので state は waiting（failed にしない）、
// 拒否の理由は summary に入り、終了コードは 0。記録は何も増えない。
func TestContractResumeOfAHumanGateIsRefused(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	id := runIDOf(t, first2(h.contract(gatesStart(t, "human")...)))
	before := eventTypes(t, filepath.Join(state, "runs", id))
	d, errOut := h.contract("resume", id, "--input", "follow")
	if d.State != "waiting" || d.RequestedAction == nil || d.RequestedAction.Decider != "human" ||
		!strings.Contains(d.Summary, "resume cannot resolve it") || !strings.Contains(errOut, "resume cannot resolve it") {
		t.Fatalf("doc = %+v\n%s", d, errOut)
	}
	if after := eventTypes(t, filepath.Join(state, "runs", id)); after != before {
		t.Fatalf("a refused resume recorded events:\n%s\n%s", before, after)
	}
}

// cancel は停止した run の状態を同じ形で返す。終わった run の cancel は、その run の状態と理由を返す。
func TestContractCancel(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := runIDOf(t, first2(h.contract(gatesStart(t, "parent")...)))
	d, _ := h.contract("cancel", id)
	if d.State != "cancelled" || d.RequestedAction != nil || runIDOf(t, d) != id {
		t.Fatalf("cancel = %+v", d)
	}
	id2 := runIDOf(t, first2(h.contract(gatesStart(t, "parent")...)))
	h.contract("resume", id2, "--input", "go")
	d, _ = h.contract("cancel", id2)
	if d.State != "succeeded" || !strings.Contains(d.Summary, "nothing to cancel") {
		t.Fatalf("cancel of a finished run = %+v", d)
	}
}

// JSON を出せない失敗は無い: 引数の誤り・ワークフロー定義の誤り・見つからない run も failed の JSON と終了コード 0。
// run を始められなかった start と、run ID を読めなかった場合の run_id は null、見つからない run は渡された ID。
func TestContractFailuresStillPrintJSON(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	for _, c := range []struct {
		args  []string
		runID string // 空なら null
		why   string
	}{
		{nil, "", "needs a command"},
		{[]string{"approve", "R-1"}, "", "unknown contract command"},
		{[]string{"start"}, "", "run takes exactly one workflow"},
		{[]string{"start", "--workflow-dir", abs(t, testWorkflows), "--scripts-dir", abs(t, testScripts), "no-such-workflow"}, "", "workflow is not valid"},
		{append([]string{"start"}, runArgs(t, "gates", "log=x")[1:]...), "", "is required"}, // 必須の入力が無い
		{[]string{"status"}, "", "exactly one run id"},
		{[]string{"status", "R-nope"}, "R-nope", "R-nope"},
		{[]string{"resume", "--bogus", "R-nope"}, "", "unknown option --bogus"},
		{[]string{"resume", "R-nope", "--input", "go"}, "R-nope", "R-nope"},
		{[]string{"cancel", "R-nope"}, "R-nope", "R-nope"},
	} {
		d, _ := h.contract(c.args...)
		gotID := ""
		if d.RunID != nil {
			gotID = *d.RunID
		}
		if d.State != "failed" || gotID != c.runID || !strings.Contains(d.Summary, c.why) || d.CostUSD != nil || d.RequestedAction != nil {
			t.Errorf("contract %v = %+v", c.args, d)
		}
	}
}

// cost_usd は run の累計。claude が費用を報告しなかった実行は、付与した上限額を消費したものとして数え（Q15）、
// その旨を summary に書く。
func TestContractCost(t *testing.T) {
	for _, c := range []struct {
		result  string
		cost    float64
		unknown bool
	}{
		{passResult(0.4), 0.4, false},
		{`{"type":"result","subtype":"success","is_error":false,"session_id":"@SID@","structured_output":{"outcome":"pass","summary":"done"}}`, 2, true},
	} {
		fdir, fenv := fakeClaude(t)
		respond(t, fdir, 1, 0, c.result)
		h := newHarness(t, append(fenv, "HARNESS_STATE_DIR="+t.TempDir())...)
		d, _ := h.contract(append([]string{"start"}, runArgs(t, "llm", "issue=5")[1:]...)...)
		if d.State != "waiting" || d.CostUSD == nil || !near(*d.CostUSD, c.cost) || strings.Contains(d.Summary, "not reported") != c.unknown {
			t.Fatalf("doc = %+v cost = %v", d, d.CostUSD)
		}
	}
}

// 既存の run・status・resume の出力と終了コードは変わらない（待機は 3・状態は status --json の形）。
func TestContractLeavesTheHumanCommandsAlone(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := runIDOf(t, first2(h.contract(gatesStart(t, "parent")...)))
	out, _, code := h.run("status", id, "--json")
	if code != ExitOK || decode[statusView](t, out).Waiting[0].Gate != "ask-parent" {
		t.Fatalf("status exit %d\n%s", code, out)
	}
	out, _, code = h.run(runArgs(t, "gates", `json={"outcome":"parent"}`, "log=x", "state=x")...)
	if code != ExitWaiting || decode[statusView](t, out).Status != "waiting" {
		t.Fatalf("run exit %d\n%s", code, out)
	}
	_, _, code = h.run("resume", decode[statusView](t, out).RunID, "--input", "stop")
	if code != ExitFailed {
		t.Fatalf("resume to a failed run exit %d, want %d", code, ExitFailed)
	}
}

// 写像の単体テスト: 状態・ゲート・作業ツリー・予算から契約 v1 の値へ。
func TestContractFromView(t *testing.T) {
	gate := func(unit, name, typ, decider string, tty bool) waitingView {
		return waitingView{Unit: unit, Gate: name, Type: typ, Decider: decider, RequestedAction: "do " + name, Inputs: []string{"a", "b"}, RequiresTTY: tty}
	}
	st := func(status string, units ...*runstate.Unit) *runstate.State {
		return &runstate.State{RunID: "R-1", Workflow: runstate.WorkflowRef{ID: "ticket"}, Status: status, Units: units}
	}
	for _, status := range []string{"running", "waiting", "succeeded", "failed", "cancelled"} {
		d := contractFromView(statusView{State: st(status)}, "")
		if d.State != status || *d.RunID != "R-1" || d.RequestedAction != nil {
			t.Errorf("%s: %+v", status, d)
		}
	}

	// ゲート → requested_action（設計 §5.6 の表）。
	for _, c := range []struct {
		w             waitingView
		kind, decider string
	}{
		{gate("main", "design-deviation", "input", "human", true), "approve", "human"},
		{gate("main", "review-human", "input", "human", true), "approve", "human"},
		{gate("main", "human-merge", "observe", "human", false), "observe", "human"},
		{gate("main", "ci-pending", "input", "any", false), "answer", "parent"},
		{gate("main", "review", "input", "any", false), "answer", "parent"},
		{gate("main", "ask", "input", "parent", false), "answer", "parent"},
		{gate("main", "wait", "observe", "any", false), "observe", "parent"},
	} {
		d := contractFromView(statusView{State: st("waiting"), Waiting: []waitingView{c.w}}, "")
		a := d.RequestedAction
		if a == nil || a.Kind != c.kind || a.Decider != c.decider || !strings.Contains(a.Text, "do "+c.w.Gate) || !strings.Contains(a.Text, "gate "+c.w.Gate) {
			t.Errorf("%s: %+v", c.w.Gate, a)
		}
	}

	// 複数の unit が待っていれば、人の判断を最優先で出し、ほかの数を添える。
	d := contractFromView(statusView{State: st("waiting"), Waiting: []waitingView{
		gate("u1", "wait", "observe", "any", false), gate("u2", "ask", "input", "parent", false), gate("u3", "review-human", "input", "human", true)}}, "")
	if a := d.RequestedAction; a.Kind != "approve" || !strings.Contains(a.Text, "unit u3") || !strings.Contains(a.Text, "2 other unit(s)") {
		t.Errorf("multi-unit action = %+v", a)
	}

	// 成果物（PR・ブランチ・最新ラウンドの head）と費用（費用不明の実行を含む）。
	u := &runstate.Unit{Key: "main",
		Budget:    &runstate.Budget{LimitUSD: 30, SpentUSD: 7.5, UnknownCostCount: 1},
		Workspace: &runstate.Workspace{Branch: "feature/x", PRNumber: 7, PRURL: "https://github.com/o/r/pull/7", HeadSHAs: map[string]string{"1": "aaa", "10": "ccc", "2": "bbb"}}}
	d = contractFromView(statusView{State: st("succeeded", u)}, "")
	arts, _ := json.Marshal(d.Artifacts)
	if string(arts) != `[{"kind":"pr","ref":"https://github.com/o/r/pull/7"},{"kind":"branch","ref":"feature/x"},{"kind":"commit","ref":"ccc"}]` {
		t.Errorf("artifacts = %s", arts)
	}
	if d.CostUSD == nil || *d.CostUSD != 7.5 || !strings.Contains(d.Summary, "counts 1 launch(es) whose cost was not reported") {
		t.Errorf("cost = %v summary = %q", d.CostUSD, d.Summary)
	}
	u.Workspace.PRURL = ""
	if d = contractFromView(statusView{State: st("succeeded", u)}, ""); d.Artifacts[0] != (artifact{Kind: "pr", Ref: "#7"}) {
		t.Errorf("artifacts without a PR URL = %+v", d.Artifacts)
	}
}

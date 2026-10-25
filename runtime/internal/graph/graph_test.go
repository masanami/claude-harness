package graph

import (
	"bytes"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

const (
	repoWorkflows = "../../workflows"
	repoScripts   = "../../../plugin/scripts"
	testWorkflows = "../engine/testdata/workflows"
	testScripts   = "../engine/testdata/scripts"
)

func init() {
	// テスト用の定義（engine/testdata/workflows/gates.yaml）の observe ゲートが使う観測。
	workflow.RegisterObservation("fake-state", []string{"merged", "open", "closed"})
}

func load(t *testing.T, dir, scripts, id string) *workflow.Workflow {
	t.Helper()
	wf, err := workflow.LoadAndValidate(dir+"/"+id+".yaml", workflow.Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	return wf
}

func node(t *testing.T, g *Graph, id string) *Node {
	t.Helper()
	for i := range g.Nodes {
		if g.Nodes[i].ID == id {
			return &g.Nodes[i]
		}
	}
	t.Fatalf("no node %q", id)
	return nil
}

func edgesFrom(g *Graph, from, outcome string) []Edge {
	var out []Edge
	for _, e := range g.Edges {
		if e.From == from && e.Outcome == outcome {
			out = append(out, e)
		}
	}
	return out
}

// ticket.yaml の 19 ステップが定義の順に並び、終端はその後に初出の順で、同じ理由の終端は 1 つにまとまる（§3.2）。
func TestTicketNodes(t *testing.T) {
	g := Build(load(t, repoWorkflows, repoScripts, "ticket"), SourceWorkflowDir, "1.2.3")
	wantSteps := []string{"resolve", "analyze", "workspace", "implement", "fix", "commit", "e2e-route", "e2e", "publish", "ci",
		"ci-pending", "review", "respond", "review-human", "merge-route", "merge", "human-merge", "design-deviation", "cleanup"}
	var steps, terms []string
	for _, n := range g.Nodes {
		if n.Terminal() {
			terms = append(terms, n.ID)
			continue
		}
		if len(terms) > 0 {
			t.Fatalf("step %s comes after a terminal", n.ID)
		}
		steps = append(steps, n.ID)
	}
	if !reflect.DeepEqual(steps, wantSteps) {
		t.Fatalf("steps = %v", steps)
	}
	if g.Entry != "resolve" {
		t.Fatalf("entry = %q", g.Entry)
	}
	wantTerms := []string{"fail:base_missing", "fail:links_invalid", "fail:worktree_conflict", "fail:quality_gate",
		"fail:self_review_incomplete", "fail:commit", "fail:e2e", "fail:ci_red", "fail:ci_timeout", "fail:aborted_by_human",
		"fail:pr_closed", "done:merged", "done:merged_worktree_dirty"}
	if !reflect.DeepEqual(terms, wantTerms) {
		t.Fatalf("terminals = %v", terms)
	}
	into := 0
	for _, e := range g.Edges {
		if e.To == "fail:quality_gate" {
			into++
		}
	}
	if into != 2 {
		t.Fatalf("edges into fail:quality_gate = %d, want 2 (implement.failure and fix.failure)", into)
	}
	// 設計文書 §12 の数: 53 本（尽きたときの辺 3 本を含む）。
	if len(g.Edges) != 53 {
		t.Fatalf("edges = %d, want 53", len(g.Edges))
	}
	if n := node(t, g, "implement"); n.Kind != "llm" || n.Agent != "claude-harness:feature-implementer" || n.BudgetUSD != 15 ||
		FormatDuration(n.Timeout) != "90m" {
		t.Fatalf("implement = %+v", n)
	}
	if n := node(t, g, "merge-route"); n.Select == nil || n.Select.Value != "$steps.resolve.base_kind" {
		t.Fatalf("merge-route = %+v", n)
	}
}

// 人のゲートは名前ではなく decider で決まる。ticket.yaml では review-human・human-merge・design-deviation の 3 つで、
// input 型の 2 つだけが端末を要る（observe 型の human-merge は要らない）。
func TestTicketHumanGates(t *testing.T) {
	g := Build(load(t, repoWorkflows, repoScripts, "ticket"), SourceWorkflowDir, "1.2.3")
	var human, tty, gates []string
	for _, n := range g.Nodes {
		if n.Gate == nil {
			continue
		}
		gates = append(gates, n.ID)
		if n.Gate.Decider == workflow.DeciderHuman {
			human = append(human, n.ID)
		}
		if n.Gate.RequiresTTY {
			tty = append(tty, n.ID)
		}
	}
	if !reflect.DeepEqual(gates, []string{"ci-pending", "review", "review-human", "human-merge", "design-deviation"}) {
		t.Fatalf("gates = %v", gates)
	}
	if !reflect.DeepEqual(human, []string{"review-human", "human-merge", "design-deviation"}) {
		t.Fatalf("human gates = %v", human)
	}
	if !reflect.DeepEqual(tty, []string{"review-human", "design-deviation"}) {
		t.Fatalf("tty gates = %v", tty)
	}
	hm := node(t, g, "human-merge").Gate
	if hm.Observe == nil || *hm.Observe != "pr-state" || hm.Inputs != nil {
		t.Fatalf("human-merge gate = %+v", hm)
	}
}

// テスト用の定義（ゲートの名前が ticket と違う）でも、decider と型だけで人のゲートと端末の要否が決まる。
func TestHumanGatesFollowTheDecider(t *testing.T) {
	g := Build(load(t, testWorkflows, testScripts, "gates"), SourceWorkflowDir, "dev")
	want := map[string][2]bool{ // id → {human, requires_tty}
		"deviation": {true, true}, "merge-wait": {true, false}, "ask-parent": {false, false}, "ask-any": {false, false},
	}
	for id, w := range want {
		gt := node(t, g, id).Gate
		if (gt.Decider == workflow.DeciderHuman) != w[0] || gt.RequiresTTY != w[1] {
			t.Errorf("%s: decider %s requires_tty %v, want human=%v tty=%v", id, gt.Decider, gt.RequiresTTY, w[0], w[1])
		}
	}
	var buf bytes.Buffer
	WriteText(&buf, g, 0)
	for _, l := range strings.Split(buf.String(), "\n") {
		f := strings.Fields(l)
		if len(f) < 2 || f[1] != "gate" {
			continue
		}
		if strings.Contains(l, "[human]") != want[f[0]][0] || strings.Contains(l, "[tty]") != want[f[0]][1] {
			t.Errorf("text line for %s: %q", f[0], l)
		}
	}
}

// 上限つきの goto と retry は、通常の行き先と尽きたときの行き先の 2 本の辺になる（§3.3）。
func TestExhaustedEdgesAreSeparate(t *testing.T) {
	g := Build(load(t, repoWorkflows, repoScripts, "ticket"), SourceWorkflowDir, "dev")
	red := edgesFrom(g, "ci", "red")
	if len(red) != 2 ||
		!reflect.DeepEqual(red[0], Edge{From: "ci", Outcome: "red", Kind: "goto", To: "fix", Carries: []string{"failure"}, Limit: "rework"}) ||
		!reflect.DeepEqual(red[1], Edge{From: "ci", Outcome: "red", Kind: "fail", To: "fail:ci_red", Exhausted: &Exhausted{Limit: "rework"}}) {
		t.Fatalf("ci.red = %+v", red)
	}
	to := edgesFrom(g, "ci", "timeout")
	if len(to) != 2 ||
		!reflect.DeepEqual(to[0], Edge{From: "ci", Outcome: "timeout", Kind: "retry", To: "ci", Retry: 1}) ||
		!reflect.DeepEqual(to[1], Edge{From: "ci", Outcome: "timeout", Kind: "gate", To: "ci-pending", Exhausted: &Exhausted{Retry: 1}}) {
		t.Fatalf("ci.timeout = %+v", to)
	}
	// 上限の無い goto は 1 本のまま。
	if fd := edgesFrom(g, "design-deviation", "follow-decision"); len(fd) != 1 || fd[0].Kind != "goto" || fd[0].Limit != "" {
		t.Fatalf("design-deviation.follow-decision = %+v", fd)
	}
}

// 予約値は on に書かれたものだけが辺になり、書かれていないものは fail_closed に並ぶ（§3.4）。
func TestReservedOutcomes(t *testing.T) {
	g := Build(load(t, testWorkflows, testScripts, "timeout"), SourceWorkflowDir, "dev")
	n := node(t, g, "sleep")
	if !reflect.DeepEqual(n.FailClosed, []string{"step_error", "invalid_output", "budget_exhausted"}) {
		t.Fatalf("fail_closed = %v", n.FailClosed)
	}
	if e := edgesFrom(g, "sleep", "step_timeout"); len(e) != 1 || e[0].To != "done:timeout_routed" {
		t.Fatalf("step_timeout edge = %+v", e)
	}
	tk := Build(load(t, repoWorkflows, repoScripts, "ticket"), SourceWorkflowDir, "dev")
	for _, e := range tk.Edges {
		if workflow.IsReserved(e.Outcome) {
			t.Fatalf("ticket has no reserved outcome in on, but got edge %+v", e)
		}
	}
	if !reflect.DeepEqual(node(t, tk, "review").FailClosed, workflow.ReservedOutcomes) {
		t.Fatalf("review fail_closed = %v", node(t, tk, "review").FailClosed)
	}
}

// JSON の形（§3.1〜§3.3）: 段 1 では overrides・changes は空の配列、overridable・overridden は null、run は null。
// 節点は種類の持つフィールドだけを持つ。
func TestJSONShape(t *testing.T) {
	g := Build(load(t, repoWorkflows, repoScripts, "ticket"), SourceEmbedded, "1.2.3")
	b, err := json.Marshal(g)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	if doc["schema"] != SchemaV1 || doc["entry"] != "resolve" || doc["run"] != nil {
		t.Fatalf("top = %v %v %v", doc["schema"], doc["entry"], doc["run"])
	}
	if _, ok := doc["run"]; !ok {
		t.Fatal("run must be present (null)")
	}
	w := doc["workflow"].(map[string]any)
	if w["source"] != "embedded" || w["cli_version"] != "1.2.3" || w["hash"] == "" || w["effective_hash"] != w["hash"] {
		t.Fatalf("workflow = %v", w)
	}
	for _, k := range []string{"overrides", "changes"} {
		if a, ok := w[k].([]any); !ok || len(a) != 0 {
			t.Fatalf("workflow.%s = %#v, want []", k, w[k])
		}
	}
	if !reflect.DeepEqual(doc["limits"], []any{map[string]any{"name": "budget_usd", "value": 40.0}, map[string]any{"name": "rework", "value": 3.0}}) {
		t.Fatalf("limits = %v", doc["limits"])
	}
	if !reflect.DeepEqual(doc["builtin_gates"], []any{map[string]any{"id": "interrupted", "type": "input", "decider": "any",
		"inputs": []any{"rerun", "abort"}}}) {
		t.Fatalf("builtin_gates = %v", doc["builtin_gates"])
	}
	keys := func(m map[string]any) []string {
		var ks []string
		for k := range m {
			ks = append(ks, k)
		}
		sort.Strings(ks)
		return ks
	}
	wantKeys := map[string][]string{
		"resolve":     {"description", "fail_closed", "id", "kind", "skipped", "timeout"},
		"implement":   {"agent", "budget_usd", "description", "fail_closed", "id", "kind", "skipped", "timeout"},
		"review":      {"description", "fail_closed", "gate", "id", "kind", "skipped"},
		"e2e-route":   {"description", "fail_closed", "id", "kind", "select", "skipped"},
		"publish":     {"description", "fail_closed", "id", "kind", "skipped"},
		"done:merged": {"id", "kind", "reason"},
	}
	for _, n := range doc["nodes"].([]any) {
		m := n.(map[string]any)
		if want, ok := wantKeys[m["id"].(string)]; ok && !reflect.DeepEqual(keys(m), want) {
			t.Errorf("node %s keys = %v, want %v", m["id"], keys(m), want)
		}
		if m["id"] == "review" {
			gt := m["gate"].(map[string]any)
			if gt["observe"] != nil || gt["requires_tty"] != false || !reflect.DeepEqual(gt["inputs"], []any{"respond", "ready"}) {
				t.Errorf("review gate = %v", gt)
			}
		}
	}
	for _, e := range doc["edges"].([]any) {
		m := e.(map[string]any)
		for _, k := range []string{"overridable", "overridden"} {
			if v, ok := m[k]; !ok || v != nil {
				t.Fatalf("edge %v: %s must be null", m, k)
			}
		}
	}
}

func TestFormatDuration(t *testing.T) {
	for in, want := range map[string]string{"90m": "90m", "2m": "2m", "60s": "1m", "90s": "90s", "1500ms": "1.5s", "2h": "120m"} {
		d, err := time.ParseDuration(in)
		if err != nil {
			t.Fatal(err)
		}
		if got := FormatDuration(d); got != want {
			t.Errorf("FormatDuration(%s) = %q, want %q", in, got, want)
		}
	}
}

package graph

import (
	"bytes"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

func exec(step, status, outcome string) *runstate.StepExecution {
	return &runstate.StepExecution{Step: step, Status: status, Outcome: outcome}
}

// visited は全ラウンドのステップ実行をステップごとに数え、最初に実行した順に並べる。終わっていない・打ち切られた実行は
// 実行の状態を last_outcome に入れる（§4）。終わった run のゲートは待っているものとして出さない。
func TestNewRun(t *testing.T) {
	st := &runstate.State{RunID: "r1", Status: runstate.StatusFailed, Reason: "interrupted", Units: []*runstate.Unit{{
		Key: "main", Status: runstate.StatusFailed, CurrentStep: "implement", LimitsUsed: map[string]int{"rework": 1},
		Gate: &runstate.Gate{GateOpened: runstate.GateOpened{Gate: "interrupted"}},
		Rounds: []*runstate.Round{
			{Steps: []*runstate.StepExecution{exec("implement", "finished", "pass"), exec("ci", "finished", "red")}},
			{Steps: []*runstate.StepExecution{exec("fix", "finished", "pass"), exec("ci", "finished", "green"), exec("implement", "interrupted", "")}},
		},
	}}}
	called := false
	r := NewRun(st, nil, func(*runstate.Unit) Waiting { called = true; return Waiting{} })
	u := r.Units[0]
	if r.RunID != "r1" || r.Status != "failed" || r.Reason == nil || *r.Reason != "interrupted" || r.RunnerAlive != nil {
		t.Fatalf("run = %+v", r)
	}
	if called || u.Waiting != nil || u.Round != 2 || u.LimitsUsed["rework"] != 1 {
		t.Fatalf("unit = %+v (waiting called: %v)", u, called)
	}
	want := []Visit{{"implement", 2, "interrupted"}, {"ci", 2, "green"}, {"fix", 1, "pass"}}
	if len(u.Visited) != len(want) {
		t.Fatalf("visited = %+v", u.Visited)
	}
	for i := range want {
		if u.Visited[i] != want[i] {
			t.Fatalf("visited = %+v, want %+v", u.Visited, want)
		}
	}
	// limits_used は写しで、状態の map を共有しない（読み取りのコマンドは状態を変えない）。
	u.LimitsUsed["rework"] = 9
	if st.Units[0].LimitsUsed["rework"] != 1 {
		t.Fatal("limits_used shares the state's map")
	}

	st.Status = runstate.StatusWaiting
	st.Units[0].Status = runstate.StatusWaiting
	r = NewRun(st, nil, func(u *runstate.Unit) Waiting { return Waiting{Unit: u.Key, Gate: u.Gate.Gate} })
	if w := r.Units[0].Waiting; w == nil || w.Gate != "interrupted" || w.Unit != "main" {
		t.Fatalf("waiting = %+v", w)
	}
}

// unit が複数なら、行末の要約は unit ごとに key を付けて並べ、いまいるステップには > を付ける。
func TestTextRunMarksMultipleUnits(t *testing.T) {
	g := Build(load(t, testWorkflows, testScripts, "llm"), SourceWorkflowDir, "dev")
	g.Run = &Run{RunID: "r", Status: "waiting", Units: []RunUnit{
		{Key: "a", Status: "waiting", CurrentStep: "review", Round: 1, Visited: []Visit{{"implement", 1, "pass"}},
			Waiting: &Waiting{Gate: "review", Decider: "any", ResumeCommand: "harness resume r --unit a --input <respond|ready>"}},
		{Key: "b", Status: "running", CurrentStep: "fix", Round: 2, Visited: []Visit{{"implement", 1, "pass"}}},
	}}
	lines := text(g, 0)
	var steps []string
	for _, l := range stepLines(lines) {
		if l == "" {
			break
		}
		steps = append(steps, l)
	}
	if len(steps) != 3 || !strings.HasPrefix(steps[0], "* implement") || !strings.HasSuffix(steps[0], "(a: x1, last pass; b: x1, last pass)") ||
		!strings.HasPrefix(steps[1], "> review") || !strings.HasPrefix(steps[2], "> fix") || !strings.HasSuffix(steps[2], "(b: here)") {
		t.Fatalf("step lines:\n%s", strings.Join(steps, "\n"))
	}
	all := strings.Join(lines, "\n")
	for _, want := range []string{"run r unit a: waiting at review (decider any), round 1", "  resume: harness resume r --unit a --input <respond|ready>",
		"run r unit b: running at fix, round 2"} {
		if !strings.Contains(all, want) {
			t.Errorf("text does not contain %q:\n%s", want, all)
		}
	}
	// runner_alive が null（running でない・分からない）なら「誰も進めていない」とは書かない。
	if strings.Contains(all, "not alive") {
		t.Errorf("text says the runner is gone:\n%s", all)
	}
}

// Mermaid のラベルは " < > を実体参照にし、節点 id は n0… に置き換える。尽きたときの辺は点線、retry は自分へ戻る線。
func TestMermaidLabelsAndLinks(t *testing.T) {
	g := Build(load(t, testWorkflows, testScripts, "retry"), SourceWorkflowDir, "dev")
	var buf bytes.Buffer
	WriteMermaid(&buf, g)
	out := buf.String()
	if strings.Contains(out, "<=") || !strings.Contains(out, "#lt;=") || !strings.Contains(out, "-.->") {
		t.Fatalf("mermaid:\n%s", out)
	}
	if got := escape(`a"b<c>d`); got != "a#quot;b#lt;c#gt;d" {
		t.Fatalf("escape = %q", got)
	}
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) == 0 || strings.HasPrefix(f[0], "%%") || f[0] == "flowchart" || f[0] == "classDef" || f[0] == "class" {
			continue
		}
		if !strings.HasPrefix(f[0], "n") {
			t.Fatalf("a line does not start with a node id n<k>: %q", l)
		}
	}
}

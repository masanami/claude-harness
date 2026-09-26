package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// テスト用の観測: with.path のファイルの中身を outcome にする（PR の実状態を見る pr-state は PR-4）。
func init() {
	RegisterObserver("fake-state", []string{"merged", "open", "closed"}, func(_ context.Context, with map[string]json.RawMessage) (string, json.RawMessage, error) {
		var path string
		if err := json.Unmarshal(with["path"], &path); err != nil {
			return "", nil, err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return "", nil, err
		}
		state := strings.TrimSpace(string(data))
		obs, _ := json.Marshal(map[string]string{"state": state})
		return state, obs, nil
	})
}

// fake は偽の claude（testdata/scripts/fake-claude.sh）の置き場。
type fake struct {
	t   *testing.T
	dir string
}

func newFake(t *testing.T) *fake {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "responses"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_CLAUDE_DIR", dir)
	return &fake{t: t, dir: dir}
}

// respond は n 回目（0 なら既定）の応答を置く。
func (f *fake) respond(n int, code int, stdout string) {
	f.t.Helper()
	name := "default"
	if n > 0 {
		name = fmt.Sprint(n)
	}
	if err := os.WriteFile(filepath.Join(f.dir, "responses", name), []byte(fmt.Sprintf("%d\n%s\n", code, stdout)), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

// claudeResult は claude -p --output-format json の結果（2.1.283 で実測した形）を作る。cost が負なら total_cost_usd を入れない。
func claudeResult(outcome string, cost float64) string {
	c := ""
	if cost >= 0 {
		c = fmt.Sprintf(`"total_cost_usd":%v,`, cost)
	}
	return fmt.Sprintf(`{"type":"result","subtype":"success","is_error":false,"session_id":"@SID@",%s"structured_output":{"outcome":%q,"summary":"did %s"},"result":"{}"}`, c, outcome, outcome)
}

func (f *fake) calls() int {
	data, err := os.ReadFile(filepath.Join(f.dir, "count"))
	if err != nil {
		return 0
	}
	var n int
	fmt.Sscan(string(data), &n)
	return n
}

func (f *fake) argv(n int) []string {
	f.t.Helper()
	data, err := os.ReadFile(filepath.Join(f.dir, "calls", fmt.Sprintf("%d.argv", n)))
	if err != nil {
		f.t.Fatal(err)
	}
	return strings.Split(strings.TrimRight(string(data), "\n"), "\n")
}

func (f *fake) file(n int, ext string) string {
	f.t.Helper()
	data, err := os.ReadFile(filepath.Join(f.dir, "calls", fmt.Sprintf("%d.%s", n, ext)))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(data)
}

func flag(argv []string, name string) (string, bool) {
	for i, a := range argv {
		if a == name && i+1 < len(argv) {
			return argv[i+1], true
		}
	}
	return "", false
}

// start は run を開始して最初のゲートか終端まで進める。
func start(t *testing.T, name string, inputs map[string]any) (*runstate.State, *Engine) {
	t.Helper()
	scripts := testdata(t, "scripts")
	wf, err := workflow.LoadAndValidate(testdata(t, "workflows", name+".yaml"), workflow.Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	raw := map[string]json.RawMessage{}
	for k, v := range inputs {
		b, _ := json.Marshal(v)
		raw[k] = b
	}
	e, err := Start(StartParams{RunsDir: t.TempDir(), WF: wf, Inputs: raw, ScriptsDir: scripts, WorkflowDir: testdata(t, "workflows"), Cwd: t.TempDir(), Origin: "test"})
	if err != nil {
		t.Fatal(err)
	}
	e.ClaudeBin = testdata(t, "scripts", "fake-claude.sh")
	e.KillGrace, e.PollInterval = time.Second, 20*time.Millisecond
	t.Setenv("FAKE_CLAUDE_EVENTS", filepath.Join(e.Run.Dir, runstate.EventsFile))
	st, err := e.Loop(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return st, e
}

// resolve は別プロセスの resume を模して、run を開き直してゲートを解決する。
func resolve(t *testing.T, e *Engine, req Resolution) (*runstate.State, error) {
	t.Helper()
	st, _, err := e.Run.Load()
	if err != nil {
		t.Fatal(err)
	}
	e2, err := Reopen(e.Run, st)
	if err != nil {
		t.Fatal(err)
	}
	e2.ClaudeBin, e2.KillGrace, e2.PollInterval = e.ClaudeBin, e.KillGrace, e.PollInterval
	if req.Actor == "" {
		req.Actor = "resume"
	}
	if req.Channel == "" {
		req.Channel = "non-tty"
	}
	return e2.Resolve(context.Background(), req)
}

func mustResolve(t *testing.T, e *Engine, req Resolution) *runstate.State {
	t.Helper()
	st, err := resolve(t, e, req)
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func input(v string) Resolution { return Resolution{Input: v, HasInput: true} }

func events(t *testing.T, e *Engine) []runstate.Event {
	t.Helper()
	evs, _, err := runstate.ReadEvents(filepath.Join(e.Run.Dir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	return evs
}

func startedCount(t *testing.T, e *Engine, step string) int {
	n := 0
	for _, ev := range events(t, e) {
		if ev.StepStarted != nil && ev.StepStarted.Step == step {
			n++
		}
	}
	return n
}

func near(a, b float64) bool { d := a - b; return d < 1e-9 && d > -1e-9 }

// llm 種類: --session-id を起動前に記録し、--max-budget-usd に min(budget_usd, 残予算) を付け、
// 型付き出力（structured_output）を検証して遷移する。ゲートに達したら waiting で止まる。
func TestLLMLaunchAndGate(t *testing.T) {
	f := newFake(t)
	f.respond(1, 0, claudeResult("pass", 0.4))
	st, e := start(t, "llm", map[string]any{"issue": 42})
	if st.Status != runstate.StatusWaiting {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	u := st.Unit(MainUnit)
	x := u.Rounds[0].Steps[0]
	if x.Step != "implement" || x.Outcome != "pass" || x.SessionID == "" || x.PID == 0 {
		t.Fatalf("execution = %+v", x)
	}
	// 記録の順: step_started（session_id・付与額）→ step_process（PID）→ step_finished。
	var order []string
	for _, ev := range events(t, e) {
		switch {
		case ev.StepStarted != nil:
			order = append(order, "started:"+ev.StepStarted.SessionID)
		case ev.StepProcess != nil:
			order = append(order, "process")
		case ev.StepFinished != nil:
			order = append(order, "finished")
		}
	}
	if strings.Join(order, " ") != "started:"+x.SessionID+" process finished" {
		t.Fatalf("event order = %v", order)
	}
	if got := f.file(1, "recorded"); strings.TrimSpace(got) != "recorded" {
		t.Fatalf("the session id was not in the event log when claude started: %s", got)
	}
	argv := f.argv(1)
	for name, want := range map[string]string{
		"--session-id": x.SessionID, "--max-budget-usd": "2", "--output-format": "json", "--agent": "claude-harness:feature-implementer",
	} {
		if got, ok := flag(argv, name); !ok || got != want {
			t.Errorf("%s = %q, want %q (argv %v)", name, got, want, argv)
		}
	}
	if argv[0] != "-p" {
		t.Errorf("argv[0] = %q, want -p", argv[0])
	}
	if schema, _ := flag(argv, "--json-schema"); !strings.Contains(schema, `"enum":["pass","failure"]`) {
		t.Errorf("--json-schema = %s", schema)
	}
	if _, ok := flag(argv, "--resume"); ok {
		t.Error("a new session must not be resumed")
	}
	stdin := f.file(1, "stdin")
	if !strings.Contains(stdin, "Issue を実装し") || !strings.Contains(stdin, `"issue": 42`) || !strings.Contains(stdin, `"granted_usd": 2`) {
		t.Fatalf("prompt:\n%s", stdin)
	}
	if b := u.Budget; !near(b.SpentUSD, 0.4) || b.UnknownCostCount != 0 || !near(*x.CostUSD, 0.4) {
		t.Fatalf("budget = %+v cost = %v", b, x.CostUSD)
	}
	if u.Gate == nil || u.Gate.Gate != "review" || u.Rounds[0].EndedBy != "gate:review" || u.Gate.RequiresTTY {
		t.Fatalf("gate = %+v rounds = %+v", u.Gate, u.Rounds[0])
	}
}

// resume はゲートを解決して次のラウンドへ進め、閉じたラウンドのステップを再実行しない。
// continue は直前の session_id を --resume に渡し、報告されたセッションの累計から前回分を差し引いて数える。
func TestResumeContinuesSessionWithoutRerunningClosedRounds(t *testing.T) {
	f := newFake(t)
	f.respond(1, 0, claudeResult("pass", 0.4))
	f.respond(2, 0, claudeResult("pass", 0.7)) // --resume ではセッションの累計（0.4 + 0.3）が報告される
	_, e := start(t, "llm", map[string]any{"issue": 7})
	st := mustResolve(t, e, input("respond"))
	if st.Status != runstate.StatusWaiting {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	u := st.Unit(MainUnit)
	implSID := u.Rounds[0].Steps[0].SessionID
	if got, ok := flag(f.argv(2), "--resume"); !ok || got != implSID {
		t.Fatalf("--resume = %q, want the implement session %q", got, implSID)
	}
	if _, ok := flag(f.argv(2), "--session-id"); ok {
		t.Fatal("a continued session must not get a new --session-id")
	}
	if len(u.Rounds) != 2 || u.Rounds[1].Trigger != (runstate.Trigger{Kind: "gate", Gate: "review", Input: "respond"}) {
		t.Fatalf("rounds = %+v", u.Rounds)
	}
	fix := u.Rounds[1].Steps[0]
	if fix.Step != "fix" || !fix.Resume || fix.SessionID != implSID || !near(*fix.CostUSD, 0.3) || !near(u.Budget.SpentUSD, 0.7) {
		t.Fatalf("fix = %+v budget = %+v", fix, u.Budget)
	}
	if !strings.Contains(f.file(2, "stdin"), `"summary": "did pass"`) || !strings.Contains(f.file(2, "stdin"), `"input": "respond"`) {
		t.Fatalf("the continued prompt lacks the implement output or the round trigger:\n%s", f.file(2, "stdin"))
	}

	st = mustResolve(t, e, input("ready"))
	if st.Status != runstate.StatusSucceeded || st.Reason != "merged" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	if n := startedCount(t, e, "implement"); n != 1 {
		t.Fatalf("implement started %d times; a closed round must not be re-run", n)
	}
	if n := f.calls(); n != 2 {
		t.Fatalf("claude was called %d times, want 2", n)
	}
	res := st.Unit(MainUnit).Gates
	if len(res) != 2 || res[0].Resolution.Actor != "resume" || res[0].Resolution.Channel != "non-tty" || res[1].Resolution.Outcome != "ready" {
		t.Fatalf("gate history = %+v", res)
	}
}

// --max-budget-usd は min(ステップの budget_usd, 残予算)。残予算が最低額を下回れば起動せず budget_exhausted。
func TestBudgetGrantAndExhaustion(t *testing.T) {
	f := newFake(t)
	f.respond(1, 0, claudeResult("pass", 3.8)) // 残り 1.2 < fix の budget_usd 2
	f.respond(2, 0, claudeResult("pass", 4.9)) // 累計 3.8 → 4.9。残り 0.1
	_, e := start(t, "llm", map[string]any{"issue": 1})
	st := mustResolve(t, e, input("respond"))
	if got, _ := flag(f.argv(2), "--max-budget-usd"); got != "1.2" {
		t.Fatalf("--max-budget-usd = %s, want 1.2 (the remaining budget, smaller than budget_usd 2)", got)
	}
	if b := st.Unit(MainUnit).Budget; !near(b.SpentUSD, 4.9) || !near(b.RemainingUSD, 0.1) {
		t.Fatalf("budget = %+v", b)
	}
	st = mustResolve(t, e, input("respond"))
	if st.Status != runstate.StatusFailed || st.Reason != "budget_exhausted" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	if n := f.calls(); n != 2 {
		t.Fatalf("claude was called %d times; with 0.1 USD left it must not be launched", n)
	}
	x := st.Unit(MainUnit).CurrentRound().Steps[0]
	if x.Outcome != "budget_exhausted" || !x.Reserved || x.PID != 0 || x.CostUSD != nil {
		t.Fatalf("execution = %+v", x)
	}
}

func TestGrant(t *testing.T) {
	step := &workflow.Step{BudgetUSD: 2}
	cheap := &workflow.Step{BudgetUSD: 0.1}
	for _, c := range []struct {
		step         *workflow.Step
		limit, spent float64
		want         float64
		ok           bool
	}{
		{step, 5, 0, 2, true},
		{step, 5, 3.5, 1.5, true},
		{step, 5, 4.75, 0.25, true},  // ちょうど最低額
		{step, 5, 4.76, 0.24, false}, // 最低額を下回る
		{step, 5, 5.5, -0.5, false},  // 使い過ぎ（報告が上限を超えた）
		{cheap, 5, 4.9, 0.1, true},   // 最低額は min(budget_usd, MinLaunchUSD)
		{step, 0.3, 0, 0.3, true},    // 浮動小数の端数で残予算を超えない
	} {
		g, _, ok := grant(c.step, &runstate.Budget{LimitUSD: c.limit, SpentUSD: c.spent})
		if ok != c.ok || (ok && !near(g, c.want)) || g > c.limit-c.spent+1e-12 {
			t.Errorf("grant(budget %v, limit %v, spent %v) = %v, %v; want %v, %v", c.step.BudgetUSD, c.limit, c.spent, g, ok, c.want, c.ok)
		}
	}
}

// 費用が取れない結果（フィールド欠落・不正 JSON・非 0 終了）は、付与した上限額を消費したものとして数える（Q15）。
func TestUnknownCostIsChargedAtTheGrantedCap(t *testing.T) {
	cases := []struct {
		name    string
		code    int
		stdout  string
		outcome string
	}{
		{"missing total_cost_usd", 0, claudeResult("pass", -1), ""},
		{"cost is not a number", 0, strings.Replace(claudeResult("pass", 0.5), "0.5", `"0.5"`, 1), ""},
		{"not JSON", 0, "this is not json", "invalid_output"},
		{"non-zero exit with a cost", 1, claudeResult("pass", 0.5), "step_error"},
		{"non-zero exit with a cost above the cap", 1, claudeResult("pass", 2.3), "step_error"},
		{"error result", 0, strings.Replace(claudeResult("pass", 0.5), `"subtype":"success","is_error":false`, `"subtype":"error_max_budget_usd","is_error":true`, 1), "step_error"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFake(t)
			f.respond(1, c.code, c.stdout)
			st, _ := start(t, "llm", map[string]any{"issue": 1})
			u := st.Unit(MainUnit)
			x := u.Rounds[0].Steps[0]
			if c.name == "non-zero exit with a cost above the cap" {
				// 上限額を超えた報告は、分かっている額より少なく数えない（claude はターンの合間に上限を確かめるので超過しうる）。
				if !near(u.Budget.SpentUSD, 2.3) || u.Budget.UnknownCostCount != 1 || x.Outcome != "step_error" {
					t.Fatalf("budget = %+v execution = %+v", u.Budget, x)
				}
				return
			}
			if c.name == "error result" {
				// is_error でも費用が報告されていれば、それを数える（費用は取れている）。
				if !near(u.Budget.SpentUSD, 0.5) || u.Budget.UnknownCostCount != 0 || x.Outcome != "step_error" {
					t.Fatalf("budget = %+v execution = %+v", u.Budget, x)
				}
				return
			}
			if !near(u.Budget.SpentUSD, 2) || u.Budget.UnknownCostCount != 1 || !x.CostUnknown || !near(*x.CostUSD, 2) {
				t.Fatalf("budget = %+v execution cost = %v unknown = %v", u.Budget, x.CostUSD, x.CostUnknown)
			}
			if c.outcome != "" && (x.Outcome != c.outcome || st.Status != runstate.StatusFailed) {
				t.Fatalf("outcome = %s status = %s", x.Outcome, st.Status)
			}
		})
	}
}

// 継続したセッションの累計が前回の報告より小さい（不整合）なら、費用不明として上限額で数える。
func TestInconsistentSessionTotalIsUnknown(t *testing.T) {
	f := newFake(t)
	f.respond(1, 0, claudeResult("pass", 0.4))
	f.respond(2, 0, claudeResult("pass", 0.1))
	_, e := start(t, "llm", map[string]any{"issue": 1})
	st := mustResolve(t, e, input("respond"))
	b := st.Unit(MainUnit).Budget
	if !near(b.SpentUSD, 2.4) || b.UnknownCostCount != 1 {
		t.Fatalf("budget = %+v", b)
	}
}

// 型付き出力が無い・スキーマに合わない結果は invalid_output（費用は取れているので数える）。
func TestStructuredOutputIsValidated(t *testing.T) {
	for name, stdout := range map[string]string{
		"no structured_output": `{"type":"result","subtype":"success","is_error":false,"session_id":"@SID@","total_cost_usd":0.3,"result":"pass"}`,
		"unknown enum value":   strings.Replace(claudeResult("pass", 0.3), `"outcome":"pass"`, `"outcome":"maybe"`, 1),
		"extra field":          strings.Replace(claudeResult("pass", 0.3), `"summary"`, `"extra":1,"summary"`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			f := newFake(t)
			f.respond(1, 0, stdout)
			st, _ := start(t, "llm", map[string]any{"issue": 1})
			x := st.Unit(MainUnit).Rounds[0].Steps[0]
			if st.Status != runstate.StatusFailed || x.Outcome != "invalid_output" || !near(*x.CostUSD, 0.3) || x.CostUnknown {
				t.Fatalf("status = %s execution = %+v", st.Status, x)
			}
		})
	}
}

// ゲートの解決経路（§5.3・Q9・N1）: TTY を要求するのは input 型かつ decider: human のゲートだけ。
func TestGateResolutionPaths(t *testing.T) {
	route := func(t *testing.T, to string) (*Engine, string, string) {
		t.Helper()
		dir := t.TempDir()
		log, state := filepath.Join(dir, "log"), filepath.Join(dir, "state")
		st, e := start(t, "gates", map[string]any{"json": fmt.Sprintf(`{"outcome":%q}`, to), "log": log, "state": state})
		if st.Status != runstate.StatusWaiting {
			t.Fatalf("status = %s (%s)", st.Status, st.Reason)
		}
		return e, log, state
	}
	refusedWith := func(t *testing.T, err error, want string) {
		t.Helper()
		var ref *RefusedError
		if !errors.As(err, &ref) || !strings.Contains(err.Error(), want) {
			t.Fatalf("err = %v, want a refusal containing %q", err, want)
		}
	}

	t.Run("input x human: resume cannot, approve needs a tty", func(t *testing.T) {
		e, log, _ := route(t, "human")
		st, _, _ := e.Run.Load()
		if g := st.Unit(MainUnit).Gate; g == nil || !g.RequiresTTY {
			t.Fatalf("gate = %+v", g)
		}
		_, err := resolve(t, e, Resolution{Input: "follow", HasInput: true, Note: "keep the decision", HasNote: true, Actor: "resume"})
		refusedWith(t, err, "harness approve")
		_, err = resolve(t, e, Resolution{Input: "follow", HasInput: true, Note: "x", HasNote: true, Actor: "approve", Channel: "non-tty"})
		refusedWith(t, err, "from a terminal")
		_, err = resolve(t, e, Resolution{Input: "follow", HasInput: true, Actor: "approve", Channel: "tty"})
		refusedWith(t, err, "give --note")
		if n := len(events(t, e)); n == 0 || events(t, e)[n-1].Type != runstate.EvGateOpened {
			t.Fatal("a refused resolution must not record anything")
		}
		st = mustResolve(t, e, Resolution{Input: "follow", HasInput: true, Note: "follow the decision in the ticket", HasNote: true, Actor: "approve", User: "someone", Channel: "tty"})
		if st.Status != runstate.StatusSucceeded || st.Reason != "followed" {
			t.Fatalf("status = %s (%s)", st.Status, st.Reason)
		}
		r := st.Unit(MainUnit).Gates[0].Resolution
		if r.Actor != "approve" || r.Channel != "tty" || r.User != "someone" || r.Note != "follow the decision in the ticket" {
			t.Fatalf("resolution = %+v", r)
		}
		if data, _ := os.ReadFile(log); !strings.Contains(string(data), "--failure follow the decision in the ticket") {
			t.Fatalf("$gate.note did not reach the next step: %s", data)
		}
	})

	t.Run("observe x human: no tty, outcome is observed", func(t *testing.T) {
		e, _, state := route(t, "observe")
		_, err := resolve(t, e, Resolution{Input: "merged", HasInput: true})
		refusedWith(t, err, "takes no --input")
		_, err = resolve(t, e, Resolution{})
		refusedWith(t, err, "observation fake-state failed")
		os.WriteFile(state, []byte("open\n"), 0o644)
		st := mustResolve(t, e, Resolution{})
		u := st.Unit(MainUnit)
		if st.Status != runstate.StatusWaiting || u.Gate == nil || u.Gate.Gate != "merge-wait" || len(u.Rounds) != 1 {
			t.Fatalf("still open: status = %s gate = %+v rounds = %d", st.Status, u.Gate, len(u.Rounds))
		}
		os.WriteFile(state, []byte("merged\n"), 0o644)
		st = mustResolve(t, e, Resolution{})
		if st.Status != runstate.StatusSucceeded || st.Reason != "merged" {
			t.Fatalf("status = %s (%s)", st.Status, st.Reason)
		}
		r := st.Unit(MainUnit).Gates[1].Resolution
		if r.Channel != "non-tty" || r.Actor != "resume" || string(r.Observed) != `{"state":"merged"}` {
			t.Fatalf("resolution = %+v", r)
		}
	})

	for _, to := range []string{"parent", "any"} {
		t.Run("input x "+to+": resume without a tty", func(t *testing.T) {
			e, _, _ := route(t, to)
			_, err := resolve(t, e, input("nope"))
			refusedWith(t, err, "does not accept")
			_, err = resolve(t, e, Resolution{})
			refusedWith(t, err, "give --input")
			st := mustResolve(t, e, input("go"))
			if st.Status != runstate.StatusSucceeded || st.Unit(MainUnit).Gates[0].Resolution.Channel != "non-tty" {
				t.Fatalf("status = %s gates = %+v", st.Status, st.Unit(MainUnit).Gates)
			}
		})
	}
}

// resume は開始時と定義が変わった run を続けない（§7.3）。
func TestReopenRefusesAChangedDefinition(t *testing.T) {
	dir := t.TempDir()
	for _, p := range []string{"llm.yaml", "prompts/implement.md", "prompts/fix.md", "schemas/impl.json"} {
		data, err := os.ReadFile(testdata(t, "workflows", p))
		if err != nil {
			t.Fatal(err)
		}
		os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o755)
		os.WriteFile(filepath.Join(dir, p), data, 0o644)
	}
	scripts := testdata(t, "scripts")
	wf, err := workflow.LoadAndValidate(filepath.Join(dir, "llm.yaml"), workflow.Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	f := newFake(t)
	f.respond(1, 0, claudeResult("pass", 0.1))
	e, err := Start(StartParams{RunsDir: t.TempDir(), WF: wf, Inputs: map[string]json.RawMessage{"issue": json.RawMessage("1")}, ScriptsDir: scripts, Cwd: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	e.ClaudeBin = testdata(t, "scripts", "fake-claude.sh")
	if _, err := e.Loop(context.Background()); err != nil {
		t.Fatal(err)
	}
	f2, _ := os.OpenFile(filepath.Join(dir, "llm.yaml"), os.O_APPEND|os.O_WRONLY, 0o644)
	f2.WriteString("# changed\n")
	f2.Close()
	st, _, _ := e.Run.Load()
	if _, err := Reopen(e.Run, st); err == nil || !strings.Contains(err.Error(), "changed since the run started") {
		t.Fatalf("err = %v", err)
	}
}

// timeout・停止で終わった llm の実行は費用が得られないので、付与した上限額を消費したものとして数える。
func TestTimeoutAndCancelAreChargedAtTheGrantedCap(t *testing.T) {
	t.Run("timeout", func(t *testing.T) {
		f := newFake(t)
		os.WriteFile(filepath.Join(f.dir, "responses", "1.sleep"), nil, 0o644)
		st, _ := start(t, "llm-timeout", nil)
		u := st.Unit(MainUnit)
		x := u.Rounds[0].Steps[0]
		if st.Status != runstate.StatusFailed || x.Outcome != "step_timeout" || !x.CostUnknown || !near(u.Budget.SpentUSD, 2) || u.Budget.UnknownCostCount != 1 {
			t.Fatalf("status = %s execution = %+v budget = %+v", st.Status, x, u.Budget)
		}
	})
	t.Run("cancel", func(t *testing.T) {
		f := newFake(t)
		os.WriteFile(filepath.Join(f.dir, "responses", "1.sleep"), nil, 0o644)
		scripts := testdata(t, "scripts")
		wf, err := workflow.LoadAndValidate(testdata(t, "workflows", "llm.yaml"), workflow.Options{ScriptsDir: scripts})
		if err != nil {
			t.Fatal(err)
		}
		e, err := Start(StartParams{RunsDir: t.TempDir(), WF: wf, Inputs: map[string]json.RawMessage{"issue": json.RawMessage("1")}, ScriptsDir: scripts, Cwd: t.TempDir()})
		if err != nil {
			t.Fatal(err)
		}
		e.ClaudeBin = testdata(t, "scripts", "fake-claude.sh")
		e.KillGrace, e.PollInterval = time.Second, 20*time.Millisecond
		done := make(chan *runstate.State, 1)
		go func() {
			st, err := e.Loop(context.Background())
			if err != nil {
				t.Error(err)
			}
			done <- st
		}()
		waitFile(t, filepath.Join(f.dir, "pids"))
		os.WriteFile(filepath.Join(e.Run.Dir, runstate.CancelFile), nil, 0o644)
		var st *runstate.State
		select {
		case st = <-done:
		case <-time.After(20 * time.Second):
			t.Fatal("the run did not stop")
		}
		u := st.Unit(MainUnit)
		x := u.Rounds[0].Steps[0]
		if st.Status != runstate.StatusCancelled || x.Status != "cancelled" || !x.CostUnknown || !near(u.Budget.SpentUSD, 2) || u.Budget.UnknownCostCount != 1 {
			t.Fatalf("status = %s execution = %+v budget = %+v", st.Status, x, u.Budget)
		}
		assertDead(t, filepath.Join(f.dir, "pids"))
	})
}

// runner が claude を起動した直後、PID を記録する前に落ちた場合: PID の無い実行でも、argv の session_id から
// 生きている子を見つけ、status はそれを打ち切らず、resume（StopOrphans）が止めてから interrupted にする。
func TestOrphanWithoutARecordedPID(t *testing.T) {
	dead := exec.Command("true")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	run, err := runstate.Create(t.TempDir(), "r1")
	if err != nil {
		t.Fatal(err)
	}
	sid := newUUID()
	granted := 2.0
	if _, err := run.Append(
		runstate.Event{Type: runstate.EvRunStarted, RunStarted: &runstate.RunStarted{RunID: "r1", Inputs: map[string]json.RawMessage{},
			Limits: map[string]float64{"budget_usd": 5}, PID: dead.Process.Pid, Units: []string{MainUnit}, EntryStep: "implement"}},
		runstate.Event{Type: runstate.EvRoundStarted, RoundStarted: &runstate.RoundStarted{Unit: MainUnit, Round: 1, Trigger: runstate.Trigger{Kind: "start"}}},
		runstate.Event{Type: runstate.EvStepStarted, StepStarted: &runstate.StepStarted{Unit: MainUnit, Step: "implement", Attempt: 1, SessionID: sid, BudgetGrantedUSD: &granted}},
	); err != nil {
		t.Fatal(err)
	}
	// 偽の claude の代わりに、argv に session_id を持つプロセスを自分のプロセスグループで起動する。
	child := exec.Command("bash", "-c", "sleep 60; :", sid) // 「; :」で bash が sleep へ exec せず argv に sid が残る
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	go child.Wait()
	defer syscall.Kill(-child.Process.Pid, syscall.SIGKILL)
	// fork から exec までの間は argv がまだ bash のものではないので、見えるまで待つ。
	for deadline := time.Now().Add(5 * time.Second); len(sessionProcesses(sid)) == 0 && time.Now().Before(deadline); {
		time.Sleep(10 * time.Millisecond)
	}

	st, err := Interrupt(run)
	if err != nil {
		t.Fatal(err)
	}
	if st.Unit(MainUnit).Running() == nil {
		t.Fatal("a step whose claude is still alive must not be interrupted")
	}
	StopOrphans(st, time.Second)
	deadline := time.Now().Add(5 * time.Second)
	for runstate.Alive(child.Process.Pid) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if runstate.Alive(child.Process.Pid) {
		t.Fatal("StopOrphans did not stop the claude found by its session id")
	}
	st, err = Interrupt(run)
	if err != nil {
		t.Fatal(err)
	}
	u := st.Unit(MainUnit)
	if x := u.Rounds[0].Steps[0]; x.Status != "interrupted" || u.Gate == nil || u.Gate.Gate != workflow.InterruptedGate || !near(u.Budget.SpentUSD, 2) {
		t.Fatalf("execution = %+v gate = %+v budget = %+v", x, u.Gate, u.Budget)
	}
}

// approve の確認の後にゲートが開き直していたら（別の解決で進み、また同じゲートに来た）、見ていない文脈を解決しない。
func TestResolutionIsBoundToTheGateInstance(t *testing.T) {
	st, e := start(t, "gates", map[string]any{"json": `{"outcome":"human"}`, "log": filepath.Join(t.TempDir(), "log"), "state": "x"})
	shown := st.Unit(MainUnit).Gate.OpenedAt
	_, err := resolve(t, e, Resolution{Input: "abort", HasInput: true, Actor: "approve", Channel: "tty", GateOpenedAt: shown + "x"})
	var ref *RefusedError
	if !errors.As(err, &ref) || !strings.Contains(err.Error(), "reopened") {
		t.Fatalf("err = %v", err)
	}
	st = mustResolve(t, e, Resolution{Input: "abort", HasInput: true, Actor: "approve", Channel: "tty", GateOpenedAt: shown})
	if st.Status != runstate.StatusFailed || st.Reason != "aborted_by_human" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
}

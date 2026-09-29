package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// predictFixture は predict-conflicts を偽の claude・gh（Issue 番号で応答を引く）と一時リポジトリで通す準備（Issue #288）。
type predictFixture struct {
	h          *harness
	repo       string
	fdir, gdir string
	state      string
}

func newPredictFixture(t *testing.T) *predictFixture {
	t.Helper()
	_, repo, _ := tempRepo(t)
	if err := os.MkdirAll(filepath.Join(repo, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	fdir, gdir, bin, state, data := t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(fdir, "responses"), 0o755); err != nil {
		t.Fatal(err)
	}
	fakeGh := abs(t, "testdata/fake-gh-predict.sh")
	if err := os.Symlink(fakeGh, filepath.Join(bin, "gh")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gdir, "repo"), []byte("acme/widgets\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, "FAKE_CLAUDE_DIR="+fdir, "HARNESS_CLAUDE_BIN="+abs(t, "testdata/fake-claude-predict.sh"),
		"FAKE_GH_DIR="+gdir, "HARNESS_GH_BIN="+fakeGh, "HARNESS_STATE_DIR="+state, "HARNESS_DATA_DIR="+data,
		"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	h.cwd = filepath.Join(repo, "sub") // サブディレクトリから起動しても、探索はチェックアウトのルートで行う
	return &predictFixture{h: h, repo: repo, fdir: fdir, gdir: gdir, state: state}
}

func (f *predictFixture) issue(t *testing.T, n int, body string) {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"number": n, "title": fmt.Sprintf("Issue %d", n), "body": body, "state": "OPEN"})
	if err := os.WriteFile(filepath.Join(f.gdir, fmt.Sprintf("issue.%d.json", n)), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func (f *predictFixture) predicts(t *testing.T, n int, files []string, dependsOn []int, cost float64) {
	t.Helper()
	respond(t, f.fdir, n, 0, claudeStructured(map[string]any{"outcome": "ok", "predicted_files": files, "depends_on": dependsOn}, cost))
}

func (f *predictFixture) claudeCalls(t *testing.T) []string {
	t.Helper()
	m, _ := filepath.Glob(filepath.Join(f.fdir, "calls", "*.argv"))
	return m
}

func (f *predictFixture) runs(t *testing.T) []string {
	t.Helper()
	ids, err := runstate.List(filepath.Join(f.state, "runs"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return ids
}

func (f *predictFixture) predict(t *testing.T, embedded bool, args ...string) (predictionDoc, string) {
	t.Helper()
	full := []string{"predict-conflicts"}
	if !embedded {
		full = append(full, "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts))
	}
	out, errOut, code := f.h.run(append(full, args...)...)
	if code != ExitOK {
		t.Fatalf("predict-conflicts exit %d (want 0 whenever it printed JSON)\n%s\n%s", code, out, errOut)
	}
	d := decode[predictionDoc](t, out)
	if d.Schema != PredictionSchema {
		t.Fatalf("schema %q", d.Schema)
	}
	return d, out
}

// 3 件の予測: Issue ごとに 1 run（本文の取得 → issue-conflict-predictor）を起動し、組の共有ファイル（lockfile の印）・
// 依存の向き・根拠を決定的に出す。作業ツリー・ブランチ・Issue は変更しない。定義は作業ツリーと埋め込みの両方で通す。
func TestPredictConflicts(t *testing.T) {
	t.Run("working tree definitions", func(t *testing.T) { predictThree(t, false) })
	t.Run("embedded definitions", func(t *testing.T) { predictThree(t, true) })
}

func predictThree(t *testing.T, embedded bool) {
	f := newPredictFixture(t)
	f.issue(t, 10, "widget を足す。#11 の後で")
	f.issue(t, 11, "widget の土台")
	f.issue(t, 12, "docs")
	f.predicts(t, 10, []string{"./a.go", "go.sum", "b.go", "a.go"}, []int{11, 10}, 0.25)
	f.predicts(t, 11, []string{"a.go", "c.go", "go.sum"}, []int{}, 0.5)
	f.predicts(t, 12, []string{"docs/x.md"}, []int{10, 99}, 0.125)
	head := git(t, f.repo, "rev-parse", "HEAD")

	d, raw := f.predict(t, embedded, "10", "#11", "12")
	if d.Error != nil || !d.Complete {
		t.Fatalf("error %v complete %v\n%s", d.Error, d.Complete, raw)
	}
	if d.Repository == nil || *d.Repository != "acme/widgets" || d.HeadSHA == nil || *d.HeadSHA != head {
		t.Fatalf("repository %v head %v (want %s)", d.Repository, d.HeadSHA, head)
	}
	if d.Budget.LimitUSD != 3 || d.Budget.PerIssueUSD != 1 || d.CostUSD != 0.875 || d.UnknownCostCount != 0 {
		t.Fatalf("budget %+v cost %v unknown %d", d.Budget, d.CostUSD, d.UnknownCostCount)
	}
	want := []issuePrediction{
		{Issue: 10, Status: issuePredicted, PredictedFiles: []string{"a.go", "go.sum", "b.go"}, DependsOn: []int{11}, CostUSD: 0.25},
		{Issue: 11, Status: issuePredicted, PredictedFiles: []string{"a.go", "c.go", "go.sum"}, DependsOn: []int{}, CostUSD: 0.5},
		{Issue: 12, Status: issuePredicted, PredictedFiles: []string{"docs/x.md"}, DependsOn: []int{10, 99}, CostUSD: 0.125},
	}
	if g, w := jsonOf(t, d.Issues), jsonOf(t, want); g != w {
		t.Fatalf("issues\n got %s\nwant %s", g, w)
	}
	if len(d.Pairs) != 3 {
		t.Fatalf("pairs = %d", len(d.Pairs))
	}
	p := d.Pairs[0] // 10 × 11: a.go と go.sum（lockfile の印）を共有し、10 が 11 に依存する（11 が先）
	if p.Issues != [2]int{10, 11} || p.Status != pairPredicted ||
		jsonOf(t, p.SharedFiles) != `[{"path":"a.go","merge_friendly":false},{"path":"go.sum","merge_friendly":true}]` ||
		p.Dependency.First == nil || *p.Dependency.First != 11 || jsonOf(t, p.Dependency.Stated) != `[{"issue":10,"depends_on":11}]` ||
		len(p.Evidence) != 2 || p.Evidence[0].Issue != 10 || p.Evidence[1].Issue != 11 || jsonOf(t, p.Evidence[1].PredictedFiles) != `["a.go","c.go","go.sum"]` {
		t.Fatalf("pair 10x11 = %s", jsonOf(t, p))
	}
	p = d.Pairs[1] // 10 × 12: 共有なし、12 が 10 に依存する（10 が先）
	if p.Issues != [2]int{10, 12} || len(p.SharedFiles) != 0 || p.Dependency.First == nil || *p.Dependency.First != 10 ||
		jsonOf(t, p.Dependency.Stated) != `[{"issue":12,"depends_on":10}]` {
		t.Fatalf("pair 10x12 = %s", jsonOf(t, p))
	}
	p = d.Pairs[2] // 11 × 12: 共有も依存も無い
	if p.Issues != [2]int{11, 12} || p.Status != pairPredicted || len(p.SharedFiles) != 0 || p.Dependency.First != nil || len(p.Dependency.Stated) != 0 {
		t.Fatalf("pair 11x12 = %s", jsonOf(t, p))
	}
	// 汎用の語彙だけ: harness の step id・ワークフロー名・判断値を出さない。
	for _, internal := range []string{`"fetch"`, `"predict"`, "conflict-predict-issue", `"outcome"`, "session"} {
		if strings.Contains(raw, internal) {
			t.Fatalf("output leaks %s:\n%s", internal, raw)
		}
	}

	// 予測はチェックアウトのルートで、道具を Read・Glob・Grep に絞ったエージェントとして、1 件分の上限で起動した。
	for _, n := range []int{10, 11, 12} {
		argv := readFile(t, filepath.Join(f.fdir, "calls", fmt.Sprintf("%d.argv", n)))
		if !strings.Contains(argv, "--agent\nclaude-harness:issue-conflict-predictor\n") || !strings.Contains(argv, "--max-budget-usd\n1\n") {
			t.Fatalf("issue %d argv:\n%s", n, argv)
		}
		if pwd := strings.TrimSpace(readFile(t, filepath.Join(f.fdir, "calls", fmt.Sprintf("%d.pwd", n)))); pwd != f.repo {
			t.Fatalf("issue %d ran in %s, want %s", n, pwd, f.repo)
		}
	}
	if stdin := readFile(t, filepath.Join(f.fdir, "calls", "10.stdin")); !strings.Contains(stdin, `widget を足す。#11 の後で`) {
		t.Fatalf("the issue body is not in the prompt:\n%s", stdin)
	}
	if n := len(f.runs(t)); n != 3 {
		t.Fatalf("runs = %d, want one per issue", n)
	}
	// 読み取り専用: gh は Issue と repo を読んだだけ。作業ツリー・ブランチ・HEAD は変わっていない。
	for _, line := range strings.Split(strings.TrimSpace(readFile(t, filepath.Join(f.gdir, "calls"))), "\n") {
		if !strings.HasPrefix(line, "issue\tview\t") && !strings.HasPrefix(line, "repo\tview\t") {
			t.Fatalf("gh was called with %q", line)
		}
	}
	if s := git(t, f.repo, "status", "--porcelain"); s != "" {
		t.Fatalf("the working tree changed:\n%s", s)
	}
	if b := git(t, f.repo, "branch", "--format=%(refname:short)"); b != "main" || git(t, f.repo, "rev-parse", "HEAD") != head {
		t.Fatalf("branches %q / HEAD moved", b)
	}
}

// 口全体の予算: 1 件分ずつ起動前に確保し、残りが 1 件分を下回った Issue は起動せず budget_exhausted にする（fail-closed）。
// 予測の無い Issue を含む組は unknown。
func TestPredictConflictsBudget(t *testing.T) {
	f := newPredictFixture(t)
	for _, n := range []int{1, 2, 3} {
		f.issue(t, n, "body")
		f.predicts(t, n, []string{"a.go"}, []int{}, 0.1)
	}
	d, raw := f.predict(t, false, "--max-budget-usd", "1.5", "1", "2", "3")
	if d.Error != nil || d.Complete || d.Budget.LimitUSD != 1.5 || d.CostUSD != 0.1 {
		t.Fatalf("error %v complete %v budget %+v cost %v\n%s", d.Error, d.Complete, d.Budget, d.CostUSD, raw)
	}
	if d.Issues[0].Status != issuePredicted || d.Issues[1].Status != issueBudgetExhausted || d.Issues[2].Status != issueBudgetExhausted ||
		!strings.Contains(d.Issues[1].Detail, "not launched") {
		t.Fatalf("issues = %s", jsonOf(t, d.Issues))
	}
	if n := len(f.claudeCalls(t)); n != 1 {
		t.Fatalf("claude launched %d times, want 1", n)
	}
	for _, p := range d.Pairs {
		if p.Status != pairUnknown || len(p.SharedFiles) != 0 || len(p.Evidence) != 0 {
			t.Fatalf("pair with an unpredicted issue = %s", jsonOf(t, p))
		}
	}

	// 1 件分に満たない上限では 1 件も起動しない。
	f2 := newPredictFixture(t)
	d, _ = f2.predict(t, false, "--max-budget-usd", "0.99", "1", "2")
	if d.Error != nil || d.Issues[0].Status != issueBudgetExhausted || d.Issues[1].Status != issueBudgetExhausted || len(f2.runs(t)) != 0 {
		t.Fatalf("issues = %s runs %d", jsonOf(t, d.Issues), len(f2.runs(t)))
	}
}

// 1 件の失敗は他の予測を止めない。Issue を読めなかった・予測が費用を報告せずに失敗した Issue は failed、
// 費用不明の実行は付与した上限額（1 件分）を消費したものとして数える（§4.3・Q15）。
func TestPredictConflictsPartialFailure(t *testing.T) {
	f := newPredictFixture(t)
	f.issue(t, 5, "ok")
	f.predicts(t, 5, []string{"a.go"}, []int{}, 0.2)
	// 6 は Issue.6.json が無い（gh issue view が失敗する）
	f.issue(t, 7, "claude fails")
	respond(t, f.fdir, 7, 1, `{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"@SID@"}`)

	d, raw := f.predict(t, false, "5", "6", "7")
	if d.Error != nil || d.Complete {
		t.Fatalf("error %v complete %v\n%s", d.Error, d.Complete, raw)
	}
	if d.Issues[0].Status != issuePredicted || d.Issues[1].Status != issueFailed || d.Issues[2].Status != issueFailed {
		t.Fatalf("issues = %s", jsonOf(t, d.Issues))
	}
	if d.Issues[1].CostUSD != 0 || d.Issues[2].CostUSD != 1 || d.UnknownCostCount != 1 || d.CostUSD != 1.2 {
		t.Fatalf("costs %v %v unknown %d total %v", d.Issues[1].CostUSD, d.Issues[2].CostUSD, d.UnknownCostCount, d.CostUSD)
	}
	if !strings.Contains(d.Issues[1].Detail, "harness status") {
		t.Fatalf("detail = %q", d.Issues[1].Detail)
	}
	for _, p := range d.Pairs {
		if p.Status != pairUnknown {
			t.Fatalf("pair = %s", jsonOf(t, p))
		}
	}
}

// 口全体を実行できないとき（入力の件数・形・予算の値・チェックアウトの外）は、何も起動せず error を入れた JSON を出して 0 で終わる。
func TestPredictConflictsRejectsInput(t *testing.T) {
	many := make([]string, 21)
	for i := range many {
		many[i] = fmt.Sprint(i + 1)
	}
	cases := map[string]struct {
		args []string
		want string
	}{
		"one issue":       {[]string{"1"}, "2 to 20 issue numbers, got 1"},
		"no issue":        {nil, "got 0"},
		"21 issues":       {many, "got 21"},
		"not a number":    {[]string{"1", "x"}, `positive integer, got "x"`},
		"zero":            {[]string{"0", "1"}, "positive integer"},
		"duplicate":       {[]string{"3", "#3"}, "#3 is given twice"},
		"budget negative": {[]string{"--max-budget-usd", "-1", "1", "2"}, "--max-budget-usd must be a positive number"},
		"budget text":     {[]string{"--max-budget-usd", "lots", "1", "2"}, "--max-budget-usd must be a positive number"},
		"unknown option":  {[]string{"--parallel", "1", "2"}, "unknown option --parallel"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			f := newPredictFixture(t)
			d, raw := f.predict(t, false, c.args...)
			if d.Error == nil || !strings.Contains(*d.Error, c.want) || d.Complete || len(d.Issues) != 0 || len(d.Pairs) != 0 {
				t.Fatalf("want error containing %q:\n%s", c.want, raw)
			}
			if len(f.runs(t)) != 0 || len(f.claudeCalls(t)) != 0 {
				t.Fatal("something was launched")
			}
		})
	}

	t.Run("outside a git working tree", func(t *testing.T) {
		f := newPredictFixture(t)
		f.h.cwd = t.TempDir()
		d, raw := f.predict(t, false, "1", "2")
		if d.Error == nil || !strings.Contains(*d.Error, "not in a git working tree") || d.HeadSHA != nil || len(f.runs(t)) != 0 {
			t.Fatalf("got\n%s", raw)
		}
	})
	t.Run("plugin version out of range", func(t *testing.T) {
		f := newPredictFixture(t)
		f.h.env = append(f.h.env, PluginVersionEnv+"=0.0.1")
		d, raw := f.predict(t, false, "1", "2")
		if d.Error == nil || !strings.Contains(*d.Error, PluginVersionEnv) || len(f.runs(t)) != 0 {
			t.Fatalf("got\n%s", raw)
		}
	})
}

// 依存の向き: 片方向だけなら挙げられた側が先、相互なら決めない（first は null）。
func TestPredictDependencyDirection(t *testing.T) {
	a := issuePrediction{Issue: 1, DependsOn: []int{2}}
	b := issuePrediction{Issue: 2, DependsOn: []int{1}}
	if d := dependency(a, b); d.First != nil || len(d.Stated) != 2 {
		t.Fatalf("mutual = %s", jsonOf(t, d))
	}
	b.DependsOn = nil
	if d := dependency(a, b); d.First == nil || *d.First != 2 {
		t.Fatalf("one-way = %s", jsonOf(t, d))
	}
	a.DependsOn = nil
	if d := dependency(a, b); d.First != nil || len(d.Stated) != 0 {
		t.Fatalf("none = %s", jsonOf(t, d))
	}
}

func jsonOf(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

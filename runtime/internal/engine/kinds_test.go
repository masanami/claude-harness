package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// tools は偽の git・gh・worktree スクリプトの置き場（実際の git・gh を呼ばずに PR-4 の種類を試す）。
type tools struct {
	t             *testing.T
	git, gh, wt   string
	gitBin, ghBin string
	cwd           string
}

func newTools(t *testing.T) *tools {
	t.Helper()
	tl := &tools{t: t, git: t.TempDir(), gh: t.TempDir(), wt: t.TempDir(), cwd: t.TempDir(),
		gitBin: testdata(t, "scripts", "fake-git.sh"), ghBin: testdata(t, "scripts", "fake-gh.sh")}
	t.Setenv("FAKE_GIT_DIR", tl.git)
	t.Setenv("FAKE_GH_DIR", tl.gh)
	t.Setenv("FAKE_WT_DIR", tl.wt)
	return tl
}

func (tl *tools) write(dir, name, content string) {
	tl.t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		tl.t.Fatal(err)
	}
}

func (tl *tools) read(dir, name string) string {
	tl.t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return ""
	}
	return string(data)
}

// start は tools の偽物を使って run を開始し、最初のゲートか終端まで進める。
func (tl *tools) start(name string, inputs map[string]any) (*runstate.State, *Engine) {
	t := tl.t
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
	e, err := Start(StartParams{RunsDir: t.TempDir(), WF: wf, Inputs: raw, ScriptsDir: scripts, WorkflowDir: testdata(t, "workflows"), Cwd: tl.cwd, Origin: "test"})
	if err != nil {
		t.Fatal(err)
	}
	e.GitBin, e.GhBin = tl.gitBin, tl.ghBin
	e.KillGrace, e.PollInterval = time.Second, 20*time.Millisecond
	st, err := e.Loop(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return st, e
}

func (tl *tools) resume(e *Engine) *runstate.State {
	tl.t.Helper()
	st, _, err := e.Run.Load()
	if err != nil {
		tl.t.Fatal(err)
	}
	e2, err := Reopen(e.Run, st)
	if err != nil {
		tl.t.Fatal(err)
	}
	e2.GitBin, e2.GhBin, e2.KillGrace, e2.PollInterval = e.GitBin, e.GhBin, e.KillGrace, e.PollInterval
	st, err = e2.Resolve(context.Background(), Resolution{Actor: "resume", Channel: "non-tty"})
	if err != nil {
		tl.t.Fatal(err)
	}
	return st
}

func output(t *testing.T, st *runstate.State, step string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(st.Unit(MainUnit).Outputs[step], &m); err != nil {
		t.Fatalf("output of %s: %v (%s)", step, err, st.Unit(MainUnit).Outputs[step])
	}
	return m
}

func realpath(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// --- select -----------------------------------------------------------------

func TestSelectTakesTheEnumValueAsTheOutcome(t *testing.T) {
	for _, choice := range []string{"left", "right"} {
		st, _ := run(t, "sel", map[string]any{"json": fmt.Sprintf(`{"outcome":"ok","choice":%q}`, choice)})
		if st.Status != runstate.StatusSucceeded || st.Reason != "went_"+choice {
			t.Fatalf("choice %s: status %s reason %s", choice, st.Status, st.Reason)
		}
		if got := steps(st); strings.Join(got, ",") != "route:ok,pick:"+choice {
			t.Fatalf("steps = %v", got)
		}
	}
}

// --- workspace ----------------------------------------------------------------

// acquire が worktree-setup で作った作業ツリーの中で後続のステップが動き、release はそれを消す。
func TestWorkspaceCreatedIsUsedAndReleased(t *testing.T) {
	tl := newTools(t)
	st, _ := tl.start("ws", nil)
	if st.Status != runstate.StatusSucceeded || st.Reason != "released" {
		t.Fatalf("status %s reason %s: %s", st.Status, st.Reason, steps(st))
	}
	wt := filepath.Join(realpath(t, tl.wt), "wt")
	if got := strings.TrimSpace(tl.read(tl.wt, "setup.calls")); got != "7 feature/issue-7-x main" {
		t.Errorf("worktree-setup args = %q", got)
	}
	if got := output(t, st, "acquire"); got["outcome"] != "created" || got["worktree_path"] != wt || got["provided_by"] != "runtime" {
		t.Errorf("acquire output = %v", got)
	}
	if got := output(t, st, "work")["dir"]; got != wt {
		t.Errorf("the step after acquire ran in %v, want the worktree %s", got, wt)
	}
	if got := output(t, st, "work")["scripts_dir"]; got != testdata(t, "scripts") {
		t.Errorf("HARNESS_SCRIPTS_DIR = %v", got)
	}
	if got := strings.TrimSpace(tl.read(tl.wt, "cleanup.calls")); got != wt+" --skip-if-dirty" {
		t.Errorf("worktree-cleanup args = %q", got)
	}
	if _, err := os.Stat(wt); !os.IsNotExist(err) {
		t.Errorf("the worktree the run created was not removed: %v", err)
	}
	ws := st.Unit(MainUnit).Workspace
	if ws == nil || !ws.Created || !ws.Released || !ws.Removed || ws.ProvidedBy != "runtime" {
		t.Errorf("workspace = %+v", ws)
	}
}

// 呼び出し元が渡した作業ツリーは検証して provided とし、release は消さない（worktree-cleanup を呼ばない）。
func TestWorkspaceProvidedIsNeverRemoved(t *testing.T) {
	tl := newTools(t)
	provided := t.TempDir()
	tl.write(provided, ".fake-branch", "feature/issue-7-callers\n")
	st, _ := tl.start("ws", map[string]any{"provided": provided})
	if st.Status != runstate.StatusSucceeded || st.Reason != "kept" {
		t.Fatalf("status %s reason %s: %s", st.Status, st.Reason, steps(st))
	}
	if tl.read(tl.wt, "setup.calls") != "" {
		t.Errorf("worktree-setup was called for a provided worktree")
	}
	if tl.read(tl.wt, "cleanup.calls") != "" {
		t.Errorf("worktree-cleanup was called for a worktree the caller provided")
	}
	if _, err := os.Stat(provided); err != nil {
		t.Errorf("the provided worktree is gone: %v", err)
	}
	acq := output(t, st, "acquire")
	if acq["outcome"] != "provided" || acq["provided_by"] != "caller" || acq["branch"] != "feature/issue-7-callers" {
		t.Errorf("acquire output = %v", acq)
	}
	if got := output(t, st, "work")["dir"]; got != realpath(t, provided) {
		t.Errorf("the step after acquire ran in %v, want the provided worktree %s", got, provided)
	}
	if ws := st.Unit(MainUnit).Workspace; ws.Created || ws.Removed || ws.ProvidedBy != "caller" {
		t.Errorf("workspace = %+v", ws)
	}
}

// 同じブランチの既存の作業ツリーを再利用した（この run が作っていない）場合も、release は消さない。
func TestWorkspaceReusedThatThisRunDidNotCreateIsKept(t *testing.T) {
	tl := newTools(t)
	tl.write(tl.wt, "setup.reused", "")
	st, _ := tl.start("ws", nil)
	if st.Status != runstate.StatusSucceeded || st.Reason != "kept" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if output(t, st, "acquire")["outcome"] != "reused" {
		t.Errorf("acquire = %v", output(t, st, "acquire"))
	}
	if tl.read(tl.wt, "cleanup.calls") != "" {
		t.Errorf("worktree-cleanup was called for a reused worktree this run did not create")
	}
}

func TestWorkspaceDirtyIsKept(t *testing.T) {
	tl := newTools(t)
	tl.write(tl.wt, "cleanup.dirty", "")
	st, _ := tl.start("ws", nil)
	if st.Status != runstate.StatusSucceeded || st.Reason != "dirty" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if ws := st.Unit(MainUnit).Workspace; !ws.Released || ws.Removed {
		t.Errorf("workspace = %+v", ws)
	}
}

// 払い出し先が使えない（別ブランチの worktree・未登録のディレクトリ・別のリポジトリ）なら conflict。
// それ以外の worktree-setup の失敗は step_error（conflict に丸めない）。
func TestWorkspaceConflict(t *testing.T) {
	t.Run("different branch", func(t *testing.T) {
		tl := newTools(t)
		tl.write(tl.wt, "setup.stderr", "Error: worktree path '/x/issue-7' is already registered for a different branch ('other', expected 'feature/issue-7-x'). Refusing to overwrite; resolve manually.\n")
		st, _ := tl.start("ws", nil)
		if st.Status != runstate.StatusFailed || st.Reason != "conflict" {
			t.Fatalf("status %s reason %s", st.Status, st.Reason)
		}
		if st.Unit(MainUnit).Workspace != nil {
			t.Errorf("a conflict must not record a workspace")
		}
	})
	t.Run("unregistered directory", func(t *testing.T) {
		tl := newTools(t)
		tl.write(tl.wt, "setup.stderr", "Error: worktree path '/x/issue-7' already exists but is not a registered git worktree (stale directory?). Refusing to overwrite; resolve manually.\n")
		st, _ := tl.start("ws", nil)
		if st.Reason != "conflict" {
			t.Fatalf("status %s reason %s", st.Status, st.Reason)
		}
	})
	t.Run("other failure is a step error", func(t *testing.T) {
		tl := newTools(t)
		tl.write(tl.wt, "setup.stderr", "Error: base branch 'main' does not exist on remote 'origin'\n")
		st, _ := tl.start("ws", nil)
		if st.Status != runstate.StatusFailed || st.Reason != "step_error" {
			t.Fatalf("status %s reason %s", st.Status, st.Reason)
		}
	})
	t.Run("provided worktree of another repository", func(t *testing.T) {
		tl := newTools(t)
		provided := t.TempDir()
		tl.write(provided, ".fake-common", "/elsewhere/.git\n")
		st, _ := tl.start("ws", map[string]any{"provided": provided})
		if st.Reason != "conflict" || !strings.Contains(output(t, st, "acquire")["detail"].(string), "different repository") {
			t.Fatalf("status %s reason %s", st.Status, st.Reason)
		}
	})
	t.Run("provided directory that is not a worktree top", func(t *testing.T) {
		tl := newTools(t)
		provided := t.TempDir()
		tl.write(provided, ".fake-top", "/somewhere/else\n")
		st, _ := tl.start("ws", map[string]any{"provided": provided})
		if st.Reason != "conflict" {
			t.Fatalf("status %s reason %s", st.Status, st.Reason)
		}
	})
}

// worktree-setup.sh が conflict の判定に使う文言を今も出していることを、実物のスクリプトで確かめる
// （文言が変わると conflict が step_error に落ちる。fail-closed だが、利用者に見える失敗の理由が変わる）。
func TestWorktreeSetupStillPrintsTheConflictMarkers(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "plugin", "scripts", "worktree-setup.sh"))
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range worktreeConflictMarkers {
		if !strings.Contains(string(data), m) {
			t.Errorf("plugin/scripts/worktree-setup.sh no longer contains %q", m)
		}
	}
}

// --- pull-request -------------------------------------------------------------

var findings = []map[string]string{
	{"location": "a.go:10", "severity": "major", "claim": "nil map write | when empty", "reason": "below_fix_threshold"},
	{"location": "b.go:3", "severity": "minor", "claim": "naming\nspans two lines", "reason": "out of scope"},
	{"location": "c.go:99", "severity": "info", "claim": "third finding", "reason": "converged: true but left"},
}

func TestPullRequestOpensWithTheTranscribedSections(t *testing.T) {
	tl := newTools(t)
	st, e := tl.start("pr", map[string]any{"findings": findings, "unverified": []string{"E2E を実行できなかった（ブラウザが無い）"}, "quality": "skip"})
	if st.Status != runstate.StatusWaiting {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	out := output(t, st, "publish")
	if out["outcome"] != "opened" || out["pr_number"] != float64(7) || out["branch"] != "feature/issue-7-x" || out["head_sha"] != "0123abcd" {
		t.Fatalf("publish output = %v", out)
	}
	calls := tl.read(tl.git, "calls")
	if !strings.Contains(calls, "push\t-u\torigin\tfeature/issue-7-x") {
		t.Errorf("git calls = %s", calls)
	}
	gh := tl.read(tl.gh, "calls")
	if !strings.Contains(gh, "pr\tcreate\t--base\tmain\t--head\tfeature/issue-7-x\t--title\tfeat: add the widget\t--body-file") {
		t.Errorf("gh calls = %s", gh)
	}
	body := tl.read(tl.gh, "body.1.md")
	for _, want := range []string{
		"Adds the widget.", "Closes #9",
		"skip（未検証あり）", "## 未検証", "E2E を実行できなかった（ブラウザが無い）",
		"## 残指摘（全 3 件）", "nil map write | when empty", "naming\n   spans two lines", "third finding", "below_fix_threshold", "`c.go:99`",
		"## クロスリポジトリ確証", "masanami/other#12: confirmed the API returns 404 (attested)",
		st.RunID,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("PR body lacks %q:\n%s", want, body)
		}
	}
	if st.Unit(MainUnit).Workspace.PRNumber != 7 {
		t.Errorf("workspace = %+v", st.Unit(MainUnit).Workspace)
	}
	// 観測（pr-state）: まだ open ならゲートに留まり、マージされたら先へ進む。人の申告は受け付けない。
	st = tl.resume(e)
	if st.Status != runstate.StatusWaiting {
		t.Fatalf("an open PR must keep the gate open: %s", st.Status)
	}
	tl.write(tl.gh, "pr-state", "MERGED")
	st = tl.resume(e)
	if st.Status != runstate.StatusSucceeded || st.Reason != "merged" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	g := st.Unit(MainUnit).Gates
	if res := g[len(g)-1].Resolution; res == nil || res.Outcome != "merged" || !strings.Contains(string(res.Observed), `"MERGED"`) {
		t.Errorf("resolution = %+v", res)
	}
}

// 既存の PR があれば push だけで終わる（PR を作り直さない。W4）。
func TestPullRequestUpdatesAnExistingPR(t *testing.T) {
	tl := newTools(t)
	tl.write(tl.gh, "pr-list", `[{"number":31,"url":"https://github.com/o/r/pull/31","baseRefName":"main"}]`)
	st, _ := tl.start("pr", map[string]any{"findings": []any{}, "unverified": []any{}, "quality": "pass"})
	out := output(t, st, "publish")
	if out["outcome"] != "updated" || out["pr_number"] != float64(31) {
		t.Fatalf("publish output = %v (%s)", out, st.Status)
	}
	if strings.Contains(tl.read(tl.gh, "calls"), "pr\tcreate") {
		t.Errorf("created a PR although one was open:\n%s", tl.read(tl.gh, "calls"))
	}
	if !strings.Contains(tl.read(tl.git, "calls"), "push\t-u\torigin") {
		t.Errorf("did not push")
	}
}

func TestPullRequestRefusals(t *testing.T) {
	t.Run("open PR to another base", func(t *testing.T) {
		tl := newTools(t)
		tl.write(tl.gh, "pr-list", `[{"number":31,"url":"u","baseRefName":"release"}]`)
		st, _ := tl.start("pr", map[string]any{"findings": []any{}, "unverified": []any{}, "quality": "pass"})
		if st.Status != runstate.StatusFailed || st.Reason != "step_error" {
			t.Fatalf("status %s reason %s", st.Status, st.Reason)
		}
	})
	t.Run("branch is the base", func(t *testing.T) {
		tl := newTools(t)
		tl.write(tl.cwd, ".fake-branch", "main\n")
		st, _ := tl.start("pr", map[string]any{"findings": []any{}, "unverified": []any{}, "quality": "pass"})
		if st.Status != runstate.StatusFailed || strings.Contains(tl.read(tl.git, "calls"), "push") {
			t.Fatalf("status %s; git calls:\n%s", st.Status, tl.read(tl.git, "calls"))
		}
	})
	t.Run("push rejected", func(t *testing.T) {
		tl := newTools(t)
		tl.write(tl.git, "push.code", "1")
		st, _ := tl.start("pr", map[string]any{"findings": []any{}, "unverified": []any{}, "quality": "pass"})
		if st.Status != runstate.StatusFailed || strings.Contains(tl.read(tl.gh, "calls"), "pr\tcreate") {
			t.Fatalf("status %s", st.Status)
		}
	})
}

func TestRenderPRBody(t *testing.T) {
	raw := func(s string) json.RawMessage { return json.RawMessage(s) }
	body := RenderPRBody(PRInput{RunID: "r1", Base: "main", Closes: 4, Title: "t", Summary: "s",
		Quality: "pass", QualityGiven: true, FindingsGiven: true, CrossRepoGiven: true})
	for _, want := range []string{"- 結果: pass", "## 残指摘（全 0 件）", "なし（0 件）", "なし（クロスリポジトリ依存なし）"} {
		if !strings.Contains(body, want) {
			t.Errorf("body lacks %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "## 未検証") {
		t.Errorf("a pass without unverified items must not have the unverified section:\n%s", body)
	}
	// 形の分からない要素も落とさない（JSON のまま載せる）。知っているフィールド以外も残す。
	body = RenderPRBody(PRInput{RunID: "r1", Closes: 4, Quality: "skip", QualityGiven: true, FindingsGiven: true,
		ResidualFindings: []json.RawMessage{raw(`{"file":"x.go","line":3,"claim":"c","extra":{"k":1}}`), raw(`"plain text finding"`), raw(`42`)}})
	for _, want := range []string{"## 残指摘（全 3 件）", "`x.go:3` c", "extra: `{\"k\":1}`", "2. plain text finding", "3. `42`",
		"## 未検証", "未検証の事項は列挙されていない", "（渡されていない）"} {
		if !strings.Contains(body, want) {
			t.Errorf("body lacks %q:\n%s", want, body)
		}
	}
}

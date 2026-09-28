package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// gitIdentity は一時リポジトリでコミットするための作者情報（利用者の git 設定を読まない・書かない）。
var gitIdentity = []string{
	"GIT_AUTHOR_NAME=harness-test", "GIT_AUTHOR_EMAIL=harness-test@example.invalid",
	"GIT_COMMITTER_NAME=harness-test", "GIT_COMMITTER_EMAIL=harness-test@example.invalid",
	"GIT_CONFIG_NOSYSTEM=1",
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(append(os.Environ(), gitIdentity...), "HOME="+dir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

// tempRepo は一時ディレクトリに bare の origin と、main を push 済みのクローンを作る（ネットワークに出ない）。
func tempRepo(t *testing.T) (root, repo, origin string) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	origin, repo = filepath.Join(root, "origin.git"), filepath.Join(root, "repo")
	git(t, root, "init", "-q", "--bare", "-b", "main", origin)
	git(t, root, "init", "-q", "-b", "main", repo)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("widget\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", "README.md")
	git(t, repo, "commit", "-q", "-m", "init")
	git(t, repo, "remote", "add", "origin", origin)
	git(t, repo, "push", "-q", "-u", "origin", "main")
	return root, repo, origin
}

func claudeStructured(v any, cost float64) string {
	b, _ := json.Marshal(v)
	return fmt.Sprintf(`{"type":"result","subtype":"success","is_error":false,"session_id":"@SID@","total_cost_usd":%v,"structured_output":%s}`, cost, b)
}

func check(name, bucket string) string {
	return fmt.Sprintf(`[{"name":%q,"state":%q,"bucket":%q,"description":"","workflow":"CI","link":"https://github.com/o/r/actions/runs/555/job/1"}]`, name, strings.ToUpper(bucket), bucket)
}

// 同梱の ticket ワークフロー（runtime/workflows/ticket.yaml）を、偽の claude・gh と一時リポジトリで通す（Issue #269 の完了条件）:
// 実装 → PR → CI の観測（red で fix へ差し戻し・既存 PR へ push）→ CI が時間内に終わらず ci-pending ゲート → resume で CI の
// 再確認から続ける → レビュー待ち → 既定ブランチ宛なので人のマージを観測するゲート → マージを観測して作業ツリーを片付ける。
func TestTicketWorkflowEndToEnd(t *testing.T) {
	root, repo, origin := tempRepo(t)
	fdir, fenv := fakeClaude(t)
	ghDir := t.TempDir()
	bin := t.TempDir()
	if err := os.Symlink(abs(t, testScripts+"/fake-gh.sh"), filepath.Join(bin, "gh")); err != nil {
		t.Fatal(err)
	}
	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(ghDir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	issue, _ := json.Marshal(map[string]any{"number": 42, "title": "Add the widget", "body": "## 背景\nwidget が要る\n", "state": "OPEN"})
	write("issue.json", string(issue))
	write("checks.1", check("test", "fail")) // 1 回目の CI は red（fix へ差し戻す）
	write("checks", check("test", "pending"))

	branch := "feature/issue-42-add-widget"
	findings := []map[string]string{
		{"location": "widget.go:10", "severity": "major", "claim": "first residual finding", "reason": "below_fix_threshold"},
		{"location": "widget.go:20", "severity": "minor", "claim": "second residual finding", "reason": "out of scope"},
	}
	respond(t, fdir, 1, 0, claudeStructured(map[string]any{"outcome": "ok", "e2e_target": "no", "e2e_reason": "internal only", "branch": branch, "critical_design": ""}, 0.3))
	respond(t, fdir, 2, 0, claudeStructured(map[string]any{"outcome": "pass", "pr_title": "feat: add the widget", "summary": "Adds the widget.",
		"residual_findings": findings, "unverified": []string{}, "cross_repo_attestation": "", "deviation_report": ""}, 4.0))
	respond(t, fdir, 3, 0, claudeStructured(map[string]any{"outcome": "committed", "commit_sha": "abc", "summary": "committed"}, 4.5))
	respond(t, fdir, 4, 0, claudeStructured(map[string]any{"outcome": "pass", "summary": "fixed the failing test", "deviation_report": ""}, 5.25))
	respond(t, fdir, 5, 0, claudeStructured(map[string]any{"outcome": "committed", "commit_sha": "def", "summary": "committed"}, 5.5))

	state := t.TempDir()
	env := append(append(fenv, gitIdentity...),
		"HARNESS_STATE_DIR="+state, "FAKE_GH_DIR="+ghDir, "POLL_SLEEP_CMD=true",
		"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	h := newHarness(t, env...)
	h.cwd = repo

	// ラウンド 1: 実装 → PR → CI red → fix → 既存 PR へ push → CI が終わらない（retry 1 回の後）→ ci-pending
	out, errOut, code := h.run("run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--input", "issue=42", "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "ci-pending" || v.Waiting[0].RequiresTTY {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	u := v.Unit("main")
	wt := filepath.Join(root, "repo-worktrees", "issue-42")
	if u.Workspace == nil || u.Workspace.WorktreePath != wt || !u.Workspace.Created || u.Workspace.PRNumber != 7 || u.Workspace.Branch != branch {
		t.Fatalf("workspace = %+v", u.Workspace)
	}
	if u.LimitsUsed["rework"] != 1 {
		t.Errorf("rework used = %d, want 1 (the red CI)", u.LimitsUsed["rework"])
	}
	var seq []string
	for _, x := range u.Rounds[0].Steps {
		seq = append(seq, x.Step+":"+x.Outcome)
	}
	want := "resolve:ok analyze:ok workspace:created implement:pass commit:committed e2e-route:no publish:opened ci:red " +
		"fix:pass commit:committed e2e-route:no publish:updated ci:timeout ci:timeout"
	if strings.Join(seq, " ") != want {
		t.Fatalf("round 1 steps:\n got %s\nwant %s", strings.Join(seq, " "), want)
	}
	// 接続契約 v1 の面（contract status）は、同じ run を PR・ブランチ・最後に push した head と累計費用で返す。
	// ci-pending は decider: any の input 型なので、呼び出し元が答える answer / parent になる。
	cd, _ := h.contract("status", v.RunID)
	arts, _ := json.Marshal(cd.Artifacts)
	wantArts := fmt.Sprintf(`[{"kind":"pr","ref":%q},{"kind":"branch","ref":%q},{"kind":"commit","ref":%q}]`,
		u.Workspace.PRURL, branch, u.Workspace.HeadSHAs["1"])
	if cd.State != "waiting" || u.Workspace.PRURL == "" || string(arts) != wantArts {
		t.Errorf("contract status = %+v, artifacts %s, want %s", cd, arts, wantArts)
	}
	if a := cd.RequestedAction; a == nil || a.Kind != "answer" || a.Decider != "parent" || !strings.Contains(a.Text, "gate ci-pending") {
		t.Errorf("contract requested_action = %+v", a)
	}
	if cd.CostUSD == nil || !near(*cd.CostUSD, u.Budget.SpentUSD) || u.Budget.SpentUSD == 0 {
		t.Errorf("contract cost_usd = %v, want the unit's spent %v", cd.CostUSD, u.Budget.SpentUSD)
	}
	// 実装・修正は払い出した作業ツリーの中で動き、修正は実装のセッションを --resume で引き継ぐ（Q11 の既定）。
	for n := 2; n <= 5; n++ {
		if pwd := strings.TrimSpace(readFile(t, filepath.Join(fdir, "calls", fmt.Sprintf("%d.pwd", n)))); pwd != wt {
			t.Errorf("claude call %d ran in %s, want the worktree %s", n, pwd, wt)
		}
	}
	implement, fix := u.Rounds[0].Steps[3], u.Rounds[0].Steps[8]
	if implement.Resume || !fix.Resume || fix.SessionID != implement.SessionID || fix.SessionID == "" {
		t.Errorf("session hand-over: implement %s (resume %v), fix %s (resume %v)", implement.SessionID, implement.Resume, fix.SessionID, fix.Resume)
	}
	if !strings.Contains(readFile(t, filepath.Join(fdir, "calls", "4.stdin")), "assertion failed in test_widget") {
		t.Errorf("the fix step did not receive the CI failure log")
	}
	// 費用はステップごとに記録され、ラウンドの費用になる（--resume の報告は累計なので差で数える）。
	if !near(u.Rounds[0].CostUSD, 5.5+0.3) || fix.CostUSD == nil || !near(*fix.CostUSD, 5.25-4.5) {
		t.Errorf("round cost %v, fix cost %v", u.Rounds[0].CostUSD, fix.CostUSD)
	}
	// PR は 1 回だけ作られ、本文は型付きの値から作られている。作業ブランチは origin へ push されている。
	if got := strings.TrimSpace(readFile(t, filepath.Join(ghDir, "create.count"))); got != "1" {
		t.Errorf("gh pr create called %s times", got)
	}
	body := readFile(t, filepath.Join(ghDir, "body.1.md"))
	for _, s := range []string{"Closes #42", "## 残指摘（全 2 件）", "first residual finding", "second residual finding", "- 結果: pass"} {
		if !strings.Contains(body, s) {
			t.Errorf("PR body lacks %q:\n%s", s, body)
		}
	}
	if got := git(t, repo, "ls-remote", "--heads", origin, branch); !strings.Contains(got, branch) {
		t.Errorf("the branch was not pushed to origin: %q", got)
	}
	if got := git(t, repo, "rev-parse", "--abbrev-ref", "HEAD"); got != "main" {
		t.Errorf("the main checkout was switched to %s", got)
	}

	// ラウンド 2: CI の完了後に recheck → CI green → レビュー待ち
	write("checks", check("test", "pass"))
	runID := v.RunID
	out, errOut, code = h.run("resume", runID, "--input", "recheck")
	if code != ExitWaiting {
		t.Fatalf("resume recheck exit %d\n%s\n%s", code, out, errOut)
	}
	v = decode[statusView](t, out)
	if v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	r2 := v.Unit("main").Rounds[1]
	if r2.Trigger.Kind != "gate" || r2.Trigger.Gate != "ci-pending" || r2.Trigger.Input != "recheck" || len(r2.Steps) != 1 || r2.Steps[0].Step != "ci" || r2.Steps[0].Outcome != "green" {
		t.Fatalf("round 2 = %+v", r2)
	}

	// ラウンド 3: マージしてよい → base は既定ブランチなので、人のマージを観測するゲート（runtime はマージしない）
	out, errOut, code = h.run("resume", runID, "--input", "ready")
	if code != ExitWaiting {
		t.Fatalf("resume ready exit %d\n%s\n%s", code, out, errOut)
	}
	v = decode[statusView](t, out)
	if v.Waiting[0].Gate != "human-merge" || v.Waiting[0].Type != "observe" || v.Waiting[0].RequiresTTY {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	if strings.TrimSpace(readFile(t, filepath.Join(fdir, "count"))) != "5" {
		t.Errorf("claude was called %s times; merging to the default branch must not launch claude", readFile(t, filepath.Join(fdir, "count")))
	}
	// まだ open なら待ち続ける（人の申告を信じない）
	out, _, code = h.run("resume", runID)
	if code != ExitWaiting || decode[statusView](t, out).Waiting[0].Gate != "human-merge" {
		t.Fatalf("an open PR must keep the run waiting: exit %d\n%s", code, out)
	}
	// マージを観測したら、作った作業ツリーを片付けて終わる
	write("pr-state", "MERGED")
	out, errOut, code = h.run("resume", runID)
	if code != ExitOK {
		t.Fatalf("resume after merge exit %d\n%s\n%s", code, out, errOut)
	}
	v = decode[statusView](t, out)
	if v.Status != runstate.StatusSucceeded || v.Reason != "merged" {
		t.Fatalf("status %s reason %s", v.Status, v.Reason)
	}
	if ws := v.Unit("main").Workspace; !ws.Released || !ws.Removed {
		t.Errorf("workspace = %+v", ws)
	}
	if _, err := os.Stat(wt); !os.IsNotExist(err) {
		t.Errorf("the worktree the run created is still there: %v", err)
	}
	var triggers []string
	for _, r := range v.Unit("main").Rounds {
		triggers = append(triggers, r.Trigger.Kind+":"+r.Trigger.Gate+":"+r.Trigger.Input)
	}
	// open の観測はゲートを開き直すだけでラウンドを始めない（ゲートとゲートの間にステップが無い）。
	if got := strings.Join(triggers, " "); got != "start:: gate:ci-pending:recheck gate:review:ready gate:human-merge:merged" {
		t.Errorf("round triggers = %s", got)
	}
}

// base の統合ブランチが remote に無ければ、作業ツリーを払い出す前に base_missing で止まる（I3）。
func TestTicketWorkflowStopsWhenTheIntegrationBranchIsMissing(t *testing.T) {
	_, repo, _ := tempRepo(t)
	fdir, fenv := fakeClaude(t)
	ghDir, bin := t.TempDir(), t.TempDir()
	if err := os.Symlink(abs(t, testScripts+"/fake-gh.sh"), filepath.Join(bin, "gh")); err != nil {
		t.Fatal(err)
	}
	issue, _ := json.Marshal(map[string]any{"number": 42, "title": "t", "body": "Base: feat/issue-40\n", "state": "OPEN"})
	if err := os.WriteFile(filepath.Join(ghDir, "issue.json"), issue, 0o644); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, append(append(fenv, gitIdentity...), "HARNESS_STATE_DIR="+t.TempDir(), "FAKE_GH_DIR="+ghDir,
		"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))...)
	h.cwd = repo
	out, errOut, code := h.run("run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--input", "issue=42", "ticket")
	if code != ExitFailed {
		t.Fatalf("exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "base_missing" || v.Unit("main").Workspace != nil {
		t.Fatalf("reason %s workspace %+v", v.Reason, v.Unit("main").Workspace)
	}
	if !strings.Contains(string(v.Unit("main").Outputs["resolve"]), "git push -u origin feat/issue-40") {
		t.Errorf("resolve output lacks how to create the branch: %s", v.Unit("main").Outputs["resolve"])
	}
	if _, err := os.Stat(filepath.Join(fdir, "count")); err == nil {
		t.Errorf("claude was launched although the base is missing")
	}
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func near(a, b float64) bool { d := a - b; return d < 1e-9 && d > -1e-9 }

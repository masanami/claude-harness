package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 品質ゲートを機械で回す quality ステップ（#326）: 宣言（.claude-harness/quality-gate.json）を PR の宛先から読み、push する
// コミットに対してゲートを実行し、結果を SHA と一緒に run の記録（units[].outputs.quality）に残す。

type qualityOutput struct {
	Result      string `json:"result"`
	CommitSHA   string `json:"commit_sha"`
	Base        string `json:"base"`
	Declaration struct {
		Path, Ref, Commit, Sha256 string
	} `json:"declaration"`
	Gates          map[string]any `json:"gates"`
	FailureExcerpt string         `json:"failure_excerpt"`
	Message        string         `json:"message"`
}

func stepSeq(v statusView) string {
	var seq []string
	for _, r := range v.Unit("main").Rounds {
		for _, x := range r.Steps {
			seq = append(seq, x.Step+":"+x.Outcome)
		}
	}
	return strings.Join(seq, " ")
}

func qualityOf(t *testing.T, v statusView) qualityOutput {
	t.Helper()
	raw, ok := v.Unit("main").Outputs["quality"]
	if !ok {
		t.Fatalf("no output of quality in status: %v", v.Unit("main").Outputs)
	}
	var q qualityOutput
	if err := json.Unmarshal(raw, &q); err != nil {
		t.Fatal(err)
	}
	return q
}

// providedWorktree は origin/main から作業ブランチの作業ツリーを作る（作業ブランチ上のコミットを足せるように）。
func providedWorktree(t *testing.T, f *ticketFixture) string {
	t.Helper()
	wt := filepath.Join(f.root, "repo-worktrees", "issue-42")
	git(t, f.repo, "worktree", "add", "-q", "-b", f.branch, wt, "origin/main")
	return wt
}

func commitFile(t *testing.T, dir, rel, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, rel)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, rel), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "add", rel)
	git(t, dir, "commit", "-q", "-m", "change "+rel)
}

// 上書きなしでは PR を作る前に quality が走り、ゲートの結果・回したコミット（作業ツリーの HEAD）・宣言を読んだ base の版を
// 記録する。作業ブランチで宣言を書き換えても、使われるのは PR の宛先（origin/main）の宣言である（Q-O1）。
func TestTicketQualityRunsTheBaseDeclarationOnTheCommit(t *testing.T) {
	f := newTicketFixture(t) // origin/main の宣言は {"test": "true"}
	f.write("checks.1", check("test", "pass"))
	f.write("checks", check("test", "pass"))
	wt := providedWorktree(t, f)
	commitFile(t, wt, ".claude-harness/quality-gate.json", `{"test": "false"}`+"\n") // 子が宣言を書き換えた想定
	f.h.cwd = wt

	out, errOut, code := f.h.run("run", "--input", "issue=42", "--input", "worktree="+wt,
		"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if got, want := stepSeq(v), "resolve:ok analyze:ok workspace:provided implement:pass commit:committed e2e-route:no quality:pass publish:opened ci:green"; got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}
	q := qualityOf(t, v)
	head, base := git(t, wt, "rev-parse", "HEAD"), git(t, f.repo, "rev-parse", "origin/main")
	if q.Result != "pass" || q.CommitSHA != head || q.Base != "main" || q.FailureExcerpt != "" || q.Message != "" {
		t.Fatalf("quality = %+v (HEAD %s)", q, head)
	}
	if q.Declaration.Path != ".claude-harness/quality-gate.json" || q.Declaration.Ref != "origin/main" || q.Declaration.Commit != base || len(q.Declaration.Sha256) != 64 {
		t.Fatalf("declaration = %+v (origin/main %s)", q.Declaration, base)
	}
	gates, _ := q.Gates["gates"].(map[string]any)
	test, _ := gates["test"].(map[string]any)
	if q.Gates["result"] != "pass" || test["status"] != "pass" || gates["lint"].(map[string]any)["status"] != "skip" {
		t.Fatalf("gates = %v", q.Gates)
	}
	// PR の head（publish が push した SHA）と記録の SHA を照合できる。
	if sha := v.Unit("main").Workspace.HeadSHAs["1"]; sha != q.CommitSHA {
		t.Fatalf("head_sha_by_round[1] = %s, quality commit_sha = %s", sha, q.CommitSHA)
	}
}

// ゲートが落ちると fix へ差し戻し（落ちた出力の末尾を渡す）、commit の後に再び quality を通る。差し戻しは rework を 1 回使う。
func TestTicketQualityFailGoesToFixAndRunsAgain(t *testing.T) {
	f := newTicketFixture(t)
	f.write("checks.1", check("test", "pass"))
	f.write("checks", check("test", "pass"))
	marker := filepath.Join(t.TempDir(), "gate-ran-once") // 作業ツリーの外（ゲートが作業ツリーを変えない）
	makefile := "gate:\n\t@if [ -f \"$(MARKER)\" ]; then echo gate passed; else touch \"$(MARKER)\"; echo 'widget gate failed: TestWidget'; exit 1; fi\n"
	commitFile(t, f.repo, "Makefile", makefile)
	declareQualityGate(t, f.repo, `{"test": "make gate MARKER=`+marker+`"}`)

	out, errOut, code := f.h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	want := "resolve:ok analyze:ok workspace:created implement:pass commit:committed e2e-route:no quality:fail " +
		"fix:pass commit:committed e2e-route:no quality:pass publish:opened ci:green"
	if got := stepSeq(v); got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}
	if v.Waiting[0].Gate != "review" || v.Unit("main").LimitsUsed["rework"] != 1 {
		t.Fatalf("waiting %+v rework %d", v.Waiting, v.Unit("main").LimitsUsed["rework"])
	}
	if !strings.Contains(readFile(t, filepath.Join(f.fdir, "calls", "4.stdin")), "widget gate failed: TestWidget") {
		t.Errorf("the fix step did not receive the failure of the quality gate")
	}
	if q := qualityOf(t, v); q.Result != "pass" { // 最後に成功した実行（2 回目）の出力
		t.Errorf("quality = %+v", q)
	}
}

// 宣言が PR の宛先に無ければ、作業ブランチに宣言があっても読まず、PR を作らずに quality_gate_undeclared で止まる（Q-O2）。
// message は宣言を置くか上書きで省くかを伝える。
func TestTicketQualityStopsWithoutADeclaration(t *testing.T) {
	f := newTicketFixture(t)
	git(t, f.repo, "rm", "-q", ".claude-harness/quality-gate.json")
	git(t, f.repo, "commit", "-q", "-m", "drop the declaration")
	git(t, f.repo, "push", "-q", "origin", "main")
	wt := providedWorktree(t, f)
	commitFile(t, wt, ".claude-harness/quality-gate.json", `{"test": "true"}`+"\n")
	f.h.cwd = wt

	out, errOut, code := f.h.run("run", "--input", "issue=42", "--input", "worktree="+wt,
		"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitFailed {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "quality_gate_undeclared" {
		t.Fatalf("reason = %s, steps %s", v.Reason, stepSeq(v))
	}
	q := qualityOf(t, v)
	if q.Result != "undeclared" || q.Gates != nil || q.Declaration.Sha256 != "" ||
		!strings.Contains(q.Message, "origin/main") || !strings.Contains(q.Message, "上書き") || !strings.Contains(q.Message, "宣言を置く") {
		t.Fatalf("quality = %+v", q)
	}
	if _, err := os.Stat(filepath.Join(f.ghDir, "create.count")); err == nil {
		t.Errorf("a PR was opened although the quality gate is not declared")
	}
}

// ゲートが 1 つも走らない宣言（runner の exit 3）とコマンドの形が拒否された宣言（exit 4）も undeclared で止まる（Q-O2）。
func TestTicketQualityUndeclaredWhenNothingRunsOrTheCommandIsRejected(t *testing.T) {
	for _, c := range []struct{ name, decl, msg string }{
		{"no gate", `{"lint": ""}`, "1 つも無い"},
		{"rejected", `{"test": "rm -rf build"}`, "拒否された"},
		{"not the shape", `{"tests": "true"}`, "宣言の形になっていない"},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newTicketFixture(t)
			declareQualityGate(t, f.repo, c.decl)
			out, errOut, code := f.h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
			if code != ExitFailed {
				t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
			}
			v := decode[statusView](t, out)
			if q := qualityOf(t, v); v.Reason != "quality_gate_undeclared" || q.Result != "undeclared" || !strings.Contains(q.Message, c.msg) {
				t.Fatalf("reason %s quality %+v", v.Reason, q)
			}
		})
	}
}

// リポジトリの上書き（.claude-harness/overrides/ticket.yaml）で前段の 2 本を publish へ付け替えると、quality は実行されず、
// 宣言が無くても PR へ進む。省いたことは status --json の skipped_steps に出る（pre-commit 等で同じゲートが回るリポジトリ）。
func TestTicketQualitySkippedByARepositoryOverride(t *testing.T) {
	f := newTicketFixture(t)
	f.write("checks.1", check("test", "pass"))
	f.write("checks", check("test", "pass"))
	git(t, f.repo, "rm", "-q", ".claude-harness/quality-gate.json")
	git(t, f.repo, "commit", "-q", "-m", "drop the declaration")
	git(t, f.repo, "push", "-q", "origin", "main")
	writeFile(t, filepath.Join(f.repo, ".claude-harness", "overrides", "ticket.yaml"),
		"schema: harness.workflow-override/v1\nworkflow: ticket\nsteps:\n  e2e-route: { on: { no: publish } }\n  e2e: { on: { pass: publish } }\n")

	out, errOut, code := f.h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if got, want := stepSeq(v), "resolve:ok analyze:ok workspace:created implement:pass commit:committed e2e-route:no publish:opened ci:green"; got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}
	if _, ran := v.Unit("main").Outputs["quality"]; ran {
		t.Fatalf("quality ran although the override skips it")
	}
	var doc struct {
		Workflow struct {
			SkippedSteps []string `json:"skipped_steps"`
		} `json:"workflow"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatal(err)
	}
	if strings.Join(doc.Workflow.SkippedSteps, ",") != "quality" {
		t.Fatalf("skipped_steps = %v, want [quality]", doc.Workflow.SkippedSteps)
	}
}

// 検査したものとコミットを一致させる: 未コミットの変更が残っている・ゲートが作業ツリーを変えた場合は、結果をコミットの
// ものとして記録せず step_error で止まる（fail-closed）。
func TestTicketQualityRefusesWhenTheTreeIsNotTheCommit(t *testing.T) {
	for _, c := range []struct{ name, stderr string }{
		{"uncommitted changes before", "the working tree has uncommitted changes"},
		{"the gate changes the tree", "the quality gates changed HEAD or the working tree"},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newTicketFixture(t)
			if c.name == "the gate changes the tree" {
				commitFile(t, f.repo, "Makefile", "gate:\n\t@touch generated.txt\n")
				declareQualityGate(t, f.repo, `{"test": "make gate"}`)
			}
			wt := providedWorktree(t, f)
			if c.name == "uncommitted changes before" {
				writeFile(t, filepath.Join(wt, "left-behind.txt"), "not committed\n")
			}
			f.h.cwd = wt
			out, errOut, code := f.h.run("run", "--input", "issue=42", "--input", "worktree="+wt,
				"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
			if code != ExitFailed {
				t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
			}
			v := decode[statusView](t, out)
			if _, ok := v.Unit("main").Outputs["quality"]; ok || v.Reason != "step_error" || !strings.Contains(out, c.stderr) {
				t.Fatalf("reason %s steps %s\n%s", v.Reason, stepSeq(v), out)
			}
		})
	}
}

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
	// PR を作った時点では、実際の PR の head（origin の作業ブランチ）が記録の SHA と一致する。照合は head_sha_by_round では
	// なく実際の PR の head で行う（head_sha_by_round を書くのは publish だけで、respond が push した head は記録されない）。
	if remote := strings.Fields(git(t, f.repo, "ls-remote", "--heads", f.origin, f.branch)); len(remote) == 0 || remote[0] != q.CommitSHA {
		t.Fatalf("the PR head on origin = %v, quality commit_sha = %s", remote, q.CommitSHA)
	}
}

// ゲートが落ちると fix へ差し戻し（落ちたゲートの出力だけを渡す。通った lint の出力は混ぜない）、commit の後に再び quality を
// 通る。差し戻しは rework を 1 回使う。
func TestTicketQualityFailGoesToFixAndRunsAgain(t *testing.T) {
	f := newTicketFixture(t)
	f.write("checks.1", check("test", "pass"))
	f.write("checks", check("test", "pass"))
	marker := filepath.Join(t.TempDir(), "gate-ran-once") // 作業ツリーの外（ゲートが作業ツリーを変えない）
	makefile := "gate:\n\t@if [ -f \"$(MARKER)\" ]; then echo gate passed; else touch \"$(MARKER)\"; echo 'widget gate failed: TestWidget'; exit 1; fi\n"
	commitFile(t, f.repo, "Makefile", makefile)
	declareQualityGate(t, f.repo, `{"lint": "echo lint-passed-noise", "test": "make gate MARKER=`+marker+`"}`)

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
	if in := readFile(t, filepath.Join(f.fdir, "calls", "4.stdin")); !strings.Contains(in, "widget gate failed: TestWidget") || strings.Contains(in, "lint-passed-noise") {
		t.Errorf("the fix step did not receive only the failure of the quality gate:\n%s", in)
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
		{"two JSON values", `{"test": "true"} {"test": "false"}`, "宣言の形になっていない"},
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

// 落ち続けると、差し戻しの上限（limits.rework。E2E・CI と共有）を使い切ったところで quality_gate_red で止まり、PR を作らない。
func TestTicketQualityStopsWhenReworkIsExhausted(t *testing.T) {
	f := newTicketFixture(t)
	declareQualityGate(t, f.repo, `{"test": "false"}`)
	for n := 6; n <= 9; n += 2 { // fix と commit の 2 回目・3 回目（1 回目は newTicketFixture の 4・5）
		respond(t, f.fdir, n, 0, claudeStructured(map[string]any{"outcome": "pass", "summary": "fixed", "deviation_report": ""}, 5.5+float64(n)))
		respond(t, f.fdir, n+1, 0, claudeStructured(map[string]any{"outcome": "committed", "commit_sha": "x", "summary": "committed"}, 6+float64(n)))
	}
	out, errOut, code := f.h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitFailed {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "quality_gate_red" || v.Unit("main").LimitsUsed["rework"] != 3 || strings.Count(stepSeq(v), "quality:fail") != 4 {
		t.Fatalf("reason %s rework %d steps %s", v.Reason, v.Unit("main").LimitsUsed["rework"], stepSeq(v))
	}
	if _, err := os.Stat(filepath.Join(f.ghDir, "create.count")); err == nil {
		t.Errorf("a PR was opened although the quality gate kept failing")
	}
}

// 宣言は、その時点の origin から取り直した PR の宛先から読む。ローカルの base（refs/heads/main）や、取り直す前の
// refs/remotes/origin/main が別の宣言を指していても使わない。渡された作業ツリーの経路は workspace が fetch しないので、
// quality 自身が取り直さないと古い refs/remotes/origin/main を読む。
func TestTicketQualityReadsTheDeclarationFromOriginNow(t *testing.T) {
	for _, c := range []struct {
		name, reason string
		setup        func(t *testing.T, f *ticketFixture)
	}{
		// (a) ローカルの main と refs/remotes/origin/main を {"test":"false"} の宣言を持つ未 push のコミットへ向けても、
		// origin の {"test":"true"} で pass になる。
		{"local refs point to another declaration", "", func(t *testing.T, f *ticketFixture) {
			declareLocally(t, f.repo, `{"test": "false"}`)
			git(t, f.repo, "update-ref", "refs/remotes/origin/main", "HEAD")
		}},
		// (b) 作業ツリーを用意した後に、別のクローンから origin の宣言を消すと undeclared で止まる。
		{"origin dropped the declaration afterwards", "quality_gate_undeclared", func(t *testing.T, f *ticketFixture) {
			other := filepath.Join(f.root, "other")
			git(t, f.root, "clone", "-q", f.origin, other)
			git(t, other, "rm", "-q", ".claude-harness/quality-gate.json")
			git(t, other, "commit", "-q", "-m", "drop the declaration")
			git(t, other, "push", "-q", "origin", "main")
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newTicketFixture(t)
			f.write("checks.1", check("test", "pass"))
			f.write("checks", check("test", "pass"))
			wt := providedWorktree(t, f)
			c.setup(t, f)
			f.h.cwd = wt
			out, errOut, code := f.h.run("run", "--input", "issue=42", "--input", "worktree="+wt,
				"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
			v := decode[statusView](t, out)
			q := qualityOf(t, v)
			if c.reason == "" {
				if code != ExitWaiting || q.Result != "pass" || q.Declaration.Commit != git(t, f.origin, "rev-parse", "main") {
					t.Fatalf("exit %d quality %+v\n%s", code, q, errOut)
				}
				return
			}
			if code != ExitFailed || v.Reason != c.reason || q.Result != "undeclared" {
				t.Fatalf("exit %d reason %s quality %+v\n%s", code, v.Reason, q, errOut)
			}
		})
	}
}

// declareLocally は宣言を変えるコミットを repo の main に作るが、origin へは push しない。
func declareLocally(t *testing.T, repo, decl string) {
	t.Helper()
	commitFile(t, repo, ".claude-harness/quality-gate.json", decl+"\n")
}

// fakeScriptsDir は repoScripts の写し（シンボリックリンク）で、quality-check-runner.sh だけを偽物に差し替えた scripts ディレクトリ。
// エージェント定義は <scripts-dir>/../agents から探されるので、隣に agents を置く。
func fakeScriptsDir(t *testing.T, runner string) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Symlink(filepath.Join(abs(t, repoScripts), "..", "agents"), filepath.Join(root, "agents")); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, "scripts")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(abs(t, repoScripts))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.Name() == "quality-check-runner.sh" {
			continue
		}
		if err := os.Symlink(filepath.Join(abs(t, repoScripts), e.Name()), filepath.Join(dir, e.Name())); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, filepath.Join(dir, "quality-check-runner.sh"), "#!/bin/bash\n"+runner+"\n")
	return dir
}

// runner の結果と終了コードが食い違う・想定外の終了コード・宛先を取り直せない場合は、結果を記録せず step_error で止まる（fail-closed）。
func TestTicketQualityFailsClosed(t *testing.T) {
	for _, c := range []struct{ name, runner, stderr string }{
		{"exit 0 without pass", `echo '{"result":"fail","gates":{}}'; exit 0`, "exited 0 without a pass result"},
		{"exit 1 without fail", `echo '{"result":"pass","gates":{}}'; exit 1`, "exited 1 without a fail result"},
		{"exit 1 without JSON", `echo 'usage' >&2; exit 1`, "exited 1 without a fail result"},
		{"unexpected exit code", `exit 7`, "quality-check-runner.sh failed (exit 7)"},
		{"cannot fetch the base", "", "cannot fetch the base 'main' from origin"},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newTicketFixture(t)
			scripts := abs(t, repoScripts)
			if c.runner != "" {
				scripts = fakeScriptsDir(t, c.runner)
			}
			wt := providedWorktree(t, f) // workspace が fetch しない経路（fetch の失敗を quality で起こすため）
			if c.runner == "" {
				git(t, f.repo, "remote", "set-url", "origin", filepath.Join(f.root, "gone.git"))
			}
			f.h.cwd = wt
			out, errOut, code := f.h.run("run", "--input", "issue=42", "--input", "worktree="+wt,
				"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", scripts, "ticket")
			if code != ExitFailed {
				t.Fatalf("exit %d\n%s\n%s", code, out, errOut)
			}
			v := decode[statusView](t, out)
			if _, ok := v.Unit("main").Outputs["quality"]; ok || v.Reason != "step_error" || !strings.Contains(stepSeq(v), "quality:step_error") || !strings.Contains(out, c.stderr) {
				t.Fatalf("reason %s steps %s\n%s", v.Reason, stepSeq(v), out)
			}
		})
	}
}

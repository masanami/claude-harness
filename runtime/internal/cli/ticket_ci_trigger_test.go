package cli

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// CI の運用の宣言（.claude-harness/ci.json。Issue #363）: PR の宛先（origin/<base>）が {"trigger": "after-merge"} を宣言する
// リポジトリでは、ci の段は CI を待たずに skipped（none とは別の値）で review へ進む。宣言が無い・per-push・壊れた宣言では、
// 今の動き（チェック 0 件が約 2 分続いてから none と確定する。#341）のまま。

// declareCITrigger は CI の運用の宣言を main にコミットして origin へ push する（content が空なら宣言を置かない）。
func declareCITrigger(t *testing.T, repo, content string) {
	t.Helper()
	if content == "" {
		return
	}
	if err := os.MkdirAll(filepath.Join(repo, ".claude-harness"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".claude-harness", "ci.json"), []byte(content+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", ".claude-harness/ci.json")
	git(t, repo, "commit", "-q", "-m", "declare the CI trigger")
	git(t, repo, "push", "-q", "origin", "main")
}

type ciOutput struct {
	CI       string `json:"ci"`
	PRNumber *int   `json:"pr_number"`
	PRURL    string `json:"pr_url"`
	PRExists bool   `json:"pr_exists"`
}

func ciOf(t *testing.T, v statusView) ciOutput {
	t.Helper()
	raw, ok := v.Unit("main").Outputs["ci"]
	if !ok {
		t.Fatalf("no output of ci in status: %v", v.Unit("main").Outputs)
	}
	var c ciOutput
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

// ghChecksCalls は偽の gh が pr checks を受けた回数（ci-wait.sh のポーリングの回数）。
func ghChecksCalls(t *testing.T, ghDir string) int {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(ghDir, "calls"))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "pr\tchecks") {
			n++
		}
	}
	return n
}

// ③ after-merge のときは、CI を待たずに（gh pr checks を 1 度も呼ばずに）skipped で review へ進み、記録の ci は skipped。
func TestTicketCIAfterMergeSkipsTheWait(t *testing.T) {
	t.Run("working tree definitions", func(t *testing.T) { ticketCIAfterMerge(t, false) })
	t.Run("embedded definitions", func(t *testing.T) { ticketCIAfterMerge(t, true) })
}

func ticketCIAfterMerge(t *testing.T, embedded bool) {
	f := newTicketFixture(t)
	declareCITrigger(t, f.repo, `{"trigger": "after-merge"}`)
	f.write("checks.1", "[]") // PR では CI が走らない（マージの後だけ）ので、チェックは出ない
	f.write("checks", "[]")
	args := []string{"run", "--input", "issue=42", "ticket"}
	if !embedded {
		args = append(args, "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts))
	}
	out, errOut, code := f.h.run(args...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if got, want := stepSeq(v), "resolve:ok analyze:ok workspace:created implement:pass commit:committed e2e-route:no quality:pass publish:opened ci:skipped"; got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	c := ciOf(t, v)
	if c.CI != "skipped" || c.CI == "none" || !c.PRExists || c.PRNumber == nil || *c.PRNumber != 7 || c.PRURL != "https://github.com/o/r/pull/7" {
		t.Fatalf("ci output = %+v", c)
	}
	if n := ghChecksCalls(t, f.ghDir); n != 0 {
		t.Fatalf("gh pr checks was called %d times; after-merge must not poll", n)
	}
	if u := v.Unit("main"); u.LimitsUsed["rework"] != 0 {
		t.Errorf("rework used = %d", u.LimitsUsed["rework"])
	}
}

// ① 宣言なし・② per-push・④ 壊れた宣言（JSON として読めない・知らない値。受け付けない before-merge を含む）のときは今の動き: チェック 0 件のまま
// 約 2 分（30 秒間隔で 5 回目の観測。#341 の NONE_CONFIRM_SECONDS=120）待ってから none で review へ進む。
func TestTicketCIWithoutAfterMergeKeepsTheNoneConfirmation(t *testing.T) {
	for _, c := range []struct{ name, decl string }{
		{"undeclared", ""},
		{"per-push", `{"trigger": "per-push"}`},
		{"no trigger key", `{}`},
		{"broken JSON", `{"trigger": "after-merge"`},
		{"unknown value", `{"trigger": "nightly"}`},
		{"before-merge is not accepted", `{"trigger": "before-merge"}`},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newTicketFixture(t)
			declareCITrigger(t, f.repo, c.decl)
			f.write("checks.1", "[]")
			f.write("checks", "[]")
			out, errOut, code := f.h.run("run", "--input", "issue=42", "ticket", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts))
			if code != ExitWaiting {
				t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
			}
			v := decode[statusView](t, out)
			if got, want := stepSeq(v), "resolve:ok analyze:ok workspace:created implement:pass commit:committed e2e-route:no quality:pass publish:opened ci:none"; got != want {
				t.Fatalf("steps:\n got %s\nwant %s", got, want)
			}
			if v.Waiting[0].Gate != "review" {
				t.Fatalf("waiting = %+v", v.Waiting)
			}
			// 0 秒・30・60・90・120 秒の 5 回観測して、120 秒に達した 5 回目で none と確定する（#341 のまま）。
			if n := ghChecksCalls(t, f.ghDir); n != 5 {
				t.Fatalf("gh pr checks was called %d times, want 5 (the 120-second confirmation of #341)", n)
			}
		})
	}
}

// ② per-push・宣言なしで CI が red なら、今までどおり fix へ差し戻す（宣言の読み手を足しても ci の他の遷移は変わらない）。
func TestTicketCIPerPushStillSendsRedToFix(t *testing.T) {
	f := newTicketFixture(t) // 1 回目の CI は red、以後 pending
	declareCITrigger(t, f.repo, `{"trigger": "per-push"}`)
	f.write("checks", check("test", "pass"))
	out, errOut, code := f.h.run("run", "--input", "issue=42", "ticket", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts))
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	want := "resolve:ok analyze:ok workspace:created implement:pass commit:committed e2e-route:no quality:pass publish:opened ci:red " +
		"fix:pass commit:committed e2e-route:no quality:pass publish:updated ci:green"
	if got := stepSeq(v); got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}
}

// ⑤ 宣言は作業ブランチではなく PR の宛先（origin/<base>）から読む。作業ブランチで after-merge を宣言しても CI を待ち、
// 宛先が after-merge なら作業ブランチの per-push に関わらず待たない。
func TestTicketCITriggerIsReadFromTheBase(t *testing.T) {
	t.Run("after-merge only on the work branch", func(t *testing.T) {
		f := newTicketFixture(t)
		f.write("checks.1", check("test", "pass"))
		f.write("checks", check("test", "pass"))
		wt := providedWorktree(t, f)
		commitFile(t, wt, ".claude-harness/ci.json", `{"trigger": "after-merge"}`+"\n") // 子が宣言を書き換えた想定
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
		if n := ghChecksCalls(t, f.ghDir); n == 0 {
			t.Fatal("gh pr checks was not called; the declaration on the work branch must not skip the wait")
		}
	})
	t.Run("after-merge on the base, per-push on the work branch", func(t *testing.T) {
		f := newTicketFixture(t)
		declareCITrigger(t, f.repo, `{"trigger": "after-merge"}`)
		f.write("checks.1", check("test", "pass"))
		f.write("checks", check("test", "pass"))
		wt := providedWorktree(t, f)
		commitFile(t, wt, ".claude-harness/ci.json", `{"trigger": "per-push"}`+"\n")
		f.h.cwd = wt
		out, errOut, code := f.h.run("run", "--input", "issue=42", "--input", "worktree="+wt,
			"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
		if code != ExitWaiting {
			t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
		}
		v := decode[statusView](t, out)
		if got, want := stepSeq(v), "resolve:ok analyze:ok workspace:provided implement:pass commit:committed e2e-route:no quality:pass publish:opened ci:skipped"; got != want {
			t.Fatalf("steps:\n got %s\nwant %s", got, want)
		}
		if n := ghChecksCalls(t, f.ghDir); n != 0 {
			t.Fatalf("gh pr checks was called %d times", n)
		}
	})
}

// ci-wait-pr.sh を単体で: --base を渡すと宣言の読み手（ci-trigger.sh）を使う。壊れた宣言・知らない値は警告を stderr に出して
// ci-wait.sh をそのまま呼び（④）、after-merge は ci-wait.sh を呼ばずに skipped を出す（③）。--base を渡さない呼び出しは
// 宣言を読まない（従来の呼び出しの形のまま）。after-merge でも PR が見つからなければ非 0（fail-closed）。
func TestCIWaitPRReadsTheTriggerDeclaration(t *testing.T) {
	for _, c := range []struct {
		name, decl  string
		withBase    bool
		prMissing   bool
		wantCI      string
		wantWaited  bool
		wantWarning bool
		wantFail    bool
	}{
		{name: "undeclared", wantCI: "none", wantWaited: true, withBase: true},
		{name: "per-push", decl: `{"trigger": "per-push"}`, wantCI: "none", wantWaited: true, withBase: true},
		{name: "broken JSON", decl: `{"trigger":`, wantCI: "none", wantWaited: true, wantWarning: true, withBase: true},
		{name: "unknown value", decl: `{"trigger": "on-merge"}`, wantCI: "none", wantWaited: true, wantWarning: true, withBase: true},
		{name: "before-merge is not accepted", decl: `{"trigger": "before-merge"}`, wantCI: "none", wantWaited: true, wantWarning: true, withBase: true},
		{name: "after-merge", decl: `{"trigger": "after-merge"}`, wantCI: "skipped", wantWaited: false, withBase: true},
		{name: "after-merge without --base", decl: `{"trigger": "after-merge"}`, wantCI: "none", wantWaited: true},
		{name: "after-merge with a missing PR", decl: `{"trigger": "after-merge"}`, withBase: true, prMissing: true, wantFail: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, repo, _ := tempRepo(t)
			declareCITrigger(t, repo, c.decl)
			scripts := t.TempDir()
			// 偽の ci-wait.sh: 呼ばれた印を残し、none を出す。宣言の読み手は本物を使う。
			marker := filepath.Join(scripts, "ci-wait.called")
			fake := "#!/bin/bash\necho \"$@\" > \"" + marker + "\"\n" +
				`echo '{"ci":"none","failed_checks":[],"failure_log_excerpt":"","pr_url":"https://github.com/o/r/pull/7","pr_number":7,"pr_exists":true}'` + "\n"
			if err := os.WriteFile(filepath.Join(scripts, "ci-wait.sh"), []byte(fake), 0o755); err != nil {
				t.Fatal(err)
			}
			src, err := os.ReadFile(abs(t, repoScripts+"/ci-trigger.sh"))
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(scripts, "ci-trigger.sh"), src, 0o755); err != nil {
				t.Fatal(err)
			}
			ghDir, bin := t.TempDir(), t.TempDir()
			if err := os.Symlink(abs(t, testScripts+"/fake-gh.sh"), filepath.Join(bin, "gh")); err != nil {
				t.Fatal(err)
			}
			if c.prMissing {
				if err := os.WriteFile(filepath.Join(ghDir, "pr-missing"), nil, 0o644); err != nil {
					t.Fatal(err)
				}
			}
			args := []string{abs(t, repoWorkflows+"/scripts/ci-wait-pr.sh"), "--pr", "7"}
			if c.withBase {
				args = append(args, "--base", "main")
			}
			cmd := exec.Command("bash", args...)
			cmd.Dir = repo
			cmd.Env = append(append(os.Environ(), gitIdentity...), "HARNESS_SCRIPTS_DIR="+scripts, "FAKE_GH_DIR="+ghDir,
				"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			var stderr strings.Builder
			cmd.Stderr = &stderr
			out, err := cmd.Output()
			if c.wantFail {
				if err == nil {
					t.Fatalf("ci-wait-pr.sh succeeded with a missing PR: %s", out)
				}
				if _, statErr := os.Stat(marker); statErr == nil {
					t.Error("ci-wait.sh was called")
				}
				return
			}
			if err != nil {
				t.Fatalf("ci-wait-pr.sh: %v\n%s\n%s", err, out, stderr.String())
			}
			got := decode[map[string]any](t, string(out))
			if got["ci"] != c.wantCI || got["pr_exists"] != true || got["pr_number"] != float64(7) {
				t.Fatalf("output = %s", out)
			}
			if _, statErr := os.Stat(marker); (statErr == nil) != c.wantWaited {
				t.Errorf("ci-wait.sh called = %v, want %v", statErr == nil, c.wantWaited)
			}
			if c.wantWaited {
				// ci-wait.sh へ渡す引数は従来どおり PR 番号だけ（--timeout・--interval を渡さないとき）。
				if a := strings.TrimSpace(readFile(t, marker)); a != "7" {
					t.Errorf("ci-wait.sh args = %q, want \"7\"", a)
				}
			}
			if n := strings.Count(stderr.String(), "Warning:"); (n == 1) != c.wantWarning || n > 1 {
				t.Errorf("warnings = %d (want one: %v)\n%s", n, c.wantWarning, stderr.String())
			}
		})
	}
}

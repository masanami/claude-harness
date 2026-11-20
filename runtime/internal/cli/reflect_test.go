package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// reflect（すでにある PR を、既定ブランチの最新を取り込んで検証し、land を受けたら既定ブランチへ入れる依頼。#388 の S3-6）の通しの試験。
// 同梱の reflect ワークフローを、偽の claude・gh と、実の git（bare の origin）で通す。

const reflectURL = "https://github.com/o/r/pull/7"

type reflectFixture struct {
	h                  *harness
	root, repo, origin string
	fdir, ghDir        string
	branch, head, wt   string
	other              string // PR のブランチを checkout している、作った側の作業ツリー
	write              func(name, content string)
}

// newReflectFixture は、PR のブランチ（main から切って 1 コミット）を origin へ push し、別の作業ツリー（作った側）で checkout したまま
// にして、偽の gh がその PR を返すようにする。gate は品質ゲートの宣言（.claude-harness/quality-gate.json）。
func newReflectFixture(t *testing.T, gate string) *reflectFixture {
	t.Helper()
	root, repo, origin := tempRepo(t)
	declareQualityGate(t, repo, gate)
	fdir, fenv := fakeClaude(t)
	ghDir, bin := t.TempDir(), t.TempDir()
	if err := os.Symlink(abs(t, testScripts+"/fake-gh.sh"), filepath.Join(bin, "gh")); err != nil {
		t.Fatal(err)
	}
	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(ghDir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	branch := "feature/issue-42-add-widget"
	git(t, repo, "checkout", "-q", "-b", branch)
	if err := os.WriteFile(filepath.Join(repo, "widget.txt"), []byte("widget\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", "widget.txt")
	git(t, repo, "commit", "-q", "-m", "feat: add the widget")
	git(t, repo, "push", "-q", "origin", branch)
	head := git(t, repo, "rev-parse", "HEAD")
	git(t, repo, "checkout", "-q", "main")
	other := filepath.Join(root, "other-wt")
	git(t, repo, "worktree", "add", "-q", other, branch) // 作った側の作業ツリーが、ブランチを checkout したまま
	git(t, origin, "update-ref", "refs/pull/7/head", head)

	write("adopt.json", adoptJSON(branch, head, "OPEN", "main", false, false))
	write("pr-view.json", viewJSON("OPEN", head, "main", ""))
	write("pr-head-ref", origin+"\nrefs/heads/"+branch+"\n")
	write("checks", check("test", "pass"))

	state, data := t.TempDir(), t.TempDir()
	env := append(append(fenv, gitIdentity...),
		"HARNESS_STATE_DIR="+state, "HARNESS_DATA_DIR="+data, "FAKE_GH_DIR="+ghDir, "POLL_SLEEP_CMD=true",
		"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	h := newHarness(t, env...)
	h.cwd = repo
	return &reflectFixture{h: h, root: root, repo: repo, origin: origin, fdir: fdir, ghDir: ghDir, branch: branch, head: head,
		wt: filepath.Join(root, "repo-worktrees", "pr-7"), other: other, write: write}
}

func adoptJSON(branch, head, state, base string, fork, draft bool) string {
	return fmt.Sprintf(`{"number":7,"url":%q,"state":%q,"baseRefName":%q,"headRefName":%q,"headRefOid":%q,"isCrossRepository":%v,"isDraft":%v}`,
		reflectURL, state, base, branch, head, fork, draft)
}

func (f *reflectFixture) runArgs(ref string, extra ...string) []string {
	args := []string{"run", "--input", "artifact_ref=" + ref}
	args = append(args, extra...)
	return append(args, "--workflow-dir", abs(f.h.t, repoWorkflows), "--scripts-dir", abs(f.h.t, repoScripts), "reflect")
}

// toReview は reflect をレビュー待ちまで進める。
func (f *reflectFixture) toReview() string {
	f.h.t.Helper()
	out, errOut, code := f.h.run(f.runArgs(reflectURL)...)
	if code != ExitWaiting {
		f.h.t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](f.h.t, out)
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "review" {
		f.h.t.Fatalf("waiting = %+v, steps %s", v.Waiting, stepSeq(v))
	}
	return v.RunID
}

func (f *reflectFixture) ghCalls() string {
	b, _ := os.ReadFile(filepath.Join(f.ghDir, "calls"))
	return string(b)
}

func (f *reflectFixture) merges() int { return strings.Count(f.ghCalls(), "pr\tmerge\t") }

func (f *reflectFixture) assertPROpenAndUntouched() {
	f.h.t.Helper()
	for _, banned := range []string{"pr\tclose", "pr\tmerge", "pr\tedit", "--delete-branch"} {
		if strings.Contains(f.ghCalls(), banned) {
			f.h.t.Fatalf("the PR was touched (%q):\n%s", banned, f.ghCalls())
		}
	}
	if got := git(f.h.t, f.repo, "ls-remote", "--heads", f.origin, f.branch); !strings.HasPrefix(got, f.head) {
		f.h.t.Fatalf("the PR branch on origin = %q, want it to stay at %s", got, f.head)
	}
}

func (f *reflectFixture) assertWorktreeGone(id string, removed bool) {
	f.h.t.Helper()
	if _, err := os.Stat(f.wt); !os.IsNotExist(err) {
		f.h.t.Fatalf("the worktree %s still exists (err %v)", f.wt, err)
	}
	if list := git(f.h.t, f.repo, "worktree", "list", "--porcelain"); strings.Contains(list, f.wt) {
		f.h.t.Fatalf("git still lists the worktree:\n%s", list)
	}
	ws := f.h.statusOf(id).Unit("main").Workspace
	if ws == nil || !ws.Released || ws.Removed != removed {
		f.h.t.Fatalf("workspace = %+v, want released (removed %v)", ws, removed)
	}
}

// adopt の結果を 1 行ずつ: 扱えない PR・入力では、作業ツリーを作らず、決められた理由で失敗する。
func TestReflectAdoptOutcomes(t *testing.T) {
	cases := []struct {
		name, outcome, reason string
		ref                   string
		adopt, repoView       string // 空なら既定のまま
		ghCalled              bool
	}{
		{name: "a branch name", ref: "feature/issue-42-add-widget", outcome: "unsupported_ref", reason: "integration_reflect_unsupported"},
		{name: "a pull request number", ref: "7", outcome: "unsupported_ref", reason: "integration_reflect_unsupported"},
		{name: "a URL with a suffix", ref: reflectURL + "/files", outcome: "unsupported_ref", reason: "integration_reflect_unsupported"},
		{name: "a closed pull request", adopt: "closed", outcome: "not_open", reason: "pr_not_open", ghCalled: true},
		{name: "a merged pull request", adopt: "merged", outcome: "not_open", reason: "pr_not_open", ghCalled: true},
		{name: "a pull request to another base", adopt: "develop", outcome: "not_default_base", reason: "pr_not_default_base", ghCalled: true},
		{name: "a pull request from a fork", adopt: "fork", outcome: "fork", reason: "pr_from_fork", ghCalled: true},
		{name: "a draft pull request", adopt: "draft", outcome: "draft", reason: "pr_draft", ghCalled: true},
		{name: "a pull request of another repository", ref: "https://github.com/x/y/pull/7", outcome: "other_repo", reason: "pr_other_repo", ghCalled: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newReflectFixture(t, `{"test": "true"}`)
			ref := c.ref
			if ref == "" {
				ref = reflectURL
			}
			switch c.adopt {
			case "closed", "merged":
				f.write("adopt.json", adoptJSON(f.branch, f.head, strings.ToUpper(c.adopt), "main", false, false))
			case "develop":
				f.write("adopt.json", adoptJSON(f.branch, f.head, "OPEN", "develop", false, false))
			case "fork":
				f.write("adopt.json", adoptJSON(f.branch, f.head, "OPEN", "main", true, false))
			case "draft":
				f.write("adopt.json", adoptJSON(f.branch, f.head, "OPEN", "main", false, true))
			}
			out, errOut, code := f.h.run(f.runArgs(ref)...)
			if code != ExitFailed {
				t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
			}
			v := decode[statusView](t, out)
			if v.Status != runstate.StatusFailed || v.Reason != c.reason || stepSeq(v) != "adopt:"+c.outcome {
				t.Fatalf("status %s reason %s steps %s", v.Status, v.Reason, stepSeq(v))
			}
			if _, err := os.Stat(f.wt); !os.IsNotExist(err) {
				t.Fatalf("a worktree was made for a pull request that is not accepted (err %v)", err)
			}
			if got := strings.Contains(f.ghCalls(), "pr\tview"); got != c.ghCalled {
				t.Fatalf("gh pr view called = %v, want %v:\n%s", got, c.ghCalled, f.ghCalls())
			}
			f.assertPROpenAndUntouched()
		})
	}
}

// URL → 取り込み → 検証 → レビュー待ち（options は land だけ・commit が 1 つ・facts は出ない）→ land → 入って片付け → succeeded。
// land の前に既定ブランチへ入らない。PR のブランチが別の作業ツリーで checkout されたままでも進む（作業ツリーは detached）。
func TestReflectEndToEnd(t *testing.T) {
	f := newReflectFixture(t, `{"test": "true"}`)
	mainBefore := git(t, f.repo, "ls-remote", "--heads", f.origin, "main")
	id := f.toReview()

	v := f.h.statusOf(id)
	if got := stepSeq(v); got != "adopt:adopted workspace:created sync:current quality:pass push:unchanged" {
		t.Fatalf("steps = %s", got)
	}
	ws := v.Unit("main").Workspace
	if ws == nil || ws.WorktreePath != f.wt || !ws.Created || ws.PRNumber != 7 || ws.Branch != f.branch || ws.HeadSHA != f.head {
		t.Fatalf("workspace = %+v", ws)
	}
	// 作業ツリーは detached で、PR のブランチは作った側の作業ツリーが checkout したまま。
	if cur := git(t, f.wt, "branch", "--show-current"); cur != "" {
		t.Fatalf("the worktree is on the branch %q, want detached", cur)
	}
	if cur := git(t, f.other, "branch", "--show-current"); cur != f.branch {
		t.Fatalf("the original worktree left the branch (now %q)", cur)
	}
	if git(t, f.wt, "rev-parse", "HEAD") != f.head {
		t.Fatalf("the worktree is not at the PR head")
	}

	d, _ := f.h.contract("status", id)
	if d.State != "waiting" || d.RequestedAction == nil {
		t.Fatalf("doc = %+v", d)
	}
	if rd, _ := f.h.contract("status", "--accept-kind", "review", id); rd.RequestedAction == nil || rd.RequestedAction.Kind != "review" {
		t.Fatalf("the review gate is not shown as a review: %+v", rd.RequestedAction)
	}
	if got := strings.Join(d.RequestedAction.Options, ","); got != "land" {
		t.Fatalf("options = %s, want land only", got)
	}
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != f.head {
		t.Fatalf("commit artifacts = %v, want exactly [%s]", refs, f.head)
	}
	if d.Facts != nil {
		t.Fatalf("reflect declares no facts, got %v", d.Facts)
	}
	// respond・ready は受けない。
	for _, in := range []string{"respond", "ready"} {
		if out, errOut, code := f.h.run("resume", id, "--input", in); code == ExitOK {
			t.Fatalf("resume --input %s was accepted\n%s\n%s", in, out, errOut)
		}
	}
	// land の前に、既定ブランチへ入っていない。
	if f.merges() != 0 || git(t, f.repo, "ls-remote", "--heads", f.origin, "main") != mainBefore {
		t.Fatalf("something was merged before land (%d merges)", f.merges())
	}

	f.write("pr-view.json", viewJSON("OPEN", f.head, "main", ""))
	f.write("merge.then", viewJSON("MERGED", f.head, "main", "squashed0000000000000000000000000000000000"))
	d, errOut := f.h.contract("resume", "--unit", "main", "--input", "land", "--approved-ref", f.head, id)
	if d.State != runstate.StatusSucceeded || d.RequestedAction != nil {
		t.Fatalf("doc = %+v\n%s", d, errOut)
	}
	if want := "pr\tmerge\t7\t--squash\t--match-head-commit\t" + f.head + "\n"; !strings.Contains(f.ghCalls(), want) {
		t.Fatalf("gh calls lack %q:\n%s", want, f.ghCalls())
	}
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != "squashed0000000000000000000000000000000000" {
		t.Fatalf("commit artifacts after landing = %v", refs)
	}
	v = f.h.statusOf(id)
	if v.Status != runstate.StatusSucceeded || v.Reason != "landed" || !strings.HasSuffix(stepSeq(v), " land:landed cleanup:released") {
		t.Fatalf("status %s reason %s steps %s", v.Status, v.Reason, stepSeq(v))
	}
	f.assertWorktreeGone(id, true)
	if got := git(t, f.repo, "ls-remote", "--heads", f.origin, f.branch); !strings.HasPrefix(got, f.head) {
		t.Fatalf("the PR branch on origin must stay (the repository's setting deletes it): %q", got)
	}
}

// challenge_id は受けるだけで、動きを変えない。
func TestReflectAcceptsChallengeID(t *testing.T) {
	f := newReflectFixture(t, `{"test": "true"}`)
	out, errOut, code := f.h.run(f.runArgs(reflectURL, "--input", "challenge_id=C-12")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
}

// 宛先が動いた → 入れずに、取り込んで PR のブランチへ push し（detached の作業ツリーから HEAD:refs/heads/<ブランチ>）、新しい先頭でレビュー待ちへ戻る。
func TestReflectLandWhenTheBaseMovedSyncsAndPushes(t *testing.T) {
	f := newReflectFixture(t, `{"test": "true"}`)
	id := f.toReview()
	other := t.TempDir()
	git(t, other, "clone", "-q", f.origin, "c")
	clone := filepath.Join(other, "c")
	if err := os.WriteFile(filepath.Join(clone, "other.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, clone, "add", "other.txt")
	git(t, clone, "commit", "-q", "-m", "chore: advance main")
	git(t, clone, "push", "-q", "origin", "main")
	newBase := git(t, clone, "rev-parse", "HEAD")

	d, _ := f.h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", f.head, id)
	_ = d
	d = f.h.settle(id)
	v := f.h.statusOf(id)
	if d.State != "waiting" || v.Waiting[0].Gate != "review" || !strings.HasSuffix(stepSeq(v), " land:behind land-sync:synced land-push:pushed") {
		t.Fatalf("doc %+v steps %s", d, stepSeq(v))
	}
	if f.merges() != 0 {
		t.Fatalf("a PR behind its base must not be merged")
	}
	refs := commitRefs(d)
	remote := strings.Fields(git(t, f.repo, "ls-remote", "--heads", f.origin, f.branch))[0]
	if len(refs) != 1 || refs[0] == f.head || refs[0] != remote {
		t.Fatalf("commit artifacts = %v, the PR branch on origin = %s", refs, remote)
	}
	if parents := strings.Fields(git(t, f.repo, "rev-list", "--parents", "-n", "1", remote)); len(parents) != 3 || parents[1] != f.head || parents[2] != newBase {
		t.Fatalf("parents of the new head = %v", parents)
	}
	if got := git(t, f.repo, "ls-remote", "--heads", f.origin, "main"); !strings.HasPrefix(got, newBase) {
		t.Fatalf("main moved: %s", got)
	}
	if got := strings.Join(d.RequestedAction.Options, ","); got != "land" {
		t.Fatalf("options after the return = %s", got)
	}
}

// 取り消し（待っているとき）: 作業ツリーが消え、PR は開いたまま（既定ブランチへ入れず、閉じず、ブランチを消さない）。
func TestReflectCancelWhileWaitingRemovesTheWorktreeAndLeavesThePR(t *testing.T) {
	f := newReflectFixture(t, `{"test": "true"}`)
	id := f.toReview()
	if _, err := os.Stat(f.wt); err != nil {
		t.Fatal(err)
	}
	if out, errOut, code := f.h.run("cancel", id); code != ExitOK {
		t.Fatalf("cancel exit %d\n%s%s", code, out, errOut)
	}
	if st := f.h.statusOf(id).Status; st != runstate.StatusCancelled {
		t.Fatalf("status = %s", st)
	}
	f.assertWorktreeGone(id, true)
	f.assertPROpenAndUntouched()
	// 片付けは終わりを書く前に行う。
	if types := eventTypes(t, filepath.Join(f.h.stateDir(), "runs", id)); !strings.HasSuffix(types, "cancel_requested workspace run_cancelled") {
		t.Fatalf("events = %s", types)
	}
}

// 取り消し（走っているとき）: runner が止まり、作業ツリーが消え、PR は開いたまま。runner が落ちた後の cancel も同じ。
func TestReflectCancelWhileRunningRemovesTheWorktree(t *testing.T) {
	for _, killRunner := range []bool{false, true} {
		t.Run(fmt.Sprintf("runner killed first: %v", killRunner), func(t *testing.T) {
			marker := filepath.Join(t.TempDir(), "quality-started")
			f := newReflectFixture(t, `{"test": "make gate"}`)
			// 品質の検査（make gate）が、始まったことを知らせてから待ち続ける。
			if err := os.WriteFile(filepath.Join(f.repo, "Makefile"), []byte("gate:\n\t@touch \"$(MARKER)\"; sleep 60\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			git(t, f.repo, "add", "Makefile")
			git(t, f.repo, "commit", "-q", "-m", "chore: add the gate")
			git(t, f.repo, "push", "-q", "origin", "main")
			f.h = f.h.with("MARKER=" + marker)
			runner := f.h.cmd(f.runArgs(reflectURL)...)
			if err := runner.Start(); err != nil {
				t.Fatal(err)
			}
			defer runner.Process.Kill()
			waitFor(t, func() bool { _, err := os.Stat(marker); return err == nil })
			id := onlyRun(t, f.h)
			if killRunner {
				// 品質の検査が実行中のまま、runner だけを落とす。
				waitFor(t, func() bool {
					x := f.h.statusOf(id).Unit("main").Running()
					return x != nil && x.Step == "quality"
				})
				_ = runner.Process.Signal(syscall.SIGKILL)
				_ = runner.Wait()
			}
			if out, errOut, code := f.h.run("cancel", id); code != ExitOK {
				t.Fatalf("cancel exit %d\n%s%s", code, out, errOut)
			}
			if !killRunner {
				if err := waitExit(runner, 20*time.Second); err != nil {
					t.Fatal(err)
				}
			}
			if st := f.h.statusOf(id).Status; st != runstate.StatusCancelled {
				t.Fatalf("status = %s", st)
			}
			f.assertWorktreeGone(id, true)
			f.assertPROpenAndUntouched()
		})
	}
}

// 失敗で終わるとき（用意の検証が落ちた・取り込みの衝突を直せない・入れた直後に runner が落ちた・runner を起動できなかった）も、
// 作業ツリーが消え、PR は開いたまま（入れたものは入ったまま）。
func TestReflectFailureRemovesTheWorktree(t *testing.T) {
	t.Run("the verification failed", func(t *testing.T) {
		f := newReflectFixture(t, `{"test": "false"}`)
		out, errOut, code := f.h.run(f.runArgs(reflectURL)...)
		if code != ExitFailed {
			t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
		}
		v := decode[statusView](t, out)
		if v.Reason != "quality_gate_red" || !strings.HasSuffix(stepSeq(v), " quality:fail") || strings.Contains(stepSeq(v), "fix") {
			t.Fatalf("reason %s steps %s (a failing verification must end the run, not be fixed)", v.Reason, stepSeq(v))
		}
		f.assertWorktreeGone(v.RunID, true)
		f.assertPROpenAndUntouched()
	})
	t.Run("the verification is not declared", func(t *testing.T) {
		f := newReflectFixture(t, `{}`)
		out, errOut, code := f.h.run(f.runArgs(reflectURL)...)
		if code != ExitFailed {
			t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
		}
		if v := decode[statusView](t, out); v.Reason != "quality_gate_undeclared" {
			t.Fatalf("reason %s", v.Reason)
		} else {
			f.assertWorktreeGone(v.RunID, true)
		}
	})
	t.Run("the conflict of the sync cannot be resolved", func(t *testing.T) {
		f := newReflectFixture(t, `{"test": "true"}`)
		// PR のブランチも宛先も、同じファイルを別の内容にする（PR を切った後に宛先が動いた）。
		if err := os.WriteFile(filepath.Join(f.other, "README.md"), []byte("from the PR\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		git(t, f.other, "commit", "-q", "-am", "feat: change the README")
		git(t, f.other, "push", "-q", "origin", f.branch)
		f.head = git(t, f.other, "rev-parse", "HEAD")
		git(t, f.origin, "update-ref", "refs/pull/7/head", f.head)
		f.write("adopt.json", adoptJSON(f.branch, f.head, "OPEN", "main", false, false))
		if err := os.WriteFile(filepath.Join(f.repo, "README.md"), []byte("from main\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		git(t, f.repo, "commit", "-q", "-am", "chore: change the README on main")
		git(t, f.repo, "push", "-q", "origin", "main")
		respond(t, f.fdir, 1, 0, claudeStructured(map[string]any{"outcome": "failure", "summary": "cannot decide which side to keep"}, 0.5))
		out, errOut, code := f.h.run(f.runArgs(reflectURL)...)
		if code != ExitFailed {
			t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
		}
		v := decode[statusView](t, out)
		if v.Reason != "sync_conflict" || !strings.Contains(stepSeq(v), "sync:conflict sync-resolve:failure") {
			t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
		}
		f.assertWorktreeGone(v.RunID, true)
		f.assertPROpenAndUntouched()
	})
	t.Run("the runner died right after landing", func(t *testing.T) {
		f := newReflectFixture(t, `{"test": "true"}`)
		id := f.toReview()
		f.write("merge.then", viewJSON("MERGED", f.head, "main", "squashed1111111111111111111111111111111111"))
		f.write("merge.kill", "1")
		f.h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", f.head, id)
		d := f.h.settle(id)
		v := f.h.statusOf(id)
		if d.State != runstate.StatusFailed || v.Reason != "interrupted_after_land" || len(v.Waiting) != 0 {
			t.Fatalf("doc %+v status %s reason %s", d, v.Status, v.Reason)
		}
		f.assertWorktreeGone(id, true)
		if f.merges() != 1 {
			t.Fatalf("merges = %d", f.merges())
		}
	})
	t.Run("the runner could not be started", func(t *testing.T) {
		f := newReflectFixture(t, `{"test": "true"}`)
		id := f.toReview()
		breakRunnerLog(t, f.h, id)
		d, _ := f.h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", f.head, id)
		if d.State != runstate.StatusFailed || !strings.Contains(d.Summary, "interrupted_after_land") {
			t.Fatalf("doc = %+v", d)
		}
		f.assertWorktreeGone(id, true)
		f.assertPROpenAndUntouched()
	})
}

// 同じ PR への依頼が 2 本重なっても、後の方は別の run の detached の作業ツリーに相乗りしない（worktree_conflict）。先の run の作業ツリーは残る。
func TestReflectDoesNotShareAnotherRunsWorktree(t *testing.T) {
	f := newReflectFixture(t, `{"test": "true"}`)
	first := f.toReview()
	out, errOut, code := f.h.run(f.runArgs(reflectURL)...)
	if code != ExitFailed {
		t.Fatalf("second run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "worktree_conflict" || v.RunID == first {
		t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
	}
	if _, err := os.Stat(f.wt); err != nil {
		t.Fatalf("the first run's worktree was removed by the second run: %v", err)
	}
	if ws := f.h.statusOf(first).Unit("main").Workspace; ws == nil || ws.Released {
		t.Fatalf("first run's workspace = %+v", ws)
	}
}

// ticket は、取り消し・失敗で終わっても作業ツリーを残す（人が見て続きを直す、いまの動き）。
func TestTicketKeepsTheWorktreeWhenCancelledOrFailed(t *testing.T) {
	t.Run("cancelled", func(t *testing.T) {
		l := newLandFixture(t, nil)
		wt := filepath.Join(l.f.root, "repo-worktrees", "issue-42")
		if out, errOut, code := l.f.h.run("cancel", l.id); code != ExitOK {
			t.Fatalf("cancel exit %d\n%s%s", code, out, errOut)
		}
		v := l.f.h.statusOf(l.id)
		if _, err := os.Stat(wt); err != nil {
			t.Fatalf("the worktree was removed on cancel: %v", err)
		}
		if ws := v.Unit("main").Workspace; v.Status != runstate.StatusCancelled || ws == nil || ws.Released {
			t.Fatalf("status %s workspace %+v", v.Status, ws)
		}
		if types := eventTypes(t, filepath.Join(l.f.h.stateDir(), "runs", l.id)); strings.Contains(types, "workspace run_cancelled") {
			t.Fatalf("events = %s", types)
		}
	})
	t.Run("failed", func(t *testing.T) {
		l := newLandFixture(t, nil)
		wt := filepath.Join(l.f.root, "repo-worktrees", "issue-42")
		l.merged(l.head, "squashed4444444444444444444444444444444444")
		l.f.write("merge.kill", "1")
		l.f.h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", l.head, l.id)
		d := l.f.h.settle(l.id)
		v := l.f.h.statusOf(l.id)
		if d.State != runstate.StatusFailed || v.Reason != "interrupted_after_land" {
			t.Fatalf("doc %+v reason %s", d, v.Reason)
		}
		if _, err := os.Stat(wt); err != nil {
			t.Fatalf("the worktree was removed on failure: %v", err)
		}
		if ws := v.Unit("main").Workspace; ws == nil || ws.Released {
			t.Fatalf("workspace %+v", ws)
		}
	})
}

// 片付けは、この run が作ったと所有の印で確かめられる作業ツリーだけを消す。印が無ければ消さず、理由を released の記録に残し、
// 終わり（取り消し）は成立させる。
func TestReflectCancelKeepsAWorktreeWithoutTheOwnershipMark(t *testing.T) {
	f := newReflectFixture(t, `{"test": "true"}`)
	id := f.toReview()
	gitDir := git(t, f.wt, "rev-parse", "--absolute-git-dir")
	if err := os.Remove(filepath.Join(gitDir, "claude-harness-owner")); err != nil {
		t.Fatal(err)
	}
	if out, errOut, code := f.h.run("cancel", id); code != ExitOK {
		t.Fatalf("cancel exit %d\n%s%s", code, out, errOut)
	}
	v := f.h.statusOf(id)
	ws := v.Unit("main").Workspace
	if v.Status != runstate.StatusCancelled || ws == nil || !ws.Released || ws.Removed || !strings.Contains(ws.ReleaseNote, "ownership mark") {
		t.Fatalf("status %s workspace %+v", v.Status, ws)
	}
	if _, err := os.Stat(f.wt); err != nil {
		t.Fatalf("a worktree this run cannot prove it made was removed: %v", err)
	}
}

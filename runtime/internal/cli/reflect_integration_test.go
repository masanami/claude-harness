package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// reflect が統合ブランチの名前を受ける道（docs/harness-runtime-design.md §5.6.3 の S3b-3）。偽の claude・gh、実の git（bare の origin）で、
// 同梱の reflect を通す。統合ブランチ integration/c-12 は、main から 1 コミット進んだ origin のブランチで、開いている PR は無い。

const (
	integration    = "integration/c-12"
	squashedCommit = "squashed2222222222222222222222222222222222"
)

type integrationReflect struct {
	*reflectFixture
}

func newIntegrationReflect(t *testing.T, gate string) *integrationReflect {
	t.Helper()
	rf := newReflectFixture(t, gate)
	f := &integrationReflect{rf}
	git(t, f.repo, "push", "-q", "origin", f.head+":refs/heads/"+integration)
	f.write("pr-head-ref", f.origin+"\nrefs/heads/"+integration+"\n")
	f.write("pr-view.json", f.integrationView("OPEN", ""))
	f.write("create.oid", f.head)
	f.write("pr-list-merged", `[{"number":3,"title":"feat: add the widget (task 1)","url":"https://github.com/o/r/pull/3","body":"## 概要\n\nx\n\nCloses #42\nRefs #40\n"},`+
		`{"number":4,"title":"feat: another task","url":"https://github.com/o/r/pull/4","body":"Refs #40\nRefs #41\nCloses #42 (not a whole line)\n"}]`)
	respond(t, f.fdir, 1, 0, claudeStructured(map[string]any{"outcome": "ok", "pr_title": "feat: add the widget set", "summary": "the widgets of challenge C-12"}, 0.3))
	return f
}

func (f *integrationReflect) integrationView(state, merge string) string {
	mc := "null"
	if merge != "" {
		mc = `{"oid":"` + merge + `"}`
	}
	return `{"title":"feat: add the widget set","state":"` + state + `","headRefOid":"` + f.head + `","headRefName":"` + integration + `","baseRefName":"main","mergeCommit":` + mc + `,"isDraft":false}`
}

func (f *integrationReflect) originBranch() string {
	return git(f.h.t, f.repo, "ls-remote", "--heads", f.origin, integration)
}

func (f *integrationReflect) toReview(extra ...string) string {
	f.h.t.Helper()
	out, errOut, code := f.h.run(f.runArgs(integration, extra...)...)
	if code != ExitWaiting {
		f.h.t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](f.h.t, out)
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "review" {
		f.h.t.Fatalf("waiting = %+v, steps %s", v.Waiting, stepSeq(v))
	}
	return v.RunID
}

func (f *integrationReflect) land(id string) contractDoc {
	f.h.t.Helper()
	f.write("merge.then", f.integrationView("MERGED", squashedCommit))
	d, errOut := f.h.contract("resume", "--unit", "main", "--input", "land", "--approved-ref", f.head, id)
	if d.State != runstate.StatusSucceeded {
		f.h.t.Fatalf("doc = %+v\n%s", d, errOut)
	}
	return d
}

func (f *integrationReflect) assertIntegrationAndPRStay(id string) {
	f.h.t.Helper()
	if got := f.originBranch(); !strings.HasPrefix(got, f.head) {
		f.h.t.Fatalf("the integration branch on origin = %q, want it to stay at %s", got, f.head)
	}
	for _, banned := range []string{"pr\tclose", "pr\tmerge", "pr\tedit"} {
		if strings.Contains(f.ghCalls(), banned) {
			f.h.t.Fatalf("the PR was touched (%q):\n%s", banned, f.ghCalls())
		}
	}
}

// ブランチの名前 → PR が作られる（describe は run を始めたディレクトリで動く）→ 取り込みが統合ブランチへ push される → 検証 → レビュー待ち
// （options は land だけ・role の無い commit が 1 つ・role の付いた要素が無い）→ land の前に既定ブランチへ入らない → land → 入って、統合ブランチが消え、succeeded。
func TestReflectIntegrationBranchEndToEnd(t *testing.T) {
	f := newIntegrationReflect(t, `{"test": "true"}`)
	// 既定ブランチが進んでいる（取り込みのマージが、統合ブランチへ push される）。
	clone := filepath.Join(t.TempDir(), "c")
	git(t, f.root, "clone", "-q", f.origin, clone)
	if err := os.WriteFile(filepath.Join(clone, "later.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, clone, "add", "later.txt")
	git(t, clone, "commit", "-q", "-m", "chore: advance main")
	git(t, clone, "push", "-q", "origin", "main")
	mainHead := git(t, clone, "rev-parse", "HEAD")

	id := f.toReview("--input", "challenge_id=C-12")
	v := f.h.statusOf(id)
	if got := stepSeq(v); got != "adopt:no_pr describe:ok open:opened adopt:adopted workspace:created sync:synced quality:pass push:pushed" {
		t.Fatalf("steps = %s", got)
	}
	// describe は、作業ツリーの払い出しより前に、run を始めたディレクトリで動く。
	wantDir, err := filepath.EvalSymlinks(f.repo)
	if err != nil {
		t.Fatal(err)
	}
	if pwd := strings.TrimSpace(readFile(t, filepath.Join(f.fdir, "calls", "1.pwd"))); pwd != wantDir {
		t.Fatalf("describe ran in %q, want the directory the run was started in %q", pwd, wantDir)
	}
	// PR は、題名と、Go が組み立てた本文で作られる。
	if want := "pr\tcreate\t--base\tmain\t--head\t" + integration + "\t--title\tfeat: add the widget set\t--body-file\t"; !strings.Contains(f.ghCalls(), want) {
		t.Fatalf("gh calls lack %q:\n%s", want, f.ghCalls())
	}
	body := readFile(t, filepath.Join(f.ghDir, "body.1.md"))
	for _, want := range []string{"the widgets of challenge C-12", "| #3 | feat: add the widget (task 1) |", "| #4 | feat: another task |",
		"Closes #42\nRefs #40\nRefs #41\n", "課題: `C-12`。"} {
		if !strings.Contains(body, want) {
			t.Errorf("body lacks %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "Closes #42 (not") {
		t.Errorf("a line that is not a whole-line match was copied:\n%s", body)
	}
	ws := v.Unit("main").Workspace
	if ws == nil || ws.PRNumber != 7 || ws.Branch != integration || ws.WorktreePath != f.wt || !ws.Created {
		t.Fatalf("workspace = %+v", ws)
	}
	// 取り込み（既定ブランチの最新のマージ）が、統合ブランチへ push されている。
	remote := strings.Fields(f.originBranch())[0]
	if parents := strings.Fields(git(t, f.repo, "rev-list", "--parents", "-n", "1", remote)); len(parents) != 3 || parents[1] != f.head || parents[2] != mainHead {
		t.Fatalf("parents of the integration head = %v (head %s, main %s)", parents, f.head, mainHead)
	}
	if cur := git(t, f.wt, "branch", "--show-current"); cur != "" {
		t.Fatalf("the worktree is on the branch %q, want detached", cur)
	}
	if got := git(t, f.repo, "ls-remote", "--heads", f.origin, "main"); !strings.HasPrefix(got, mainHead) {
		t.Fatalf("main moved: %s", got)
	}

	d, _ := f.h.contract("status", id)
	if d.State != "waiting" || d.RequestedAction == nil || strings.Join(d.RequestedAction.Options, ",") != "land" {
		t.Fatalf("doc = %+v", d)
	}
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != remote {
		t.Fatalf("commit artifacts = %v, want exactly [%s]", refs, remote)
	}
	if n, _ := countRole(d.Artifacts, "commit", ""); n != 1 {
		t.Fatalf("commit artifacts without a role = %d: %+v", n, d.Artifacts)
	}
	for _, a := range d.Artifacts {
		if a.Role != "" {
			t.Fatalf("reflect must not output an element with a role: %+v", d.Artifacts)
		}
	}
	// land を受けるまで既定ブランチへ入れない。
	if f.merges() != 0 {
		t.Fatalf("something was merged before land")
	}

	f.write("pr-view.json", f.integrationView("OPEN", ""))
	f.write("pr-head-ref", f.origin+"\nrefs/heads/"+integration+"\n")
	// land は、レビュー待ちの先頭（取り込み後）で行う。
	f.head = remote
	d = f.land(id)
	if want := "pr\tmerge\t7\t--squash\t--match-head-commit\t" + remote + "\t--subject\tfeat: add the widget set (#7)\n"; !strings.Contains(f.ghCalls(), want) {
		t.Fatalf("gh calls lack %q:\n%s", want, f.ghCalls())
	}
	v = f.h.statusOf(id)
	if v.Status != runstate.StatusSucceeded || v.Reason != "landed" || !strings.HasSuffix(stepSeq(v), " land:landed retire-route:integration retire:deleted cleanup:released") {
		t.Fatalf("status %s reason %s steps %s", v.Status, v.Reason, stepSeq(v))
	}
	if got := f.originBranch(); got != "" {
		t.Fatalf("the integration branch is still on origin: %q", got)
	}
	if !strings.Contains(git(t, f.repo, "ls-remote", "--heads", f.origin, "main"), mainHead) {
		t.Fatalf("main is not where it was")
	}
	f.assertWorktreeGone(id, true)
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != squashedCommit {
		t.Fatalf("commit artifacts after landing = %v", refs)
	}
}

// retire が kept（統合ブランチ宛ての、開いている PR が在る）でも succeeded。終わりの理由は landed_integration_kept で、統合ブランチは残る。
func TestReflectIntegrationBranchKeptStillSucceeds(t *testing.T) {
	f := newIntegrationReflect(t, `{"test": "true"}`)
	id := f.toReview()
	f.write("pr-list-base-open", `[{"number":20}]`)
	f.land(id)
	v := f.h.statusOf(id)
	if v.Status != runstate.StatusSucceeded || v.Reason != "landed_integration_kept" || !strings.HasSuffix(stepSeq(v), " land:landed retire-route:integration retire:kept cleanup-kept:released") {
		t.Fatalf("status %s reason %s steps %s", v.Status, v.Reason, stepSeq(v))
	}
	if got := f.originBranch(); !strings.HasPrefix(got, f.head) {
		t.Fatalf("the integration branch must stay: %q", got)
	}
	f.assertWorktreeGone(id, true)
}

// 入れた後に統合ブランチの先頭が動いていたら、統合ブランチは消えず、実行は succeeded（理由 landed_integration_kept）で終わる。
func TestReflectIntegrationBranchMovedAfterLandingIsKept(t *testing.T) {
	f := newIntegrationReflect(t, `{"test": "true"}`)
	id := f.toReview()
	// 入った後に、別の誰かが統合ブランチへ積む（偽の gh が、入れる命令の後でこの手順を走らせる）。PR の先頭は、入った先頭のまま見せる。
	if err := os.Remove(filepath.Join(f.ghDir, "pr-head-ref")); err != nil {
		t.Fatal(err)
	}
	f.write("merge.run", "set -e\nc=$(mktemp -d)\ngit clone -q '"+f.origin+"' \"$c/x\"\ncd \"$c/x\"\ngit checkout -q -B t origin/"+integration+"\necho late > late.txt\ngit add late.txt\ngit commit -q -m 'chore: a late push'\ngit push -q origin t:refs/heads/"+integration+"\n")
	f.land(id)
	v := f.h.statusOf(id)
	if v.Status != runstate.StatusSucceeded || v.Reason != "landed_integration_kept" || !strings.HasSuffix(stepSeq(v), " land:landed retire-route:integration retire:kept cleanup-kept:released") {
		t.Fatalf("status %s reason %s steps %s", v.Status, v.Reason, stepSeq(v))
	}
	if got := f.originBranch(); got == "" || strings.HasPrefix(got, f.head) {
		t.Fatalf("the integration branch must stay at the late push, got %q", got)
	}
	f.assertWorktreeGone(id, true)
}

// 取り消しでも、統合ブランチと PR は残り、作業ツリーが消える。
func TestReflectIntegrationBranchCancelKeepsTheBranchAndThePR(t *testing.T) {
	f := newIntegrationReflect(t, `{"test": "true"}`)
	id := f.toReview()
	if out, errOut, code := f.h.run("cancel", id); code != ExitOK {
		t.Fatalf("cancel exit %d\n%s%s", code, out, errOut)
	}
	if st := f.h.statusOf(id).Status; st != runstate.StatusCancelled {
		t.Fatalf("status = %s", st)
	}
	f.assertWorktreeGone(id, true)
	f.assertIntegrationAndPRStay(id)
	if strings.Contains(f.ghCalls(), "state,headRefOid,headRefName,baseRefName") {
		t.Fatalf("retire ran on a cancelled run")
	}
}

// 検証が落ちた失敗でも、統合ブランチが残る。
func TestReflectIntegrationBranchFailureKeepsTheBranch(t *testing.T) {
	f := newIntegrationReflect(t, `{"test": "false"}`)
	out, errOut, code := f.h.run(f.runArgs(integration)...)
	if code != ExitFailed {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "quality_gate_red" || strings.Contains(stepSeq(v), "retire") {
		t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
	}
	f.assertWorktreeGone(v.RunID, true)
	f.assertIntegrationAndPRStay(v.RunID)
}

// 同じ統合ブランチへの 2 本目の依頼は、在る PR を使い（PR を増やさない）、作業ツリーの鍵が同じなので worktree_conflict で止まる。
func TestReflectIntegrationBranchSecondRequestUsesTheExistingPR(t *testing.T) {
	f := newIntegrationReflect(t, `{"test": "true"}`)
	first := f.toReview()
	out, errOut, code := f.h.run(f.runArgs(integration)...)
	if code != ExitFailed {
		t.Fatalf("second run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "worktree_conflict" || v.RunID == first || stepSeq(v) != "adopt:adopted workspace:conflict" {
		t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
	}
	if n := strings.Count(f.ghCalls(), "pr\tcreate\t"); n != 1 {
		t.Fatalf("pull requests created = %d, want 1", n)
	}
}

// 作った PR の後でも見つからない（adopt へ戻っても no_pr のまま）→ pr_not_found。PR を 2 つ作らない。
func TestReflectIntegrationBranchPRNotFoundAfterCreating(t *testing.T) {
	f := newIntegrationReflect(t, `{"test": "true"}`)
	f.write("pr-number", "7")
	// create の後に pr-list を書き戻して、見つからない状態にする（作った PR が見えない）。
	f.write("create.nolist", "1")
	out, errOut, code := f.h.run(f.runArgs(integration)...)
	if code != ExitFailed {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "pr_not_found" || stepSeq(v) != "adopt:no_pr describe:ok open:opened adopt:no_pr" {
		t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
	}
	if n := strings.Count(f.ghCalls(), "pr\tcreate\t"); n != 1 {
		t.Fatalf("pull requests created = %d, want 1", n)
	}
}

// 差分の無い統合ブランチ・題名を書けなかった describe は、PR を作らず失敗で終わる。
func TestReflectIntegrationBranchEmptyAndDescribeFailed(t *testing.T) {
	t.Run("no difference", func(t *testing.T) {
		f := newIntegrationReflect(t, `{"test": "true"}`)
		git(t, f.repo, "push", "-q", "origin", f.head+":refs/heads/main")
		out, errOut, code := f.h.run(f.runArgs(integration)...)
		if code != ExitFailed {
			t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
		}
		if v := decode[statusView](t, out); v.Reason != "integration_empty" || stepSeq(v) != "adopt:empty" {
			t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
		}
		if strings.Contains(f.ghCalls(), "pr\tcreate") {
			t.Fatalf("a pull request was created for an empty branch")
		}
	})
	t.Run("describe failed", func(t *testing.T) {
		f := newIntegrationReflect(t, `{"test": "true"}`)
		respond(t, f.fdir, 1, 0, claudeStructured(map[string]any{"outcome": "failure", "pr_title": "", "summary": "cannot read the diff"}, 0.3))
		out, errOut, code := f.h.run(f.runArgs(integration)...)
		if code != ExitFailed {
			t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
		}
		if v := decode[statusView](t, out); v.Reason != "describe_failed" || stepSeq(v) != "adopt:no_pr describe:failure" {
			t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
		}
		if strings.Contains(f.ghCalls(), "pr\tcreate") {
			t.Fatalf("a pull request was created although describe failed")
		}
	})
}

// 開いている PR が在る統合ブランチは、describe・open を通らずに受ける（source: integration）。
func TestReflectIntegrationBranchUsesAnOpenPullRequest(t *testing.T) {
	f := newIntegrationReflect(t, `{"test": "true"}`)
	f.write("pr-list", `[{"number":7,"url":"`+reflectURL+`","headRefName":"`+integration+`","headRefOid":"`+f.head+`","baseRefName":"main","isCrossRepository":false,"isDraft":false}]`)
	id := f.toReview()
	if got := stepSeq(f.h.statusOf(id)); got != "adopt:adopted workspace:created sync:current quality:pass push:unchanged" {
		t.Fatalf("steps = %s", got)
	}
	if _, err := os.Stat(filepath.Join(f.fdir, "count")); strings.Contains(f.ghCalls(), "pr\tcreate") || err == nil {
		t.Fatalf("a pull request was created or describe ran although an open pull request exists")
	}
}

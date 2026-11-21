package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// 統合ブランチ宛ての land・取り込み・取り直し（docs/harness-runtime-design.md §5.6.3 の S3b-2）。偽の gh・bare の origin で、
// 宛先を統合ブランチ（integration/c-12）にした ticket をレビュー待ちまで進めて試す。

const integrationBranch = "integration/c-12"

// newIntegrationLand は、uses_integration の ticket をレビュー待ちまで進める。setup は run を始める前に呼ぶ。
func newIntegrationLand(t *testing.T, setup func(f *ticketFixture), extraEnv ...string) *landFixture {
	t.Helper()
	f := newTicketFixture(t, extraEnv...)
	greenCI(f)
	f.setAnalyzeBranch("feature/task-1-add-widget")
	f.branch = "feature/task-1-add-widget"
	if setup != nil {
		setup(f)
	}
	run := startIntegration(t, f, "T-1", "uses_integration=true", "challenge_id=C-12")
	if len(run.out.Waiting) != 1 || run.out.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v, steps %s", run.out.Waiting, stepSeq(run.out))
	}
	l := &landFixture{f: f, id: run.id, head: originHead(t, f), base: integrationBranch}
	l.setPRHead(l.head)
	return l
}

// advanceIntegration は origin の統合ブランチを、メインのクローンから進める（宛先が動いた）。
func advanceIntegration(t *testing.T, f *ticketFixture, name, content string) string {
	t.Helper()
	git(t, f.repo, "fetch", "-q", "origin")
	git(t, f.repo, "checkout", "-q", "-B", "tmp-integration", "origin/"+integrationBranch)
	if err := os.WriteFile(filepath.Join(f.repo, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, f.repo, "add", name)
	git(t, f.repo, "commit", "-q", "-m", "chore: advance integration ("+name+")")
	git(t, f.repo, "push", "-q", "origin", "tmp-integration:refs/heads/"+integrationBranch)
	sha := git(t, f.repo, "rev-parse", "HEAD")
	git(t, f.repo, "checkout", "-q", "main")
	return sha
}

func integrationCommit(t *testing.T, d contractDoc) string {
	t.Helper()
	n, ref := countRole(d.Artifacts, "commit", "integration")
	if n != 1 {
		t.Fatalf("integration commit artifacts = %d: %+v", n, d.Artifacts)
	}
	return ref
}

func integrationEvents(t *testing.T, l *landFixture) int {
	t.Helper()
	out, _, _ := l.f.h.run("status", "--json", l.id)
	dir := decode[statusView](t, out).RunDir
	return strings.Count(readFile(t, filepath.Join(dir, "events.jsonl")), `"action":"integration"`)
}

// 一致して統合ブランチの最新を含む → 統合ブランチへ入って succeeded。role の無い commit と role: integration の commit は、入れた後の
// コミットで同じ値。入れる命令は squash・--match-head-commit。
func TestTicketLandIntoTheIntegrationBranchSucceeds(t *testing.T) {
	l := newIntegrationLand(t, nil)
	before, _ := l.f.h.contract("status", l.id)
	if got := integrationCommit(t, before); got != git(t, l.f.origin, "rev-parse", "refs/heads/"+integrationBranch) {
		t.Fatalf("integration commit before = %s", got)
	}
	const squashed = "squashed0000000000000000000000000000000000"
	l.merged(l.head, squashed)
	d := l.land(l.head)
	if d.State != runstate.StatusSucceeded {
		t.Fatalf("doc = %+v", d)
	}
	if want := "pr\tmerge\t7\t--squash\t--match-head-commit\t" + l.head + "\n"; !strings.Contains(l.ghCalls(), want) {
		t.Fatalf("gh calls lack %q:\n%s", want, l.ghCalls())
	}
	if refs := commitRefs(d); len(refs) != 2 || refs[0] != squashed || refs[1] != squashed {
		t.Fatalf("commit artifacts = %v, want the merge commit for both (with and without a role)", refs)
	}
	if n, ref := countRole(d.Artifacts, "commit", ""); n != 1 || ref != squashed {
		t.Fatalf("the commit without a role = %d %q", n, ref)
	}
	if got := integrationCommit(t, d); got != squashed {
		t.Fatalf("integration commit = %s, want %s (the commit after the merge, not a re-read origin head)", got, squashed)
	}
}

// 通した中身と PR の先頭が違う → 入れずにレビュー待ちへ戻る。宛先は fetch していないので、統合ブランチの先頭の記録は変わらない。
func TestTicketLandMismatchIntoTheIntegrationBranchReturnsToReview(t *testing.T) {
	l := newIntegrationLand(t, nil)
	before, _ := l.f.h.contract("status", l.id)
	recorded := integrationCommit(t, before)
	l.setPRHead(advanceMain(t, l.f, "outside.txt", "x\n"))
	d := l.land(l.head)
	if d.State != "waiting" || l.merges() != 0 {
		t.Fatalf("doc = %+v merges %d", d, l.merges())
	}
	if got := integrationCommit(t, d); got != recorded {
		t.Fatalf("integration commit = %s, want the recorded %s", got, recorded)
	}
}

// 統合ブランチが進んでいる → マージのコミットで取り込み、入れずに、新しい先頭を出してレビュー待ちへ戻る。既定ブランチは取り込まない。
func TestTicketLandWhenTheIntegrationBranchMovedSyncsIt(t *testing.T) {
	env, dir := blockableLsRemote(t)
	l := newIntegrationLand(t, nil, env)
	block(t, dir) // 取り直しが記録を書き直して、取り込みの書いた記録を隠さない
	l.followOrigin()
	mainMoved := advanceMain(t, l.f, "main-only.txt", "m\n")
	moved := advanceIntegration(t, l.f, "other.txt", "x\n")
	d := l.land(l.head)
	if d.State != "waiting" {
		t.Fatalf("doc = %+v", d)
	}
	v := l.f.h.statusOf(l.id)
	if !strings.HasSuffix(stepSeq(v), " land:behind land-sync:synced land-push:pushed") {
		t.Fatalf("steps %s", stepSeq(v))
	}
	if l.merges() != 0 {
		t.Fatalf("a PR behind its base must not be merged (%d merges)", l.merges())
	}
	refs := commitRefs(d)
	newHead := originHead(t, l.f)
	if n, ref := countRole(d.Artifacts, "commit", ""); n != 1 || ref != newHead || newHead == l.head {
		t.Fatalf("the commit without a role = %d %q, want the new head %s (old %s)", n, ref, newHead, l.head)
	}
	if parents := strings.Fields(git(t, l.f.repo, "rev-list", "--parents", "-n", "1", newHead)); len(parents) != 3 || parents[1] != l.head || parents[2] != moved {
		t.Fatalf("parents of the new head = %v (commit artifacts %v), want [old head, integration head]", parents, refs)
	}
	if err := gitErr(l.f.repo, "merge-base", "--is-ancestor", mainMoved, newHead); err == nil {
		t.Fatalf("the default branch head %s was taken in", mainMoved)
	}
	// 取り込みで fetch した統合ブランチの先頭が記録される。
	if got := integrationCommit(t, d); got != moved {
		t.Fatalf("integration commit = %s, want the fetched head %s", got, moved)
	}
}

// 最初のレビュー待ちの前にも、進んだ統合ブランチを取り込む。
func TestTicketSyncsTheIntegrationBranchBeforeTheFirstReview(t *testing.T) {
	var moved string
	env, dir := blockableLsRemote(t)
	l := newIntegrationLand(t, func(f *ticketFixture) {
		runStep(t, f, 2, "touch "+dir+"/block\necho widget > widget.txt\ngit add widget.txt\ngit commit -q -m 'feat: widget'\n"+
			"tmp=$(mktemp -d)\ngit clone -q -b "+integrationBranch+" \"$(git remote get-url origin)\" \"$tmp/c\"\n"+
			"(cd \"$tmp/c\" && echo x > other.txt && git add other.txt && git commit -q -m 'chore: advance integration' && git push -q origin HEAD:refs/heads/"+integrationBranch+")")
	}, env)
	moved = git(t, l.f.origin, "rev-parse", "refs/heads/"+integrationBranch)
	v := l.f.h.statusOf(l.id)
	if !strings.Contains(stepSeq(v), "commit:committed sync:synced") {
		t.Fatalf("steps %s", stepSeq(v))
	}
	if parents := strings.Fields(git(t, l.f.repo, "rev-list", "--parents", "-n", "1", l.head)); len(parents) != 3 || parents[2] != moved {
		t.Fatalf("the PR head must be a merge of the integration branch %s: %v", moved, parents)
	}
	d, _ := l.f.h.contract("status", l.id)
	if got := integrationCommit(t, d); got != moved {
		t.Fatalf("integration commit = %s, want %s", got, moved)
	}
}

// CI の運用の宣言は、統合ブランチから読む。統合ブランチが after-merge を宣言していれば、チェックが落ちていても入れる
// （既定ブランチが per-push に変わっていても）。
func TestTicketLandReadsTheCITriggerFromTheIntegrationBranch(t *testing.T) {
	l := newIntegrationLand(t, func(f *ticketFixture) { declareCITrigger(t, f.repo, `{"trigger": "after-merge"}`) })
	// 既定ブランチだけ per-push に変える（統合ブランチは切った時点の after-merge のまま）。
	declareCITrigger(t, l.f.repo, `{"trigger": "per-push"}`)
	l.f.write("checks", check("test", "fail"))
	l.merged(l.head, "squashed2222222222222222222222222222222222")
	d := l.land(l.head)
	if d.State != runstate.StatusSucceeded || l.merges() != 1 {
		t.Fatalf("doc = %+v merges %d (the declaration of the integration branch must be read)", d, l.merges())
	}
}

// 待っている間に統合ブランチが進むと、status の role: integration の commit が新しい先頭になる。記録も追従し、同じ先頭なら
// もう書かない。
func TestTicketStatusRefreshesTheIntegrationHead(t *testing.T) {
	l := newIntegrationLand(t, nil)
	l.followOrigin()
	baseEvents := integrationEvents(t, l)
	moved := advanceIntegration(t, l.f, "other.txt", "x\n")
	d, _ := l.f.h.contract("status", l.id)
	if got := integrationCommit(t, d); got != moved {
		t.Fatalf("integration commit after the branch moved = %s, want %s", got, moved)
	}
	if n, ref := countRole(d.Artifacts, "commit", ""); n != 1 || ref != l.head {
		t.Fatalf("the commit without a role = %d %q, want the unchanged PR head %s", n, ref, l.head)
	}
	l.f.h.contract("status", l.id)
	if n := integrationEvents(t, l); n != baseEvents+1 {
		t.Fatalf("integration events = %d, want %d (one refresh)", n, baseEvents+1)
	}
}

// 読めなければ出力は変わらない（標準エラーに理由）。
func TestTicketStatusKeepsTheIntegrationHeadWhenOriginCannotBeRead(t *testing.T) {
	l := newIntegrationLand(t, nil)
	before, _ := l.f.h.contract("status", l.id)
	advanceIntegration(t, l.f, "other.txt", "x\n")
	// origin を、読めない場所へ動かす。
	if err := os.Rename(l.f.origin, l.f.origin+".gone"); err != nil {
		t.Fatal(err)
	}
	baseEvents := integrationEvents(t, l)
	after, _ := l.f.h.contract("status", l.id)
	if got, want := integrationCommit(t, after), integrationCommit(t, before); got != want {
		t.Fatalf("integration commit = %s, want the recorded %s", got, want)
	}
	_, errOut, code := l.f.h.run("status", l.id)
	if code != ExitOK || !strings.Contains(errOut, "cannot refresh the integration branch head") {
		t.Fatalf("status exit %d\n%s", code, errOut)
	}
	if n := integrationEvents(t, l); n != baseEvents {
		t.Fatalf("integration events = %d, want %d (nothing written)", n, baseEvents)
	}
}

// 統合先の記録の無い unit では ls-remote を呼ばない（宛先が既定ブランチの ticket）。統合先の記録のある unit では呼ぶ。
func TestTicketStatusLsRemotesOnlyWithAnIntegrationRecord(t *testing.T) {
	lsRemoteCalls := func(dir string) int {
		return strings.Count(readFileOrEmpty(filepath.Join(dir, "ls-remote.log")), "ls-remote")
	}
	wrapper := func(t *testing.T) (env, dir string) {
		dir = t.TempDir()
		script := "#!/bin/bash\n[ \"$1\" = ls-remote ] && [ \"$2\" = origin ] && echo ls-remote >> \"" + dir + "/ls-remote.log\"\nexec git \"$@\"\n"
		w := filepath.Join(dir, "git")
		if err := os.WriteFile(w, []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
		return "HARNESS_GIT_BIN=" + w, dir
	}
	t.Run("no integration record", func(t *testing.T) {
		env, dir := wrapper(t)
		l := newLandFixture(t, nil, env)
		base := lsRemoteCalls(dir)
		l.f.h.contract("status", l.id)
		l.f.h.run("status", "--json", l.id)
		if got := lsRemoteCalls(dir); got != base {
			t.Fatalf("git ls-remote origin was called by status (%d -> %d)", base, got)
		}
	})
	t.Run("integration record", func(t *testing.T) {
		env, dir := wrapper(t)
		l := newIntegrationLand(t, nil, env)
		base := lsRemoteCalls(dir)
		l.f.h.contract("status", l.id)
		if got := lsRemoteCalls(dir); got <= base {
			t.Fatalf("git ls-remote origin was not called by status (%d -> %d)", base, got)
		}
	})
}

// ゲートが解かれた後（入れて終えた後）は、統合ブランチが進んでも書かない。
func TestTicketStatusDoesNotWriteTheIntegrationHeadAfterTheGateIsResolved(t *testing.T) {
	l := newIntegrationLand(t, nil)
	const squashed = "squashed3333333333333333333333333333333333"
	l.merged(l.head, squashed)
	l.land(l.head)
	baseEvents := integrationEvents(t, l)
	advanceIntegration(t, l.f, "other.txt", "x\n")
	d, _ := l.f.h.contract("status", l.id)
	if got := integrationCommit(t, d); got != squashed {
		t.Fatalf("integration commit = %s, want the commit after the merge %s", got, squashed)
	}
	if n := integrationEvents(t, l); n != baseEvents {
		t.Fatalf("integration events = %d, want %d (nothing written after the gate was resolved)", n, baseEvents)
	}
}

func gitErr(dir string, args ...string) error {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	return cmd.Run()
}

func readFileOrEmpty(path string) string {
	b, _ := os.ReadFile(path)
	return string(b)
}

// blockableLsRemote は、<dir>/block があるあいだ、統合ブランチへの git ls-remote を失敗させる git の包み（HARNESS_GIT_BIN に渡す）。
// status の取り直しが、段の書いた記録と同じ値を書き直して、段が書かなかったことを隠さないようにする。
func blockableLsRemote(t *testing.T) (env, dir string) {
	t.Helper()
	dir = t.TempDir()
	script := "#!/bin/bash\nif [ \"$1\" = ls-remote ] && [ \"$3\" = refs/heads/" + integrationBranch + " ] && [ -f \"" + dir + "/block\" ]; then echo 'fatal: blocked' >&2; exit 128; fi\nexec git \"$@\"\n"
	w := filepath.Join(dir, "git")
	if err := os.WriteFile(w, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return "HARNESS_GIT_BIN=" + w, dir
}

func block(t *testing.T, dir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "block"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

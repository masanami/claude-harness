package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// land（レビュー待ちで「入れてよい」を、通した中身の識別 --approved-ref を添えて受ける。#388 の S3-3）の通しの試験。
// 同梱の ticket ワークフローを、偽の claude・gh と、実の git（bare の origin）で、レビュー待ちまで進めてから land を返す。

// landFixture は ticket をレビュー待ちまで進めた状態。PR（偽の gh が返す）の先頭は、作業ブランチの先頭と同じ。
type landFixture struct {
	f    *ticketFixture
	id   string
	head string
	base string // PR の宛先（空なら main）
}

func (l *landFixture) baseName() string {
	if l.base == "" {
		return "main"
	}
	return l.base
}

func viewJSON(state, head, base, merge string) string {
	mc := "null"
	if merge != "" {
		mc = fmt.Sprintf(`{"oid":%q}`, merge)
	}
	return fmt.Sprintf(`{"state":%q,"headRefOid":%q,"baseRefName":%q,"mergeCommit":%s,"isDraft":false}`, state, head, base, mc)
}

// newLandFixture は run をレビュー待ちまで進める。setup は run を始める前に呼ぶ（偽の claude の応答・宛先の更新など）。
func newLandFixture(t *testing.T, setup func(f *ticketFixture), extraEnv ...string) *landFixture {
	t.Helper()
	f := newTicketFixture(t, extraEnv...)
	greenCI(f)
	if setup != nil {
		setup(f)
	}
	id := runToReview(t, f)
	l := &landFixture{f: f, id: id, head: originHead(t, f)}
	l.setPRHead(l.head)
	return l
}

// setPRHead は、PR の先頭（偽の gh の読み取りと、origin の refs/pull/7/head）を sha にする。
func (l *landFixture) setPRHead(sha string) {
	git(l.f.t(), l.f.origin, "update-ref", "refs/pull/7/head", sha)
	l.f.write("pr-view.json", viewJSON("OPEN", sha, l.baseName(), ""))
}

// followOrigin は、PR の先頭を origin の作業ブランチの先頭に追従させる（harness が push した後の、実物の PR と同じ。取り直しが、
// push の後の先頭を古い先頭へ戻さないために要る）。
func (l *landFixture) followOrigin() {
	l.f.write("pr-head-ref", l.f.origin+"\nrefs/heads/"+l.f.branch+"\n")
}

func (l *landFixture) merged(head, merge string) {
	l.f.write("merge.then", viewJSON("MERGED", head, l.baseName(), merge))
}

// land は land を --approved-ref 付きで返す。落ち着くまで待った契約の出力を返す。
func (l *landFixture) land(approved string) contractDoc {
	l.f.t().Helper()
	d, errOut := l.f.h.contract("resume", "--unit", "main", "--input", "land", "--approved-ref", approved, l.id)
	if d.RunID == nil {
		l.f.t().Fatalf("no run id: %+v\n%s", d, errOut)
	}
	return d
}

func (l *landFixture) ghCalls() string { return readFile(l.f.t(), filepath.Join(l.f.ghDir, "calls")) }

func (l *landFixture) merges() int { return strings.Count(l.ghCalls(), "pr\tmerge\t") }

func (f *ticketFixture) t() *testing.T { return f.h.t }

// advanceMain は origin の main を、メインのクローンから進める（宛先が動いた）。
func advanceMain(t *testing.T, f *ticketFixture, name, content string) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.repo, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, f.repo, "add", name)
	git(t, f.repo, "commit", "-q", "-m", "chore: advance main ("+name+")")
	git(t, f.repo, "push", "-q", "origin", "main")
	return git(t, f.repo, "rev-parse", "HEAD")
}

// advanceMainScript は、実装の段（偽の claude）の間に、origin の main を別のクローンから進めるスクリプト。作業ツリーを払い出した
// 後に宛先が動いた形になる（払い出しは、その時点の宛先から作業ブランチを切るので、先に進めておくと取り込みが要らなくなる）。
func advanceMainScript(name, content string) string {
	return fmt.Sprintf("tmp=$(mktemp -d)\ngit clone -q \"$(git remote get-url origin)\" \"$tmp/c\"\n"+
		"(cd \"$tmp/c\" && printf '%%s\\n' %q > %s && git add %s && git commit -q -m 'chore: advance main' && git push -q origin HEAD:refs/heads/main)", content, name, name)
}

func commitRefs(d contractDoc) []string {
	var out []string
	for _, a := range d.Artifacts {
		if a.Kind == "commit" {
			out = append(out, a.Ref)
		}
	}
	return out
}

// レビュー待ちは options に land を出し、成果物に kind が commit の要素をちょうど 1 つ（role なし）出す。ready の道は変わらない。
func TestTicketReviewOffersLandAndOneCommit(t *testing.T) {
	l := newLandFixture(t, nil)
	d, _ := l.f.h.contract("status", l.id)
	if d.State != "waiting" || d.RequestedAction == nil {
		t.Fatalf("doc = %+v", d)
	}
	if got := strings.Join(d.RequestedAction.Options, ","); got != "respond,ready,land" {
		t.Fatalf("options = %s", got)
	}
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != l.head {
		t.Fatalf("commit artifacts = %v, want exactly [%s]", refs, l.head)
	}
	// ready の後の道は変わらない: 既定ブランチ宛なので、人のマージを観測するゲート（runtime は入れない）。
	out, errOut, code := l.f.h.run("resume", l.id, "--input", "ready")
	if code != ExitWaiting {
		t.Fatalf("ready exit %d\n%s\n%s", code, out, errOut)
	}
	if v := decode[statusView](t, out); v.Waiting[0].Gate != "human-merge" || l.merges() != 0 {
		t.Fatalf("waiting = %+v, merges %d", v.Waiting, l.merges())
	}
}

// 一致して宛先の最新を含む → 入れて、片付けて、succeeded。入れる命令は squash・--match-head-commit。成果物の commit は入れた後のコミット。
func TestTicketLandMergesAndSucceeds(t *testing.T) {
	l := newLandFixture(t, nil)
	l.merged(l.head, "squashed0000000000000000000000000000000000")
	d := l.land(l.head)
	if d.State != runstate.StatusSucceeded || d.RequestedAction != nil {
		t.Fatalf("doc = %+v", d)
	}
	if want := "pr\tmerge\t7\t--squash\t--match-head-commit\t" + l.head + "\n"; !strings.Contains(l.ghCalls(), want) {
		t.Fatalf("gh calls lack %q:\n%s", want, l.ghCalls())
	}
	for _, banned := range []string{"--auto", "--admin", "--delete-branch"} {
		if strings.Contains(l.ghCalls(), banned) {
			t.Fatalf("gh was called with %s", banned)
		}
	}
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != "squashed0000000000000000000000000000000000" {
		t.Fatalf("commit artifacts = %v, want the commit after the merge", refs)
	}
	v := l.f.h.statusOf(l.id)
	if v.Status != runstate.StatusSucceeded || v.Reason != "merged" || !strings.HasSuffix(stepSeq(v), " land:landed cleanup:released") {
		t.Fatalf("status %s reason %s steps %s", v.Status, v.Reason, stepSeq(v))
	}
	last := v.Unit("main").Rounds[len(v.Unit("main").Rounds)-1]
	if last.Trigger.Kind != "gate" || last.Trigger.Gate != "review" || last.Trigger.Input != "land" {
		t.Fatalf("the round that landed was started by %+v", last.Trigger)
	}
}

// 宛先が動いている → 入れずに、取り込んで push し、新しい先頭を出してレビュー待ちへ戻る。入れていない。
// 新しい先頭で land を返すと、今度は入る。
func TestTicketLandWhenTheBaseMovedSyncsAndReturnsToReview(t *testing.T) {
	l := newLandFixture(t, nil)
	l.followOrigin()
	newBase := advanceMain(t, l.f, "other.txt", "x\n")
	// land を受けてから、レビュー待ちへ戻るまでは running（受け付ける前のレビュー待ちを返さない）。速い runner が、もう戻っていても、
	// 返すのは新しい先頭のレビュー待ちで、通した中身のままのレビュー待ちではない。
	d0, _ := l.f.h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", l.head, l.id)
	if refs := commitRefs(d0); d0.State != runstate.StatusRunning && (d0.State != "waiting" || len(refs) != 1 || refs[0] == l.head) {
		t.Fatalf("right after land: state %s, commit artifacts %v (the head that was approved is %s)", d0.State, refs, l.head)
	}
	d := l.f.h.settle(l.id)
	if d.State != "waiting" || d.RequestedAction == nil || d.RequestedAction.Kind != "answer" {
		t.Fatalf("doc = %+v", d)
	}
	v := l.f.h.statusOf(l.id)
	if !strings.HasSuffix(stepSeq(v), " land:behind land-sync:synced land-push:pushed") || v.Waiting[0].Gate != "review" {
		t.Fatalf("steps %s waiting %+v", stepSeq(v), v.Waiting)
	}
	if l.merges() != 0 {
		t.Fatalf("a PR behind its base must not be merged (%d merges)", l.merges())
	}
	if !strings.Contains(d.RequestedAction.Text, "Detail: 宛先 main の先頭 "+newBase+" を取り込み、PR の先頭は "+l.head+" から ") ||
		!strings.Contains(d.RequestedAction.Text, " になった。宛先へは入れていない。") {
		t.Fatalf("text = %q", d.RequestedAction.Text)
	}
	// 新しい先頭: マージのコミット（親は、前の先頭と宛先の先頭）。origin の作業ブランチも同じ。
	refs := commitRefs(d)
	if len(refs) != 1 || refs[0] == l.head || refs[0] != originHead(t, l.f) {
		t.Fatalf("commit artifacts = %v, want the new head of origin %s (old %s)", refs, originHead(t, l.f), l.head)
	}
	if parents := strings.Fields(git(t, l.f.repo, "rev-list", "--parents", "-n", "1", refs[0])); len(parents) != 3 || parents[1] != l.head || parents[2] != newBase {
		t.Fatalf("parents of the new head = %v", parents)
	}
	if got := strings.Join(d.RequestedAction.Options, ","); got != "respond,ready,land" {
		t.Fatalf("options after the return = %s", got)
	}

	// 新しい先頭で、改めて入れる。
	newHead := refs[0]
	l.setPRHead(newHead)
	l.merged(newHead, "squashed1111111111111111111111111111111111")
	d = l.land(newHead)
	if d.State != runstate.StatusSucceeded || l.merges() != 1 {
		t.Fatalf("doc = %+v, merges %d", d, l.merges())
	}
	// 古い先頭の識別では、入れない（mismatch）。上の 1 回で入れ終えているので、ここでは確かめない。
}

// 通した中身と PR の先頭が違う → 入れずに、いまの先頭を出してレビュー待ちへ戻る（status は running を経て waiting）。
func TestTicketLandMismatchReturnsToReviewWithTheCurrentHead(t *testing.T) {
	l := newLandFixture(t, nil)
	// 外から push された: PR の先頭が、通した中身（l.head）と違う。
	git(t, l.f.repo, "fetch", "-q", "origin")
	git(t, l.f.repo, "checkout", "-q", "-B", "outside", "origin/"+l.f.branch)
	if err := os.WriteFile(filepath.Join(l.f.repo, "outside.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, l.f.repo, "add", "outside.txt")
	git(t, l.f.repo, "commit", "-q", "-m", "fix: from outside")
	outside := git(t, l.f.repo, "rev-parse", "HEAD")
	git(t, l.f.repo, "push", "-q", "origin", "outside:refs/heads/"+l.f.branch)
	git(t, l.f.repo, "checkout", "-q", "main")
	l.setPRHead(outside)

	d := l.land(l.head)
	if d.State != "waiting" || d.RequestedAction == nil || !strings.Contains(d.RequestedAction.Text, "Detail: PR の先頭 "+outside+" が、通した中身") {
		t.Fatalf("doc = %+v", d)
	}
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != outside {
		t.Fatalf("commit artifacts = %v, want the current head %s", refs, outside)
	}
	if l.merges() != 0 {
		t.Fatal("a mismatch must not merge")
	}
	// 通した中身の識別が空でも、入れない。
	d = l.land("")
	if d.State != "waiting" || l.merges() != 0 {
		t.Fatalf("an empty approved ref: doc %+v merges %d", d, l.merges())
	}
}

// チェックが通っていない → 理由（detail）を添えてレビュー待ちへ戻る。中身は変えない。
func TestTicketLandBlockedByAFailingCheckReturnsToReview(t *testing.T) {
	l := newLandFixture(t, nil)
	l.f.write("checks", check("test", "fail"))
	before := git(t, l.f.repo, "ls-remote", l.f.origin, "refs/heads/"+l.f.branch)
	d := l.land(l.head)
	if d.State != "waiting" || d.RequestedAction == nil || !strings.Contains(d.RequestedAction.Text, "Detail: PR #7 のチェックが通っていない") || !strings.Contains(d.RequestedAction.Text, "test（fail）") {
		t.Fatalf("doc = %+v", d)
	}
	if l.merges() != 0 || git(t, l.f.repo, "ls-remote", l.f.origin, "refs/heads/"+l.f.branch) != before {
		t.Fatal("blocked must change neither the PR nor the branch")
	}
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != l.head {
		t.Fatalf("commit artifacts = %v", refs)
	}
}

// 取り込みで衝突した → 直す段（sync-resolve の指示文）が直し、機械が形を確かめ、push して、新しい先頭でレビュー待ちへ戻る。
func TestTicketLandSyncConflictIsResolvedThenReturnsToReview(t *testing.T) {
	l := newLandFixture(t, func(f *ticketFixture) {
		// 実装の段が、作業ブランチに conflict.txt のコミットを足す（偽の claude の 2 回目の応答の間に作る）。
		runStep(t, f, 2, "echo branch > conflict.txt\ngit add conflict.txt\ngit commit -q -m 'feat: conflict.txt'")
	})
	l.followOrigin()
	mainSide := advanceMain(t, l.f, "conflict.txt", "main\n")
	// 衝突を直す段（4 回目の claude）が、マージを終える。
	runStep(t, l.f, 4, "echo resolved > conflict.txt\ngit add conflict.txt\ngit commit -q --no-edit")
	respond(t, l.f.fdir, 4, 0, claudeStructured(map[string]any{"outcome": "resolved", "summary": "kept both"}, 1))
	d := l.land(l.head)
	if d.State != "waiting" {
		t.Fatalf("doc = %+v", d)
	}
	v := l.f.h.statusOf(l.id)
	if !strings.HasSuffix(stepSeq(v), " land:behind land-sync:conflict land-sync-resolve:resolved land-sync:current land-push:pushed") {
		t.Fatalf("steps %s", stepSeq(v))
	}
	if v.Unit("main").LimitsUsed["sync_resolve"] != 1 {
		t.Fatalf("limits used = %v", v.Unit("main").LimitsUsed)
	}
	refs := commitRefs(d)
	if len(refs) != 1 || refs[0] == l.head {
		t.Fatalf("commit artifacts = %v", refs)
	}
	if parents := strings.Fields(git(t, l.f.repo, "rev-list", "--parents", "-n", "1", refs[0])); len(parents) != 3 || parents[1] != l.head || parents[2] != mainSide {
		t.Fatalf("the resolved merge must be [old head, base head], got %v", parents)
	}
	if l.merges() != 0 {
		t.Fatal("the conflict return must not merge")
	}
}

// 最初のレビュー待ちの前にも、宛先の最新を取り込む（衝突は直す段が直す）。取り込んだ後のコミットで quality・publish が回る。
func TestTicketSyncsBeforeTheFirstReview(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	// 実装の段が作業ブランチへコミットを足し、その間に宛先が動く（宛先から枝分かれする）。
	runStep(t, f, 2, "echo widget > widget.txt\ngit add widget.txt\ngit commit -q -m 'feat: widget'\n"+advanceMainScript("other.txt", "x"))
	id := runToReview(t, f)
	v := f.h.statusOf(id)
	if !strings.Contains(stepSeq(v), "commit:committed sync:synced e2e-route:no quality:pass publish:opened") {
		t.Fatalf("steps %s", stepSeq(v))
	}
	baseHead := strings.Fields(git(t, f.repo, "ls-remote", f.origin, "refs/heads/main"))[0]
	head := originHead(t, f)
	parents := strings.Fields(git(t, f.repo, "rev-list", "--parents", "-n", "1", head))
	if len(parents) != 3 || parents[2] != baseHead {
		t.Fatalf("the PR head must be a merge of the base %s: %v", baseHead, parents)
	}
}

func TestTicketSyncConflictBeforeTheFirstReviewIsResolved(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	runStep(t, f, 2, "echo branch > conflict.txt\ngit add conflict.txt\ngit commit -q -m 'feat: conflict.txt'\n"+advanceMainScript("conflict.txt", "main side"))
	runStep(t, f, 4, "echo resolved > conflict.txt\ngit add conflict.txt\ngit commit -q --no-edit")
	respond(t, f.fdir, 4, 0, claudeStructured(map[string]any{"outcome": "resolved", "summary": "kept both"}, 1))
	id := runToReview(t, f)
	v := f.h.statusOf(id)
	if !strings.Contains(stepSeq(v), "commit:committed sync:conflict sync-resolve:resolved sync:current e2e-route:no quality:pass publish:opened") {
		t.Fatalf("steps %s", stepSeq(v))
	}
	// 直す段は、実装のセッションを引き継ぐ（session: continue:implement）。
	if !strings.Contains(readFile(t, filepath.Join(f.fdir, "calls", "4.argv")), "--resume") {
		t.Errorf("sync-resolve did not continue the implement session:\n%s", readFile(t, filepath.Join(f.fdir, "calls", "4.argv")))
	}
}

// 直す段がマージを終えずに戻った → 失敗（sync_conflict）。レビュー待ちの前なので、戻る先が無い。
func TestTicketSyncUnresolvedConflictFails(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	runStep(t, f, 2, "echo branch > conflict.txt\ngit add conflict.txt\ngit commit -q -m 'feat: conflict.txt'\n"+advanceMainScript("conflict.txt", "main side"))
	respond(t, f.fdir, 4, 0, claudeStructured(map[string]any{"outcome": "resolved", "summary": "claimed to resolve, did not"}, 1))
	out, errOut, code := f.h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitFailed {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	if v := decode[statusView](t, out); v.Reason != "sync_conflict" {
		t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
	}
}

// 最初の取り込みで宛先を取得できない → 失敗（remote_unavailable）。land の後の取り込みなら、レビュー待ちへ戻す。
func TestTicketSyncFetchFailure(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	// 作業ツリーを払い出した後で、origin を壊す（実装の段の間に）。
	runStep(t, f, 2, "git remote set-url origin /nonexistent/origin.git")
	out, errOut, code := f.h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitFailed {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	if v := decode[statusView](t, out); v.Reason != "remote_unavailable" {
		t.Fatalf("reason %s", v.Reason)
	}
}

// failingFetchGit は、git fetch を数え、<dir>/fetch.failafter に書いた回数より後の fetch をすべて失敗させる git の包み
// （HARNESS_GIT_BIN に渡す。runtime が呼ぶ git だけに効く）。
func failingFetchGit(t *testing.T) (env, dir string) {
	t.Helper()
	dir = t.TempDir()
	script := "#!/bin/bash\nif [ \"$1\" = fetch ]; then\n  n=$(( $(cat \"" + dir + "/fetch.count\" 2>/dev/null || echo 0) + 1 )); echo $n > \"" + dir + "/fetch.count\"\n" +
		"  if [ -f \"" + dir + "/fetch.failafter\" ] && [ \"$n\" -gt \"$(cat \"" + dir + "/fetch.failafter\")\" ]; then echo 'fatal: unable to access the remote' >&2; exit 128; fi\nfi\nexec git \"$@\"\n"
	wrapper := filepath.Join(dir, "git")
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return "HARNESS_GIT_BIN=" + wrapper, dir
}

// land が behind と確かめた後の取り込みで、宛先を取得できない → 何も変えていないので、理由（detail）を添えてレビュー待ちへ戻す
// （失敗で終えない）。
func TestTicketLandSyncFetchFailureReturnsToReview(t *testing.T) {
	env, dir := failingFetchGit(t)
	l := newLandFixture(t, nil, env)
	advanceMain(t, l.f, "other.txt", "x\n")
	// ここまでの fetch の数に、land の確かめの 2 回（宛先・PR の先頭）を足した後を落とす（land-sync の fetch から落ちる）。
	n := strings.TrimSpace(readFile(t, filepath.Join(dir, "fetch.count")))
	var done int
	if _, err := fmt.Sscan(n, &done); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "fetch.failafter"), []byte(fmt.Sprint(done+2)), 0o644); err != nil {
		t.Fatal(err)
	}
	before := git(t, l.f.repo, "ls-remote", l.f.origin, "refs/heads/"+l.f.branch)
	d := l.land(l.head)
	if d.State != "waiting" || d.RequestedAction == nil || !strings.Contains(d.RequestedAction.Text, "Detail: 宛先 main を取得できなかった") || l.merges() != 0 {
		t.Fatalf("doc = %+v merges %d", d, l.merges())
	}
	v := l.f.h.statusOf(l.id)
	if v.Waiting[0].Gate != "review" || !strings.HasSuffix(stepSeq(v), " land:behind land-sync:unavailable") {
		t.Fatalf("waiting %+v steps %s", v.Waiting, stepSeq(v))
	}
	if git(t, l.f.repo, "ls-remote", l.f.origin, "refs/heads/"+l.f.branch) != before {
		t.Fatal("nothing may be pushed when the sync could not fetch")
	}
	if refs := commitRefs(d); len(refs) != 1 || refs[0] != l.head {
		t.Fatalf("commit artifacts = %v, want the unchanged head", refs)
	}
}

// 同じ approved_ref の land を 2 度受けても、2 度入れない: 入って終わった run への resume は、終わりの状態を返す。
func TestTicketLandTwiceMergesOnce(t *testing.T) {
	l := newLandFixture(t, nil)
	l.merged(l.head, "squashed2222222222222222222222222222222222")
	if d := l.land(l.head); d.State != runstate.StatusSucceeded {
		t.Fatalf("doc = %+v", d)
	}
	d, _ := l.f.h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", l.head, l.id)
	if d.State != runstate.StatusSucceeded || l.merges() != 1 {
		t.Fatalf("second land: doc %+v, merges %d", d, l.merges())
	}
}

// 入れた直後に runner が落ちた run は、interrupted のゲートを開かず、interrupted_after_land の失敗で終わる。終わった実行への resume は
// 終わりの状態を返し、2 度入れない。
func TestTicketLandRunnerKilledAfterTheMergeEndsAsFailed(t *testing.T) {
	l := newLandFixture(t, nil)
	l.merged(l.head, "squashed3333333333333333333333333333333333")
	l.f.write("merge.kill", "1") // 偽の gh が、入れる命令の後で runner を SIGKILL する
	l.f.h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", l.head, l.id)
	d := l.f.h.settle(l.id)
	if d.State != runstate.StatusFailed || !strings.Contains(d.Summary, "interrupted_after_land") || d.RequestedAction != nil {
		t.Fatalf("doc = %+v", d)
	}
	v := l.f.h.statusOf(l.id)
	if v.Status != runstate.StatusFailed || v.Reason != "interrupted_after_land" || len(v.Waiting) != 0 {
		t.Fatalf("status %s reason %s waiting %+v", v.Status, v.Reason, v.Waiting)
	}
	d, _ = l.f.h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", l.head, l.id)
	if d.State != runstate.StatusFailed || l.merges() != 1 {
		t.Fatalf("resume after the end: doc %+v, merges %d", d, l.merges())
	}
}

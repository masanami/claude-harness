package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// pull-request 種類の action: sync・push・land の試験（docs/harness-runtime-design.md §5.6.2）。git は実物（bare の origin を
// 一時ディレクトリに作る）、gh は偽物（testdata/scripts/fake-gh.sh）。git の呼び出しは包みのスクリプトが記録する。

func init() {
	retryDelay = 0
	landMergeWait, landMergePoll = 200*time.Millisecond, 10*time.Millisecond
}

// prEnv は、main を push 済みの origin と、作業ブランチ feature/x（main から 1 コミット進めて push 済み）のクローンを持つ。
type prEnv struct {
	t      *testing.T
	tl     *tools
	repo   string // クローン（run のカレント）
	origin string
	other  string // もう 1 つのクローン（外からの push・宛先の更新に使う）
	head   string // feature/x の先頭（push 済み）
	branch string
}

func rgit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s (in %s): %v\n%s", strings.Join(args, " "), dir, err, out)
	}
	return strings.TrimSpace(string(out))
}

func commitFile(t *testing.T, dir, name, content, msg string) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	rgit(t, dir, "add", name)
	rgit(t, dir, "commit", "-q", "-m", msg)
	return rgit(t, dir, "rev-parse", "HEAD")
}

func newPREnv(t *testing.T) *prEnv {
	t.Helper()
	for k, v := range map[string]string{
		"GIT_AUTHOR_NAME": "harness-test", "GIT_AUTHOR_EMAIL": "harness-test@example.invalid",
		"GIT_COMMITTER_NAME": "harness-test", "GIT_COMMITTER_EMAIL": "harness-test@example.invalid",
		"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.DevNull, "HOME": t.TempDir(),
	} {
		t.Setenv(k, v)
	}
	tl := newTools(t)
	root := realpath(t, t.TempDir())
	// git の呼び出しを記録する包み（--force が使われないこと・試し直しの回数を見るため）。
	wrapper := filepath.Join(root, "git-wrapper.sh")
	if err := os.WriteFile(wrapper, []byte("#!/bin/bash\nprintf '%s\\n' \"$*\" >> \""+filepath.Join(root, "git.calls")+"\"\nexec git \"$@\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	tl.gitBin = wrapper
	env := &prEnv{t: t, tl: tl, origin: filepath.Join(root, "origin.git"), repo: filepath.Join(root, "repo"), other: filepath.Join(root, "other"), branch: "feature/x"}
	rgit(t, root, "init", "-q", "--bare", "-b", "main", env.origin)
	rgit(t, root, "init", "-q", "-b", "main", env.repo)
	commitFile(t, env.repo, "README.md", "widget\n", "init")
	rgit(t, env.repo, "remote", "add", "origin", env.origin)
	rgit(t, env.repo, "push", "-q", "-u", "origin", "main")
	rgit(t, env.repo, "checkout", "-q", "-b", env.branch)
	env.head = commitFile(t, env.repo, "widget.txt", "widget\n", "feat: widget")
	rgit(t, env.repo, "push", "-q", "-u", "origin", env.branch)
	rgit(t, env.origin, "update-ref", "refs/pull/7/head", env.head)
	rgit(t, root, "clone", "-q", env.origin, env.other)
	tl.cwd = env.repo
	return env
}

func (p *prEnv) gitCalls() string {
	data, _ := os.ReadFile(filepath.Join(filepath.Dir(p.repo), "git.calls"))
	return string(data)
}

// advanceBase は origin の main を、別のクローンから進める（宛先が動いた）。
func (p *prEnv) advanceBase(name, content string) string {
	p.t.Helper()
	rgit(p.t, p.other, "checkout", "-q", "main")
	rgit(p.t, p.other, "pull", "-q", "origin", "main")
	sha := commitFile(p.t, p.other, name, content, "chore: advance main")
	rgit(p.t, p.other, "push", "-q", "origin", "main")
	return sha
}

// pushFromOutside は origin の作業ブランチを、別のクローンから進める（外から push された）。
func (p *prEnv) pushFromOutside(name string) string {
	p.t.Helper()
	rgit(p.t, p.other, "fetch", "-q", "origin")
	rgit(p.t, p.other, "checkout", "-q", "-B", p.branch, "origin/"+p.branch)
	sha := commitFile(p.t, p.other, name, "outside\n", "fix: from outside")
	rgit(p.t, p.other, "push", "-q", "origin", p.branch)
	return sha
}

func (p *prEnv) localHead() string { return rgit(p.t, p.repo, "rev-parse", "HEAD") }

// --- sync -------------------------------------------------------------------

func (p *prEnv) sync(inputs map[string]any) (*runstate.State, *Engine) {
	p.t.Helper()
	if inputs["base"] == nil {
		inputs["base"] = "main"
	}
	if inputs["mode"] == nil {
		inputs["mode"] = "ok"
	}
	return p.tl.start("pr-sync", inputs)
}

func outcomeOf(t *testing.T, st *runstate.State, step string) string {
	t.Helper()
	return st.Unit(MainUnit).Outcomes[step]
}

// 1: 未コミットの変更があり、マージの途中でもない → step_error。追跡外のファイルは数えない。
func TestSyncRefusesUncommittedChanges(t *testing.T) {
	p := newPREnv(t)
	p.advanceBase("other.txt", "x\n")
	if err := os.WriteFile(filepath.Join(p.repo, "untracked.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if st, _ := p.sync(map[string]any{}); st.Status != runstate.StatusSucceeded || st.Reason != "synced" {
		t.Fatalf("an untracked file must not stop the sync: %s %s", st.Status, st.Reason)
	}
	p = newPREnv(t)
	if err := os.WriteFile(filepath.Join(p.repo, "widget.txt"), []byte("edited\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	st, _ := p.sync(map[string]any{})
	if st.Status != runstate.StatusFailed || st.Reason != "step_error" {
		t.Fatalf("status %s reason %s, want step_error for an uncommitted change", st.Status, st.Reason)
	}
}

// 2: マージの途中のまま入った → unresolved。
func TestSyncReportsAMergeLeftInProgress(t *testing.T) {
	p := newPREnv(t)
	p.advanceBase("widget.txt", "main side\n")
	cmd := exec.Command("git", "-C", p.repo, "fetch", "-q", "origin")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	if err := exec.Command("git", "-C", p.repo, "merge", "--no-ff", "--no-edit", "origin/main").Run(); err == nil {
		t.Fatal("the setup merge was expected to conflict")
	}
	st, _ := p.sync(map[string]any{})
	if st.Status != runstate.StatusFailed || st.Reason != "unresolved" {
		t.Fatalf("status %s reason %s, want unresolved", st.Status, st.Reason)
	}
	if out := output(t, st, "sync"); out["outcome"] != "unresolved" {
		t.Fatalf("output = %v", out)
	}
}

// 3: 衝突を直した後の再入は、HEAD が「第 1 の親 = 取り込む前の先頭・第 2 の親 = 宛先の先頭」のマージのコミットであることを確かめる。
func TestSyncChecksTheShapeOfTheResolvedMerge(t *testing.T) {
	// 衝突 → 直す（ok）→ 再入で形が合い、current で終わる。第 1・第 2 の親は head_before・base_sha。
	p := newPREnv(t)
	baseSHA := p.advanceBase("conflict.txt", "main side\n")
	commitFile(t, p.repo, "conflict.txt", "branch side\n", "feat: the same file")
	before := p.localHead()
	st, e := p.sync(map[string]any{})
	if st.Status != runstate.StatusSucceeded || st.Reason != "current" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	parents := strings.Fields(rgit(t, p.repo, "rev-list", "--parents", "-n", "1", "HEAD"))
	if len(parents) != 3 || parents[1] != before || parents[2] != baseSHA {
		t.Fatalf("HEAD parents = %v, want [%s %s]", parents[1:], before, baseSHA)
	}
	// 1 回目の実行（conflict）の出力は、直した後の形の確かめの材料（head_before・base_sha）を持つ。
	var conflict *runstate.StepFinished
	for _, ev := range events(t, e) {
		if f := ev.StepFinished; f != nil && f.Step == "sync" && f.Outcome == "conflict" {
			conflict = f
		}
	}
	if conflict == nil {
		t.Fatal("no conflict result was recorded")
	}
	var out map[string]any
	if err := json.Unmarshal(conflict.Output, &out); err != nil {
		t.Fatal(err)
	}
	if out["head_before"] != before || out["base_sha"] != baseSHA {
		t.Fatalf("conflict output = %v, want head_before %s base_sha %s", out, before, baseSHA)
	}

	// 直した後に別のコミットを足した → not_merge_only。
	p = newPREnv(t)
	p.advanceBase("conflict.txt", "main side\n")
	commitFile(t, p.repo, "conflict.txt", "branch side\n", "feat: the same file")
	st, _ = p.sync(map[string]any{"mode": "extra"})
	if st.Status != runstate.StatusFailed || st.Reason != "not_merge_only" {
		t.Fatalf("status %s reason %s, want not_merge_only", st.Status, st.Reason)
	}
	// 直す段がマージを終えなかった → unresolved。
	p = newPREnv(t)
	p.advanceBase("conflict.txt", "main side\n")
	commitFile(t, p.repo, "conflict.txt", "branch side\n", "feat: the same file")
	st, _ = p.sync(map[string]any{"mode": "none"})
	if st.Status != runstate.StatusFailed || st.Reason != "unresolved" {
		t.Fatalf("status %s reason %s, want unresolved", st.Status, st.Reason)
	}
}

// 4: fetch が通らない → unavailable。origin の作業ブランチと枝分かれ → diverged。遅れているだけなら早送りする。
func TestSyncFetchAndTheWorkingBranchOnOrigin(t *testing.T) {
	p := newPREnv(t)
	rgit(t, p.repo, "remote", "set-url", "origin", filepath.Join(filepath.Dir(p.repo), "no-such-origin.git"))
	before := p.localHead()
	st, _ := p.sync(map[string]any{})
	if st.Status != runstate.StatusFailed || st.Reason != "unavailable" || p.localHead() != before {
		t.Fatalf("status %s reason %s head %s", st.Status, st.Reason, p.localHead())
	}
	if n := strings.Count(p.gitCalls(), "fetch origin +refs/heads/main"); n != retryTimes {
		t.Fatalf("fetch was tried %d times, want %d", n, retryTimes)
	}

	// 枝分かれ: origin の作業ブランチにも、手元の作業ブランチにも、お互いに無いコミットがある。
	p = newPREnv(t)
	p.pushFromOutside("outside.txt")
	local := commitFile(t, p.repo, "local.txt", "local\n", "feat: local")
	st, _ = p.sync(map[string]any{})
	if st.Status != runstate.StatusFailed || st.Reason != "diverged" || p.localHead() != local {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}

	// 遅れているだけ: 外から push された分を早送りで取り込み、そのうえで宛先の最新を取り込む。
	p = newPREnv(t)
	outside := p.pushFromOutside("outside.txt")
	p.advanceBase("other.txt", "x\n")
	st, _ = p.sync(map[string]any{})
	if st.Status != runstate.StatusSucceeded || st.Reason != "synced" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if parents := strings.Fields(rgit(t, p.repo, "rev-list", "--parents", "-n", "1", "HEAD")); len(parents) != 3 || parents[1] != outside {
		t.Fatalf("the first parent of the merge must be the fast-forwarded head %s: %v", outside, parents)
	}
}

// 5: expect_head があり、最初に入ったときだけ、手元の HEAD と比べる。再入では確かめない。
func TestSyncExpectHead(t *testing.T) {
	p := newPREnv(t)
	p.advanceBase("other.txt", "x\n")
	local := commitFile(t, p.repo, "local.txt", "local\n", "feat: local, not pushed")
	st, _ := p.sync(map[string]any{"expect_head": p.head})
	if st.Status != runstate.StatusFailed || st.Reason != "head_moved" || p.localHead() != local {
		t.Fatalf("status %s reason %s, want head_moved (an unpushed local commit)", st.Status, st.Reason)
	}
	if out := output(t, st, "sync"); out["outcome"] != "head_moved" || !strings.Contains(fmt.Sprint(out["detail"]), local) || !strings.Contains(fmt.Sprint(out["detail"]), p.head) {
		t.Fatalf("output = %v", out)
	}

	// 一致していれば取り込む。
	p = newPREnv(t)
	p.advanceBase("other.txt", "x\n")
	if st, _ = p.sync(map[string]any{"expect_head": p.head}); st.Reason != "synced" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}

	// 再入では確かめない: 衝突を直した後の HEAD（マージのコミット）は expect_head と違うが、head_moved にならない。
	p = newPREnv(t)
	p.advanceBase("conflict.txt", "main side\n")
	head := commitFile(t, p.repo, "conflict.txt", "branch side\n", "feat: the same file")
	rgit(t, p.repo, "push", "-q", "origin", p.branch)
	st, _ = p.sync(map[string]any{"expect_head": head})
	if st.Status != runstate.StatusSucceeded || st.Reason != "current" {
		t.Fatalf("status %s reason %s, want current (the re-entry does not check expect_head)", st.Status, st.Reason)
	}
}

// 6・7: すでに宛先の先頭を含む → current（何も変えない）。含まなければマージのコミットで取り込む（push はしない）。
func TestSyncCurrentAndSynced(t *testing.T) {
	p := newPREnv(t)
	st, _ := p.sync(map[string]any{})
	if st.Reason != "current" || p.localHead() != p.head {
		t.Fatalf("reason %s head %s", st.Reason, p.localHead())
	}
	p = newPREnv(t)
	base := p.advanceBase("other.txt", "x\n")
	st, _ = p.sync(map[string]any{})
	if st.Reason != "synced" {
		t.Fatalf("reason %s", st.Reason)
	}
	out := output(t, st, "sync")
	parents := strings.Fields(rgit(t, p.repo, "rev-list", "--parents", "-n", "1", "HEAD"))
	if len(parents) != 3 || parents[1] != p.head || parents[2] != base || out["head_sha"] != p.localHead() || out["head_before"] != p.head || out["base_sha"] != base {
		t.Fatalf("parents %v output %v", parents, out)
	}
	if got := rgit(t, p.repo, "ls-remote", "origin", "refs/heads/"+p.branch); !strings.HasPrefix(got, p.head) {
		t.Fatalf("sync must not push: origin has %s", got)
	}
	calls := p.gitCalls()
	for _, banned := range []string{"rebase", "--force", "push"} {
		if strings.Contains(calls, banned) {
			t.Errorf("sync ran git with %q:\n%s", banned, calls)
		}
	}
	if !strings.Contains(calls, "merge --no-ff --no-edit origin/main") {
		t.Errorf("git calls lack the merge:\n%s", calls)
	}
}

// --- push -------------------------------------------------------------------

func (p *prEnv) push() (*runstate.State, *Engine) {
	p.t.Helper()
	p.tl.write(p.tl.gh, "default-branch", "main\n")
	return p.tl.start("pr-push", map[string]any{"pr": 7, "base": "main"})
}

// pushed: 宛先を取り込んだコミットを push できた。detail は設計の文のとおり（全部の桁）。PR の先頭を記録する。
func TestPushPushed(t *testing.T) {
	p := newPREnv(t)
	base := p.advanceBase("other.txt", "x\n")
	rgit(t, p.repo, "fetch", "-q", "origin")
	rgit(t, p.repo, "merge", "-q", "--no-ff", "--no-edit", "origin/main")
	newHead := p.localHead()
	st, _ := p.push()
	if st.Status != runstate.StatusSucceeded || st.Reason != "pushed" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	want := fmt.Sprintf("宛先 main の先頭 %s を取り込み、PR の先頭は %s から %s になった。宛先へは入れていない。", base, p.head, newHead)
	if out := output(t, st, "push"); out["detail"] != want || out["head_sha"] != newHead || out["pr_number"] != float64(7) {
		t.Fatalf("output = %v\nwant detail %s", out, want)
	}
	if got := rgit(t, p.repo, "ls-remote", "origin", "refs/heads/"+p.branch); !strings.HasPrefix(got, newHead) {
		t.Fatalf("origin has %s, want %s", got, newHead)
	}
	ws := st.Unit(MainUnit).Workspace
	if ws == nil || ws.PRNumber != 7 || ws.HeadSHA != newHead || len(ws.HeadSHAs) != 0 {
		t.Fatalf("workspace = %+v (push records the head of the PR, not a per-round head)", ws)
	}
	if calls := p.gitCalls(); strings.Contains(calls, "--force") || !strings.Contains(calls, "push --porcelain origin HEAD:refs/heads/"+p.branch) {
		t.Fatalf("git calls:\n%s", calls)
	}
}

// unchanged: origin の先頭が手元の HEAD とすでに同じ。
func TestPushUnchanged(t *testing.T) {
	p := newPREnv(t)
	base := rgit(t, p.repo, "rev-parse", "refs/remotes/origin/main")
	st, _ := p.push()
	if st.Status != runstate.StatusSucceeded || st.Reason != "unchanged" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	want := fmt.Sprintf("PR の先頭は %s のまま（宛先 main の先頭 %s を、すでに含んでいる）。宛先へは入れていない。", p.head, base)
	if out := output(t, st, "push"); out["detail"] != want {
		t.Fatalf("detail = %v\nwant %s", out["detail"], want)
	}
	if ws := st.Unit(MainUnit).Workspace; ws == nil || ws.HeadSHA != p.head {
		t.Fatalf("workspace = %+v", ws)
	}
}

// rejected: origin が拒否した（取り込みの間に、外から push された）。失敗で終える。強制はしない。
func TestPushRejected(t *testing.T) {
	p := newPREnv(t)
	outside := p.pushFromOutside("outside.txt")
	commitFile(t, p.repo, "local.txt", "local\n", "feat: local")
	st, _ := p.push()
	if st.Status != runstate.StatusFailed || st.Reason != "rejected" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if got := rgit(t, p.repo, "ls-remote", "origin", "refs/heads/"+p.branch); !strings.HasPrefix(got, outside) {
		t.Fatalf("a rejected push must leave origin as it was: %s", got)
	}
	if strings.Count(p.gitCalls(), "push --porcelain") != 1 {
		t.Errorf("a rejection is not retried:\n%s", p.gitCalls())
	}
}

// unavailable: 3 回試しても origin へ届かない。失敗で終える。
func TestPushUnavailable(t *testing.T) {
	p := newPREnv(t)
	commitFile(t, p.repo, "local.txt", "local\n", "feat: local")
	rgit(t, p.repo, "remote", "set-url", "origin", filepath.Join(filepath.Dir(p.repo), "no-such-origin.git"))
	st, _ := p.push()
	if st.Status != runstate.StatusFailed || st.Reason != "unavailable" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if n := strings.Count(p.gitCalls(), "push --porcelain"); n != retryTimes {
		t.Fatalf("push was tried %d times, want %d", n, retryTimes)
	}
}

// 既定ブランチと PR の宛先そのものへは push しない（publish と同じ検査）。
func TestPushRefusesTheDefaultBranchAndTheBase(t *testing.T) {
	p := newPREnv(t)
	rgit(t, p.repo, "checkout", "-q", "main")
	p.tl.write(p.tl.gh, "default-branch", "main\n")
	st, _ := p.tl.start("pr-push", map[string]any{"pr": 7, "base": "main"})
	if st.Status != runstate.StatusFailed || st.Reason != "step_error" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	p = newPREnv(t)
	p.tl.write(p.tl.gh, "default-branch", p.branch+"\n")
	st, _ = p.tl.start("pr-push", map[string]any{"pr": 7, "base": "main"})
	if st.Status != runstate.StatusFailed || st.Reason != "step_error" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if strings.Contains(p.gitCalls(), "push") {
		t.Fatalf("git push ran:\n%s", p.gitCalls())
	}
}

// --- land -------------------------------------------------------------------

func (p *prEnv) view(state, head, base string, merge string, draft bool) string {
	mc := "null"
	if merge != "" {
		mc = fmt.Sprintf(`{"oid":%q}`, merge)
	}
	return fmt.Sprintf(`{"state":%q,"headRefOid":%q,"baseRefName":%q,"mergeCommit":%s,"isDraft":%v}`, state, head, base, mc, draft)
}

func (p *prEnv) openView() string { return p.view("OPEN", p.head, "main", "", false) }

// land は review のゲートまで進め、approved_ref を添えて land を受ける。
func (p *prEnv) land(approved string) (*runstate.State, *Engine) {
	p.t.Helper()
	st, e := p.tl.start("pr-land", map[string]any{"json": `{"outcome":"back","detail":"x"}`, "pr": 7, "base": "main"})
	if st.Status != runstate.StatusWaiting {
		p.t.Fatalf("status %s", st.Status)
	}
	return mustResolve(p.t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: approved}), e
}

func (p *prEnv) ghCalls() string { return p.tl.read(p.tl.gh, "calls") }

func (p *prEnv) merges() int { return strings.Count(p.ghCalls(), "pr\tmerge\t") }

func landOut(t *testing.T, st *runstate.State) map[string]any { return output(t, st, "land") }

// 1: PR を読めない（3 回試す）→ blocked。入れていない。
func TestLandUnreadablePRIsBlocked(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-missing", "1")
	st, _ := p.land(p.head)
	out := landOut(t, st)
	if st.Reason != "blocked" || out["outcome"] != "blocked" || !strings.Contains(fmt.Sprint(out["detail"]), "読めない") || p.merges() != 0 {
		t.Fatalf("reason %s output %v merges %d", st.Reason, out, p.merges())
	}
	if n := strings.Count(p.ghCalls(), "pr\tview\t"); n != retryTimes {
		t.Fatalf("gh pr view was tried %d times, want %d", n, retryTimes)
	}
	if ws := st.Unit(MainUnit).Workspace; ws != nil && ws.HeadSHA != "" {
		t.Fatalf("no head can be recorded when the PR was not read: %+v", ws)
	}
}

// 2: 宛先が with.base と違う → base_changed（失敗）。入った後の PR も含む（付け替えて入った PR を landed にしない）。
func TestLandBaseChanged(t *testing.T) {
	for name, view := range map[string]func(p *prEnv) string{
		"open":   func(p *prEnv) string { return p.view("OPEN", p.head, "develop", "", false) },
		"merged": func(p *prEnv) string { return p.view("MERGED", p.head, "develop", "m1", false) },
	} {
		t.Run(name, func(t *testing.T) {
			p := newPREnv(t)
			p.tl.write(p.tl.gh, "pr-view.json", view(p))
			st, _ := p.land(p.head)
			if st.Status != runstate.StatusFailed || st.Reason != "pr_base_changed" || landOut(t, st)["outcome"] != "base_changed" || p.merges() != 0 {
				t.Fatalf("status %s reason %s output %v", st.Status, st.Reason, landOut(t, st))
			}
		})
	}
}

// 3: すでに入っていて、入った先頭が approved_ref と同じ → landed。入れる命令は呼ばない。入れた後のコミットを記録する。
func TestLandAlreadyMerged(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.view("MERGED", p.head, "main", "m1m1", false))
	st, _ := p.land(p.head)
	out := landOut(t, st)
	if st.Reason != "landed" || out["outcome"] != "landed" || out["merge_commit"] != "m1m1" || out["head_sha"] != p.head || p.merges() != 0 {
		t.Fatalf("reason %s output %v merges %d", st.Reason, out, p.merges())
	}
	ws := st.Unit(MainUnit).Workspace
	if ws == nil || ws.MergeCommit != "m1m1" || ws.HeadSHA != p.head {
		t.Fatalf("workspace = %+v", ws)
	}
}

// 4: すでに入っているが、先頭が approved_ref と違う → merged_other（失敗）。
func TestLandMergedOther(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.view("MERGED", p.head, "main", "m1", false))
	st, _ := p.land("0000000000000000000000000000000000000000")
	if st.Status != runstate.StatusFailed || st.Reason != "merged_unapproved" || landOut(t, st)["outcome"] != "merged_other" || p.merges() != 0 {
		t.Fatalf("status %s reason %s output %v", st.Status, st.Reason, landOut(t, st))
	}
}

// 5: 入らずに閉じた → closed（失敗）。
func TestLandClosed(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.view("CLOSED", p.head, "main", "", false))
	st, _ := p.land(p.head)
	if st.Status != runstate.StatusFailed || st.Reason != "pr_closed" || landOut(t, st)["outcome"] != "closed" || p.merges() != 0 {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
}

// 6: approved_ref が空、または PR の先頭と違う → mismatch。入れず、いまの先頭を記録する。
func TestLandMismatch(t *testing.T) {
	for name, approved := range map[string]string{"empty": "", "other": "1111111111111111111111111111111111111111"} {
		t.Run(name, func(t *testing.T) {
			p := newPREnv(t)
			p.tl.write(p.tl.gh, "pr-view.json", p.openView())
			st, _ := p.land(approved)
			out := landOut(t, st)
			if st.Reason != "mismatch" || out["outcome"] != "mismatch" || out["head_sha"] != p.head || p.merges() != 0 {
				t.Fatalf("reason %s output %v merges %d", st.Reason, out, p.merges())
			}
			if ws := st.Unit(MainUnit).Workspace; ws == nil || ws.HeadSHA != p.head {
				t.Fatalf("the current head must be recorded: %+v", ws)
			}
		})
	}
}

// 7: PR の先頭が宛先の最新を含んでいない（merge-base --is-ancestor が 1）→ behind。外から push された先頭が手元に無くても
// 「含んでいない」と読み違えない（PR の先頭も fetch する）。
func TestLandBehind(t *testing.T) {
	p := newPREnv(t)
	base := p.advanceBase("other.txt", "x\n")
	p.tl.write(p.tl.gh, "pr-view.json", p.openView())
	st, _ := p.land(p.head)
	out := landOut(t, st)
	if st.Reason != "behind" || out["outcome"] != "behind" || out["head_sha"] != p.head || !strings.Contains(fmt.Sprint(out["detail"]), base) || p.merges() != 0 {
		t.Fatalf("reason %s output %v merges %d", st.Reason, out, p.merges())
	}
}

// 7（続き）: 手元に無い先頭でも、宛先を含むかを正しく判定する。
func TestLandHeadMissingLocally(t *testing.T) {
	p := newPREnv(t)
	outside := p.pushFromOutside("outside.txt")
	rgit(t, p.origin, "update-ref", "refs/pull/7/head", outside)
	if err := exec.Command("git", "-C", p.repo, "cat-file", "-e", outside+"^{commit}").Run(); err == nil {
		t.Fatal("the outside head must not exist in the local clone before the land")
	}
	p.advanceBase("other.txt", "x\n")
	p.tl.write(p.tl.gh, "pr-view.json", p.view("OPEN", outside, "main", "", false))
	st, _ := p.land(outside)
	out := landOut(t, st)
	if st.Reason != "behind" || out["outcome"] != "behind" || out["head_sha"] != outside {
		t.Fatalf("reason %s output %v (a head that is not local yet must not be read as a failure)", st.Reason, out)
	}
}

// 7': fetch が通らない・祖先の判定が 0 でも 1 でもない終了コードで終わった → blocked（理由は detail に）。
func TestLandFetchOrAncestryFailureIsBlocked(t *testing.T) {
	p := newPREnv(t)
	rgit(t, p.origin, "update-ref", "-d", "refs/pull/7/head")
	p.tl.write(p.tl.gh, "pr-view.json", p.openView())
	st, _ := p.land(p.head)
	out := landOut(t, st)
	if st.Reason != "blocked" || out["outcome"] != "blocked" || p.merges() != 0 {
		t.Fatalf("a failed fetch of the PR head: reason %s output %v", st.Reason, out)
	}

	// PR の先頭として読んだ SHA が、どこにも無い（祖先の判定が 128 で終わる）。
	p = newPREnv(t)
	ghost := "2222222222222222222222222222222222222222"
	p.tl.write(p.tl.gh, "pr-view.json", p.view("OPEN", ghost, "main", "", false))
	st, _ = p.land(ghost)
	out = landOut(t, st)
	if st.Reason != "blocked" || out["outcome"] != "blocked" || p.merges() != 0 {
		t.Fatalf("an ancestry check that failed: reason %s output %v", st.Reason, out)
	}
}

// 8: 下書き・失敗か未完了のチェック・チェックを読めない → blocked。チェック 0 件は通す。宛先の CI の運用が after-merge なら見ない。
func TestLandChecks(t *testing.T) {
	merged := func(p *prEnv) { p.tl.write(p.tl.gh, "merge.then", p.view("MERGED", p.head, "main", "mc01", false)) }
	cases := []struct {
		name   string
		setup  func(p *prEnv)
		reason string
	}{
		{"draft", func(p *prEnv) {
			p.tl.write(p.tl.gh, "pr-view.1", p.view("OPEN", p.head, "main", "", true))
		}, "blocked"},
		{"failed check", func(p *prEnv) { p.tl.write(p.tl.gh, "checks", `[{"name":"test","state":"FAILURE","bucket":"fail"}]`) }, "blocked"},
		{"cancelled check", func(p *prEnv) {
			p.tl.write(p.tl.gh, "checks", `[{"name":"test","state":"CANCELLED","bucket":"cancel"}]`)
		}, "blocked"},
		{"pending check", func(p *prEnv) {
			p.tl.write(p.tl.gh, "checks", `[{"name":"test","state":"PENDING","bucket":"pending"}]`)
		}, "blocked"},
		{"unreadable checks", func(p *prEnv) { p.tl.write(p.tl.gh, "checks", `not json`) }, "blocked"},
		{"no checks, as an empty array", func(p *prEnv) { p.tl.write(p.tl.gh, "checks", `[]`) }, "landed"},
		{"no checks, as gh reports them", func(p *prEnv) { p.tl.write(p.tl.gh, "checks.none", "1") }, "landed"},
		{"passing and skipped checks", func(p *prEnv) {
			p.tl.write(p.tl.gh, "checks", `[{"name":"a","state":"SUCCESS","bucket":"pass"},{"name":"b","state":"SKIPPED","bucket":"skipping"}]`)
		}, "landed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := newPREnv(t)
			p.tl.write(p.tl.gh, "pr-view.1", p.openView()) // 入れる命令の後の読み直しは、入った後の PR（merge.then）
			merged(p)
			c.setup(p)
			st, _ := p.land(p.head)
			out := landOut(t, st)
			if st.Reason != c.reason || out["outcome"] != c.reason {
				t.Fatalf("reason %s output %v, want %s", st.Reason, out, c.reason)
			}
			if (c.reason == "blocked") != (p.merges() == 0) {
				t.Fatalf("merges = %d for %s", p.merges(), c.reason)
			}
		})
	}

	t.Run("after-merge CI is not looked at", func(t *testing.T) {
		p := newPREnv(t)
		rgit(t, p.repo, "checkout", "-q", "main")
		if err := os.MkdirAll(filepath.Join(p.repo, ".claude-harness"), 0o755); err != nil {
			t.Fatal(err)
		}
		commitFile(t, p.repo, ".claude-harness/ci.json", `{"trigger":"after-merge"}`+"\n", "chore: declare the CI")
		rgit(t, p.repo, "push", "-q", "origin", "main")
		// PR の先頭は、この宣言のコミットを含む（含まなければ behind になる）。
		rgit(t, p.repo, "checkout", "-q", p.branch)
		rgit(t, p.repo, "merge", "-q", "--no-ff", "--no-edit", "main")
		head := p.localHead()
		rgit(t, p.repo, "push", "-q", "origin", p.branch)
		rgit(t, p.origin, "update-ref", "refs/pull/7/head", head)
		p.tl.write(p.tl.gh, "pr-view.json", p.view("OPEN", head, "main", "", false))
		p.tl.write(p.tl.gh, "merge.then", p.view("MERGED", head, "main", "mc02", false))
		p.tl.write(p.tl.gh, "checks", `[{"name":"test","state":"FAILURE","bucket":"fail"}]`)
		st, e := p.tl.start("pr-land", map[string]any{"json": `{"outcome":"back","detail":"x"}`, "pr": 7, "base": "main"})
		dir := t.TempDir()
		script, err := os.ReadFile(filepath.Join("..", "..", "..", "plugin", "scripts", "ci-trigger.sh"))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "ci-trigger.sh"), script, 0o755); err != nil {
			t.Fatal(err)
		}
		e.ScriptsDir = dir
		st = mustResolve(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: head})
		if st.Reason != "landed" || strings.Contains(p.ghCalls(), "pr\tchecks") {
			t.Fatalf("reason %s; gh calls:\n%s", st.Reason, p.ghCalls())
		}
	})
}

// 9: gh pr merge <pr> --squash --match-head-commit <approved_ref> が通ったら、PR を読み直す。MERGED・宛先が with.base・先頭が
// approved_ref なら landed。入れ方は squash に固定し、--auto・--admin・--delete-branch を付けない。
func TestLandMergesAndConfirms(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.openView())
	p.tl.write(p.tl.gh, "merge.then", p.view("MERGED", p.head, "main", "squashed01", false))
	st, _ := p.land(p.head)
	out := landOut(t, st)
	if st.Status != runstate.StatusSucceeded || st.Reason != "landed" || out["outcome"] != "landed" || out["merge_commit"] != "squashed01" || out["head_sha"] != p.head {
		t.Fatalf("status %s reason %s output %v", st.Status, st.Reason, out)
	}
	want := "pr\tmerge\t7\t--squash\t--match-head-commit\t" + p.head + "\n"
	calls := p.ghCalls()
	if !strings.Contains(calls, want) {
		t.Fatalf("gh calls lack %q:\n%s", want, calls)
	}
	for _, banned := range []string{"--auto", "--admin", "--delete-branch", "--rebase", "--merge"} {
		if strings.Contains(calls, banned) {
			t.Errorf("gh was called with %s:\n%s", banned, calls)
		}
	}
	if ws := st.Unit(MainUnit).Workspace; ws == nil || ws.MergeCommit != "squashed01" || ws.HeadSHA != p.head {
		t.Fatalf("workspace = %+v", ws)
	}
	// 入れる前に確かめている: 先頭の一致の確かめ（PR を読む）→ 宛先の fetch → チェック → 入れる、の順。
	iView, iChecks, iMerge := strings.Index(calls, "pr\tview"), strings.Index(calls, "pr\tchecks"), strings.Index(calls, "pr\tmerge")
	if !(iView >= 0 && iView < iChecks && iChecks < iMerge) {
		t.Fatalf("the checks must come before the merge:\n%s", calls)
	}
}

// 9（続き）: 入れる命令が通っても、読み直した PR が MERGED でなければ not_confirmed（失敗 merge_not_confirmed）。
func TestLandNotConfirmed(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.openView()) // 入れる命令の後も OPEN のまま（待ち行列）
	st, _ := p.land(p.head)
	if st.Status != runstate.StatusFailed || st.Reason != "merge_not_confirmed" || landOut(t, st)["outcome"] != "not_confirmed" || p.merges() != 1 {
		t.Fatalf("status %s reason %s output %v merges %d", st.Status, st.Reason, landOut(t, st), p.merges())
	}
	// 入った後の先頭が approved_ref と違う、または宛先が違うときも、landed にしない。
	for name, after := range map[string]string{
		"other head": "MERGED/3333333333333333333333333333333333333333/main",
		"other base": "MERGED/HEAD/develop",
	} {
		t.Run(name, func(t *testing.T) {
			p := newPREnv(t)
			f := strings.Split(after, "/")
			head := f[1]
			if head == "HEAD" {
				head = p.head
			}
			p.tl.write(p.tl.gh, "pr-view.json", p.openView())
			p.tl.write(p.tl.gh, "merge.then", p.view(f[0], head, f[2], "m", false))
			st, _ := p.land(p.head)
			if st.Reason != "merge_not_confirmed" {
				t.Fatalf("reason %s output %v", st.Reason, landOut(t, st))
			}
		})
	}
}

// 10: 入れる命令が通らなかった → 1〜7' を確かめ直し、当たればその結果。どれにも当たらなければ blocked（gh の標準エラーを detail に）。
func TestLandMergeCommandFails(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.openView())
	p.tl.write(p.tl.gh, "merge.code", "1")
	p.tl.write(p.tl.gh, "merge.err", "Squash merges are not allowed on this repository")
	st, _ := p.land(p.head)
	out := landOut(t, st)
	if st.Reason != "blocked" || out["outcome"] != "blocked" || !strings.Contains(fmt.Sprint(out["detail"]), "Squash merges are not allowed") || p.merges() != 1 {
		t.Fatalf("reason %s output %v", st.Reason, out)
	}

	// 命令が通らなかった間に、PR が（入った後の先頭が approved_ref と同じで）入っていた → landed。
	p = newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.1", p.openView())
	p.tl.write(p.tl.gh, "pr-view.json", p.view("MERGED", p.head, "main", "mc03", false))
	p.tl.write(p.tl.gh, "merge.code", "1")
	st, _ = p.land(p.head)
	if st.Reason != "landed" || landOut(t, st)["merge_commit"] != "mc03" {
		t.Fatalf("reason %s output %v", st.Reason, landOut(t, st))
	}

	// 通らなかった間に、PR の先頭が変わった → 確かめ直しの 6（mismatch）。
	p = newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.1", p.openView())
	p.tl.write(p.tl.gh, "pr-view.json", p.view("OPEN", "4444444444444444444444444444444444444444", "main", "", false))
	p.tl.write(p.tl.gh, "merge.code", "1")
	st, _ = p.land(p.head)
	if st.Reason != "mismatch" {
		t.Fatalf("reason %s output %v", st.Reason, landOut(t, st))
	}
}

// 同じ approved_ref の land を 2 度受けても、2 度入れない: 終わった実行への resume は終わりの状態を返し、入れる命令は 1 度だけ。
func TestLandTwiceMergesOnce(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.openView())
	p.tl.write(p.tl.gh, "merge.then", p.view("MERGED", p.head, "main", "mc04", false))
	st, e := p.land(p.head)
	if st.Reason != "landed" {
		t.Fatalf("reason %s", st.Reason)
	}
	_, err := resolve(t, e, Resolution{Input: "land", HasInput: true, ApprovedRef: p.head})
	if err == nil {
		t.Fatal("a second land on a finished run must not be accepted")
	}
	if p.merges() != 1 {
		t.Fatalf("gh pr merge ran %d times", p.merges())
	}
}

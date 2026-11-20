package engine

import (
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// pull-request 種類の action: ensure-base の試験（docs/harness-runtime-design.md §5.6.3）。git は実物（bare の origin）。

func (p *prEnv) ensureBase(branch string) (*runstate.State, *Engine) {
	p.t.Helper()
	return p.tl.start("pr-ensure-base", map[string]any{"branch": branch, "from": "main"})
}

func (p *prEnv) originRef(branch string) string {
	out := rgit(p.t, p.origin, "for-each-ref", "--format=%(objectname)", "refs/heads/"+branch)
	return out
}

func integrationOf(t *testing.T, st *runstate.State) (string, string) {
	t.Helper()
	ws := st.Unit(MainUnit).Workspace
	if ws == nil {
		t.Fatal("no workspace recorded")
	}
	return ws.IntegrationBranch, ws.IntegrationHead
}

// 無い → 既定ブランチの先頭から作り、名前と先頭を記録する。強制の push（--force 単体）は使わない。
func TestEnsureBaseCreatesFromTheDefaultBranch(t *testing.T) {
	p := newPREnv(t)
	main := rgit(t, p.repo, "rev-parse", "refs/remotes/origin/main")
	st, _ := p.ensureBase("integration/c-12")
	if st.Status != runstate.StatusSucceeded || st.Reason != "created" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if got := p.originRef("integration/c-12"); got != main {
		t.Fatalf("origin integration/c-12 = %q, want the head of main %q", got, main)
	}
	if b, h := integrationOf(t, st); b != "integration/c-12" || h != main {
		t.Fatalf("recorded %q %q", b, h)
	}
	if out := output(t, st, "integration"); out["head_sha"] != main || out["branch"] != "integration/c-12" {
		t.Fatalf("output = %v", out)
	}
	calls := p.gitCalls()
	if strings.Contains(calls, " --force ") || strings.Contains(calls, "push -f") || !strings.Contains(calls, "--force-with-lease=refs/heads/integration/c-12:") {
		t.Fatalf("git calls:\n%s", calls)
	}
}

// 在る → 動かさない。既定ブランチが進んでいても、統合ブランチの先頭は変わらない。
func TestEnsureBaseLeavesAnExistingBranchAlone(t *testing.T) {
	p := newPREnv(t)
	st, _ := p.ensureBase("integration/c-12")
	first := p.originRef("integration/c-12")
	p.advanceBase("later.txt", "x\n")
	pushesBefore := strings.Count(p.gitCalls(), "push")
	st, _ = p.ensureBase("integration/c-12")
	if st.Status != runstate.StatusSucceeded || st.Reason != "existing" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if got := p.originRef("integration/c-12"); got != first {
		t.Fatalf("an existing integration branch moved: %s -> %s", first, got)
	}
	if b, h := integrationOf(t, st); b != "integration/c-12" || h != first {
		t.Fatalf("recorded %q %q, want the existing head %s", b, h, first)
	}
	if n := strings.Count(p.gitCalls(), "push"); n != pushesBefore {
		t.Errorf("an existing branch must not be pushed to (%d pushes in the second run):\n%s", n-pushesBefore, p.gitCalls())
	}
}

// 先に別の先頭で作られていた → existing（その先頭を記録する。動かさない）。
func TestEnsureBaseExistingWithAnotherHead(t *testing.T) {
	p := newPREnv(t)
	rgit(t, p.other, "fetch", "-q", "origin")
	rgit(t, p.other, "checkout", "-q", "-B", "integration/c-12", "origin/main")
	other := commitFile(t, p.other, "int.txt", "i\n", "feat: on the integration branch")
	rgit(t, p.other, "push", "-q", "origin", "integration/c-12")
	st, _ := p.ensureBase("integration/c-12")
	if st.Status != runstate.StatusSucceeded || st.Reason != "existing" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if b, h := integrationOf(t, st); b != "integration/c-12" || h != other {
		t.Fatalf("recorded %q %q, want %s", b, h, other)
	}
	if got := p.originRef("integration/c-12"); got != other {
		t.Fatalf("origin moved to %s", got)
	}
}

// 2 つの実行を並べる: どちらも失敗せず、同じ先頭を記録する。
func TestEnsureBaseTwoRunsAtOnce(t *testing.T) {
	p := newPREnv(t)
	rgit(t, filepath.Dir(p.repo), "clone", "-q", p.origin, filepath.Join(filepath.Dir(p.repo), "repo2"))
	second := *p.tl
	second.cwd = filepath.Join(filepath.Dir(p.repo), "repo2")
	var wg sync.WaitGroup
	states := make([]*runstate.State, 2)
	for i, tl := range []*tools{p.tl, &second} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			states[i], _ = tl.start("pr-ensure-base", map[string]any{"branch": "integration/c-12", "from": "main"})
		}()
	}
	wg.Wait()
	want := p.originRef("integration/c-12")
	for i, st := range states {
		if st.Status != runstate.StatusSucceeded {
			t.Fatalf("run %d: status %s reason %s", i, st.Status, st.Reason)
		}
		if b, h := integrationOf(t, st); b != "integration/c-12" || h != want {
			t.Fatalf("run %d recorded %q %q, want head %s", i, b, h, want)
		}
	}
}

// origin へ届かない → unavailable（3 回試す）。
func TestEnsureBaseUnavailable(t *testing.T) {
	p := newPREnv(t)
	rgit(t, p.repo, "remote", "set-url", "origin", filepath.Join(filepath.Dir(p.repo), "no-such-origin.git"))
	st, _ := p.ensureBase("integration/c-12")
	if st.Status != runstate.StatusFailed || st.Reason != "unavailable" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if n := strings.Count(p.gitCalls(), "ls-remote"); n != retryTimes {
		t.Fatalf("ls-remote was tried %d times, want %d", n, retryTimes)
	}
	if ws := st.Unit(MainUnit).Workspace; ws != nil && ws.IntegrationBranch != "" {
		t.Fatalf("a failed step recorded %+v", ws)
	}
}

// 作れない（origin が拒む。integration という名前のブランチが在ると integration/<名前> は作れない）→ refused。
func TestEnsureBaseRefused(t *testing.T) {
	p := newPREnv(t)
	rgit(t, p.repo, "push", "-q", "origin", "main:refs/heads/integration")
	st, _ := p.ensureBase("integration/c-12")
	if st.Status != runstate.StatusFailed || st.Reason != "refused" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if ws := st.Unit(MainUnit).Workspace; ws != nil && ws.IntegrationBranch != "" {
		t.Fatalf("a refused step recorded %+v", ws)
	}
}

// 入力の誤り: from と同じ・ブランチ名として受けられない形 → step_error。
func TestEnsureBaseRejectsBadInput(t *testing.T) {
	for _, branch := range []string{"main", "integration/../x", "-x", "a b"} {
		p := newPREnv(t)
		st, _ := p.ensureBase(branch)
		if st.Status != runstate.StatusFailed || st.Reason != "step_error" {
			t.Errorf("branch %q: status %s reason %s", branch, st.Status, st.Reason)
		}
	}
}

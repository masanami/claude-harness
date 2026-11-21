package engine

import (
	"fmt"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// pull-request 種類の action: adopt（ブランチの名前）・open・retire の試験（docs/harness-runtime-design.md §5.6.3）。git は実物（bare の origin）、gh は偽。
// p.branch（feature/x）を統合ブランチに見立てる（main から 1 コミット進んでいる）。

func (p *prEnv) adopt(ref string) (*runstate.State, *Engine) {
	p.t.Helper()
	return p.tl.start("pr-adopt", map[string]any{"ref": ref})
}

func (p *prEnv) listJSON(number int, head, base string, extra string) string {
	return fmt.Sprintf(`[{"number":%d,"url":"https://github.com/o/r/pull/%d","headRefName":%q,"headRefOid":%q,"baseRefName":%q,"isCrossRepository":false,"isDraft":false%s}]`,
		number, number, p.branch, head, base, extra)
}

// adopt の足した結果を 1 行ずつ。
func TestAdoptBranchName(t *testing.T) {
	cases := []struct {
		name, ref, reason string
		setup             func(p *prEnv)
		check             func(t *testing.T, p *prEnv, out map[string]any)
		ghCalled          bool
	}{
		{name: "an open pull request exists", ref: "feature/x", reason: "adopted", ghCalled: true,
			setup: func(p *prEnv) { p.tl.write(p.tl.gh, "pr-list", p.listJSON(9, p.head, "main", "")) },
			check: func(t *testing.T, p *prEnv, out map[string]any) {
				if out["pr_number"] != float64(9) || out["key"] != "pr-9" || out["source"] != "integration" || out["branch"] != "feature/x" || out["base"] != "main" || out["head_sha"] != p.head {
					t.Fatalf("output = %v", out)
				}
			}},
		{name: "a draft pull request", ref: "feature/x", reason: "draft", ghCalled: true,
			setup: func(p *prEnv) {
				p.tl.write(p.tl.gh, "pr-list", p.listJSON(9, p.head, "main", "")[:0]+strings.Replace(p.listJSON(9, p.head, "main", ""), `"isDraft":false`, `"isDraft":true`, 1))
			}},
		{name: "a pull request from a fork is ignored", ref: "feature/x", reason: "no_pr", ghCalled: true,
			setup: func(p *prEnv) {
				p.tl.write(p.tl.gh, "pr-list", strings.Replace(p.listJSON(9, p.head, "main", ""), `"isCrossRepository":false`, `"isCrossRepository":true`, 1))
			}},
		{name: "no pull request, commits ahead of the default branch", ref: "feature/x", reason: "no_pr", ghCalled: true,
			check: func(t *testing.T, p *prEnv, out map[string]any) {
				if out["pr_number"] != float64(0) || out["branch"] != "feature/x" || out["base"] != "main" || out["head_sha"] != p.head || out["source"] != "integration" || out["key"] != "" {
					t.Fatalf("output = %v", out)
				}
			}},
		{name: "two open pull requests", ref: "feature/x", reason: "", ghCalled: true,
			setup: func(p *prEnv) {
				one := p.listJSON(9, p.head, "main", "")
				p.tl.write(p.tl.gh, "pr-list", strings.TrimSuffix(one, "]")+","+strings.TrimPrefix(p.listJSON(10, p.head, "main", ""), "["))
			}},
		{name: "the branch is missing on origin", ref: "feature/none", reason: "branch_missing", ghCalled: true},
		{name: "no commit that the default branch lacks", ref: "feature/x", reason: "empty", ghCalled: true,
			setup: func(p *prEnv) {
				// main を、統合ブランチの先頭まで進める
				rgit(p.t, p.repo, "push", "-q", "origin", p.head+":refs/heads/main")
			}},
		{name: "the name of the default branch", ref: "main", reason: "unsupported_ref", ghCalled: true},
		{name: "a form that is not a branch name", ref: "feature/x:y", reason: "unsupported_ref"},
		{name: "a name starting with a dash", ref: "-x", reason: "unsupported_ref"},
		{name: "a name with two dots", ref: "a..b", reason: "unsupported_ref"},
		{name: "a name ending with .lock", ref: "a.lock", reason: "unsupported_ref"},
		{name: "a URL with a suffix", ref: "https://github.com/o/r/pull/7/files", reason: "unsupported_ref"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := newPREnv(t)
			if c.setup != nil {
				c.setup(p)
			}
			st, _ := p.adopt(c.ref)
			if c.reason == "" {
				if st.Status != runstate.StatusFailed {
					t.Fatalf("status %s reason %s, want a step error", st.Status, st.Reason)
				}
				return
			}
			if st.Status != runstate.StatusSucceeded || st.Reason != c.reason {
				t.Fatalf("status %s reason %s, want %s", st.Status, st.Reason, c.reason)
			}
			out := output(t, st, "adopt")
			if c.reason != "adopted" && c.reason != "no_pr" && out["source"] != "pr" {
				t.Fatalf("source = %v, want pr for a ref that was not accepted", out["source"])
			}
			if c.check != nil {
				c.check(t, p, out)
			}
			if got := strings.Contains(p.ghCalls(), "repo\tview"); got != c.ghCalled {
				t.Fatalf("gh repo view called = %v, want %v", got, c.ghCalled)
			}
			if strings.Contains(p.ghCalls(), "pr\tcreate") || strings.Contains(p.gitCalls(), "push") && c.name != "no commit that the default branch lacks" {
				t.Fatalf("adopt must only read:\ngh: %s\ngit: %s", p.ghCalls(), p.gitCalls())
			}
		})
	}
}

// adopted（ブランチの名前から）は PR を記録する。URL から受けた adopted は source: pr。
func TestAdoptRecordsThePullRequest(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-list", p.listJSON(9, p.head, "main", ""))
	st, _ := p.adopt("feature/x")
	ws := st.Unit(MainUnit).Workspace
	if ws == nil || ws.PRNumber != 9 || ws.Branch != "feature/x" || ws.HeadSHA != p.head {
		t.Fatalf("workspace = %+v", ws)
	}
	p2 := newPREnv(t)
	p2.tl.write(p2.tl.gh, "adopt.json", fmt.Sprintf(`{"number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","baseRefName":"main","headRefName":"feature/x","headRefOid":%q,"isCrossRepository":false,"isDraft":false}`, p2.head))
	st, _ = p2.adopt("https://github.com/o/r/pull/7")
	if st.Reason != "adopted" || output(t, st, "adopt")["source"] != "pr" {
		t.Fatalf("reason %s output %v", st.Reason, output(t, st, "adopt"))
	}
}

// --- open -------------------------------------------------------------------

func (p *prEnv) open(extra map[string]any) (*runstate.State, *Engine) {
	p.t.Helper()
	in := map[string]any{"head": "feature/x", "base": "main", "title": "feat: add the widget", "summary": "the widget"}
	for k, v := range extra {
		in[k] = v
	}
	return p.tl.start("pr-open", in)
}

func TestOpenCreatesAPullRequestWithADeterministicBody(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-list-merged", `[
	  {"number":12,"title":"feat: second","url":"https://github.com/o/r/pull/12","body":"## 概要\n\nx\n\nCloses #101\nRefs #102\n\n## 振る舞い"},
	  {"number":11,"title":"feat: first | pipe","url":"https://github.com/o/r/pull/11","body":"Refs #102\nRefs #103\nCloses #101\nSee Closes #999 in the text\nCloses #7 (not a whole-line match)\n  Closes #8\r\nCloses #104\r\n"}
	]`)
	p.tl.write(p.tl.gh, "create.oid", p.head)
	st, _ := p.open(map[string]any{"challenge_id": "C-12",
		"summary": "the widget\n\nCloses #555\nfixes #556 and Resolved: #557\nCloses https://github.com/o/r/issues/558"})
	if st.Status != runstate.StatusSucceeded || st.Reason != "opened" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	out := output(t, st, "open")
	if out["pr_number"] != float64(7) || out["pr_url"] != "https://github.com/o/r/pull/7" {
		t.Fatalf("output = %v", out)
	}
	if !strings.Contains(p.ghCalls(), "pr\tcreate\t--base\tmain\t--head\tfeature/x\t--title\tfeat: add the widget\t--body-file\t") {
		t.Fatalf("gh calls:\n%s", p.ghCalls())
	}
	body := p.tl.read(p.tl.gh, "body.1.md")
	for _, want := range []string{
		"## 概要\n\nthe widget\n",
		"| #11 | feat: first \\| pipe | https://github.com/o/r/pull/11 |\n| #12 | feat: second | https://github.com/o/r/pull/12 |",
		"## Issue 参照\n\nCloses #101\nCloses #104\nRefs #102\nRefs #103\n\n",
		"課題: `C-12`。",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("body lacks %q:\n%s", want, body)
		}
	}
	// 行の全体が合わないものは写さない。概要（LLM の出力）の Issue を閉じる記法は、Closes の行にならない。
	for _, line := range strings.Split(body, "\n") {
		l := strings.ToLower(line)
		if strings.HasPrefix(line, "Closes #5") || strings.Contains(l, "fixes #556") || strings.Contains(line, "Resolved: #557") || strings.Contains(line, "Closes https://") {
			t.Errorf("the summary produced a closing keyword: %q", line)
		}
	}
	for _, not := range []string{"Closes #999", "Closes #7 ", "Closes #8\n", "Refs #101"} {
		if strings.Contains(body, not) {
			t.Errorf("body contains %q, which is not a whole-line match:\n%s", not, body)
		}
	}
	if !strings.Contains(body, "run `") {
		t.Errorf("body lacks the run id:\n%s", body)
	}
	ws := st.Unit(MainUnit).Workspace
	if ws == nil || ws.PRNumber != 7 || ws.Branch != "feature/x" || ws.HeadSHA != p.head {
		t.Fatalf("workspace = %+v", ws)
	}
	if strings.Contains(p.gitCalls(), "push") {
		t.Fatalf("open must not push:\n%s", p.gitCalls())
	}
}

// 題名にも、Issue を閉じる記法は残さない（squash で既定ブランチのコミットの題名になる）。取った件数が上限に届いたら、PR を作らない。
func TestOpenNeutralizesTheTitleAndRefusesATruncatedList(t *testing.T) {
	p := newPREnv(t)
	st, _ := p.open(map[string]any{"title": "fix: Closes #12 and more"})
	if st.Reason != "opened" || !strings.Contains(p.ghCalls(), "--title\t`Closes` #12") && !strings.Contains(p.ghCalls(), "`Closes` #12") {
		t.Fatalf("reason %s calls:\n%s", st.Reason, p.ghCalls())
	}
	if !strings.Contains(p.ghCalls(), "--limit\t1000\t") {
		t.Fatalf("the merged list must be read with a limit:\n%s", p.ghCalls())
	}
	p2 := newPREnv(t)
	var items []string
	for i := 1; i <= mergedListLimit; i++ {
		items = append(items, fmt.Sprintf(`{"number":%d,"title":"t","url":"u","body":""}`, i))
	}
	p2.tl.write(p2.tl.gh, "pr-list-merged", "["+strings.Join(items, ",")+"]")
	st, _ = p2.open(nil)
	if st.Status != runstate.StatusFailed || strings.Contains(p2.ghCalls(), "pr\tcreate") {
		t.Fatalf("status %s: a possibly truncated list must not create a pull request", st.Status)
	}
}

func TestOpenUsesAnExistingPullRequest(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-list", p.listJSON(9, p.head, "main", ""))
	st, _ := p.open(nil)
	if st.Status != runstate.StatusSucceeded || st.Reason != "existing" {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
	if out := output(t, st, "open"); out["pr_number"] != float64(9) {
		t.Fatalf("output = %v", out)
	}
	if strings.Contains(p.ghCalls(), "pr\tcreate") || strings.Contains(p.ghCalls(), "--state\tmerged") {
		t.Fatalf("an existing pull request must not be created again:\n%s", p.ghCalls())
	}
	if ws := st.Unit(MainUnit).Workspace; ws == nil || ws.PRNumber != 9 || ws.HeadSHA != p.head {
		t.Fatalf("workspace = %+v", ws)
	}
}

func TestOpenWithoutAChallengeID(t *testing.T) {
	p := newPREnv(t)
	st, _ := p.open(nil)
	if st.Reason != "opened" {
		t.Fatalf("reason %s", st.Reason)
	}
	body := p.tl.read(p.tl.gh, "body.1.md")
	if strings.Contains(body, "課題:") || !strings.Contains(body, "なし\n") {
		t.Fatalf("body:\n%s", body)
	}
}

func TestOpenRefusesSameHeadAndBase(t *testing.T) {
	p := newPREnv(t)
	st, _ := p.open(map[string]any{"head": "main"})
	if st.Status != runstate.StatusFailed {
		t.Fatalf("status %s reason %s", st.Status, st.Reason)
	}
}

// --- retire -----------------------------------------------------------------

func (p *prEnv) retire(branch, base, head string) (*runstate.State, *Engine) {
	p.t.Helper()
	return p.tl.start("pr-retire", map[string]any{"pr": 7, "branch": branch, "base": base, "head": head})
}

func (p *prEnv) mergedView(head, branch, base string) string {
	return fmt.Sprintf(`{"state":"MERGED","headRefOid":%q,"headRefName":%q,"baseRefName":%q}`, head, branch, base)
}

func TestRetire(t *testing.T) {
	cases := []struct {
		name, reason string
		view         func(p *prEnv) string // 空なら pr-view.json を置かない（読めない）
		openBase     string                // pr-list-base-open
		unreadable   bool
		move         bool // origin の統合ブランチを、入った先頭より先へ進める
		gone         bool // origin の統合ブランチが、すでに無い
		wantGone     bool
		branch, base string
		stepError    bool
	}{
		{name: "merged, same head → deleted", reason: "deleted", wantGone: true, view: func(p *prEnv) string { return p.mergedView(p.head, "feature/x", "main") }},
		{name: "a pull request that is not merged", reason: "kept", view: func(p *prEnv) string {
			return strings.Replace(p.mergedView(p.head, "feature/x", "main"), "MERGED", "OPEN", 1)
		}},
		{name: "a closed pull request", reason: "kept", view: func(p *prEnv) string {
			return strings.Replace(p.mergedView(p.head, "feature/x", "main"), "MERGED", "CLOSED", 1)
		}},
		{name: "merged into another base", reason: "kept", view: func(p *prEnv) string { return p.mergedView(p.head, "feature/x", "develop") }},
		{name: "merged from another branch", reason: "kept", view: func(p *prEnv) string { return p.mergedView(p.head, "feature/y", "main") }},
		{name: "merged with another head", reason: "kept", view: func(p *prEnv) string {
			return p.mergedView("0123456789012345678901234567890123456789", "feature/x", "main")
		}},
		{name: "the pull request cannot be read", reason: "kept", view: nil},
		{name: "the head moved on origin", reason: "kept", move: true, view: func(p *prEnv) string { return p.mergedView(p.head, "feature/x", "main") }},
		{name: "an open pull request to the branch", reason: "kept", openBase: `[{"number":20}]`, view: func(p *prEnv) string { return p.mergedView(p.head, "feature/x", "main") }},
		{name: "already gone", reason: "absent", gone: true, view: func(p *prEnv) string { return p.mergedView(p.head, "feature/x", "main") }},
		{name: "the default branch as the branch", stepError: true, branch: "main", base: "develop", view: func(p *prEnv) string { return p.mergedView(p.head, "main", "develop") }},
		{name: "the branch is the base", stepError: true, branch: "feature/x", base: "feature/x", view: func(p *prEnv) string { return p.mergedView(p.head, "feature/x", "feature/x") }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := newPREnv(t)
			if c.view != nil {
				p.tl.write(p.tl.gh, "pr-view.json", c.view(p))
			} else {
				p.tl.write(p.tl.gh, "pr-missing", "1")
			}
			if c.openBase != "" {
				p.tl.write(p.tl.gh, "pr-list-base-open", c.openBase)
			}
			if c.move {
				p.pushFromOutside("later.txt")
			}
			head := p.head
			if c.gone {
				rgit(t, p.repo, "push", "-q", "origin", ":refs/heads/feature/x")
			}
			branch, base := c.branch, c.base
			if branch == "" {
				branch = "feature/x"
			}
			if base == "" {
				base = "main"
			}
			st, _ := p.retire(branch, base, head)
			if c.stepError {
				if st.Status != runstate.StatusFailed {
					t.Fatalf("status %s reason %s, want a step error", st.Status, st.Reason)
				}
				if strings.Contains(p.gitCalls(), "push") {
					t.Fatalf("a delete command was built for the default branch / the base:\n%s", p.gitCalls())
				}
				if rgit(t, p.repo, "ls-remote", "--heads", p.origin, "main") == "" {
					t.Fatalf("main is gone")
				}
				return
			}
			if st.Status != runstate.StatusSucceeded || st.Reason != c.reason {
				t.Fatalf("status %s reason %s, want %s", st.Status, st.Reason, c.reason)
			}
			out := output(t, st, "retire")
			if d, _ := out["detail"].(string); d == "" {
				t.Fatalf("detail is empty: %v", out)
			}
			ref := p.originRef("feature/x")
			if c.wantGone && ref != "" {
				t.Fatalf("the branch is still on origin: %s", ref)
			}
			if !c.wantGone && !c.gone && ref == "" {
				t.Fatalf("the branch was deleted (outcome %s): %v", c.reason, out)
			}
			if p.originRef("main") == "" {
				t.Fatalf("main is gone")
			}
			if c.reason == "deleted" {
				if want := "push --porcelain --force-with-lease=refs/heads/feature/x:" + p.head + " origin :refs/heads/feature/x"; !strings.Contains(p.gitCalls(), want) {
					t.Fatalf("git calls lack %q:\n%s", want, p.gitCalls())
				}
			}
			if c.reason == "kept" && strings.Contains(p.gitCalls(), ":refs/heads/feature/x") && !c.move {
				t.Fatalf("a delete command ran although the branch is kept:\n%s", p.gitCalls())
			}
		})
	}
}

// 先頭が動いているときは、削除の命令を送っても origin が拒む（--force-with-lease の条件）。kept で、統合ブランチはそのまま。
func TestRetireDoesNotDeleteABranchWhoseHeadMoved(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.mergedView(p.head, "feature/x", "main"))
	moved := p.pushFromOutside("later.txt")
	st, _ := p.retire("feature/x", "main", p.head)
	out := output(t, st, "retire")
	if out["outcome"] != "kept" || !strings.Contains(out["detail"].(string), moved) {
		t.Fatalf("output = %v", out)
	}
	if p.originRef("feature/x") != moved {
		t.Fatalf("the branch moved or was deleted: %q", p.originRef("feature/x"))
	}
}

func TestRetireRejectsAnUnusableHead(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.mergedView(p.head, "feature/x", "main"))
	for _, head := range []string{"abc", "HEAD", "feature/x"} {
		st, _ := p.retire("feature/x", "main", head)
		if st.Status != runstate.StatusFailed {
			t.Fatalf("head %q: status %s", head, st.Status)
		}
	}
	if p.originRef("feature/x") == "" {
		t.Fatal("the branch was deleted")
	}
}

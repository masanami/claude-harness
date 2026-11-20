package engine

import (
	"fmt"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// land の squash の題名: 出来るコミットの題名は、PR のコミットの数に関わらず「PR の題名 (#番号)」にする
// （GitHub の既定は、コミットが 1 つだけの PR ではそのコミットの文面）。--match-head-commit は変えない。

func (p *prEnv) titled(view, title string) string {
	return strings.Replace(view, `{"state"`, fmt.Sprintf(`{"title":%q,"state"`, title), 1)
}

func (p *prEnv) mergeCall() string {
	for _, l := range strings.Split(p.ghCalls(), "\n") {
		if strings.HasPrefix(l, "pr\tmerge\t") {
			return l
		}
	}
	return ""
}

func TestLandSquashSubjectIsThePRTitleWhateverTheCommitCount(t *testing.T) {
	const title = "feat(runtime): add the widget"
	for _, extra := range []int{0, 2} { // 0: コミットが 1 つだけの PR、2: 3 つの PR
		t.Run(fmt.Sprintf("%d commits", extra+1), func(t *testing.T) {
			p := newPREnv(t)
			for i := 0; i < extra; i++ {
				p.head = commitFile(t, p.repo, fmt.Sprintf("more%d.txt", i), "x\n", fmt.Sprintf("wip: step %d", i))
			}
			rgit(t, p.repo, "push", "-q", "origin", p.branch)
			rgit(t, p.origin, "update-ref", "refs/pull/7/head", p.head)
			p.tl.write(p.tl.gh, "pr-view.json", p.titled(p.openView(), title))
			p.tl.write(p.tl.gh, "merge.then", p.titled(p.view("MERGED", p.head, "main", "squashed01", false), title))
			st, _ := p.land(p.head)
			if st.Status != runstate.StatusSucceeded || st.Reason != "landed" {
				t.Fatalf("status %s reason %s output %v", st.Status, st.Reason, landOut(t, st))
			}
			want := "pr\tmerge\t7\t--squash\t--match-head-commit\t" + p.head + "\t--subject\t" + title + " (#7)"
			if got := p.mergeCall(); got != want {
				t.Fatalf("merge call = %q, want %q", got, want)
			}
		})
	}
}

// 題名が読めない（空）ときは --subject を付けない（GitHub の既定に任せる）。--match-head-commit は付く。
func TestLandWithoutATitleOmitsTheSubject(t *testing.T) {
	p := newPREnv(t)
	p.tl.write(p.tl.gh, "pr-view.json", p.openView())
	p.tl.write(p.tl.gh, "merge.then", p.view("MERGED", p.head, "main", "squashed01", false))
	p.land(p.head)
	if got, want := p.mergeCall(), "pr\tmerge\t7\t--squash\t--match-head-commit\t"+p.head; got != want {
		t.Fatalf("merge call = %q, want %q", got, want)
	}
}

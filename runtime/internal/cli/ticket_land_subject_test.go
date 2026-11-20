package cli

import (
	"fmt"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// land の squash の題名（既定ブランチ宛て・統合ブランチ宛ての両方）。出来るコミットの題名は「PR の題名 (#番号)」。

func titledView(view, title string) string {
	return strings.Replace(view, `{"state"`, fmt.Sprintf(`{"title":%q,"state"`, title), 1)
}

func (l *landFixture) mergeCall() string {
	for _, c := range strings.Split(l.ghCalls(), "\n") {
		if strings.HasPrefix(c, "pr\tmerge\t") {
			return c
		}
	}
	return ""
}

func TestTicketLandSquashSubjectIsThePRTitle(t *testing.T) {
	const title = "feat(runtime): add the widget"
	cases := map[string]func(t *testing.T) *landFixture{
		"default branch":     func(t *testing.T) *landFixture { return newLandFixture(t, nil) },
		"integration branch": func(t *testing.T) *landFixture { return newIntegrationLand(t, nil) },
	}
	for name, mk := range cases {
		t.Run(name, func(t *testing.T) {
			l := mk(t)
			l.f.write("pr-view.json", titledView(viewJSON("OPEN", l.head, l.baseName(), ""), title))
			l.f.write("merge.then", titledView(viewJSON("MERGED", l.head, l.baseName(), "squashed0000000000000000000000000000000000"), title))
			d := l.land(l.head)
			if d.State != runstate.StatusSucceeded {
				t.Fatalf("doc = %+v", d)
			}
			want := "pr\tmerge\t7\t--squash\t--match-head-commit\t" + l.head + "\t--subject\t" + title + " (#7)"
			if got := l.mergeCall(); got != want {
				t.Fatalf("merge call = %q, want %q", got, want)
			}
		})
	}
}

// 入れる命令が通ったが、入ったと確かめられなかった（not_confirmed）統合ブランチ宛て: 実行は失敗で終わり、統合ブランチの先頭の記録は、
// 宛先を fetch したときの先頭（入れる前の値）のまま。入れた後のコミットとしては書かない。
func TestTicketLandNotConfirmedIntoTheIntegrationBranchKeepsTheFetchedHead(t *testing.T) {
	l := newIntegrationLand(t, nil)
	fetched := git(t, l.f.origin, "rev-parse", "refs/heads/"+integrationBranch)
	// 入れる命令の後も OPEN のまま（待ち行列）。
	d := l.land(l.head)
	if d.State != runstate.StatusFailed {
		t.Fatalf("doc = %+v", d)
	}
	if got := integrationCommit(t, d); got != fetched {
		t.Fatalf("integration commit = %s, want the fetched head %s", got, fetched)
	}
	if v := l.f.h.statusOf(l.id); v.Reason != "merge_not_confirmed" {
		t.Fatalf("reason = %s", v.Reason)
	}
}

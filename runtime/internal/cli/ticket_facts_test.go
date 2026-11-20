package cli

import (
	"reflect"
	"testing"
)

// 接続契約の facts（名前 → 値）: ticket のレビュー待ちの出力には毎回 facts.self_review が出る。値は implement・fix・respond のうち、
// 最後に成功して終わり self_review を返した段の値で、返さなかった段は値を変えない。宣言の無いワークフローではキーが無い。

func factsOfContract(t *testing.T, f *ticketFixture, args ...string) map[string]string {
	t.Helper()
	d, _ := f.h.contract(args...)
	return d.Facts
}

func respondReturning(t *testing.T, f *ticketFixture, n int, outcome string, extra map[string]any) {
	t.Helper()
	m := map[string]any{"outcome": outcome, "summary": "s", "human_question": ""}
	for k, v := range extra {
		m[k] = v
	}
	respond(t, f.fdir, n, 0, claudeStructured(m, 9))
}

func TestTicketReviewWaitAlwaysCarriesSelfReviewFact(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	id := runToReview(t, f)
	want := map[string]string{"self_review": "complete"}
	if got := factsOfContract(t, f, "status", id); !reflect.DeepEqual(got, want) {
		t.Fatalf("facts at the first review = %v, want %v", got, want)
	}
}

// respond が self_review を返せば、pushed でも no_change でも値が変わる。返さなければ前の値のまま。
func TestTicketFactFollowsTheLastStepThatReturnedSelfReview(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	// 4 回目: 自己レビューを実行して no_change。5 回目: 返さない pushed。6 回目: 実行して pushed。
	respondReturning(t, f, 4, "no_change", map[string]any{"self_review": "incomplete"})
	respondReturning(t, f, 5, "no_change", nil)
	respondPushes(t, f, 6, "late-fix.txt")
	id := runToReview(t, f)

	if _, errOut, code := f.h.run("resume", id, "--input", "respond"); code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s", code, errOut)
	}
	if got := factsOfContract(t, f, "status", id)["self_review"]; got != "incomplete" {
		t.Fatalf("after respond:no_change with self_review=incomplete: %q", got)
	}
	if _, errOut, code := f.h.run("resume", id, "--input", "respond"); code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s", code, errOut)
	}
	if got := factsOfContract(t, f, "status", id)["self_review"]; got != "incomplete" {
		t.Fatalf("after respond without self_review: %q, want the previous value", got)
	}

	respondReturning(t, f, 6, "pushed", map[string]any{"self_review": "complete"})
	runStep(t, f, 6, pushFile(f, "late-fix.txt"))
	greenCI(f)
	if _, errOut, code := f.h.run("resume", id, "--input", "respond"); code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s", code, errOut)
	}
	if got := factsOfContract(t, f, "status", id)["self_review"]; got != "complete" {
		t.Fatalf("after respond:pushed with self_review=complete: %q", got)
	}
}

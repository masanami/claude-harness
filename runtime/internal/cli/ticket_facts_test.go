package cli

import (
	"reflect"
	"testing"
)

// 接続契約の facts（名前 → 値）: ticket のレビュー待ちの出力には毎回 facts.self_review が出る。値は implement・fix・respond のうち、
// 最後に成功して終わり self_review を返した段の値。fix・respond は self_review を必須で返す（実行していなければ not_run）ので、
// implement が complete でも、後の respond が not_run を返せば facts.self_review は not_run になる。宣言の無いワークフローではキーが無い。

func factsOfContract(t *testing.T, f *ticketFixture, args ...string) map[string]string {
	t.Helper()
	d, _ := f.h.contract(args...)
	return d.Facts
}

func respondReturning(t *testing.T, f *ticketFixture, n int, outcome string, extra map[string]any) {
	t.Helper()
	m := map[string]any{"outcome": outcome, "summary": "s", "human_question": "", "self_review": "not_run"}
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

// respond は self_review を毎回返す。実行して返した値（complete・incomplete）がそのまま facts になり、実行していなければ not_run
// （implement が complete の後でも not_run。前の段の値は残らない）。
func TestTicketFactFollowsTheLastStepThatReturnedSelfReview(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	// 4 回目: 自己レビューを実行して no_change（incomplete）。5 回目: 実行せずに no_change（not_run）。6 回目: 実行して pushed（complete）。
	respondReturning(t, f, 4, "no_change", map[string]any{"self_review": "incomplete"})
	respondReturning(t, f, 5, "no_change", nil)
	id := runToReview(t, f)
	if got := factsOfContract(t, f, "status", id)["self_review"]; got != "complete" {
		t.Fatalf("after implement: %q, want complete", got)
	}

	if _, errOut, code := f.h.run("resume", id, "--input", "respond"); code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s", code, errOut)
	}
	if got := factsOfContract(t, f, "status", id)["self_review"]; got != "incomplete" {
		t.Fatalf("after respond:no_change with self_review=incomplete: %q", got)
	}
	if _, errOut, code := f.h.run("resume", id, "--input", "respond"); code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s", code, errOut)
	}
	if got := factsOfContract(t, f, "status", id)["self_review"]; got != "not_run" {
		t.Fatalf("after respond that did not run /self-review: %q, want not_run (the earlier value must not remain)", got)
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

// 型: self_review の欄が欠けた fix・respond の出力は、型付きの出力の検査で拒まれ（invalid_output）、次の段へ進まない。
// 欄を返さないことで前の段の complete を残させない。
func TestTicketRejectsFixAndRespondOutputWithoutSelfReview(t *testing.T) {
	t.Run("fix", func(t *testing.T) {
		f := newTicketFixture(t) // 1 回目の CI は red で、4 回目の claude の呼び出しが fix
		respond(t, f.fdir, 4, 0, claudeStructured(map[string]any{"outcome": "pass", "summary": "fixed", "deviation_report": ""}, 5.25))
		v, _, logs := runTicket(t, f)
		steps := v.Unit("main").Rounds[0].Steps
		if last := steps[len(steps)-1]; last.Step != "fix" || last.Outcome != "invalid_output" {
			t.Fatalf("last step %s:%s, want fix:invalid_output (steps %s)\n%s", last.Step, last.Outcome, stepSeq(v), logs)
		}
	})
	t.Run("respond", func(t *testing.T) {
		f := newTicketFixture(t)
		greenCI(f)
		respond(t, f.fdir, 4, 0, claudeStructured(map[string]any{"outcome": "no_change", "summary": "s", "human_question": ""}, 9))
		id := runToReview(t, f)
		f.h.run("resume", id, "--input", "respond")
		v := f.h.statusOf(id)
		steps := v.Unit("main").Rounds[len(v.Unit("main").Rounds)-1].Steps
		if last := steps[len(steps)-1]; last.Step != "respond" || last.Outcome != "invalid_output" {
			t.Fatalf("last step %s:%s, want respond:invalid_output (steps %s)", last.Step, last.Outcome, stepSeq(v))
		}
	})
}

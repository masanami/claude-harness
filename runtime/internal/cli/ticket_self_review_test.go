package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// /self-review は変更の種類に関わらず必須（#381）: implement の self_review が complete でなければ、outcome が pass・skip でも
// PR へ進めない。1 回だけ implement へ戻して /self-review を実行させ、2 回目も complete でなければ self_review_incomplete で止まる。

// implementResult は implement（偽の claude）の型付き出力。
func implementResult(outcome, selfReview string) string {
	return claudeStructured(map[string]any{"outcome": outcome, "self_review": selfReview, "pr_title": "test: cover the widget", "summary": "Adds a test.",
		"behaviors": []map[string]string{}, "residual_findings": []map[string]string{}, "unverified": []string{},
		"cross_repo_attestation": "", "deviation_report": ""}, 4.0)
}

func runTicket(t *testing.T, f *ticketFixture) (statusView, int, string) {
	t.Helper()
	out, errOut, code := f.h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	return decode[statusView](t, out), code, out + "\n" + errOut
}

func prCreated(t *testing.T, f *ticketFixture) bool {
	t.Helper()
	return strings.Contains(readFile(t, filepath.Join(f.ghDir, "calls")), "pr\tcreate")
}

// ① self_review が complete でない出力は（outcome が skip でも）commit・PR へ進まず implement へ戻る。戻った implement が
// complete を返せば、従来どおり commit から PR まで進む。
func TestTicketSendsImplementBackWhenSelfReviewIsNotComplete(t *testing.T) {
	for _, c := range []struct{ outcome, selfReview string }{
		{"skip", "not_run"},
		{"pass", "not_run"},
		{"pass", "incomplete"},
		{"skip", "incomplete"},
	} {
		t.Run(c.outcome+"/"+c.selfReview, func(t *testing.T) {
			f := newTicketFixture(t)
			greenCI(f)
			respond(t, f.fdir, 2, 0, implementResult(c.outcome, c.selfReview))
			respond(t, f.fdir, 3, 0, implementResult("pass", "complete"))
			respond(t, f.fdir, 4, 0, claudeStructured(map[string]any{"outcome": "committed", "commit_sha": "abc", "summary": "committed"}, 4.5))

			v, code, logs := runTicket(t, f)
			if code != ExitWaiting {
				t.Fatalf("run exit %d, want %d\n%s", code, ExitWaiting, logs)
			}
			want := "resolve:ok integration-route:none analyze:ok workspace:created implement:" + c.outcome + " self-review-route:" + c.selfReview +
				" implement:pass self-review-route:complete commit:committed sync:current e2e-route:no quality:pass publish:opened ci:green"
			if got := stepSeq(v); got != want {
				t.Fatalf("steps:\n got %s\nwant %s", got, want)
			}
			// 戻された implement は 2 回目の実行として起動され、同じ実装の指示文を受け取る。
			stdin := readFile(t, filepath.Join(f.fdir, "calls", "3.stdin"))
			if !strings.Contains(stdin, "# ticket: 実装（implement）") || !strings.Contains(stdin, `"attempt": 2`) {
				t.Errorf("the 3rd claude call is not the 2nd attempt of implement:\n%s", stdin)
			}
		})
	}
}

// ② 戻した implement も complete を返さなければ、commit へ進まず self_review_incomplete で止まり、PR を作らない。
func TestTicketStopsWhenSelfReviewIsStillNotCompleteAfterSendBack(t *testing.T) {
	for _, second := range []string{"not_run", "incomplete"} {
		t.Run(second, func(t *testing.T) {
			f := newTicketFixture(t)
			respond(t, f.fdir, 2, 0, implementResult("skip", "not_run"))
			respond(t, f.fdir, 3, 0, implementResult("pass", second))

			v, code, logs := runTicket(t, f)
			if code != ExitFailed {
				t.Fatalf("run exit %d, want %d\n%s", code, ExitFailed, logs)
			}
			if v.Status != "failed" || v.Reason != "self_review_incomplete" {
				t.Fatalf("status %q reason %q", v.Status, v.Reason)
			}
			want := "resolve:ok integration-route:none analyze:ok workspace:created implement:skip self-review-route:not_run implement:pass self-review-route:" + second
			if got := stepSeq(v); got != want {
				t.Fatalf("steps:\n got %s\nwant %s", got, want)
			}
			if _, err := os.Stat(filepath.Join(f.fdir, "calls", "4.stdin")); !os.IsNotExist(err) {
				t.Errorf("claude was launched a 4th time (commit): %v", err)
			}
			if prCreated(t, f) {
				t.Error("a PR was created")
			}
		})
	}
}

// ③ self_review が complete なら、従来どおり implement を 1 回だけ実行して commit から PR へ進む（skip も同じ）。
func TestTicketProceedsWhenSelfReviewIsComplete(t *testing.T) {
	for _, outcome := range []string{"pass", "skip"} {
		t.Run(outcome, func(t *testing.T) {
			f := newTicketFixture(t)
			greenCI(f)
			respond(t, f.fdir, 2, 0, implementResult(outcome, "complete"))

			v, code, logs := runTicket(t, f)
			if code != ExitWaiting {
				t.Fatalf("run exit %d, want %d\n%s", code, ExitWaiting, logs)
			}
			want := "resolve:ok integration-route:none analyze:ok workspace:created implement:" + outcome + " self-review-route:complete commit:committed sync:current e2e-route:no quality:pass publish:opened ci:green"
			if got := stepSeq(v); got != want {
				t.Fatalf("steps:\n got %s\nwant %s", got, want)
			}
			if !prCreated(t, f) {
				t.Error("no PR was created")
			}
		})
	}
}

// 型: self_review の欄が欠けた implement の出力は検証で弾かれ、commit・PR へ進まない。
func TestTicketRejectsImplementOutputWithoutSelfReview(t *testing.T) {
	f := newTicketFixture(t)
	respond(t, f.fdir, 2, 0, claudeStructured(map[string]any{"outcome": "pass", "pr_title": "test: cover the widget", "summary": "Adds a test.",
		"behaviors": []map[string]string{}, "residual_findings": []map[string]string{}, "unverified": []string{},
		"cross_repo_attestation": "", "deviation_report": ""}, 4.0))

	v, _, logs := runTicket(t, f)
	steps := v.Unit("main").Rounds[0].Steps
	last := steps[len(steps)-1]
	if last.Step != "implement" || last.Outcome != "invalid_output" {
		t.Fatalf("last step %s:%s, want implement:invalid_output (steps %s)\n%s", last.Step, last.Outcome, stepSeq(v), logs)
	}
	if strings.Contains(stepSeq(v), "commit:") || prCreated(t, f) {
		t.Fatalf("the output without self_review went on: steps %s", stepSeq(v))
	}
}

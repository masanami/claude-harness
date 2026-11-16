package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// レビュー待ちのゲート（review・review-human）を respond と添え書き（--note）で再開すると、添え書きが respond の段に届く（#377）。
// 呼び出し元は差し戻しの理由を --note で返すので、PR にレビューコメントが無くても respond が対応できるようにする。

// respondInputs は n 回目の claude の呼び出しに添付された inputs（段の with の値）を返す。
func respondInputs(t *testing.T, f *ticketFixture, n int) map[string]json.RawMessage {
	t.Helper()
	in := readFile(t, filepath.Join(f.fdir, "calls", fmt.Sprintf("%d.stdin", n)))
	start := strings.LastIndex(in, "```json\n")
	end := strings.LastIndex(in, "\n```")
	if start < 0 || end <= start {
		t.Fatalf("call %d has no attached data:\n%s", n, in)
	}
	var data struct {
		Inputs map[string]json.RawMessage `json:"inputs"`
	}
	if err := json.Unmarshal([]byte(in[start+len("```json\n"):end]), &data); err != nil {
		t.Fatalf("call %d: %v", n, err)
	}
	return data.Inputs
}

func noteOf(t *testing.T, inputs map[string]json.RawMessage) string {
	t.Helper()
	raw, ok := inputs["note"]
	if !ok {
		t.Fatalf("respond did not receive a note: %v", inputs)
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatalf("note = %s: %v", raw, err)
	}
	return s
}

const reviewNote = "完了の検証で差し戻し: README の手順が古い。harness resume の例を直すこと"

// review から respond を --note 付きで再開すると、respond の段の入力に添え書きが入る。PR にレビューコメントが無くても、
// 添え書きに対応して push した respond は pushed で quality → publish → ci へ進み、no_change で review へ戻らない。
func TestTicketReviewNoteReachesRespond(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	respondPushes(t, f, 4, "readme-fix.txt")
	id := runToReview(t, f)

	out, errOut, code := f.h.run("resume", id, "--input", "respond", "--note", reviewNote)
	if code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if got, want := stepSeq(v), firstRound+" respond:pushed quality:pass publish:updated ci:green"; got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}
	if v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	in := respondInputs(t, f, 4)
	if got := noteOf(t, in); got != reviewNote {
		t.Fatalf("note = %q, want %q", got, reviewNote)
	}
	if string(in["pr"]) == "" {
		t.Fatalf("respond lost the PR number: %v", in)
	}
}

// --note の無い respond の再開は拒否されず、添え書きは空文字で、今と同じ動き（PR のコメントだけを読み、対応が無ければ
// no_change で review へ戻る）になる。前の再開の添え書きは次の再開に残らない。
func TestTicketReviewWithoutNoteKeepsTheCurrentBehavior(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	noChange := claudeStructured(map[string]any{"outcome": "no_change", "summary": "no review comments", "human_question": ""}, 9)
	respond(t, f.fdir, 4, 0, noChange)
	respond(t, f.fdir, 5, 0, noChange)
	id := runToReview(t, f)

	out, errOut, code := f.h.run("resume", id, "--input", "respond", "--note", reviewNote)
	if code != ExitWaiting {
		t.Fatalf("resume with a note exit %d\n%s\n%s", code, out, errOut)
	}
	out, errOut, code = f.h.run("resume", id, "--input", "respond")
	if code != ExitWaiting {
		t.Fatalf("resume without a note exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if got, want := stepSeq(v), firstRound+" respond:no_change respond:no_change"; got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}
	if v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	if got := noteOf(t, respondInputs(t, f, 4)); got != reviewNote {
		t.Fatalf("first note = %q", got)
	}
	if got := noteOf(t, respondInputs(t, f, 5)); got != "" {
		t.Fatalf("note = %q, want the empty string (the previous note must not carry over)", got)
	}
}

// review-human（人の判断が要るゲート。端末から approve する）から respond を --note 付きで再開しても、添え書きが respond に届く。
// 添え書きの無い approve も拒否されない。
func TestTicketReviewHumanNoteReachesRespond(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	respond(t, f.fdir, 4, 0, claudeStructured(map[string]any{"outcome": "needs_human", "summary": "a design_change finding", "human_question": "which way?"}, 9))
	respondPushes(t, f, 5, "human-fix.txt")
	respond(t, f.fdir, 6, 0, claudeStructured(map[string]any{"outcome": "needs_human", "summary": "still a design_change", "human_question": "which way?"}, 10))
	respond(t, f.fdir, 7, 0, claudeStructured(map[string]any{"outcome": "no_change", "summary": "nothing to do", "human_question": ""}, 11))
	id := runToReview(t, f)

	out, errOut, code := f.h.run("resume", id, "--input", "respond")
	if code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	if v := decode[statusView](t, out); v.Waiting[0].Gate != "review-human" {
		t.Fatalf("waiting = %+v steps %s", v.Waiting, stepSeq(v))
	}

	// review-human は端末からの approve で解決する。端末を差し替えるため、このプロセスの中で Main を呼ぶ
	// （偽の claude・gh が届くように、fixture の環境をこのプロセスへ写す）。
	for _, kv := range f.h.env {
		k, v, _ := strings.Cut(kv, "=")
		t.Setenv(k, v)
	}
	approve := func(args ...string) (string, string, int) {
		t.Helper()
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		w.WriteString("yes\n")
		w.Close()
		var stdout, stderr bytes.Buffer
		code := Main(append([]string{"approve", id, "--input", "respond"}, args...), Env{
			Stdin: r, Stdout: &stdout, Stderr: &stderr,
			Getenv:     os.Getenv,
			Getwd:      func() (string, error) { return f.repo, nil },
			IsTerminal: func(*os.File) bool { return true },
		})
		return stdout.String(), stderr.String(), code
	}
	const humanNote = "設計は Issue の決定どおり。README だけ直してよい"
	if out, errOut, code := approve("--note", humanNote); code != ExitWaiting {
		t.Fatalf("approve with a note exit %d\n%s\n%s", code, out, errOut)
	}
	if got := noteOf(t, respondInputs(t, f, 5)); got != humanNote {
		t.Fatalf("note = %q, want %q", got, humanNote)
	}
	v := f.h.statusOf(id)
	if got, want := stepSeq(v), firstRound+" respond:needs_human respond:pushed quality:pass publish:updated ci:green"; got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}

	// review へ戻った後、もう一度 review-human へ行き、添え書きの無い approve でも拒否されず空文字が届く。
	if out, errOut, code := f.h.run("resume", id, "--input", "respond"); code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	if out, errOut, code := approve(); code != ExitWaiting {
		t.Fatalf("approve without a note exit %d\n%s\n%s", code, out, errOut)
	}
	if got := noteOf(t, respondInputs(t, f, 7)); got != "" {
		t.Fatalf("note = %q, want the empty string", got)
	}
	if v := f.h.statusOf(id); v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v steps %s", v.Waiting, stepSeq(v))
	}
}

// design-deviation の follow-decision（note: optional を書かない遷移）は、今と同じく --note が無ければ同じ文言で拒否される。
// 同梱の ticket.yaml の定義をそのまま読んで確かめる（review・review-human の任意の欄が他の遷移へ広がっていない）。
func TestTicketNoteIsOptionalOnlyOnRespond(t *testing.T) {
	wf := loadTicket(t)
	for _, c := range []struct {
		gate, input string
		optional    bool
	}{
		{"review", "respond", true},
		{"review-human", "respond", true},
		{"design-deviation", "follow-decision", false},
	} {
		tr := wf.Step(c.gate).OnFor(c.input)
		if tr == nil || tr.NoteOptional != c.optional {
			t.Errorf("%s.%s: transition %+v, want note optional %v", c.gate, c.input, tr, c.optional)
		}
	}
	for _, s := range wf.Steps {
		for _, o := range s.On {
			if o.T.NoteOptional && !(s.ID == "review" || s.ID == "review-human") {
				t.Errorf("steps.%s.on.%s declares note: optional", s.ID, o.Outcome)
			}
		}
	}
}

// 指示文（runtime/workflows/prompts/ticket-respond.md）が、添え書きを対応すべき指摘として扱うこと・PR にコメントが無くても
// no_change にしないこと・PR へ 1 件コメントすること・空なら PR のコメントだけを読むことを書いている。
func TestTicketRespondPromptHandlesTheNote(t *testing.T) {
	p := readFile(t, filepath.Join(repoWorkflows, "prompts", "ticket-respond.md"))
	for _, want := range []string{
		"`inputs.note` が空でなければ、PR のレビューコメントと同じく対応すべき指摘として扱う",
		"PR にレビューコメントが 1 件も無くても、`inputs.note` が空でなければ `no_change` にしない",
		"自分の PR へ 1 件のコメントとして残す",
		"`inputs.note` が空文字なら、今までどおり PR のレビューコメントだけを読む",
	} {
		if !strings.Contains(p, want) {
			t.Errorf("ticket-respond.md does not say %q", want)
		}
	}
}

func loadTicket(t *testing.T) *workflow.Workflow {
	t.Helper()
	wf, err := workflow.LoadAndValidate(filepath.Join(abs(t, repoWorkflows), "ticket.yaml"), workflow.Options{ScriptsDir: abs(t, repoScripts)})
	if err != nil {
		t.Fatal(err)
	}
	return wf
}

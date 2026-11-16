package engine

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// lastEdgeFrom は from から出た最後の遷移が渡した値（$edge の元）を返す。
func lastEdgeFrom(t *testing.T, e *Engine, from string) map[string]string {
	t.Helper()
	var last *runstate.Transition
	for _, ev := range events(t, e) {
		if ev.Transition != nil && ev.Transition.From == from {
			last = ev.Transition
		}
	}
	if last == nil {
		t.Fatalf("no transition from %s", from)
	}
	out := map[string]string{}
	for k, v := range last.Edge {
		out[k] = string(v)
	}
	return out
}

// 遷移の note: optional（#377）: 添え書きがあれば次の段へ渡し、無ければ拒否せず空文字を渡す。前の再開の添え書きは残らない。
// 欄を書かない遷移は今と同じく --note を必須にし、同じ文言で拒否する。
func TestOptionalGateNote(t *testing.T) {
	log := filepath.Join(t.TempDir(), "log")
	st, e := start(t, "gate-note", map[string]any{"log": log})
	if st.Status != runstate.StatusWaiting || st.Unit(MainUnit).Gate.Gate != "ask" {
		t.Fatalf("status = %s gate = %+v", st.Status, st.Unit(MainUnit).Gate)
	}
	lines := func() []string {
		data, _ := os.ReadFile(log)
		return strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	}

	// 添え書きつきの再開: 段の入力に添え書きが入る。
	mustResolve(t, e, Resolution{Input: "again", HasInput: true, Note: "address: the README is stale", HasNote: true})
	if got := lastEdgeFrom(t, e, "ask")["note"]; got != `"address: the README is stale"` {
		t.Fatalf("edge note = %s", got)
	}
	if l := lines(); l[len(l)-1] != "recorder --log "+log+" --note address: the README is stale" {
		t.Fatalf("the note did not reach the step: %q", l[len(l)-1])
	}

	// 添え書きの無い再開: 拒否されず、空文字を渡す（前の再開の添え書きは残らない）。
	st = mustResolve(t, e, Resolution{Input: "again", HasInput: true})
	if st.Status != runstate.StatusWaiting || st.Unit(MainUnit).Gate.Gate != "ask" {
		t.Fatalf("status = %s gate = %+v", st.Status, st.Unit(MainUnit).Gate)
	}
	if got := lastEdgeFrom(t, e, "ask")["note"]; got != `""` {
		t.Fatalf("edge note = %s, want the empty string", got)
	}
	if l := lines(); l[len(l)-1] != "recorder --log "+log+" --note " {
		t.Fatalf("the step did not receive the empty note: %q", l[len(l)-1])
	}

	// 欄を書かない遷移は --note を必須のまま（文言も同じ）。拒否は何も記録しない。
	before := len(events(t, e))
	_, err := resolve(t, e, Resolution{Input: "strict", HasInput: true})
	var ref *RefusedError
	if !errors.As(err, &ref) || err.Error() != "input strict passes $gate.note to the next step; give --note" {
		t.Fatalf("err = %v", err)
	}
	if n := len(events(t, e)); n != before {
		t.Fatalf("a refused resolution recorded %d events", n-before)
	}
	mustResolve(t, e, Resolution{Input: "strict", HasInput: true, Note: "strict note", HasNote: true})
	if got := lastEdgeFrom(t, e, "ask")["note"]; got != `"strict note"` {
		t.Fatalf("edge note = %s", got)
	}
}

package cli

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// wantVersionAction は版の不一致の requested_action（§5.6.1）: run の状態は waiting のまま、observe × human で、
// 何をすべきか（why）と、その後に contract status で確かめ直すことを案内する。理由は summary にも 1 回だけ入る。
func wantVersionAction(t *testing.T, what string, d contractDoc, why string) {
	t.Helper()
	a := d.RequestedAction
	if d.State != runstate.StatusWaiting || a == nil || a.Kind != "observe" || a.Decider != "human" ||
		!strings.Contains(a.Text, why) || !strings.Contains(a.Text, "harness contract status "+*d.RunID) {
		t.Errorf("%s: doc = %+v action = %+v", what, d, a)
	}
	if n := strings.Count(d.Summary, why); n != 1 {
		t.Errorf("%s: summary has the reason %d times: %q", what, n, d.Summary)
	}
}

// プラグイン版が範囲外なら、contract status も contract resume も、ゲートの操作の代わりに「人が更新してから確かめ直す」を
// 出す。human のゲート（approve）でも同じ。範囲内に戻れば元のゲートの操作に戻る。終わった run には出さない。
func TestContractPluginMismatchAsksAPersonToUpdate(t *testing.T) {
	for _, c := range []struct{ plugin, why string }{{"4.7.0", "update the plugin"}, {"5.1.0", "update the harness CLI"}} {
		for _, gate := range []string{"parent", "human"} {
			state := t.TempDir()
			h := newHarness(t, "HARNESS_STATE_DIR="+state, "HARNESS_DATA_DIR="+t.TempDir())
			start, _ := h.contract(gatesStart(t, gate)...)
			id := runIDOf(t, start)
			before := eventTypes(t, filepath.Join(state, "runs", id))
			bad := h.with(PluginVersionEnv + "=" + c.plugin)
			s, _ := bad.contract("status", id)
			wantVersionAction(t, c.plugin+" "+gate+" status", s, c.why)
			r, _ := bad.contract("resume", id, "--input", "go")
			wantVersionAction(t, c.plugin+" "+gate+" resume", r, c.why)
			if s.CostUSD == nil || *s.CostUSD != *start.CostUSD || len(s.Artifacts) != len(start.Artifacts) {
				t.Errorf("status changed cost or artifacts: %+v", s)
			}
			if after := eventTypes(t, filepath.Join(state, "runs", id)); after != before {
				t.Errorf("the refused resume recorded events:\n%s\n%s", before, after)
			}
			ok, _ := h.with(PluginVersionEnv+"=4.9.0").contract("status", id)
			if *ok.RequestedAction != *start.RequestedAction {
				t.Errorf("in range: action = %+v, want %+v", ok.RequestedAction, start.RequestedAction)
			}
		}
	}
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := runIDOf(t, first2(h.contract(gatesStart(t, "parent")...)))
	h.contract("resume", id, "--input", "go")
	if d, _ := h.with(PluginVersionEnv+"=4.7.0").contract("status", id); d.State != "succeeded" || d.RequestedAction != nil {
		t.Errorf("finished run = %+v", d)
	}
	// 版として読めないプラグイン版は版の不一致ではない（resume は ExitUsage）。status はゲートの操作のまま。
	if d, _ := h.with(PluginVersionEnv+"=latest").contract("status", runIDOf(t, first2(h.contract(gatesStart(t, "parent")...)))); d.RequestedAction.Kind != "answer" {
		t.Errorf("unparsable plugin version: %+v", d.RequestedAction)
	}
}

// N3: 開始時の版の定義を使えない CLI からは、status も resume も「開始時の版で resume するか cancel する」を人に求める。
// status の判定は何も書かない（消えた展開ディレクトリを作り直さない）。開始時と同じ版からは元のゲートの操作のまま。
func TestContractDefinitionsGoneAsksAPerson(t *testing.T) {
	f := newTicketFixture(t)
	v1 := f.h.with("HARNESS_TEST_CLI_VERSION=1.0.0")
	v2 := f.h.with("HARNESS_TEST_CLI_VERSION=2.0.0")
	out, errOut, code := v1.run("run", "--input", "issue=42", "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	id := decode[statusView](t, out).RunID
	old := filepath.Join(f.dataDir, "runtime", "1.0.0")
	if err := os.Rename(old, old+".moved"); err != nil {
		t.Fatal(err)
	}
	why := "resume run " + id + " with harness 1.0.0, or stop it with harness cancel " + id
	s, _ := v2.contract("status", id)
	wantVersionAction(t, "status", s, why)
	r, _ := v2.contract("resume", "--input", "recheck", id)
	wantVersionAction(t, "resume", r, why)
	same, _ := v1.contract("status", id)
	if a := same.RequestedAction; a == nil || a.Kind != "answer" || !strings.Contains(a.Text, "gate ci-pending") {
		t.Errorf("status by 1.0.0 = %+v", a)
	}
	if _, err := os.Stat(old); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("contract status re-extracted the definitions: %v", err)
	}
}

// statusBlock の単体: この CLI が読めないスキーマ版と、実行中の run。
func TestStatusBlockUnsupportedSchema(t *testing.T) {
	env := Env{Getenv: func(k string) string { return map[string]string{"HARNESS_DATA_DIR": t.TempDir()}[k] }}
	st := &runstate.State{RunID: "r1", Status: runstate.StatusWaiting, CLIVersion: "9.0.0", Embedded: true, Workflow: runstate.WorkflowRef{Schema: "harness.workflow/v9"}}
	if why := statusBlock(env, st, innerResult{}); !strings.Contains(why, "harness.workflow/v9") || !strings.Contains(why, "harness 9.0.0") {
		t.Errorf("why = %q", why)
	}
	// 実行中の run は runner が進めているので、status は操作を求めない。
	st.Status = runstate.StatusRunning
	if why := statusBlock(env, st, innerResult{}); why != "" {
		t.Errorf("running: why = %q, want none", why)
	}
	st.Status = runstate.StatusWaiting
	st.Workflow.Schema = "harness.workflow/v1"
	st.Embedded = false
	if why := statusBlock(env, st, innerResult{}); why != "" {
		t.Errorf("why = %q, want none", why)
	}
}

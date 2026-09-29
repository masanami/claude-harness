package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// contractRaw は harness contract <args> の JSON を、summary を除いたキーごとの生の値で返す（終了コード 0 を確かめる）。
func (h *harness) contractRaw(args ...string) map[string]json.RawMessage {
	h.t.Helper()
	out, errOut, code := h.run(append([]string{"contract"}, args...)...)
	if code != ExitOK {
		h.t.Fatalf("contract %v: exit %d, want 0\n%s\n%s", args, code, out, errOut)
	}
	raw := decode[map[string]json.RawMessage](h.t, out)
	delete(raw, "summary")
	return raw
}

// #283: 版の不一致で拒否された contract resume は、summary を読まなくても、ふつうに待っている run と機械的に
// 区別できなければならない。区別できないと、呼び出し元は requested_action に従って同じ resume を繰り返し、
// 同じ拒否に当たり続ける（版の不一致は CLI かプラグインを更新するまで解消しない）。
//
// ここでは出力の形（どのフィールドに何を出すか）を決めず、「summary 以外のどこかが違う」ことだけを確かめる。
func TestContractResumeRefusedByVersionIsDistinguishable(t *testing.T) {
	t.Run("plugin out of range", func(t *testing.T) {
		state := t.TempDir()
		h := newHarness(t, "HARNESS_STATE_DIR="+state, "HARNESS_DATA_DIR="+t.TempDir())
		id := runIDOf(t, first2(h.contract(gatesStart(t, "parent")...)))
		before := eventTypes(t, filepath.Join(state, "runs", id))
		waiting := h.contractRaw("status", id)
		refused := h.with(PluginVersionEnv+"=4.7.0").contractRaw("resume", id, "--input", "go")
		if after := eventTypes(t, filepath.Join(state, "runs", id)); after != before {
			t.Fatalf("a refused resume recorded events:\n%s\n%s", before, after)
		}
		if reflect.DeepEqual(waiting, refused) {
			t.Errorf("the refused resume looks the same as a waiting run apart from summary:\n%s", refused)
		}
	})

	t.Run("definitions of the starting version are gone", func(t *testing.T) {
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
		waiting := v2.contractRaw("status", id)
		refused := v2.contractRaw("resume", "--input", "recheck", id)
		if reflect.DeepEqual(waiting, refused) {
			t.Errorf("the refused resume looks the same as a waiting run apart from summary:\n%s", refused)
		}
	})
}

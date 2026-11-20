package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// --approved-ref・gate の detail・interrupted の印（S3-2）を、練習用のワークフロー gate-ref（engine/testdata/workflows）で確かめる。

const refBack = `json={"outcome":"back","detail":"the head moved: now abc123"}`

// startGateRef は gate-ref を同期の run で始め、review のゲートで待たせる。
func startGateRef(t *testing.T, h *harness) string {
	t.Helper()
	out, errOut, code := h.run(runArgs(t, "gate-ref", "log="+filepath.Join(t.TempDir(), "log"), refBack)...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	return decode[statusView](t, out).RunID
}

// contract resume --approved-ref の値は、ゲートの解決の記録に残り（status --json のゲートの履歴）、次の段へ届く。戻ったゲートの
// detail は、status --json の waiting[].detail・requested_action.text の先頭の文の後ろ・summary の末尾に出る。--note は求めない。
func TestContractResumeApprovedRefAndDetail(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := startGateRef(t, h)
	d, errOut := h.contract("resume", "--unit", "main", "--input", "land", "--approved-ref", "deadbeef", id)
	if d.State != runstate.StatusWaiting || d.RequestedAction == nil {
		t.Fatalf("doc = %+v\n%s", d, errOut)
	}
	const detail = "the head moved: now abc123"
	if want := "land (with the approved ref), respond or stop Detail: " + detail + " [gate review"; !strings.HasPrefix(d.RequestedAction.Text, want) {
		t.Fatalf("text = %q, want it to start with %q", d.RequestedAction.Text, want)
	}
	if !strings.HasSuffix(d.Summary, "; detail: "+detail) {
		t.Fatalf("summary = %q", d.Summary)
	}
	out, _, _ := h.run("status", "--json", id)
	v := decode[statusView](t, out)
	if len(v.Waiting) != 1 || v.Waiting[0].Detail != detail {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	if r := v.Units[0].Gates[0].Resolution; r == nil || r.ApprovedRef != "deadbeef" || r.Note != "" {
		t.Fatalf("resolution = %+v", r)
	}
	if !strings.Contains(out, `"approved_ref": "deadbeef"`) {
		t.Fatalf("status --json does not show approved_ref:\n%s", out)
	}
	// 書かない遷移で開き直せば、detail は無い。
	d, _ = h.contract("resume", "--unit", "main", "--input", "respond", "--approved-ref", "", id)
	if d.State != runstate.StatusWaiting || strings.Contains(d.RequestedAction.Text, "Detail:") || strings.Contains(d.Summary, "detail:") {
		t.Fatalf("doc = %+v", d)
	}
}

// resume も --approved-ref を受ける。approve は受けない（人の承認の道に通した中身の識別を足さない）。
func TestResumeTakesApprovedRefAndApproveDoesNot(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := startGateRef(t, h)
	out, errOut, code := h.run("resume", "--input", "land", "--approved-ref", "deadbeef", id)
	if code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	if r := decode[statusView](t, out).Units[0].Gates[0].Resolution; r.ApprovedRef != "deadbeef" {
		t.Fatalf("resolution = %+v", r)
	}
	_, errOut, code = h.run("approve", "--input", "land", "--approved-ref", "deadbeef", id)
	if code != ExitUsage || !strings.Contains(errOut, "approve takes no --approved-ref") {
		t.Fatalf("approve exit %d\n%s", code, errOut)
	}
}

// runner を起動できないようにする（runner.log を開けなくする）。
func breakRunnerLog(t *testing.T, h *harness, id string) {
	t.Helper()
	if err := os.Mkdir(filepath.Join(h.stateDir(), "runs", id, runstate.RunnerLogFile), 0o755); err != nil {
		t.Fatal(err)
	}
}

func (h *harness) stateDir() string {
	for _, kv := range h.env {
		if v, ok := strings.CutPrefix(kv, "HARNESS_STATE_DIR="); ok {
			return v
		}
	}
	h.t.Fatal("no HARNESS_STATE_DIR")
	return ""
}

// 印（interrupted）のあるラウンドで runner を起動できなかった contract resume は、runner の居ない running のまま返さず、
// その場で印の理由の failed を返す。印の無いラウンドは、いまと同じに running のまま返す。
func TestContractResumeThatCannotStartARunner(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id := startGateRef(t, h)
	breakRunnerLog(t, h, id)
	d, _ := h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", "deadbeef", id)
	if d.State != runstate.StatusFailed || !strings.Contains(d.Summary, "interrupted_after_land") || d.RequestedAction != nil {
		t.Fatalf("a marked round: doc = %+v", d)
	}
	// 失敗で終えた後の resume は、終わりの状態を返す（2 度入れない）。
	d, _ = h.contractNow("resume", "--unit", "main", "--input", "land", "--approved-ref", "deadbeef", id)
	if d.State != runstate.StatusFailed {
		t.Fatalf("after the end: doc = %+v", d)
	}

	h = newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id = startGateRef(t, h)
	breakRunnerLog(t, h, id)
	d, _ = h.contractNow("resume", "--unit", "main", "--input", "respond", id)
	if d.State != runstate.StatusRunning {
		t.Fatalf("an unmarked round: doc = %+v", d)
	}
}

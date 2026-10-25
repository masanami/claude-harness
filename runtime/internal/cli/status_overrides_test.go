package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// status --json に上書きの記録を出す（docs/harness-runtime-overrides.md §7.1。#314）: workflow の下の overrides・changes・
// skipped_steps。上書きの無い run と上書きを記録する前の版で始めた run は空の配列で読め、接続契約 v1 の contract status は
// 変わらない（§8・O3）。

// statusWorkflow は status --json の workflow を生の JSON のまま返す。
func statusWorkflow(t *testing.T, h *harness, runID string) map[string]json.RawMessage {
	t.Helper()
	out, errOut, code := h.run("status", runID, "--json")
	if code != ExitOK {
		t.Fatalf("status exit %d\n%s\n%s", code, out, errOut)
	}
	// workflow は従来どおり run_id の次に 1 回だけ出る（既存のフィールドの位置を変えない）。
	if keys := topKeys(t, out); len(keys) < 2 || keys[0] != "run_id" || keys[1] != "workflow" || strings.Count(","+strings.Join(keys, ",")+",", ",workflow,") != 1 {
		t.Fatalf("status --json top-level keys = %v, want run_id, workflow, ...", keys)
	}
	top := decode[map[string]json.RawMessage](t, out)
	return decode[map[string]json.RawMessage](t, string(top["workflow"]))
}

// topKeys は JSON オブジェクトの最上位のキーを出現順に返す。
func topKeys(t *testing.T, s string) []string {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(s))
	if _, err := dec.Token(); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for dec.More() {
		k, err := dec.Token()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, k.(string))
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			t.Fatal(err)
		}
	}
	return keys
}

func sortedKeys[V any](m map[string]V) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return strings.Join(keys, ",")
}

// statusWorkflowKeys は status --json の workflow が持つキー（過不足なし）。
const statusWorkflowKeys = "changes,hash,id,overrides,path,schema,skipped_steps"

// 上書きで走った run の status --json に overrides・changes・skipped_steps が出て、run_started の記録と同じ値になる。
// contract status は契約 v1 の形のまま、上書きの記録を出さない。
func TestStatusShowsOverrides(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "rte.yaml"), routeWorkflow)
	cwd, repo := overrideRepo(t, "rte", "schema: harness.workflow-override/v1\nworkflow: rte\nlimits: { rework: 2 }\n")
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), routeOverride)
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	h.cwd = cwd
	out, errOut, code := h.run("run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", arg, "rte")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	rec := runStarted(t, v.RunDir).Workflow

	w := statusWorkflow(t, h, v.RunID)
	if got := sortedKeys(w); got != statusWorkflowKeys {
		t.Fatalf("status --json workflow keys = %s, want %s", got, statusWorkflowKeys)
	}
	wantOverrides, _ := json.Marshal(rec.Overrides)
	if len(rec.Overrides) != 2 || rec.Overrides[0].Path != repo || rec.Overrides[1].Path != arg {
		t.Fatalf("run_started.workflow.overrides = %s", wantOverrides)
	}
	if got := compact(t, w["overrides"]); got != string(wantOverrides) {
		t.Fatalf("status --json workflow.overrides = %s\nwant %s", got, wantOverrides)
	}
	if want := `[{"key":"limits.rework","from":1,"to":2,"layer":"repo"},{"key":"steps.first.on.ok","from":"extra","to":"ask","layer":"arg"}]`; compact(t, w["changes"]) != want {
		t.Fatalf("status --json workflow.changes = %s\nwant %s", w["changes"], want)
	}
	if got := compact(t, w["skipped_steps"]); got != `["extra"]` {
		t.Fatalf("status --json workflow.skipped_steps = %s, want [\"extra\"]", got)
	}
	if got := compact(t, w["hash"]); got != `"`+rec.Hash+`"` {
		t.Fatalf("status --json workflow.hash = %s, want the hash of the original definition %s", got, rec.Hash)
	}

	// 同じ run の contract status は契約 v1 のキーだけを持ち、上書きの記録はどこにも出ない。
	d, _ := h.contract("status", v.RunID)
	raw, _ := json.Marshal(d)
	for _, k := range []string{"overrides", "changes", "skipped_steps", "effective_hash", arg, repo} {
		if strings.Contains(string(raw), k) {
			t.Fatalf("contract status leaks %s: %s", k, raw)
		}
	}
	if d.State != "waiting" || d.RequestedAction == nil || d.Summary != "workflow rte: waiting at gate ask (unit main)" {
		t.Fatalf("contract status = %s", raw)
	}
}

// 上書きの無い run と、上書きを記録する前の版（run_started の workflow に overrides 等のキーが無く、cli_version・embedded
// も無い）で始めた run の status --json は従来どおり読め、3 つは空の配列で出る。
func TestStatusWithoutOverrides(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, errOut, code := h.run(runArgs(t, "gates", `json={"outcome":"any"}`, "log=x", "state=x")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s", code, errOut)
	}
	v := decode[statusView](t, out)
	checkEmpty := func(label string) {
		t.Helper()
		out, errOut, code := h.run("status", v.RunID, "--json")
		if code != ExitOK {
			t.Fatalf("%s: status exit %d\n%s\n%s", label, code, out, errOut)
		}
		// 従来の読み方（statusView への読み込み）で読める。
		if sv := decode[statusView](t, out); sv.State == nil || sv.Workflow.ID != "gates" || sv.Workflow.Hash != v.Workflow.Hash || sv.Status != "waiting" {
			t.Fatalf("%s: status --json = %s", label, out)
		}
		w := statusWorkflow(t, h, v.RunID)
		if got := sortedKeys(w); got != statusWorkflowKeys {
			t.Fatalf("%s: status --json workflow keys = %s, want %s", label, got, statusWorkflowKeys)
		}
		for _, k := range []string{"overrides", "changes", "skipped_steps"} {
			if got := compact(t, w[k]); got != "[]" {
				t.Fatalf("%s: status --json workflow.%s = %s, want []", label, k, got)
			}
		}
	}
	checkEmpty("without overrides")

	// 上書きを記録する前の版の run_started に書き換える（events.jsonl の 1 行目から段 1 以降のキーを除く）。
	path := filepath.Join(v.RunDir, "events.jsonl")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	first, rest, _ := strings.Cut(string(b), "\n")
	head := decode[map[string]json.RawMessage](t, first)
	rs := decode[map[string]json.RawMessage](t, string(head["run_started"]))
	delete(rs, "cli_version")
	delete(rs, "embedded")
	wf := decode[map[string]json.RawMessage](t, string(rs["workflow"]))
	if got := sortedKeys(wf); got != "hash,id,path,schema" {
		t.Fatalf("run_started.workflow of a run without overrides has keys %s", got)
	}
	head["run_started"], _ = json.Marshal(rs)
	line, _ := json.Marshal(head)
	if err := os.WriteFile(path, []byte(string(line)+"\n"+rest), 0o644); err != nil {
		t.Fatal(err)
	}
	checkEmpty("started before overrides were recorded")
}

func compact(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	var b bytes.Buffer
	if err := json.Compact(&b, raw); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, raw)
	}
	return b.String()
}

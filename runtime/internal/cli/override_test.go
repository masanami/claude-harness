package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// ワークフロー定義の上書き（docs/harness-runtime-overrides.md・#312）の CLI の面: run・contract start・validate の
// --override、リポジトリの .claude-harness/overrides/、run の記録と resume での組み立て直し。

// overrideWorkflow は上書きを確かめる定義: emit → ask（input × any のゲート）→ sleep（60 秒眠る。timeout 2m）。
// 上書きで sleep の timeout を 1s にすると、resume の後に step_timeout で timed_out になる（上書きが効かなければ
// 60 秒後に finished になる）。
const overrideWorkflow = `schema: harness.workflow/v1
id: ovr
inputs:
  pidfile: { type: string, required: true }
limits:
  budget_usd: 5
  rework: 1
steps:
  first:
    kind: command
    run: emit
    with: { json: "{}" }
    exit: { 0: ok }
    timeout: 1m
    on: { ok: { gate: ask } }
  ask:
    kind: gate
    type: input
    decider: any
    requested_action: say go
    inputs: [go]
    on: { go: sleep }
  sleep:
    kind: command
    run: sleeper
    with: { pidfile: $inputs.pidfile }
    exit: { 0: finished }
    timeout: 2m
    on:
      finished: { done: finished }
      step_timeout: { done: timed_out }
`

const overrideFile = `schema: harness.workflow-override/v1
workflow: ovr
limits: { rework: 2 }
steps:
  sleep: { timeout: 1s }
`

func writeFile(t *testing.T, path, body string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func sha(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// runStarted は run の events.jsonl の run_started を返す。
func runStarted(t *testing.T, runDir string) *runstate.RunStarted {
	t.Helper()
	evs, _, err := runstate.ReadEvents(filepath.Join(runDir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	return evs[0].RunStarted
}

// overrideRepo は git の作業ツリーを模した cwd（.git を持つ）と、そこに置いた層 1 の上書きを作る。
func overrideRepo(t *testing.T, id, body string) (cwd, path string) {
	t.Helper()
	// 作業ディレクトリは実体のパスで返る（macOS の /var → /private/var）ので、期待するパスも実体に揃える。
	cwd, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(cwd, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(cwd, "sub", "dir") // 作業ディレクトリが最上位でなくても、git の最上位の置き場を読む
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	return sub, writeFile(t, filepath.Join(cwd, RepoOverrideDir, id+".yaml"), body)
}

// §9 の S/M/L の上書きで ticket の validate が通り、効いた値が changes に出る（完了条件 4）。
func TestValidateOverrideSizeExamples(t *testing.T) {
	cases := []struct {
		file  string
		lines []string
	}{
		{"s.yaml", []string{"limits.budget_usd: 40 -> 30 (arg)"}},
		{"m.yaml", []string{"limits.budget_usd: 40 -> 50 (arg)", "steps.implement.budget_usd: 15 -> 30 (arg)"}},
		{"l.yaml", []string{"limits.budget_usd: 40 -> 100 (arg)", "steps.implement.budget_usd: 15 -> 60 (arg)"}},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			h := newHarness(t)
			ov := abs(t, filepath.Join("testdata", "overrides", c.file))
			out, errOut, code := h.run("validate", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--override", ov, "ticket")
			if code != ExitOK {
				t.Fatalf("validate exit %d\n%s\n%s", code, out, errOut)
			}
			want := "ok " + filepath.Join(abs(t, repoWorkflows), "ticket.yaml") + "\n  override arg " + ov + "\n  changes:\n"
			for _, l := range c.lines {
				want += "    " + l + "\n"
			}
			if !strings.Contains(out, want) {
				t.Fatalf("validate output lacks\n%s\ngot\n%s", want, out)
			}
		})
	}
}

// リポジトリの層と引数の層をキーごとに重ね、どの層のどのキーが効いたかを changes に出す（§3・完了条件 3）。
func TestValidateOverrideLayers(t *testing.T) {
	cwd, repo := overrideRepo(t, "ticket", "schema: harness.workflow-override/v1\nworkflow: ticket\nlimits: { budget_usd: 60 }\nsteps: { implement: { budget_usd: 20 } }\n")
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), "schema: harness.workflow-override/v1\nworkflow: ticket\nsteps: { implement: { budget_usd: 30 }, resolve: { timeout: 5m } }\n")
	h := newHarness(t)
	h.cwd = cwd
	out, errOut, code := h.run("validate", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--override", arg)
	if code != ExitOK {
		t.Fatalf("validate exit %d\n%s\n%s", code, out, errOut)
	}
	want := "  override repo " + repo + "\n  override arg " + arg + "\n  changes:\n" +
		"    limits.budget_usd: 40 -> 60 (repo)\n" +
		"    steps.resolve.timeout: 2m0s -> 5m0s (arg)\n" +
		"    steps.implement.budget_usd: 15 -> 30 (arg)\n"
	if !strings.Contains(out, want) {
		t.Fatalf("validate output lacks\n%s\ngot\n%s", want, out)
	}
	// 上書きの無い定義（list-tests 等）には何も出さない。
	if strings.Count(out, "changes:") != 1 || !strings.Contains(out, "total=3 passed=3 failed=0") {
		t.Fatalf("validate output = %s", out)
	}
}

// 閉じたキー・元の定義に無い名前・型の違う値は validate が拒否する（§5.3）。どのファイルの何行目かを示す。
func TestValidateOverrideRejectsClosedKeys(t *testing.T) {
	arg := writeFile(t, filepath.Join(t.TempDir(), "bad.yaml"), "schema: harness.workflow-override/v1\nworkflow: ticket\nsteps:\n  human-merge: { decider: any }\n  implement: { prompt: other.md }\n")
	h := newHarness(t)
	out, errOut, code := h.run("validate", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--override", arg, "ticket")
	if code != ExitFailed {
		t.Fatalf("validate exit %d\n%s\n%s", code, out, errOut)
	}
	for _, want := range []string{
		arg + ":4: steps.human-merge.decider cannot be overridden",
		arg + ":5: steps.implement.prompt cannot be overridden",
	} {
		if !strings.Contains(errOut, want) {
			t.Fatalf("stderr lacks %q:\n%s", want, errOut)
		}
	}
	if strings.Contains(out, "ok ") {
		t.Fatalf("a rejected override must not be reported ok: %s", out)
	}
}

// --override は 1 つだけ。検査する定義に無い workflow を指す上書き・無いファイルは使い方の誤り。
func TestOverrideArgumentErrors(t *testing.T) {
	h := newHarness(t)
	ov := abs(t, filepath.Join("testdata", "overrides", "l.yaml"))
	base := []string{"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts)}
	cases := []struct {
		args []string
		want string
	}{
		{append(append([]string{"validate"}, base...), "--override", ov, "list-tests"), `is for workflow "ticket", which is not among the workflows to validate`},
		{append(append([]string{"validate"}, base...), "--override", ov, "--override", ov, "ticket"), "option --override given twice"},
		{append(append([]string{"validate"}, base...), "--override", filepath.Join(t.TempDir(), "none.yaml"), "ticket"), "--override:"},
		{append(append([]string{"run"}, base...), "--override", filepath.Join(t.TempDir(), "none.yaml"), "ticket"), "--override:"},
		{append(append([]string{"run"}, base...), "--override", ov, "--override", ov, "ticket"), "option --override given twice"},
	}
	for _, c := range cases {
		_, errOut, code := h.run(c.args...)
		if code != ExitUsage || !strings.Contains(errOut, c.want) {
			t.Fatalf("%v: exit %d\n%s", c.args, code, errOut)
		}
	}
}

// run は元の定義のハッシュを変えずに、上書きの写し・出どころ・効いた値・上書き後の定義のハッシュを記録する。
// resume は元の上書きのファイルではなく写しで定義を組み立て直す（§7・完了条件 1・2）。
func TestRunRecordsOverridesAndResumeUsesTheCopies(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	wfPath := writeFile(t, filepath.Join(wd, "ovr.yaml"), overrideWorkflow)
	cwd, repo := overrideRepo(t, "ovr", "schema: harness.workflow-override/v1\nworkflow: ovr\nlimits: { budget_usd: 7, rework: 5 }\n")
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), overrideFile)
	argSHA, repoSHA := sha(t, arg), sha(t, repo)
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	h.cwd = cwd

	out, errOut, code := h.run("run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", arg,
		"--input", "pidfile="+filepath.Join(t.TempDir(), "pid"), "ovr")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	rs := runStarted(t, v.RunDir)
	w := rs.Workflow
	if w.Hash != sha(t, wfPath) || w.Path != wfPath {
		t.Fatalf("workflow.hash must stay the hash of the original definition: %+v", w.WorkflowRef)
	}
	if len(w.Overrides) != 2 ||
		w.Overrides[0] != (runstate.OverrideRef{Layer: "repo", Path: repo, SHA256: repoSHA, Copy: "overrides/1-repo.yaml"}) ||
		w.Overrides[1] != (runstate.OverrideRef{Layer: "arg", Path: arg, SHA256: argSHA, Copy: "overrides/2-arg.yaml"}) {
		t.Fatalf("overrides = %+v", w.Overrides)
	}
	for _, o := range w.Overrides {
		if got := sha(t, filepath.Join(v.RunDir, o.Copy)); got != o.SHA256 {
			t.Fatalf("copy %s sha256 = %s, want %s", o.Copy, got, o.SHA256)
		}
	}
	if w.EffectiveHash == "" || w.EffectiveHash == w.Hash {
		t.Fatalf("effective_hash = %q", w.EffectiveHash)
	}
	changes, _ := json.Marshal(w.Changes)
	if want := `[{"key":"limits.budget_usd","from":5,"to":7,"layer":"repo"},{"key":"limits.rework","from":1,"to":2,"layer":"arg"},{"key":"steps.sleep.timeout","from":"2m0s","to":"1s","layer":"arg"}]`; string(changes) != want {
		t.Fatalf("changes = %s\nwant      %s", changes, want)
	}
	// limits の効いた値は run_started.limits と unit の予算にも入る。
	if rs.Limits["budget_usd"] != 7 || rs.Limits["rework"] != 2 || v.State.Units[0].Budget.LimitUSD != 7 {
		t.Fatalf("limits = %v budget = %+v", rs.Limits, v.State.Units[0].Budget)
	}

	// 開始後に元の上書きを書き換え・消しても、resume は写しで組み立て直す（timeout 1s が効いて timed_out になる）。
	writeFile(t, arg, "schema: harness.workflow-override/v1\nworkflow: ovr\nsteps: { sleep: { timeout: 1h } }\n")
	if err := os.Remove(repo); err != nil {
		t.Fatal(err)
	}
	out, errOut, code = h.run("resume", v.RunID, "--input", "go")
	if code != ExitOK {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	if st := decode[runstate.State](t, out); st.Reason != "timed_out" {
		t.Fatalf("resume must rebuild the definition from the copies (timeout 1s): reason %q", st.Reason)
	}
}

// 写しを書き換えた run は resume で止まる。重ね方・正規化が開始時と違う（effective_hash が食い違う）run は、
// 版の不一致（exit 5）として開始時の版での resume か cancel を案内する（§7.2）。
func TestResumeRefusesChangedOverrides(t *testing.T) {
	start := func(t *testing.T) (*harness, statusView) {
		state := t.TempDir()
		wd := t.TempDir()
		writeFile(t, filepath.Join(wd, "ovr.yaml"), overrideWorkflow)
		arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), overrideFile)
		h := newHarness(t, "HARNESS_STATE_DIR="+state)
		out, errOut, code := h.run("run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", arg,
			"--input", "pidfile="+filepath.Join(t.TempDir(), "pid"), "ovr")
		if code != ExitWaiting {
			t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
		}
		return h, decode[statusView](t, out)
	}

	t.Run("copy changed", func(t *testing.T) {
		h, v := start(t)
		writeFile(t, filepath.Join(v.RunDir, "overrides", "2-arg.yaml"), "schema: harness.workflow-override/v1\nworkflow: ovr\n")
		before := eventTypes(t, v.RunDir)
		_, errOut, code := h.run("resume", v.RunID, "--input", "go")
		if code != ExitFailed || !strings.Contains(errOut, "changed since the run started") {
			t.Fatalf("resume exit %d\n%s", code, errOut)
		}
		if after := eventTypes(t, v.RunDir); after != before {
			t.Fatalf("a refused resume recorded events:\n%s\n%s", before, after)
		}
	})

	t.Run("effective hash differs", func(t *testing.T) {
		h, v := start(t)
		events := filepath.Join(v.RunDir, runstate.EventsFile)
		b, err := os.ReadFile(events)
		if err != nil {
			t.Fatal(err)
		}
		recorded := runStarted(t, v.RunDir).Workflow.EffectiveHash
		other := strings.Repeat("0", len(recorded))
		if err := os.WriteFile(events, []byte(strings.Replace(string(b), recorded, other, 1)), 0o644); err != nil {
			t.Fatal(err)
		}
		out, errOut, code := h.run("resume", v.RunID, "--input", "go")
		if code != ExitVersion || !strings.Contains(errOut, "does not build the same") || !strings.Contains(errOut, "harness cancel "+v.RunID) {
			t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
		}
	})
}

// contract start も --override を受け付ける。契約 v1 の出力の形は変えない（O3）。
func TestContractStartAcceptsOverride(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "ovr.yaml"), overrideWorkflow)
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), overrideFile)
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, errOut, code := h.run("contract", "start", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", arg,
		"--input", "pidfile="+filepath.Join(t.TempDir(), "pid"), "ovr")
	if code != ExitOK {
		t.Fatalf("contract start exit %d\n%s\n%s", code, out, errOut)
	}
	doc := decode[map[string]any](t, out)
	var keys []string
	for k := range doc {
		keys = append(keys, k)
	}
	if len(keys) != 7 || doc["state"] != "waiting" || doc["run_id"] == nil {
		t.Fatalf("contract start = %s", out)
	}
	rs := runStarted(t, filepath.Join(state, "runs", doc["run_id"].(string)))
	if len(rs.Workflow.Overrides) != 1 || rs.Workflow.Overrides[0].Layer != "arg" || rs.Limits["rework"] != 2 {
		t.Fatalf("run_started.workflow = %+v limits = %v", rs.Workflow, rs.Limits)
	}

	// 定義に合わない上書きでは run を始めない（run_id は null）。
	bad := writeFile(t, filepath.Join(t.TempDir(), "bad.yaml"), "schema: harness.workflow-override/v1\nworkflow: ovr\nsteps: { ask: { decider: human } }\n")
	out, _, code = h.run("contract", "start", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", bad,
		"--input", "pidfile=x", "ovr")
	doc = decode[map[string]any](t, out)
	if code != ExitOK || doc["run_id"] != nil || doc["state"] != "failed" || !strings.Contains(doc["summary"].(string), "workflow is not valid") {
		t.Fatalf("contract start with a closed key: exit %d\n%s", code, out)
	}
}

// 上書きの無い run の記録は従来と同じ形（overrides・effective_hash・changes を出さない）。
func TestRunWithoutOverridesKeepsTheRecord(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, errOut, code := h.run(runArgs(t, "gates", `json={"outcome":"any"}`, "log=x", "state=x")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s", code, errOut)
	}
	v := decode[statusView](t, out)
	b, err := os.ReadFile(filepath.Join(v.RunDir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	first := strings.SplitN(string(b), "\n", 2)[0]
	for _, k := range []string{`"overrides"`, `"effective_hash"`, `"changes"`} {
		if strings.Contains(first, k) {
			t.Fatalf("run_started of a run without overrides has %s: %s", k, first)
		}
	}
	if _, err := os.Stat(filepath.Join(v.RunDir, runstate.OverridesDir)); !os.IsNotExist(err) {
		t.Fatalf("overrides/ must not be created without overrides: %v", err)
	}
}

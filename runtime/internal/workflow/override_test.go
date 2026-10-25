package workflow

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// 上書き（docs/harness-runtime-overrides.md・#312）の読み込み・重ね方・閉じたキーの拒否・上書き後の定義のハッシュ。
// 元の定義は同梱の ticket.yaml（limits.budget_usd 40・rework 3、implement の budget_usd 15、resolve の timeout 2m）。

const ticketPath = "../../workflows/ticket.yaml"

func loadTicket(t *testing.T, srcs ...OverrideSource) (*Workflow, error) {
	t.Helper()
	RegisterObservation("pr-state", []string{"merged", "open", "closed"}) // 実体は engine が登録する
	RegisterObservationInputs("pr-state", "pr")
	return LoadWithOverrides(ticketPath, Options{ScriptsDir: "../../../plugin/scripts"}, srcs)
}

func ov(layer, body string) OverrideSource {
	return OverrideSource{Layer: layer, Path: "/ov/" + layer + ".yaml", Data: []byte("schema: harness.workflow-override/v1\nworkflow: ticket\n" + body)}
}

func changesJSON(t *testing.T, cs []Change) string {
	t.Helper()
	b, err := json.Marshal(cs)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// 上書きが無ければ元の定義そのもの（上書きの記録を持たない）。
func TestLoadWithoutOverrides(t *testing.T) {
	wf, err := loadTicket(t)
	if err != nil {
		t.Fatal(err)
	}
	if wf.Overrides != nil || wf.Changes != nil || wf.EffectiveHash != "" || wf.Limit("budget_usd").Value != 40 {
		t.Fatalf("wf = %+v", wf)
	}
}

// 数値のキー（§5.1）は効いた値で定義を組み立て、Hash は元の定義のまま変えない（§7.1）。
func TestOverrideNumbers(t *testing.T) {
	orig, err := loadTicket(t)
	if err != nil {
		t.Fatal(err)
	}
	wf, err := loadTicket(t, ov(LayerArg, "limits: { budget_usd: 100, rework: 1 }\nsteps:\n  implement: { budget_usd: 60, timeout: 3h }\n  resolve: { timeout: 90s }\n"))
	if err != nil {
		t.Fatal(err)
	}
	if wf.Hash != orig.Hash {
		t.Fatalf("Hash = %s, want the original %s", wf.Hash, orig.Hash)
	}
	if wf.Limit("budget_usd").Value != 100 || wf.Limit("rework").Value != 1 || !wf.Limit("rework").Integer {
		t.Fatalf("limits = %+v %+v", wf.Limit("budget_usd"), wf.Limit("rework"))
	}
	if s := wf.Step("implement"); s.BudgetUSD != 60 || s.Timeout != 3*time.Hour {
		t.Fatalf("implement = %v %v", s.BudgetUSD, s.Timeout)
	}
	if s := wf.Step("resolve"); s.Timeout != 90*time.Second {
		t.Fatalf("resolve timeout = %v", s.Timeout)
	}
	// 書いていないキーは元の定義のまま。
	if s := wf.Step("analyze"); s.BudgetUSD != 2 || s.Timeout != 20*time.Minute {
		t.Fatalf("analyze = %v %v", s.BudgetUSD, s.Timeout)
	}
	want := `[{"key":"limits.budget_usd","from":40,"to":100,"layer":"arg"},{"key":"limits.rework","from":3,"to":1,"layer":"arg"},` +
		`{"key":"steps.resolve.timeout","from":"2m0s","to":"1m30s","layer":"arg"},` +
		`{"key":"steps.implement.budget_usd","from":15,"to":60,"layer":"arg"},{"key":"steps.implement.timeout","from":"1h30m0s","to":"3h0m0s","layer":"arg"}]`
	if got := changesJSON(t, wf.Changes); got != want {
		t.Fatalf("changes = %s\nwant      %s", got, want)
	}
	if len(wf.Overrides) != 1 || wf.Overrides[0].Layer != LayerArg || len(wf.Overrides[0].SHA256) != 64 {
		t.Fatalf("overrides = %+v", wf.Overrides)
	}
}

// キーごとに後ろの層が勝つ。片方の層だけが書いたキーはその層の値が効く（§3）。
func TestOverrideLayersKeyByKey(t *testing.T) {
	wf, err := loadTicket(t,
		ov(LayerRepo, "limits: { budget_usd: 60 }\nsteps: { implement: { budget_usd: 20 } }\n"),
		ov(LayerArg, "steps: { implement: { budget_usd: 30 } }\n"))
	if err != nil {
		t.Fatal(err)
	}
	if wf.Limit("budget_usd").Value != 60 || wf.Step("implement").BudgetUSD != 30 {
		t.Fatalf("budget = %v implement = %v", wf.Limit("budget_usd").Value, wf.Step("implement").BudgetUSD)
	}
	want := `[{"key":"limits.budget_usd","from":40,"to":60,"layer":"repo"},{"key":"steps.implement.budget_usd","from":15,"to":30,"layer":"arg"}]`
	if got := changesJSON(t, wf.Changes); got != want {
		t.Fatalf("changes = %s\nwant      %s", got, want)
	}
	if len(wf.Overrides) != 2 || wf.Overrides[0].Layer != LayerRepo || wf.Overrides[1].Layer != LayerArg {
		t.Fatalf("overrides must keep the layer order: %+v", wf.Overrides)
	}
}

// 開いたキー以外・元の定義に無い名前・型の違う値は拒否する（§4.1・§5.3）。
func TestOverrideRejects(t *testing.T) {
	cases := []struct {
		name, body, want string
	}{
		{"prompt", "steps: { implement: { prompt: other.md } }\n", "steps.implement.prompt cannot be overridden"},
		{"agent", "steps: { implement: { agent: claude-harness:other } }\n", "steps.implement.agent cannot be overridden"},
		{"decider", "steps: { review: { decider: human } }\n", "steps.review.decider cannot be overridden"},
		{"on", "steps: { ci: { on: { green: merge-route } } }\n", "steps.ci.on.green cannot be overridden"},
		{"kind", "steps: { analyze: { kind: command } }\n", "steps.analyze.kind cannot be overridden"},
		{"with", "steps: { analyze: { with: { issue: 1 } } }\n", "steps.analyze.with cannot be overridden"},
		{"id", "id: other\n", `key "id" cannot be overridden`},
		{"inputs", "inputs: { x: { type: string } }\n", `key "inputs" cannot be overridden`},
		{"overridable", "overridable: { routes: {} }\n", `key "overridable" cannot be overridden`},
		{"unknown top", "budget: 3\n", `unknown key "budget"`},
		{"unknown step key", "steps: { analyze: { budget: 3 } }\n", `unknown key "budget"`},
		{"expression", "when: x\n", "condition/expression"},
		{"new step", "steps: { ghost: { timeout: 1m } }\n", "steps.ghost: workflow ticket has no such step"},
		{"new limit", "limits: { retries: 2 }\n", "limits.retries: workflow ticket has no such limit"},
		{"budget on command", "steps: { resolve: { budget_usd: 3 } }\n", "steps.resolve.budget_usd: a command step has no budget_usd"},
		{"timeout on gate", "steps: { review: { timeout: 1m } }\n", "steps.review.timeout: a gate step has no timeout"},
		{"timeout on workspace", "steps: { workspace: { timeout: 1m } }\n", "steps.workspace.timeout: a workspace step has no timeout"},
		{"integer limit", "limits: { rework: 2.5 }\n", "limits.rework must be an integer"},
		{"negative limit", "limits: { rework: -1 }\n", "limits.rework must be a non-negative number"},
		{"zero budget", "limits: { budget_usd: 0 }\n", "limits.budget_usd must be a positive amount"},
		{"string limit", "limits: { budget_usd: \"100\" }\n", "limits.budget_usd must be a number literal"},
		{"zero step budget", "steps: { implement: { budget_usd: 0 } }\n", "steps.implement.budget_usd must be a positive amount"},
		{"bad timeout", "steps: { implement: { timeout: soon } }\n", "steps.implement.timeout must be a positive duration"},
		{"reference", "steps: { implement: { timeout: $inputs.issue } }\n", "is a reference"},
		{"alias", "limits: { budget_usd: &a 3 }\n", "YAML anchors"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadTicket(t, ov(LayerArg, c.body))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
			if !strings.Contains(err.Error(), "/ov/arg.yaml:") {
				t.Fatalf("the problem must point at the override file: %v", err)
			}
		})
	}
}

// 上書きの見出し（schema・workflow）の検査。
func TestOverrideHeader(t *testing.T) {
	cases := []struct {
		name, data, want string
	}{
		{"no schema", "workflow: ticket\n", "schema is required (harness.workflow-override/v1)"},
		{"workflow schema", "schema: harness.workflow/v1\nworkflow: ticket\n", `unsupported schema "harness.workflow/v1"`},
		{"no workflow", "schema: harness.workflow-override/v1\n", "workflow is required"},
		{"other workflow", "schema: harness.workflow-override/v1\nworkflow: list-tests\n", `workflow "list-tests" does not match the workflow being overridden ("ticket")`},
		{"two documents", "schema: harness.workflow-override/v1\nworkflow: ticket\n---\nx: 1\n", "exactly one YAML document"},
		{"not a mapping", "- 1\n", "override must be a mapping"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadTicket(t, OverrideSource{Layer: LayerArg, Path: "/ov/x.yaml", Data: []byte(c.data)})
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
	// 見出しだけの上書きは何も変えない（changes は空）。
	wf, err := loadTicket(t, ov(LayerArg, ""))
	if err != nil || len(wf.Changes) != 0 || len(wf.Overrides) != 1 {
		t.Fatalf("header-only override: %v %+v", err, wf)
	}
}

// OverrideTarget は validate が上書きを重ねる定義を選ぶための workflow の値を返す。
func TestOverrideTarget(t *testing.T) {
	if id, err := OverrideTarget("/x.yaml", []byte("schema: harness.workflow-override/v1\nworkflow: ticket\n")); err != nil || id != "ticket" {
		t.Fatalf("id = %q err = %v", id, err)
	}
	if _, err := OverrideTarget("/x.yaml", []byte("schema: harness.workflow-override/v1\n")); err == nil || !strings.Contains(err.Error(), "workflow is required") {
		t.Fatalf("err = %v", err)
	}
}

// 上書き後の定義のハッシュ（§12）は効いた値で決まり、上書きのファイルの書式・コメント・数の書き方・どの層が書いたかに
// 依らない。効いた値が違えば違う。
func TestEffectiveHash(t *testing.T) {
	hash := func(srcs ...OverrideSource) string {
		t.Helper()
		wf, err := loadTicket(t, srcs...)
		if err != nil {
			t.Fatal(err)
		}
		return wf.EffectiveHash
	}
	a := hash(ov(LayerArg, "limits: { budget_usd: 100 }\nsteps: { implement: { budget_usd: 60, timeout: 3h } }\n"))
	same := []string{
		hash(ov(LayerArg, "# comment\nsteps:\n  implement:\n    timeout: 180m\n    budget_usd: 60.0\nlimits:\n  budget_usd: 100.0\n")),
		hash(ov(LayerRepo, "limits: { budget_usd: 100 }\n"), ov(LayerArg, "steps: { implement: { budget_usd: 60, timeout: 3h } }\n")),
		hash(ov(LayerRepo, "limits: { budget_usd: 50 }\nsteps: { implement: { budget_usd: 60, timeout: 3h } }\n"), ov(LayerArg, "limits: { budget_usd: 100 }\n")),
	}
	for i, h := range same {
		if h != a {
			t.Errorf("case %d: effective hash %s, want %s", i, h, a)
		}
	}
	different := []string{
		hash(ov(LayerArg, "limits: { budget_usd: 100 }\nsteps: { implement: { budget_usd: 61, timeout: 3h } }\n")),
		hash(ov(LayerArg, "limits: { budget_usd: 100 }\nsteps: { implement: { budget_usd: 60 } }\n")),
		hash(ov(LayerArg, "")),
	}
	for i, h := range different {
		if h == a || len(h) != 64 {
			t.Errorf("case %d: effective hash %s must differ from %s", i, h, a)
		}
	}
}

// goldenWorkflow は上書き後の定義のハッシュを固定値で確かめるための元の定義。ハッシュは元の定義のバイト列に依るので、
// 他のテストの定義（validate_test.go の base）を流用せず、この 1 か所に固定する。書き換えたら下の固定値も変わる。
const goldenWorkflow = `schema: harness.workflow/v1
id: golden
limits:
  rework: 2
  budget_usd: 1.5
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: c
      bad: { fail: bad }
  c:
    kind: llm
    prompt: prompts/p.md
    output: schemas/out.json
    budget_usd: 1
    on:
      ok: { done: ok }
      bad: { goto: a, limit: rework, exhausted: { fail: exhausted } }
`

// 上書き後の定義のハッシュ（effectiveHash）の固定値。正規化（表現の JSON・値の型・キーの並べ方）を変えると、進行中の
// run の resume が照合で一斉に止まる（§7.2 の 3）。その変更は effectiveSchema を上げて意図して行うものなので、
// 気付かずに変えたらここで落ちるようにする。固定値は段 1（#312）の実装で取った値で、段 2 の遷移の付け替えを
// 足しても数値だけの上書きのハッシュは変わらない（段 1 の版で始めた run を段 2 の CLI で resume できる）。
func TestEffectiveHashGolden(t *testing.T) {
	path, scripts := setup(t, "golden", goldenWorkflow)
	src := OverrideSource{Layer: LayerArg, Path: "/ov/arg.yaml", Data: []byte("schema: harness.workflow-override/v1\nworkflow: golden\n" +
		"limits: { budget_usd: 3, rework: 1 }\nsteps:\n  a: { timeout: 90s }\n  c: { budget_usd: 2.5, timeout: 1h }\n")}
	wf, err := LoadWithOverrides(path, Options{ScriptsDir: scripts}, []OverrideSource{src})
	if err != nil {
		t.Fatal(err)
	}
	const want = "6b19d702b48d1be94671c2b5720539dab4ba7c4c261e58ceb59e67cb62442a5f"
	if wf.EffectiveHash != want {
		t.Fatalf("effective hash = %s, want %s (the normalization changed; bump effectiveSchema if that is intended)", wf.EffectiveHash, want)
	}
}

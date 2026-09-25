package workflow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// base は検証を通るワークフロー。拒否のケースはここから 1 か所だけを書き換えて作り、
// 「その 1 か所のせいで拒否された」ことをエラー文の一部で確かめる。
const base = `schema: harness.workflow/v1
id: w
inputs:
  n: { type: integer, required: true }
  s: { type: string }
  obj: { type: object }
limits:
  rework: 2
  budget_usd: 1.5
steps:
  a:
    kind: command
    run: tool
    with: { n: $inputs.n }
    output: schemas/out.json
    on:
      ok: b
      bad: { fail: bad }
  b:
    kind: command
    run: tool
    with: { v: $steps.a.detail.name }
    output: schemas/out.json
    on:
      ok: { done: ok }
      bad: { goto: a, limit: rework, exhausted: { fail: exhausted } }
`

var schemas = map[string]string{
	"out.json": `{"type":"object","required":["outcome"],"properties":{
		"outcome":{"type":"string","enum":["ok","bad"]},
		"detail":{"type":"object","properties":{"name":{"type":"string"}}},
		"items":{"type":"array","items":{"type":"string"}},
		"blob":{"type":"object"}}}`,
	"collide.json":  `{"type":"object","required":["outcome"],"properties":{"outcome":{"type":"string","enum":["ok","bad","step_error"]}}}`,
	"optional.json": `{"type":"object","properties":{"outcome":{"type":"string","enum":["ok","bad"]}}}`,
	"noenum.json":   `{"type":"object","required":["outcome"],"properties":{"outcome":{"type":"string"}}}`,
}

// setup はワークフローと出力スキーマ・スクリプトを一時ディレクトリへ置き、ワークフローのパスとスクリプトの置き場を返す。
func setup(t *testing.T, name, yaml string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "schemas"), 0o755); err != nil {
		t.Fatal(err)
	}
	for n, s := range schemas {
		if err := os.WriteFile(filepath.Join(dir, "schemas", n), []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	scripts := filepath.Join(dir, "scripts")
	if err := os.MkdirAll(scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scripts, "tool.sh"), []byte("#!/bin/bash\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for f, body := range map[string]string{"prompts/p.md": "# prompt\n", "agents/feature-implementer.md": "---\nname: feature-implementer\n---\n"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, f)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, f), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(dir, name+".yaml")
	if err := os.WriteFile(path, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
	return path, scripts
}

func check(t *testing.T, yaml string) error {
	t.Helper()
	path, scripts := setup(t, "w", yaml)
	_, err := LoadAndValidate(path, Options{ScriptsDir: scripts})
	return err
}

// mutate は base の old をちょうど 1 か所だけ new に置き換える。
func mutate(t *testing.T, old, new string) string {
	t.Helper()
	if n := strings.Count(base, old); n != 1 {
		t.Fatalf("fragment %q occurs %d times in base; a mutation must change exactly one place", old, n)
	}
	return strings.Replace(base, old, new, 1)
}

func TestBaseIsValid(t *testing.T) {
	if err := check(t, base); err != nil {
		t.Fatalf("base must be valid: %v", err)
	}
}

func TestRejects(t *testing.T) {
	cases := []struct {
		name     string
		old, new string
		want     string
	}{
		// 未知のキーの拒否（式の混入を構文として受け付けない）
		{"when in a step", "    run: tool\n    with: { n: $inputs.n }", "    run: tool\n    when: $inputs.n\n    with: { n: $inputs.n }", `key "when" is a condition/expression`},
		{"if in a transition", "      ok: b\n", "      ok: { goto: b, if: $inputs.n }\n", `key "if" is a condition/expression`},
		{"unless in a step", "    run: tool\n    with: { n: $inputs.n }", "    run: tool\n    unless: $inputs.s\n    with: { n: $inputs.n }", `key "unless" is a condition/expression`},
		{"when as an on key", "      ok: b\n", "      ok: b\n      when: b\n", `"when" is not an outcome of this step`},
		{"comparison as an on key", "      ok: b\n", "      ok: b\n      \"n > 1\": b\n", `key "n > 1" is not an outcome value`},
		{"unknown top-level key", "limits:\n", "vars: { x: 1 }\nlimits:\n", `unknown key "vars"`},
		{"unknown step key", "    run: tool\n    with: { n: $inputs.n }", "    run: tool\n    args: x\n    with: { n: $inputs.n }", `unknown key "args"`},
		{"unknown transition key", "      bad: { fail: bad }", "      bad: { fail: bad, note: x }", `unknown key "note"`},
		{"yaml anchor", "    with: { n: $inputs.n }", "    with: &w { n: $inputs.n }", "YAML anchors"},
		{"duplicate key", "    run: tool\n    with: { n: $inputs.n }", "    run: tool\n    run: tool\n    with: { n: $inputs.n }", `duplicate key "run"`},

		// on が outcome の enum を網羅すること
		{"on misses an outcome", "      bad: { fail: bad }\n", "", `outcome "bad" is not covered`},
		{"on has an unknown outcome", "      bad: { fail: bad }\n", "      bad: { fail: bad }\n      maybe: { fail: bad }\n", `"maybe" is not an outcome of this step`},
		{"on is missing", "    on:\n      ok: b\n      bad: { fail: bad }\n", "", "on is required"},

		// 参照の文法（§3.3）に無い形
		{"operator in a reference", "with: { n: $inputs.n }", `with: { n: "$inputs.n + 1" }`, "is not a reference"},
		{"index in a reference", "$steps.a.detail.name", `"$steps.a.items[0]"`, "is not a reference"},
		{"default in a reference", "with: { n: $inputs.n }", `with: { n: "$inputs.s | default" }`, "is not a reference"},
		{"unknown reference root", "with: { n: $inputs.n }", "with: { n: $env.HOME }", "is not a reference"},
		{"string building with a reference", "with: { n: $inputs.n }", `with: { n: "issue-$inputs.n" }`, "embeds a reference"},
		{"template syntax", "with: { n: $inputs.n }", `with: { n: "{{ inputs.n }}" }`, "embeds a reference"},
		{"list literal", "with: { n: $inputs.n }", "with: { n: [1, 2] }", "must be one reference or a scalar literal"},

		// 参照先の存在と型
		{"undeclared input", "with: { n: $inputs.n }", "with: { n: $inputs.missing }", "refers to an input that is not declared"},
		{"missing step", "$steps.a.detail.name", "$steps.zzz.detail.name", "refers to a step that does not exist"},
		{"missing field", "$steps.a.detail.name", "$steps.a.detail.nope", `no field "detail.nope"`},
		{"type the kind cannot take", "$steps.a.detail.name", "$steps.a.blob", "accepts scalars and arrays of scalars, not object"},
		{"object input into command", "with: { n: $inputs.n }", "with: { n: $inputs.obj }", "not object"},
		{"gate note in a step", "with: { n: $inputs.n }", "with: { n: $gate.note }", "$gate.note is only valid in the with of a transition leaving an input gate"},
		{"gate note on a non-gate transition", "      bad: { goto: a, limit: rework", "      bad: { goto: a, with: { note: $gate.note }, limit: rework", "$gate.note is only valid in the with of a transition leaving an input gate"},
		{"edge in the first step", "with: { n: $inputs.n }", "with: { n: $edge.x }", "the first step is entered without a transition"},
		{"edge not passed", "with: { v: $steps.a.detail.name }", "with: { v: $steps.a.detail.name, f: $edge.failure }", `does not pass "failure"`},
		{"edge passed but not read", "      ok: b\n", "      ok: { goto: b, with: { failure: $steps.a.detail.name } }\n", "does not read $edge.failure"},
		{"optional input on a transition", "      ok: b\n", "      ok: { goto: b, with: { x: $inputs.s } }\n", "$inputs.s is an optional input; only required inputs can be passed on a transition"},
		{"edge in a transition", "      bad: { goto: a, limit: rework", "      bad: { goto: a, with: { x: $edge.y }, limit: rework", "$edge values are only readable in the with of the step"},

		// 遷移先・到達不能
		{"transition to a missing step", "      ok: b\n", "      ok: nowhere\n      bad2: b\n", `step "nowhere" does not exist`},
		{"gate transition to a non-gate", "      ok: b\n", "      ok: { gate: b }\n", "is a command step, not a gate"},
		{"unreachable step", "exhausted: { fail: exhausted } }\n", "exhausted: { fail: exhausted } }\n  orphan:\n    kind: command\n    run: tool\n    output: schemas/out.json\n    on: { ok: { done: ok }, bad: { done: ok } }\n", "steps.orphan is unreachable"},
		{"cycle without a limit", "      bad: { goto: a, limit: rework, exhausted: { fail: exhausted } }", "      bad: a", "cycle with no limit, retry or gate"},

		// limit の定義
		{"undefined limit", "limit: rework", "limit: nope", `limit "nope" is not defined in limits`},
		{"non-integer limit", "limit: rework", "limit: budget_usd", `limit "budget_usd" must be an integer`},
		{"limit without exhausted", "limit: rework, exhausted: { fail: exhausted } }", "limit: rework }", "exhausted is required with limit"},
		{"retry inside exhausted", "exhausted: { fail: exhausted } }", "exhausted: { retry: 1, exhausted: { fail: x } } }", "exhausted must not itself count"},

		// 予約値との衝突
		{"reserved value in the output enum", "    with: { n: $inputs.n }\n    output: schemas/out.json", "    with: { n: $inputs.n }\n    output: schemas/collide.json", `outcome "step_error" collides with a reserved value`},
		{"reserved value in the exit table", "    with: { n: $inputs.n }\n    output: schemas/out.json", "    with: { n: $inputs.n }\n    exit: { 0: ok, 1: bad, 2: step_timeout }", `outcome "step_timeout" collides with a reserved value`},

		// 種類・run の参照先の実在・出力スキーマ
		{"unregistered kind", "  a:\n    kind: command", "  a:\n    kind: fanout", `kind "fanout" is not a registered step kind`},
		{"missing script", "    run: tool\n    with: { n: $inputs.n }", "    run: nope\n    with: { n: $inputs.n }", `run "nope" does not exist`},
		{"outcome not required", "    with: { n: $inputs.n }\n    output: schemas/out.json", "    with: { n: $inputs.n }\n    output: schemas/optional.json", "must be listed in required"},
		{"outcome without enum", "    with: { n: $inputs.n }\n    output: schemas/out.json", "    with: { n: $inputs.n }\n    output: schemas/noenum.json", "must declare a non-empty enum"},
		{"output outside the workflow dir", "    with: { n: $inputs.n }\n    output: schemas/out.json", "    with: { n: $inputs.n }\n    output: ../out.json", "must be a path inside the workflow directory"},
		{"exit and outcome_field", "    with: { n: $inputs.n }\n    output: schemas/out.json", "    with: { n: $inputs.n }\n    output: schemas/out.json\n    outcome_field: outcome\n    exit: { 0: ok, 1: bad }", "either exit or outcome_field"},

		// ファイルとしての整合
		{"id differs from the file name", "id: w\n", "id: other\n", `id "other" must equal the file name "w"`},
		{"unsupported schema", "schema: harness.workflow/v1", "schema: harness.workflow/v2", `unsupported schema "harness.workflow/v2"`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := check(t, mutate(t, c.old, c.new))
			if err == nil {
				t.Fatalf("expected rejection containing %q, but the workflow was accepted", c.want)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("expected rejection containing %q, got:\n%v", c.want, err)
			}
		})
	}
}

// 値が必ず在るとは限らないステップの参照を拒否する（§3.3: その経路でまだ実行されていないステップの参照は遷移の with へ寄せる）。
func TestRejectsReferenceToStepNotOnEveryPath(t *testing.T) {
	yaml := `schema: harness.workflow/v1
id: w
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: b, bad: c }
  b:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: c, bad: { fail: bad } }
  c:
    kind: command
    run: tool
    with: { v: $steps.b.detail.name }
    output: schemas/out.json
    on: { ok: { done: ok }, bad: { fail: bad } }
`
	err := check(t, yaml)
	if err == nil || !strings.Contains(err.Error(), `step "b" has not necessarily succeeded on every path that reaches "c"`) {
		t.Fatalf("want rejection of $steps.b in c, got %v", err)
	}
	// 予約値の遷移で先へ進んだ経路でも、参照先の出力は無い。
	yaml2 := strings.Replace(yaml, "on: { ok: b, bad: c }", "on: { ok: b, bad: { fail: bad } }", 1)
	yaml2 = strings.Replace(yaml2, "on: { ok: c, bad: { fail: bad } }", "on: { ok: c, bad: { fail: bad }, step_error: c }", 1)
	err = check(t, yaml2)
	if err == nil || !strings.Contains(err.Error(), `step "b" has not necessarily succeeded`) {
		t.Fatalf("want rejection when b can be left through a reserved outcome, got %v", err)
	}
	// 同じ参照を遷移の with に寄せれば通る。
	yaml3 := strings.Replace(yaml2, "step_error: c }", "step_error: { fail: b_error } }", 1)
	if err := check(t, yaml3); err != nil {
		t.Fatalf("b dominates c once the reserved path is closed; want valid, got %v", err)
	}
}

func TestEdgeTypesMustAgree(t *testing.T) {
	yaml := `schema: harness.workflow/v1
id: w
inputs:
  n: { type: integer, required: true }
limits:
  rework: 2
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: { goto: c, with: { x: $inputs.n } }
      bad: { goto: c, with: { x: $steps.a.detail.name } }
  c:
    kind: command
    run: tool
    with: { v: $edge.x }
    output: schemas/out.json
    on: { ok: { done: ok }, bad: { fail: bad } }
`
	err := check(t, yaml)
	if err == nil || !strings.Contains(err.Error(), "incoming transitions pass different types (integer and string)") {
		t.Fatalf("want rejection of mixed edge types, got %v", err)
	}
}

func TestReservedOutcomeMayBeRoutedExplicitly(t *testing.T) {
	yaml := mutate(t, "      bad: { fail: bad }\n", "      bad: { fail: bad }\n      step_error: { fail: script_failed }\n      step_timeout: { retry: 1, exhausted: { fail: slow } }\n")
	if err := check(t, yaml); err != nil {
		t.Fatalf("reserved values may appear in on: %v", err)
	}
}

func TestParseRef(t *testing.T) {
	good := map[string]RefKind{
		"$inputs.issue":        RefInputs,
		"$steps.resolve.base":  RefSteps,
		"$steps.ci-wait.a.b_c": RefSteps,
		"$edge.failure":        RefEdge,
		"$gate.note":           RefGate,
	}
	for s, k := range good {
		r, err := ParseRef(s)
		if err != nil || r.Kind != k {
			t.Errorf("ParseRef(%q) = %v, %v; want kind %s", s, r, err, k)
		}
	}
	bad := []string{"$inputs", "$inputs.a.b", "$steps.a", "$steps.a.b[0]", "$steps.a.b + 1", "$edge.a.b", "$gate.input", "$gate", "$inputs.a == 1", "$inputs.a && $inputs.b", "$env.HOME", "$ inputs.a", "$inputs.a ", "$steps.A.b"}
	for _, s := range bad {
		if _, err := ParseRef(s); err == nil {
			t.Errorf("ParseRef(%q) must fail", s)
		}
	}
}

func init() {
	RegisterObservation("pr", []string{"merged", "open"})
}

// llmBase は llm と gate（input・observe）を使う、検証を通るワークフロー。
const llmBase = `schema: harness.workflow/v1
id: w
inputs:
  n: { type: integer, required: true }
limits:
  budget_usd: 10
steps:
  impl:
    kind: llm
    agent: claude-harness:feature-implementer
    prompt: prompts/p.md
    session: new
    with: { n: $inputs.n, obj: $steps.a.detail }
    output: schemas/out.json
    budget_usd: 2
    timeout: 30m
    on:
      ok: { gate: review }
      bad: { gate: deviation }
  review:
    kind: gate
    type: input
    decider: any
    requested_action: wait for the review
    inputs: [respond, ready]
    on:
      respond: { goto: fix, with: { note: "address the review comments" } }
      ready: { gate: merged }
  deviation:
    kind: gate
    type: input
    decider: human
    requested_action: decide
    inputs: [follow, abort]
    on:
      follow: { goto: fix, with: { note: $gate.note } }
      abort: { fail: aborted }
  fix:
    kind: llm
    prompt: prompts/p.md
    session: continue:impl
    with: { note: $edge.note }
    output: schemas/out.json
    budget_usd: 1
    on:
      ok: { gate: review }
      bad: { fail: bad }
  merged:
    kind: gate
    type: observe
    decider: human
    observe: pr
    with: { n: $inputs.n }
    requested_action: a person merges
    on:
      merged: { done: merged }
      open: { gate: merged }
`

func TestLLMAndGateBaseIsValid(t *testing.T) {
	// $steps.a は llmBase に無いので、先頭に command ステップ a を置いた形で検査する。
	if err := check(t, llmWithA(llmBase)); err != nil {
		t.Fatalf("llmBase must be valid: %v", err)
	}
}

// llmWithA は llmBase の先頭に command ステップ a（impl へ進む）を足す（$steps.a.detail の参照先）。
func llmWithA(y string) string {
	return strings.Replace(y, "steps:\n", "steps:\n  a:\n    kind: command\n    run: tool\n    output: schemas/out.json\n    on: { ok: impl, bad: { fail: a_bad } }\n", 1)
}

func TestRejectsLLMAndGate(t *testing.T) {
	cases := []struct {
		name     string
		old, new string
		want     string
	}{
		{"llm without budget limit", "limits:\n  budget_usd: 10\n", "", "limits.budget_usd is required when the workflow has llm steps"},
		{"llm without budget_usd", "    budget_usd: 2\n", "", "budget_usd is required for kind llm"},
		{"non-positive budget_usd", "    budget_usd: 2\n", "    budget_usd: 0\n", "must be a positive amount"},
		{"llm without prompt", "    agent: claude-harness:feature-implementer\n    prompt: prompts/p.md\n", "    agent: claude-harness:feature-implementer\n", "prompt is required for kind llm"},
		{"missing prompt file", "    agent: claude-harness:feature-implementer\n    prompt: prompts/p.md\n", "    agent: claude-harness:feature-implementer\n    prompt: prompts/nope.md\n", `prompt "prompts/nope.md" does not exist`},
		{"missing agent", "agent: claude-harness:feature-implementer", "agent: claude-harness:nobody", `agent "claude-harness:nobody" does not exist`},
		{"agent of another plugin", "agent: claude-harness:feature-implementer", "agent: other:feature-implementer", "only agents of the claude-harness plugin"},
		{"agent without namespace", "agent: claude-harness:feature-implementer", "agent: feature-implementer", "must match"},
		{"bad session", "    session: new\n", "    session: resume\n", "must be new or continue:<step id>"},
		{"continue a missing step", "session: continue:impl", "session: continue:nope", "refers to a step that does not exist"},
		{"continue a non-llm step", "session: continue:impl", "session: continue:a", "only llm steps have a Claude session"},
		{"continue a step not on every path", "session: continue:impl", "session: continue:fix", "has not necessarily run on every path"},
		{"exit on llm", "    budget_usd: 2\n", "    budget_usd: 2\n    exit: { 0: ok }\n", `unknown key "exit"`},
		{"gate without decider", "    decider: any\n", "", "decider is required for kind gate"},
		{"unknown decider", "    decider: any\n", "    decider: robot\n", `decider "robot" must be human, parent or any`},
		{"gate without type", "    type: input\n    decider: any\n", "    decider: any\n", "type is required for kind gate"},
		{"gate without requested_action", "    requested_action: wait for the review\n", "", "requested_action is required"},
		{"input gate without inputs", "    inputs: [respond, ready]\n", "", "an input gate needs inputs"},
		{"input gate misses an input", "      ready: { gate: merged }\n", "", `outcome "ready" is not covered`},
		{"duplicate input", "inputs: [respond, ready]", "inputs: [respond, ready, ready]", `duplicate value "ready"`},
		{"reserved input", "inputs: [respond, ready]", "inputs: [respond, ready, step_error]", "collides with a reserved value"},
		{"reserved outcome routed from a gate", "      ready: { gate: merged }\n", "      ready: { gate: merged }\n      step_error: { fail: x }\n", "a gate does not produce the reserved value"},
		{"retry on a gate", "      ready: { gate: merged }\n", "      ready: { retry: 1, exhausted: { gate: merged } }\n", "retry is not valid on a gate"},
		{"with on an input gate", "    inputs: [respond, ready]\n", "    inputs: [respond, ready]\n    with: { n: $inputs.n }\n", "with is only valid for type observe"},
		{"unregistered observation", "observe: pr", "observe: nope", `observe "nope" is not a registered observation`},
		{"observe gate with inputs", "    observe: pr\n", "    observe: pr\n    inputs: [merged, open]\n", "inputs is only valid for type input"},
		{"observe gate misses an outcome", "      open: { gate: merged }\n", "", `outcome "open" is not covered`},
		{"gate note from an llm step", "      bad: { fail: bad }\n", "      bad: { goto: review, with: { x: $gate.note } }\n", "step \"fix\" is not an input gate"},
		{"note of another type on another transition", `with: { note: "address the review comments" }`, "with: { note: $inputs.n }", "incoming transitions pass different types"},
		{"note not passed by every transition", `      respond: { goto: fix, with: { note: "address the review comments" } }`, "      respond: fix", `does not pass "note"`},
		{"interrupted is reserved", "  merged:\n", "  interrupted:\n    kind: gate\n    type: input\n    decider: any\n    requested_action: x\n    inputs: [go]\n    on: { go: { done: x } }\n  merged:\n", `step id "interrupted" is reserved`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if n := strings.Count(llmBase, c.old); n != 1 {
				t.Fatalf("fragment %q occurs %d times in llmBase", c.old, n)
			}
			err := check(t, llmWithA(strings.Replace(llmBase, c.old, c.new, 1)))
			if err == nil {
				t.Fatalf("expected rejection containing %q, but the workflow was accepted", c.want)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("expected rejection containing %q, got:\n%v", c.want, err)
			}
		})
	}
}

func TestRequiresTTY(t *testing.T) {
	for _, c := range []struct {
		typ, decider string
		want         bool
	}{
		{GateInput, DeciderHuman, true},
		{GateObserve, DeciderHuman, false}, // N1
		{GateInput, DeciderParent, false},
		{GateInput, DeciderAny, false},
		{GateObserve, DeciderAny, false},
	} {
		if got := RequiresTTY(c.typ, c.decider); got != c.want {
			t.Errorf("RequiresTTY(%s, %s) = %v, want %v", c.typ, c.decider, got, c.want)
		}
	}
}

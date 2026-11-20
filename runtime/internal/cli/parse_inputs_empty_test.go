package cli

import (
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

func inputsWorkflow(required ...string) *workflow.Workflow {
	req := map[string]bool{}
	for _, n := range required {
		req[n] = true
	}
	mk := func(name string, t *workflow.Type) *workflow.Input {
		return &workflow.Input{Name: name, Type: t, Required: req[name]}
	}
	return &workflow.Workflow{ID: "t", Inputs: []*workflow.Input{
		mk("n", &workflow.Type{Name: "integer"}),
		mk("s", &workflow.Type{Name: "string"}),
		mk("a", &workflow.Type{Name: "array", Items: &workflow.Type{Name: "string"}}),
		mk("o", &workflow.Type{Name: "object"}),
	}}
}

// 値が空の文字列の入力は、型に関わらず「無い」と読む（run_started.inputs に入れない）。
func TestParseInputsReadsAnEmptyValueAsAbsent(t *testing.T) {
	for _, name := range []string{"n", "s", "a", "o"} {
		t.Run(name, func(t *testing.T) {
			got, err := parseInputs(inputsWorkflow(), []string{name + "="})
			if err != nil {
				t.Fatalf("an empty %s is an error: %v", name, err)
			}
			if _, ok := got[name]; ok {
				t.Errorf("an empty %s was kept: %s", name, got[name])
			}
		})
	}
	// 空でない値はこれまでどおり読む。値の中の = は値の一部。
	got, err := parseInputs(inputsWorkflow(), []string{"n=3", "s=a=b", "a=[\"x\"]"})
	if err != nil || string(got["n"]) != "3" || string(got["s"]) != `"a=b"` || string(got["a"]) != `["x"]` {
		t.Fatalf("got %v, %v", got, err)
	}
}

// 空の入力は必須の入力を満たさず、同じ名前を 2 度渡す誤りは空でも数える。宣言の無い入力は、空でも誤り。
func TestParseInputsEmptyValueStillCountsForTheChecks(t *testing.T) {
	if _, err := parseInputs(inputsWorkflow("s"), []string{"s="}); err == nil || !strings.Contains(err.Error(), `"s" is required`) {
		t.Errorf("an empty required input: %v", err)
	}
	for name, raw := range map[string][]string{
		"empty then empty":    {"s=", "s="},
		"empty then value":    {"s=", "s=x"},
		"value then empty":    {"s=x", "s="},
		"empty integer twice": {"n=", "n="},
	} {
		if _, err := parseInputs(inputsWorkflow(), raw); err == nil || !strings.Contains(err.Error(), "given twice") {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := parseInputs(inputsWorkflow(), []string{"x="}); err == nil || !strings.Contains(err.Error(), `input "x" is not declared`) {
		t.Errorf("an undeclared empty input: %v", err)
	}
	if _, err := parseInputs(inputsWorkflow(), []string{"x"}); err == nil {
		t.Error("NAME without = must stay an error")
	}
	// 空でない誤りは、これまでどおり型の誤り
	if _, err := parseInputs(inputsWorkflow(), []string{"n=x"}); err == nil {
		t.Error("a non-integer value must stay an error")
	}
}

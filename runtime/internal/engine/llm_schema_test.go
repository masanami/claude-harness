package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// 出力スキーマの $schema（draft 2020-12）は claude CLI が拒否するため、--json-schema へは落として渡す（#279）。
// 定義のファイルは変えず、runtime 側の検証（structured_output の型検査）は $schema のあるまま行う。
func TestLLMJSONSchemaDropsDialect(t *testing.T) {
	f := newFake(t)
	f.respond(1, 0, claudeResult("pass", 0.4))
	st, _ := start(t, "llm-dialect", map[string]any{"issue": 42})
	if st.Status != runstate.StatusSucceeded {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	schema, ok := flag(f.argv(1), "--json-schema")
	if !ok {
		t.Fatal("--json-schema was not passed")
	}
	if strings.Contains(schema, "$schema") {
		t.Errorf("--json-schema still has $schema: %s", schema)
	}
	want := `{"type":"object","required":["outcome"],"additionalProperties":false,"properties":{"outcome":{"type":"string","enum":["pass","failure"]},"summary":{"type":"string"}}}`
	if schema != want {
		t.Errorf("--json-schema = %s, want %s (the rest of the schema and its key order are kept)", schema, want)
	}
	data, err := os.ReadFile(testdata(t, "workflows", "schemas", "impl-dialect.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"$schema"`) {
		t.Fatal("the fixture must keep $schema in the file")
	}
}

// 落とした後も型付き出力の検証は効く（enum に無い outcome は invalid_output）。
func TestLLMJSONSchemaDialectStillValidates(t *testing.T) {
	f := newFake(t)
	f.respond(1, 0, claudeResult("maybe", 0.4))
	st, _ := start(t, "llm-dialect", map[string]any{"issue": 42})
	x := st.Unit(MainUnit).Rounds[0].Steps[0]
	if x.Outcome != "invalid_output" {
		t.Fatalf("outcome = %s, want invalid_output (status %s: %s)", x.Outcome, st.Status, st.Reason)
	}
}

// 同梱のスキーマ（runtime/workflows/schemas）はどれも、--json-schema へ渡る文字列に $schema を含まず、
// それ以外のキーは元のファイルと同じ値を保つ。
func TestClaudeSchemaArgBundledSchemas(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join("..", "..", "workflows", "schemas", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatal("no bundled schemas found")
	}
	for _, p := range paths {
		t.Run(filepath.Base(p), func(t *testing.T) {
			got, err := claudeSchemaArg(p)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(got, `"$schema"`) {
				t.Fatalf("--json-schema would carry $schema: %s", got)
			}
			if strings.ContainsAny(got, "\n") {
				t.Fatalf("not compacted: %s", got)
			}
			data, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			var orig, arg map[string]any
			if err := json.Unmarshal(data, &orig); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal([]byte(got), &arg); err != nil {
				t.Fatalf("not JSON: %v: %s", err, got)
			}
			delete(orig, "$schema")
			if !reflect.DeepEqual(orig, arg) {
				t.Fatalf("the schema changed beyond dropping $schema:\n got %v\nwant %v", arg, orig)
			}
		})
	}
}

func TestClaudeSchemaArgRejectsNonObject(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"array.json":    `[{"$schema":"x"}]`,
		"trailing.json": `{"type":"object"} {}`,
		"broken.json":   `{"type":`,
	} {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if got, err := claudeSchemaArg(p); err == nil {
			t.Errorf("%s: accepted as %s", name, got)
		}
	}
}

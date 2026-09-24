package workflow

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

// OutputSchema はステップの `output`（JSON Schema ファイル）。実行時の検証と、読み込み時の参照の型検査に使う。
type OutputSchema struct {
	Path        string
	raw         map[string]any
	compiled    *jsonschema.Schema
	OutcomeEnum []string // outcome フィールドの enum（exit 表を使うステップでは空）
}

// noLoader は外部の $ref を解決しない（出力スキーマは 1 ファイルで自己完結させる。検証時にネットワークへ出ない）。
type noLoader struct{}

func (noLoader) Load(url string) (any, error) {
	return nil, fmt.Errorf("external schema reference %s is not allowed; output schemas must be self-contained", url)
}

// LoadOutputSchema は JSON Schema を読み込んでコンパイルする。
func LoadOutputSchema(path string) (*OutputSchema, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("output schema %s is not a JSON object: %v", path, err)
	}
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	c := jsonschema.NewCompiler()
	c.UseLoader(noLoader{})
	url := "file://" + path
	if err := c.AddResource(url, doc); err != nil {
		return nil, err
	}
	sch, err := c.Compile(url)
	if err != nil {
		return nil, fmt.Errorf("output schema %s does not compile: %v", path, err)
	}
	return &OutputSchema{Path: path, raw: raw, compiled: sch}, nil
}

// Validate は JSON の値（jsonschema.UnmarshalJSON で読んだもの）をスキーマで検証する。
func (o *OutputSchema) Validate(v any) error {
	return o.compiled.Validate(v)
}

// outcomeEnum は outcome フィールドが「必須・string・enum（string の非空集合）」であることを確かめ、その enum を返す。
func (o *OutputSchema) outcomeEnum(field string) ([]string, error) {
	props, _ := o.raw["properties"].(map[string]any)
	prop, ok := props[field].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("output schema has no property %q to take the outcome from", field)
	}
	if t, _ := prop["type"].(string); t != "string" {
		return nil, fmt.Errorf("outcome property %q must have type string", field)
	}
	required := false
	if req, ok := o.raw["required"].([]any); ok {
		for _, r := range req {
			if r == field {
				required = true
			}
		}
	}
	if !required {
		return nil, fmt.Errorf("outcome property %q must be listed in required", field)
	}
	enum, ok := prop["enum"].([]any)
	if !ok || len(enum) == 0 {
		return nil, fmt.Errorf("outcome property %q must declare a non-empty enum (transitions match enum values only)", field)
	}
	var out []string
	for _, e := range enum {
		s, ok := e.(string)
		if !ok || !reOutcome.MatchString(s) {
			return nil, fmt.Errorf("outcome enum value %v must be a string matching %s", e, reOutcome.String())
		}
		out = append(out, s)
	}
	return out, nil
}

// FieldType は出力のフィールドパスが指す値の型を返す。パスがスキーマに無い・型が 1 つに決まらない場合はエラー。
func (o *OutputSchema) FieldType(path []string) (*Type, error) {
	node := o.raw
	for i, name := range path {
		if _, ok := node["$ref"]; ok {
			return nil, fmt.Errorf("cannot follow $ref in output schema for static checks")
		}
		props, _ := node["properties"].(map[string]any)
		next, ok := props[name].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("output schema has no field %q", joinPath(path[:i+1]))
		}
		node = next
	}
	return schemaType(node)
}

func schemaType(node map[string]any) (*Type, error) {
	if _, ok := node["$ref"]; ok {
		return nil, fmt.Errorf("cannot follow $ref in output schema for static checks")
	}
	name, ok := node["type"].(string)
	if !ok {
		return nil, fmt.Errorf("field must declare a single type")
	}
	switch name {
	case "string", "integer", "number", "boolean", "object":
		return &Type{Name: name}, nil
	case "array":
		items, ok := node["items"].(map[string]any)
		if !ok {
			return &Type{Name: "array"}, nil
		}
		it, err := schemaType(items)
		if err != nil {
			return nil, err
		}
		return &Type{Name: "array", Items: it}, nil
	}
	return nil, fmt.Errorf("unsupported type %q", name)
}

func joinPath(p []string) string {
	s := ""
	for i, x := range p {
		if i > 0 {
			s += "."
		}
		s += x
	}
	return s
}

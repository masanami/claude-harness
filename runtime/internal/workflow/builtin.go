package workflow

import (
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// 出力を runtime（Go）が生成する種類（select・workspace・pull-request）の定義（§3.2）。
// YAML に output を書かせない: 出力の形は種類が決めるもので、ワークフローごとに変えられると
// 参照の型検査（§3.3）の前提が崩れる。

//go:embed builtin/*.json
var builtinFS embed.FS

// Workspace 種類の action と outcome（§3.2・§5.4）。
const (
	ActionAcquire = "acquire"
	ActionRelease = "release"

	WorkspaceProvided = "provided"
	WorkspaceCreated  = "created"
	WorkspaceReused   = "reused"
	WorkspaceConflict = "conflict"

	WorkspaceReleased = "released"
	WorkspaceKept     = "kept"
	WorkspaceDirty    = "dirty"

	PROpened  = "opened"
	PRUpdated = "updated"
)

// withSpec は種類が受け取る with の 1 項目（名前・型・必須か）。
type withSpec struct {
	name     string
	typ      string // integer | string | array
	required bool
}

// builtinWith は Go が振る舞いを持つ種類の with の許可リスト。ここに無い名前は拒否する（渡したのに使われない値を作らない）。
var builtinWith = map[string][]withSpec{
	"workspace:" + ActionAcquire: {
		{name: "issue", typ: "integer", required: true},
		{name: "branch", typ: "string", required: true},
		{name: "base", typ: "string", required: true},
		{name: "provided", typ: "string"}, // 呼び出し元が払い出した worktree（省略可。§5.4）
	},
	"workspace:" + ActionRelease: {},
	"pull-request": {
		{name: "base", typ: "string", required: true},
		{name: "closes", typ: "integer", required: true},
		{name: "title", typ: "string", required: true},
		{name: "summary", typ: "string", required: true},
		{name: "quality", typ: "string"},          // 実装ステップの outcome（pass / skip）。skip なら未検証を明記する（I7）
		{name: "residual_findings", typ: "array"}, // 残指摘の全件（I13）
		{name: "unverified", typ: "array"},        // 未検証の事項（I7）
		{name: "cross_repo", typ: "string"},       // クロスリポジトリ確証（I13）
	},
}

func builtinKey(s *Step) string {
	if s.Kind == "workspace" {
		return "workspace:" + s.Action
	}
	return s.Kind
}

// builtinSchemaFile は種類の出力スキーマ（builtin/ に埋め込んだもの）の名前。
func builtinSchemaFile(s *Step) string {
	switch s.Kind {
	case "workspace":
		switch s.Action {
		case ActionAcquire:
			return "workspace-acquire.json"
		case ActionRelease:
			return "workspace-release.json"
		}
	case "pull-request":
		return "pull-request.json"
	}
	return ""
}

func loadBuiltinSchema(name string) (*OutputSchema, error) {
	data, err := builtinFS.ReadFile("builtin/" + name)
	if err != nil {
		return nil, err
	}
	sch, err := ParseOutputSchema("/harness-builtin/"+name, data)
	if err != nil {
		return nil, err
	}
	enum, err := sch.outcomeEnum("outcome")
	if err != nil {
		return nil, err
	}
	sch.OutcomeEnum = enum
	return sch, nil
}

// builtinKind は Go が出力を生成する種類（workspace・pull-request）の検査: action・with の名前と型・出力スキーマ。
func (v *validator) builtinKind(s *Step) {
	if s.Kind == "workspace" {
		switch s.Action {
		case ActionAcquire, ActionRelease:
		case "":
			v.errf(s.Line, "steps.%s: action is required for kind workspace (acquire or release)", s.ID)
			return
		default:
			v.errf(s.Line, "steps.%s: action %q must be acquire or release", s.ID, s.Action)
			return
		}
	}
	specs := builtinWith[builtinKey(s)]
	given := map[string]bool{}
	for _, b := range s.With {
		given[b.Name] = true
		found := false
		for _, sp := range specs {
			if sp.name == b.Name {
				found = true
			}
		}
		if !found {
			var names []string
			for _, sp := range specs {
				names = append(names, sp.name)
			}
			v.errf(b.Line, "steps.%s.with: %q is not an input of kind %s (inputs: %s)", s.ID, b.Name, builtinKey(s), strings.Join(names, ", "))
		}
	}
	for _, sp := range specs {
		if sp.required && !given[sp.name] {
			v.errf(s.Line, "steps.%s.with: %s is required for kind %s", s.ID, sp.name, builtinKey(s))
		}
	}
	sch, err := loadBuiltinSchema(builtinSchemaFile(s))
	if err != nil {
		v.errf(s.Line, "steps.%s: built-in output schema: %v", s.ID, err)
		return
	}
	s.OutputSchema = sch
}

// builtinAcceptable は with の値の型が種類の受け取る型と合うかを確かめる（array は要素の型を問わない）。
func (v *validator) builtinAcceptable(s *Step, name string, t *Type, line int, what string) {
	for _, sp := range builtinWith[builtinKey(s)] {
		if sp.name != name {
			continue
		}
		if t.Name != sp.typ {
			v.errf(line, "%s: kind %s takes %s as %s, not %s", what, builtinKey(s), name, sp.typ, t)
		}
		if sp.required {
			v.requiredValue(s, name, line, what)
		}
	}
}

// requiredValue は、必須の with に省略されうる入力（required でない $inputs）を渡していないかを確かめる。
func (v *validator) requiredValue(s *Step, name string, line int, what string) {
	for _, b := range s.With {
		if b.Name != name || b.Value.Ref == nil || b.Value.Ref.Kind != RefInputs {
			continue
		}
		if in := v.wf.Input(b.Value.Ref.Name); in != nil && !in.Required {
			v.errf(line, "%s: %s is an optional input, but kind %s requires %s", what, b.Value.Ref.Raw, builtinKey(s), name)
		}
	}
}

// resolveSelect は select を、値が別の select の outcome を指していればそちらを先に解決してから検査する
// （宣言の順に依らない）。state: 0 未着手・1 解決中・2 済み。select どうしの循環参照は拒否する。
func (v *validator) resolveSelect(s *Step, state map[string]int) {
	switch state[s.ID] {
	case 1:
		v.errf(s.Line, "steps.%s: value %s: select steps refer to each other in a cycle", s.ID, s.Value.Raw)
		return
	case 2:
		return
	}
	state[s.ID] = 1
	if r := s.Value; r != nil && r.Kind == RefSteps {
		if src := v.wf.Step(r.Step); src != nil && src.Kind == "select" && src.ID != s.ID {
			v.resolveSelect(src, state)
		}
	}
	v.selectKind(s)
	state[s.ID] = 2
}

// selectKind は select 種類（§3.2・Q12）の検査: value は $steps.<id>.<field> 1 つで、その値は enum を持つ string。
// outcome はその enum をそのまま使う（一致だけ。比較・組み合わせは持たない）。参照先が必ず成功していることは references が確かめる。
func (v *validator) selectKind(s *Step) {
	r := s.Value
	if r == nil {
		v.errf(s.Line, "steps.%s: value is required for kind select (one reference whose enum value becomes the outcome)", s.ID)
		return
	}
	if r.Kind != RefSteps {
		v.errf(s.Line, "steps.%s: value %s: select takes a step's output field ($steps.<step>.<field>); inputs, $edge and $gate.note have no enum to select on", s.ID, r.Raw)
		return
	}
	src := v.wf.Step(r.Step)
	if src == nil {
		v.errf(s.Line, "steps.%s: value %s refers to a step that does not exist", s.ID, r.Raw)
		return
	}
	if src.ID == s.ID {
		v.errf(s.Line, "steps.%s: value %s refers to the select step itself", s.ID, r.Raw)
		return
	}
	var enum []string
	if len(r.Path) == 1 && r.Path[0] == "outcome" {
		enum = src.Outcomes()
	} else if src.OutputSchema == nil {
		v.errf(s.Line, "steps.%s: value %s: step %q has no output schema", s.ID, r.Raw, src.ID)
		return
	} else {
		var err error
		enum, err = src.OutputSchema.FieldEnum(r.Path)
		if err != nil {
			v.errf(s.Line, "steps.%s: value %s: %v (select needs a string field with an enum)", s.ID, r.Raw, err)
			return
		}
	}
	if len(enum) == 0 {
		v.errf(s.Line, "steps.%s: value %s has no enum values to select on", s.ID, r.Raw)
		return
	}
	for _, o := range enum {
		if IsReserved(o) {
			v.errf(s.Line, "steps.%s: enum value %q of %s collides with a reserved value (%s)", s.ID, o, r.Raw, strings.Join(ReservedOutcomes, ", "))
		}
	}
	s.SelectOutcomes = enum
}

// ScriptPath は command の run が指すスクリプトの場所を返す。ワークフローに付属するスクリプト
// （<workflow-dir>/scripts/<run>.sh。runtime が持つもの）と、プラグインのスクリプト（<scripts-dir>/<run>.sh）の
// どちらか一方だけに在ること（同じ名前が両方に在れば、どちらを呼ぶかが読み手に分からないので拒否する）。
func ScriptPath(workflowDir, scriptsDir, run string) (string, error) {
	var found []string
	for i, dir := range []string{filepath.Join(workflowDir, "scripts"), scriptsDir} {
		if dir == "" || (i == 1 && filepath.Clean(dir) == filepath.Clean(filepath.Join(workflowDir, "scripts"))) {
			continue // 同じディレクトリを 2 度数えない
		}
		p := filepath.Join(dir, run+".sh")
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() {
			found = append(found, p)
		}
	}
	switch len(found) {
	case 0:
		return "", fmt.Errorf("run %q does not exist (%s or %s)", run,
			filepath.Join(workflowDir, "scripts", run+".sh"), filepath.Join(scriptsDir, run+".sh"))
	case 1:
		return found[0], nil
	}
	return "", fmt.Errorf("run %q exists both as %s and %s; script names must be unique", run, found[0], found[1])
}

// Package workflow は harness のワークフロー定義（式を持たない YAML・docs/harness-runtime-design.md §3.1〜§3.3）の
// 読み込みと静的検証（§6.3）を持つ。
//
// 文法は「書けるものだけを列挙する」形で実装している。未知のキー・参照の文法（§3.3）に無い形・
// 文字列の組み立て（リテラル中の `$`）は、どれも許可リストに無いという理由で拒否される。
// `when:`・`if:` のような条件キーを個別に禁止しているのではなく、許可していないから通らない。
// 個別の名前は、拒否の理由を読み手に伝えるためにだけ持つ（exprKeys）。
package workflow

import "time"

// SchemaV1 は本実装が読み込めるワークフローのスキーマ版（§3.1）。
const SchemaV1 = "harness.workflow/v1"

// ReservedOutcomes は runtime が付与する予約値（§3.1）。ステップの出力の enum 値と衝突してはならない。
// `on` に書かれていなければ、既定で run を failed にする（fail-closed）。
var ReservedOutcomes = []string{"step_error", "step_timeout", "invalid_output", "budget_exhausted"}

// IsReserved は outcome が予約値かを返す。
func IsReserved(outcome string) bool {
	for _, r := range ReservedOutcomes {
		if r == outcome {
			return true
		}
	}
	return false
}

// Workflow は読み込んだワークフロー定義。Steps の先頭が開始ステップ。
type Workflow struct {
	Schema      string
	ID          string
	Description string
	Inputs      []*Input
	Limits      []*Limit
	Steps       []*Step

	// Path は読み込んだ YAML のパス、Dir は output 等の相対パスの起点、Hash は YAML のバイト列の sha256。
	Path string
	Dir  string
	Hash string
}

// Step は id でステップを引く。無ければ nil。
func (w *Workflow) Step(id string) *Step {
	for _, s := range w.Steps {
		if s.ID == id {
			return s
		}
	}
	return nil
}

// Input は id で入力を引く。無ければ nil。
func (w *Workflow) Input(name string) *Input {
	for _, in := range w.Inputs {
		if in.Name == name {
			return in
		}
	}
	return nil
}

// Limit は名前で上限値を引く。無ければ nil。
func (w *Workflow) Limit(name string) *Limit {
	for _, l := range w.Limits {
		if l.Name == name {
			return l
		}
	}
	return nil
}

// Type は入力・参照の値の型。Items は array のときだけ持つ。
type Type struct {
	Name  string // integer | string | array | object（出力スキーマ由来では number | boolean もありうる）
	Items *Type
}

func (t *Type) String() string {
	if t == nil {
		return "unknown"
	}
	if t.Name == "array" && t.Items != nil {
		return "array<" + t.Items.String() + ">"
	}
	return t.Name
}

// Equal は 2 つの型が同じかを返す。
func (t *Type) Equal(o *Type) bool {
	if t == nil || o == nil {
		return t == o
	}
	if t.Name != o.Name {
		return false
	}
	if t.Items == nil || o.Items == nil {
		return t.Items == o.Items
	}
	return t.Items.Equal(o.Items)
}

// Input は run の入力の宣言。
type Input struct {
	Name     string
	Type     *Type
	Required bool
	Line     int
}

// Limit は名前付きの整数・金額リテラル。
type Limit struct {
	Name    string
	Value   float64
	Integer bool
	Line    int
}

// Step は 1 ステップの定義。種類ごとのフィールドは使う種類だけが埋める。
type Step struct {
	ID          string
	Kind        string
	Description string
	Line        int
	With        []*Binding
	On          []*OnEntry

	// command 種類（§3.2）
	Run          string
	Output       string // ワークフローのディレクトリからの相対パス
	OutcomeField string // 既定 "outcome"
	Exit         []*ExitEntry
	Timeout      time.Duration

	// 読み込み時に解決するもの
	OutputSchema *OutputSchema
}

// Outcomes はステップが返しうる outcome（予約値を除く）を宣言順に返す。
func (s *Step) Outcomes() []string {
	if len(s.Exit) > 0 {
		var out []string
		seen := map[string]bool{}
		for _, e := range s.Exit {
			if !seen[e.Outcome] {
				seen[e.Outcome] = true
				out = append(out, e.Outcome)
			}
		}
		return out
	}
	if s.OutputSchema != nil {
		return s.OutputSchema.OutcomeEnum
	}
	return nil
}

// OnFor は outcome に対応する遷移を返す。無ければ nil。
func (s *Step) OnFor(outcome string) *Transition {
	for _, e := range s.On {
		if e.Outcome == outcome {
			return e.T
		}
	}
	return nil
}

// ExitEntry は `exit:` の終了コード表の 1 行。
type ExitEntry struct {
	Code    int
	Outcome string
	Line    int
}

// Binding は `with` の 1 項目（名前 → 参照 1 つ、またはリテラル）。
type Binding struct {
	Name  string
	Value Value
	Line  int
}

// Value は参照 1 つ、またはリテラル（string / int64）のどちらか。
type Value struct {
	Ref     *Ref
	Literal any
}

// RefKind は参照の 4 形（§3.3）。
type RefKind string

const (
	RefInputs RefKind = "inputs"
	RefSteps  RefKind = "steps"
	RefEdge   RefKind = "edge"
	RefGate   RefKind = "gate"
)

// Ref は参照 1 つ。Name は inputs / edge の名前、Step と Path は steps の参照先。
type Ref struct {
	Kind RefKind
	Name string
	Step string
	Path []string
	Raw  string
}

// OnEntry は `on` の 1 行（outcome の値 → 遷移先）。
type OnEntry struct {
	Outcome string
	T       *Transition
	Line    int
}

// TransitionKind は遷移先の形（§3.1）。
type TransitionKind string

const (
	TStep  TransitionKind = "step"
	TGoto  TransitionKind = "goto"
	TGate  TransitionKind = "gate"
	TFail  TransitionKind = "fail"
	TDone  TransitionKind = "done"
	TRetry TransitionKind = "retry"
)

// Transition は遷移先。Target は step / goto / gate の行き先、Reason は fail / done の理由。
type Transition struct {
	Kind      TransitionKind
	Target    string
	Reason    string
	With      []*Binding
	Limit     string
	Retry     int
	Exhausted *Transition
	Line      int
}

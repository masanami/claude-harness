// Package graph はワークフロー定義の形（ステップ・遷移・ゲート・終端）を、節点と辺の一覧（harness.workflow-graph/v1）に
// 組み直す（docs/harness-runtime-visualization.md §3）。harness graph の JSON はこの形をそのまま出し、テキスト表示
// （text.go・§6.1）と Mermaid（mermaid.go・§6.2）もこの形から作る。--run の現在地（run.go・§4）はこの形に重ねる。
//
// 形に入れるのは遷移を読むのに要るものと、上書きで変えられる数値（budget_usd・timeout）だけで、prompt・with・output の
// ような実行の中身は入れない（§3.1）。ゲートの名前は Go に書かず、decider と requires_tty の性質で人のゲートを区別させる。
package graph

import (
	"bytes"
	"encoding/json"
	"strconv"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/engine"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// SchemaV1 は形の版（§3.1）。閉じた値。
const SchemaV1 = "harness.workflow-graph/v1"

// 定義の出どころ（§3.1 の workflow.source）。
const (
	SourceEmbedded    = "embedded"
	SourceWorkflowDir = "workflow-dir"
)

// Graph は形の JSON の全体（§3.1）。
type Graph struct {
	Schema       string        `json:"schema"`
	Workflow     Meta          `json:"workflow"`
	Entry        string        `json:"entry"`
	Limits       []Limit       `json:"limits"`
	BuiltinGates []BuiltinGate `json:"builtin_gates"`
	Nodes        []Node        `json:"nodes"`
	Edges        []Edge        `json:"edges"`
	// Run は --run を付けたときだけ値を持つ（§4・run.go）。付けなければ null。
	Run *Run `json:"run"`
}

// Meta はどの定義を描いたか（§3.1・§5）。Overrides・Changes は #309 の run の記録（run_started.workflow）と同じ形で、
// 上書きが無ければ空の配列。
type Meta struct {
	ID            string            `json:"id"`
	Description   string            `json:"description"`
	Source        string            `json:"source"`
	Path          string            `json:"path"`
	Hash          string            `json:"hash"`
	EffectiveHash string            `json:"effective_hash"`
	CLIVersion    string            `json:"cli_version"`
	Overrides     []Override        `json:"overrides"`
	Changes       []workflow.Change `json:"changes"`
}

// Override は重ねた上書き 1 つ（run の記録の overrides[] と同じ形）。Copy は run ディレクトリに置いた写しの相対パスで、
// run を指定せずに描いたとき（写しが無い）は null。
type Override struct {
	Layer  string  `json:"layer"`
	Path   string  `json:"path"`
	SHA256 string  `json:"sha256"`
	Copy   *string `json:"copy"`
}

// Limit は limits の 1 項目（宣言順）。
type Limit struct {
	Name  string  `json:"name"`
	Value float64 `json:"value"`
}

// BuiltinGate は定義に書かれていないが、どのステップからも入りうる組み込みのゲート（§3.4）。
type BuiltinGate struct {
	ID      string   `json:"id"`
	Type    string   `json:"type"`
	Decider string   `json:"decider"`
	Inputs  []string `json:"inputs"`
}

// Node はステップか終端（§3.2）。終端は Kind が fail・done で、ID は fail:<理由>・done:<理由>。
type Node struct {
	ID   string
	Kind string

	// 終端だけが持つ。
	Reason string

	// ステップだけが持つ。Agent は llm、BudgetUSD は llm、Timeout は llm・command、Gate は gate、Select は select だけ。
	Description string
	Agent       string
	BudgetUSD   float64
	Timeout     time.Duration
	Gate        *Gate
	Select      *Select
	Skipped     bool
	// FailClosed は on に書かれていない予約値（run を failed にする。§3.4）。
	FailClosed []string
}

// Terminal は終端の節点か。
func (n *Node) Terminal() bool {
	return n.Kind == string(workflow.TFail) || n.Kind == string(workflow.TDone)
}

// Gate はゲートの項（§3.2）。observe 型は Inputs が null、input 型は Observe が null。
type Gate struct {
	Type            string   `json:"type"`
	Decider         string   `json:"decider"`
	RequiresTTY     bool     `json:"requires_tty"`
	Inputs          []string `json:"inputs"`
	Observe         *string  `json:"observe"`
	RequestedAction *string  `json:"requested_action"`
}

// Select は select の項。Value は参照の文字列そのまま（§3.2）。
type Select struct {
	Value string `json:"value"`
}

// Edge は遷移 1 本（§3.3）。上限つきの goto と retry は、通常の行き先と尽きたときの行き先（Exhausted を持つ）の 2 本にする。
type Edge struct {
	From      string     `json:"from"`
	Outcome   string     `json:"outcome"`
	Kind      string     `json:"kind"`
	To        string     `json:"to"`
	Carries   []string   `json:"carries,omitempty"`
	Limit     string     `json:"limit,omitempty"`
	Retry     int        `json:"retry,omitempty"`
	Exhausted *Exhausted `json:"exhausted,omitempty"`
	// Overridable は元の定義の overridable.routes がこの遷移に宣言した候補（宣言が無ければ null）。Overridden は上書きで
	// 付け替えた辺の元の行き先と層（付け替えていなければ null）で、To は付け替えた後の行き先になる（§3.3）。
	Overridable []string    `json:"overridable"`
	Overridden  *Overridden `json:"overridden"`
}

// Exhausted は尽きたときの辺が、何が尽きて採られるか（{"limit": "rework"} か {"retry": 1}）。
type Exhausted struct {
	Limit string `json:"limit,omitempty"`
	Retry int    `json:"retry,omitempty"`
}

// Overridden は上書きで付け替えた辺の元の行き先と層。
type Overridden struct {
	From  string `json:"from"`
	Layer string `json:"layer"`
}

// Build は読み込んで検査した定義（上書きを重ねたものを含む）から形を組む。meta の ID・Description・Path・Hash と
// 上書きの記録は wf から埋める（呼び出し元は Source と CLIVersion を渡す）。
//
// 上書きを重ねた定義では、付け替えた辺に overridden を付け、付け替えでだけ到達できなくなったステップ（wf.SkippedSteps）を
// 節点に残して skipped を付ける（§5.3）。そのステップへ入る辺は付け替えた後の定義に無いので描かれず、出ていく辺は残る。
func Build(wf *workflow.Workflow, source, cliVersion string) *Graph {
	effective := wf.EffectiveHash
	if effective == "" {
		// 上書きが無ければ、描いた定義は元の定義そのものなので元のハッシュと同じ値にする（#309 §7.1 の「hash と同じ値」）。
		effective = wf.Hash
	}
	g := &Graph{
		Schema: SchemaV1,
		Workflow: Meta{
			ID: wf.ID, Description: wf.Description, Source: source, Path: wf.Path, Hash: wf.Hash,
			EffectiveHash: effective,
			CLIVersion:    cliVersion,
			Overrides:     []Override{}, Changes: append([]workflow.Change{}, wf.Changes...),
		},
		Limits: []Limit{},
		BuiltinGates: []BuiltinGate{{
			ID: workflow.InterruptedGate, Type: workflow.GateInput, Decider: workflow.DeciderAny,
			Inputs: []string{engine.InterruptedRerun, engine.InterruptedAbort},
		}},
		Nodes: []Node{},
		Edges: []Edge{},
	}
	if len(wf.Steps) > 0 {
		g.Entry = wf.Steps[0].ID
	}
	for _, ov := range wf.Overrides {
		g.Workflow.Overrides = append(g.Workflow.Overrides, Override{Layer: ov.Layer, Path: ov.Path, SHA256: ov.SHA256})
	}
	for _, l := range wf.Limits {
		g.Limits = append(g.Limits, Limit{Name: l.Name, Value: l.Value})
	}
	skipped := map[string]bool{}
	for _, id := range wf.SkippedSteps {
		skipped[id] = true
	}
	for _, s := range wf.Steps {
		n := stepNode(s)
		n.Skipped = skipped[s.ID]
		g.Nodes = append(g.Nodes, n)
	}
	// 付け替えは changes の steps.<id>.on.<outcome> に、元の行き先（from）と書いた層とともに残る（workflow.apply）。
	rerouted := map[string]workflow.Change{}
	for _, c := range wf.Changes {
		rerouted[c.Key] = c
	}
	seen := map[string]bool{}
	for _, s := range wf.Steps {
		for _, e := range s.On {
			for i, ed := range edges(s.ID, e.Outcome, e.T, nil) {
				// 宣言と付け替えは尽きたときの行き先を持たない素のステップ遷移だけなので（routes.go）、通常の辺にだけ付ける。
				if i == 0 {
					if d := wf.Route(s.ID, e.Outcome); d != nil {
						ed.Overridable = append([]string{}, d.Candidates...)
					}
					if c, ok := rerouted["steps."+s.ID+".on."+e.Outcome]; ok {
						from, _ := c.From.(string)
						ed.Overridden = &Overridden{From: from, Layer: c.Layer}
					}
				}
				g.Edges = append(g.Edges, ed)
				if kind, reason, ok := terminal(ed.To); ok && !seen[ed.To] {
					seen[ed.To] = true
					g.Nodes = append(g.Nodes, Node{ID: ed.To, Kind: kind, Reason: reason})
				}
			}
		}
	}
	return g
}

func stepNode(s *workflow.Step) Node {
	n := Node{ID: s.ID, Kind: s.Kind, Description: s.Description, Agent: s.Agent, BudgetUSD: s.BudgetUSD, Timeout: s.Timeout,
		FailClosed: []string{}}
	switch s.Kind {
	case "gate":
		gt := &Gate{Type: s.GateType, Decider: s.Decider, RequiresTTY: workflow.RequiresTTY(s.GateType, s.Decider),
			RequestedAction: strOrNil(s.RequestedAction)}
		if s.GateType == workflow.GateObserve {
			gt.Observe = strOrNil(s.Observe)
		} else {
			gt.Inputs = append([]string{}, s.GateInputs...)
		}
		n.Gate = gt
	case "select":
		if s.Value != nil {
			n.Select = &Select{Value: s.Value.Raw}
		}
	}
	for _, r := range workflow.ReservedOutcomes {
		if s.OnFor(r) == nil {
			n.FailClosed = append(n.FailClosed, r)
		}
	}
	return n
}

// edges は遷移 1 つを辺へ開く。尽きたときの行き先（Exhausted）は、何が尽きたかを持つ別の辺にする。
func edges(from, outcome string, t *workflow.Transition, exhausted *Exhausted) []Edge {
	e := Edge{From: from, Outcome: outcome, Kind: string(t.Kind), Exhausted: exhausted}
	switch t.Kind {
	case workflow.TStep, workflow.TGate, workflow.TGoto:
		e.To = t.Target
	case workflow.TFail, workflow.TDone:
		e.To = string(t.Kind) + ":" + t.Reason
	case workflow.TRetry:
		e.To = from
		e.Retry = t.Retry
	}
	e.Limit = t.Limit
	for _, b := range t.With {
		e.Carries = append(e.Carries, b.Name)
	}
	out := []Edge{e}
	if t.Exhausted != nil {
		ex := &Exhausted{Limit: t.Limit}
		if t.Kind == workflow.TRetry {
			ex = &Exhausted{Retry: t.Retry}
		}
		out = append(out, edges(from, outcome, t.Exhausted, ex)...)
	}
	return out
}

// terminal は節点 id が終端（fail:<理由>・done:<理由>）なら種類と理由を返す。ステップ id は `:` を含まない（reStepID）。
func terminal(id string) (kind, reason string, ok bool) {
	for _, k := range []workflow.TransitionKind{workflow.TFail, workflow.TDone} {
		p := string(k) + ":"
		if len(id) > len(p) && id[:len(p)] == p {
			return string(k), id[len(p):], true
		}
	}
	return "", "", false
}

func strOrNil(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// FormatDuration は timeout を YAML の書き方に近い短い文字列にする（90m・60s。分・秒で割り切れなければ Go の表記）。
func FormatDuration(d time.Duration) string {
	switch {
	case d <= 0:
		return ""
	case d%time.Minute == 0:
		return strconv.FormatInt(int64(d/time.Minute), 10) + "m"
	case d%time.Second == 0:
		return strconv.FormatInt(int64(d/time.Second), 10) + "s"
	}
	return d.String()
}

// MarshalJSON は節点を種類ごとのフィールドだけで出す（§3.2: 終端は id・kind・reason、ステップは種類の持つものだけ）。
func (n Node) MarshalJSON() ([]byte, error) {
	o := object{{"id", n.ID}, {"kind", n.Kind}}
	if n.Terminal() {
		return append(o, field{"reason", n.Reason}).MarshalJSON()
	}
	o = append(o, field{"description", strOrNil(n.Description)})
	switch n.Kind {
	case "llm":
		o = append(o, field{"agent", strOrNil(n.Agent)}, field{"budget_usd", amountOrNil(n.BudgetUSD)},
			field{"timeout", strOrNil(FormatDuration(n.Timeout))})
	case "command":
		o = append(o, field{"timeout", strOrNil(FormatDuration(n.Timeout))})
	case "gate":
		o = append(o, field{"gate", n.Gate})
	case "select":
		o = append(o, field{"select", n.Select})
	}
	return append(o, field{"skipped", n.Skipped}, field{"fail_closed", n.FailClosed}).MarshalJSON()
}

func amountOrNil(v float64) *float64 {
	if v <= 0 {
		return nil
	}
	return &v
}

// object はキーの順を保つ JSON のオブジェクト。
type object []field

type field struct {
	k string
	v any
}

func (o object) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, f := range o {
		if i > 0 {
			b.WriteByte(',')
		}
		k, _ := json.Marshal(f.k)
		v, err := json.Marshal(f.v)
		if err != nil {
			return nil, err
		}
		b.Write(k)
		b.WriteByte(':')
		b.Write(v)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

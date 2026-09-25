package workflow

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Options は Validate が外部の実在を確かめるための場所。
type Options struct {
	// ScriptsDir は command の run が指すスクリプト（<ScriptsDir>/<run>.sh）の置き場。
	ScriptsDir string
	// AgentsDir は llm の agent が指すエージェント定義（<AgentsDir>/<名前>.md）の置き場。
	// 空なら ScriptsDir の隣の agents/（plugin/scripts に対する plugin/agents）。
	AgentsDir string
}

// AgentPlugin は llm の agent に書けるプラグインの名前空間（本リポジトリのプラグイン名）。
// `claude -p --agent claude-harness:<名前>` で主体に据えられることは PR-3 で実測した（§1.1）。
const AgentPlugin = "claude-harness"

// LoadAndValidate は読み込みと検証をまとめて行う。問題があれば Problems を返す。
func LoadAndValidate(path string, opts Options) (*Workflow, error) {
	wf, err := Load(path)
	if err != nil {
		return nil, err
	}
	if ps := Validate(wf, opts); len(ps) > 0 {
		return nil, ps
	}
	return wf, nil
}

type validator struct {
	wf       *Workflow
	opts     Options
	problems Problems
}

func (v *validator) errf(line int, format string, args ...any) {
	v.problems = append(v.problems, Problem{File: v.wf.Path, Line: line, Msg: fmt.Sprintf(format, args...)})
}

// Validate は §6.3 の検査項目を調べる: on が outcome enum を網羅すること・予約値との衝突・
// 参照先の存在と型・到達不能なステップ・limit の定義・run の参照先の実在。
// 加えて、数える遷移（limit・retry）もゲートも通らない循環を拒否する（止まらない run を作らないため）。
func Validate(wf *Workflow, opts Options) Problems {
	v := &validator{wf: wf, opts: opts}
	base := strings.TrimSuffix(filepath.Base(wf.Path), filepath.Ext(wf.Path))
	if wf.ID != base {
		v.errf(0, "id %q must equal the file name %q", wf.ID, base)
	}
	for _, s := range wf.Steps {
		v.stepKind(s)
	}
	v.budget()
	for _, s := range wf.Steps {
		v.onTable(s)
	}
	if len(v.problems) > 0 {
		// 参照・到達の検査は outcome と遷移先が確定していることを前提にする。
		return v.problems
	}
	g := buildGraph(wf)
	v.references(g)
	v.sessions(g)
	v.reachability(g)
	v.uncountedCycles()
	return v.problems
}

func (v *validator) stepKind(s *Step) {
	switch s.Kind {
	case "command":
		v.command(s)
	case "llm":
		v.llm(s)
	case "gate":
		v.gate(s)
	}
}

// budget は、llm ステップを持つワークフローが unit の累計予算（limits.budget_usd）を定義していることを確かめる
// （上限の無い累計は数えても止められない。§4.3）。
func (v *validator) budget() {
	hasLLM := false
	for _, s := range v.wf.Steps {
		if s.Kind == "llm" {
			hasLLM = true
		}
	}
	if !hasLLM {
		return
	}
	l := v.wf.Limit(BudgetLimit)
	if l == nil {
		v.errf(0, "limits.%s is required when the workflow has llm steps (the unit's total budget in USD; see §4.3)", BudgetLimit)
	} else if !(l.Value > 0) {
		v.errf(l.Line, "limits.%s must be a positive amount", BudgetLimit)
	}
}

func (v *validator) llm(s *Step) {
	if s.Prompt == "" {
		v.errf(s.Line, "steps.%s: prompt is required for kind llm", s.ID)
	} else if filepath.IsAbs(s.Prompt) || strings.HasPrefix(filepath.Clean(s.Prompt), "..") {
		v.errf(s.Line, "steps.%s: prompt %q must be a path inside the workflow directory", s.ID, s.Prompt)
	} else if fi, err := os.Stat(filepath.Join(v.wf.Dir, s.Prompt)); err != nil || !fi.Mode().IsRegular() {
		v.errf(s.Line, "steps.%s: prompt %q does not exist", s.ID, s.Prompt)
	}
	if s.Output == "" {
		v.errf(s.Line, "steps.%s: output is required for kind llm (the typed output and its outcome enum come from it)", s.ID)
	} else {
		v.outputSchema(s)
	}
	if !(s.BudgetUSD > 0) {
		v.errf(s.Line, "steps.%s: budget_usd is required for kind llm (the most one launch may spend)", s.ID)
	}
	if s.Agent != "" {
		v.agent(s)
	}
	if s.Session == "continue" {
		src := v.wf.Step(s.SessionFrom)
		switch {
		case src == nil:
			v.errf(s.Line, "steps.%s: session continue:%s refers to a step that does not exist", s.ID, s.SessionFrom)
		case src.Kind != "llm":
			v.errf(s.Line, "steps.%s: session continue:%s refers to a %s step; only llm steps have a Claude session", s.ID, s.SessionFrom, src.Kind)
		}
	}
	for _, o := range s.Outcomes() {
		if IsReserved(o) {
			v.errf(s.Line, "steps.%s: outcome %q collides with a reserved value (%s)", s.ID, o, strings.Join(ReservedOutcomes, ", "))
		}
	}
}

func (v *validator) agent(s *Step) {
	plugin, name, _ := strings.Cut(s.Agent, ":")
	if plugin != AgentPlugin {
		v.errf(s.Line, "steps.%s: agent %q: only agents of the %s plugin can be checked (write %s:<name>)", s.ID, s.Agent, AgentPlugin, AgentPlugin)
		return
	}
	dir := v.opts.AgentsDir
	if dir == "" && v.opts.ScriptsDir != "" {
		dir = filepath.Join(filepath.Dir(v.opts.ScriptsDir), "agents")
	}
	if dir == "" {
		v.errf(s.Line, "steps.%s: cannot check agent %q: agents directory is not set", s.ID, s.Agent)
		return
	}
	if fi, err := os.Stat(filepath.Join(dir, name+".md")); err != nil || !fi.Mode().IsRegular() {
		v.errf(s.Line, "steps.%s: agent %q does not exist (%s)", s.ID, s.Agent, filepath.Join(dir, name+".md"))
	}
}

func (v *validator) gate(s *Step) {
	switch s.Decider {
	case DeciderHuman, DeciderParent, DeciderAny:
	case "":
		v.errf(s.Line, "steps.%s: decider is required for kind gate (human, parent or any)", s.ID)
	default:
		v.errf(s.Line, "steps.%s: decider %q must be human, parent or any", s.ID, s.Decider)
	}
	if strings.TrimSpace(s.RequestedAction) == "" {
		v.errf(s.Line, "steps.%s: requested_action is required for kind gate (what the resolver is asked to do)", s.ID)
	}
	switch s.GateType {
	case GateInput:
		if len(s.GateInputs) == 0 {
			v.errf(s.Line, "steps.%s: an input gate needs inputs (the values resume accepts; each becomes the outcome)", s.ID)
		}
		if s.Observe != "" {
			v.errf(s.Line, "steps.%s: observe is only valid for type observe", s.ID)
		}
		if len(s.With) > 0 {
			v.errf(s.Line, "steps.%s: with is only valid for type observe (an input gate takes its value from resume)", s.ID)
		}
	case GateObserve:
		if len(s.GateInputs) > 0 {
			v.errf(s.Line, "steps.%s: inputs is only valid for type input (an observe gate takes its outcome from the observation, not from the resolver)", s.ID)
		}
		if s.Observe == "" {
			v.errf(s.Line, "steps.%s: an observe gate needs observe (the name of a registered observation)", s.ID)
		} else if _, ok := Observation(s.Observe); !ok {
			v.errf(s.Line, "steps.%s: observe %q is not a registered observation", s.ID, s.Observe)
		}
	case "":
		v.errf(s.Line, "steps.%s: type is required for kind gate (input or observe)", s.ID)
	default:
		v.errf(s.Line, "steps.%s: type %q must be input or observe", s.ID, s.GateType)
	}
	for _, o := range s.Outcomes() {
		if IsReserved(o) {
			v.errf(s.Line, "steps.%s: outcome %q collides with a reserved value (%s)", s.ID, o, strings.Join(ReservedOutcomes, ", "))
		}
	}
	for _, e := range s.On {
		if IsReserved(e.Outcome) {
			v.errf(e.Line, "steps.%s.on: a gate does not produce the reserved value %q", s.ID, e.Outcome)
		}
		if e.T.Kind == TRetry {
			v.errf(e.Line, "steps.%s.on.%s: retry is not valid on a gate (resolve the gate again instead)", s.ID, e.Outcome)
		}
	}
}

func (v *validator) command(s *Step) {
	if s.Run == "" {
		v.errf(s.Line, "steps.%s: run is required for kind command", s.ID)
	} else if v.opts.ScriptsDir == "" {
		v.errf(s.Line, "steps.%s: cannot check run %q: scripts directory is not set", s.ID, s.Run)
	} else if fi, err := os.Stat(filepath.Join(v.opts.ScriptsDir, s.Run+".sh")); err != nil || !fi.Mode().IsRegular() {
		v.errf(s.Line, "steps.%s: run %q does not exist (%s)", s.ID, s.Run, filepath.Join(v.opts.ScriptsDir, s.Run+".sh"))
	}
	if len(s.Exit) > 0 && s.OutcomeField != "" {
		v.errf(s.Line, "steps.%s: outcome comes from either exit or outcome_field, not both", s.ID)
	}
	if len(s.Exit) == 0 && s.Output == "" {
		v.errf(s.Line, "steps.%s: output is required (the outcome enum is taken from it) unless exit maps exit codes to outcomes", s.ID)
	}
	seenCode := map[int]bool{}
	for _, e := range s.Exit {
		if seenCode[e.Code] {
			v.errf(e.Line, "steps.%s.exit: duplicate exit code %d", s.ID, e.Code)
		}
		seenCode[e.Code] = true
	}
	if s.Output != "" {
		v.outputSchema(s)
	}
	for _, o := range s.Outcomes() {
		if IsReserved(o) {
			v.errf(s.Line, "steps.%s: outcome %q collides with a reserved value (%s)", s.ID, o, strings.Join(ReservedOutcomes, ", "))
		}
	}
}

func (v *validator) outputSchema(s *Step) {
	if filepath.IsAbs(s.Output) || strings.HasPrefix(filepath.Clean(s.Output), "..") {
		v.errf(s.Line, "steps.%s: output %q must be a path inside the workflow directory", s.ID, s.Output)
		return
	}
	sch, err := LoadOutputSchema(filepath.Join(v.wf.Dir, s.Output))
	if err != nil {
		v.errf(s.Line, "steps.%s: output: %v", s.ID, err)
		return
	}
	s.OutputSchema = sch
	if len(s.Exit) > 0 {
		return
	}
	field := s.OutcomeField
	if field == "" {
		field = "outcome"
	}
	enum, err := sch.outcomeEnum(field)
	if err != nil {
		v.errf(s.Line, "steps.%s: output %s: %v", s.ID, s.Output, err)
		return
	}
	sch.OutcomeEnum = enum
}

func (v *validator) onTable(s *Step) {
	outcomes := s.Outcomes()
	if outcomes == nil {
		return // output の読み込みで既に報告済み
	}
	known := map[string]bool{}
	for _, o := range outcomes {
		known[o] = true
	}
	for _, e := range s.On {
		if !known[e.Outcome] && !IsReserved(e.Outcome) {
			v.errf(e.Line, "steps.%s.on: %q is not an outcome of this step (outcomes: %s; reserved: %s). on maps outcome values to transitions by exact match only; there are no conditions",
				s.ID, e.Outcome, strings.Join(outcomes, ", "), strings.Join(ReservedOutcomes, ", "))
		}
		v.transition(s, e.Outcome, e.T)
	}
	for _, o := range outcomes {
		if s.OnFor(o) == nil {
			v.errf(s.Line, "steps.%s.on: outcome %q is not covered (every outcome value must have a transition)", s.ID, o)
		}
	}
}

func (v *validator) transition(s *Step, outcome string, t *Transition) {
	what := fmt.Sprintf("steps.%s.on.%s", s.ID, outcome)
	switch t.Kind {
	case TStep, TGoto:
		if v.wf.Step(t.Target) == nil {
			v.errf(t.Line, "%s: step %q does not exist", what, t.Target)
		}
	case TGate:
		target := v.wf.Step(t.Target)
		if target == nil {
			v.errf(t.Line, "%s: gate %q does not exist", what, t.Target)
		} else if target.Kind != "gate" {
			v.errf(t.Line, "%s: %q is a %s step, not a gate", what, t.Target, target.Kind)
		}
	case TRetry:
		// retry は同じステップを再実行する。
	}
	if t.Limit != "" {
		l := v.wf.Limit(t.Limit)
		if l == nil {
			v.errf(t.Line, "%s: limit %q is not defined in limits", what, t.Limit)
		} else if !l.Integer {
			v.errf(t.Line, "%s: limit %q must be an integer (it counts transitions)", what, t.Limit)
		}
	}
	if len(t.With) > 0 && t.Kind != TGoto {
		v.errf(t.Line, "%s: with is only valid on goto transitions", what)
	}
	if t.Exhausted != nil {
		v.transition(s, outcome+".exhausted", t.Exhausted)
	}
}

// --- 参照 -------------------------------------------------------------------

// edge は遷移のグラフの 1 辺。success は予約値以外の outcome による遷移（出力が検証済み）。
type edge struct {
	from, to string
	success  bool
	counted  bool // limit 付きの goto・retry の自己辺（数えられるので無限には回らない）
	t        *Transition
	outcome  string
}

type graph struct {
	entry string
	edges []edge
}

func buildGraph(wf *Workflow) *graph {
	g := &graph{entry: wf.Steps[0].ID}
	for _, s := range wf.Steps {
		for _, e := range s.On {
			g.add(s.ID, e.Outcome, e.T, false)
		}
	}
	return g
}

func (g *graph) add(from, outcome string, t *Transition, counted bool) {
	success := !IsReserved(outcome)
	switch t.Kind {
	case TStep, TGate:
		g.edges = append(g.edges, edge{from: from, to: t.Target, success: success, counted: counted, t: t, outcome: outcome})
	case TGoto:
		g.edges = append(g.edges, edge{from: from, to: t.Target, success: success, counted: counted || t.Limit != "", t: t, outcome: outcome})
	case TRetry:
		g.edges = append(g.edges, edge{from: from, to: from, success: success, counted: true, t: t, outcome: outcome})
	}
	if t.Exhausted != nil {
		g.add(from, outcome, t.Exhausted, counted)
	}
}

// reachable は entry から辿れるステップの集合。skip が真の辺は通らない。
func (g *graph) reachable(skip func(edge) bool) map[string]bool {
	seen := map[string]bool{g.entry: true}
	stack := []string{g.entry}
	for len(stack) > 0 {
		n := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		for _, e := range g.edges {
			if e.from != n || seen[e.to] || (skip != nil && skip(e)) {
				continue
			}
			seen[e.to] = true
			stack = append(stack, e.to)
		}
	}
	return seen
}

// guaranteed は「target に到達する前に、step が必ず 1 回以上成功している」かを返す。
// step の成功の辺を取り除いたグラフで target に届くなら、成功を経ない経路がある。
func (g *graph) guaranteed(step, target string) bool {
	r := g.reachable(func(e edge) bool { return e.from == step && e.success })
	return !r[target]
}

// incoming は target へ入る辺（retry の自己辺は除く。retry は同じ入力で再実行する）。
func (g *graph) incoming(target string) []edge {
	var out []edge
	for _, e := range g.edges {
		if e.to == target && !(e.t.Kind == TRetry) {
			out = append(out, e)
		}
	}
	return out
}

func (v *validator) references(g *graph) {
	for _, s := range v.wf.Steps {
		edgeNames := map[string]bool{}
		for _, b := range s.With {
			what := fmt.Sprintf("steps.%s.with.%s", s.ID, b.Name)
			t := v.valueType(g, b, what, s.ID, "", false)
			if b.Value.Ref != nil && b.Value.Ref.Kind == RefEdge {
				edgeNames[b.Value.Ref.Name] = true
			}
			if t != nil {
				v.acceptable(s, t, b.Line, what)
			}
		}
		for _, e := range s.On {
			v.transitionRefs(g, s, e.Outcome, e.T)
		}
		v.edgeSupply(g, s, edgeNames)
	}
}

func (v *validator) transitionRefs(g *graph, s *Step, outcome string, t *Transition) {
	for _, b := range t.With {
		what := fmt.Sprintf("steps.%s.on.%s.with.%s", s.ID, outcome, b.Name)
		v.valueType(g, b, what, s.ID, outcome, true)
		if r := b.Value.Ref; r != nil && r.Kind == RefInputs {
			if in := v.wf.Input(r.Name); in != nil && !in.Required {
				// 省略されうる値を遷移で渡すと、遷移先で値が無い経路ができる（null を文法に持ち込まない。§3.3）。
				v.errf(b.Line, "%s: %s is an optional input; only required inputs can be passed on a transition", what, r.Raw)
			}
		}
	}
	if t.Exhausted != nil {
		v.transitionRefs(g, s, outcome, t.Exhausted)
	}
}

// valueType は with の値の型を返す（参照なら参照先を検査する）。
// inTransition が真なら、値は遷移 s --outcome--> の with にある。
func (v *validator) valueType(g *graph, b *Binding, what, stepID, outcome string, inTransition bool) *Type {
	if b.Value.Ref == nil {
		switch b.Value.Literal.(type) {
		case int64:
			return &Type{Name: "integer"}
		default:
			return &Type{Name: "string"}
		}
	}
	r := b.Value.Ref
	switch r.Kind {
	case RefInputs:
		in := v.wf.Input(r.Name)
		if in == nil {
			v.errf(b.Line, "%s: %s refers to an input that is not declared", what, r.Raw)
			return nil
		}
		return in.Type
	case RefSteps:
		src := v.wf.Step(r.Step)
		if src == nil {
			v.errf(b.Line, "%s: %s refers to a step that does not exist", what, r.Raw)
			return nil
		}
		t, err := stepFieldType(src, r.Path)
		if err != nil {
			v.errf(b.Line, "%s: %s: %v", what, r.Raw, err)
			return nil
		}
		if inTransition && src.ID == stepID {
			if IsReserved(outcome) {
				v.errf(b.Line, "%s: %s: the step has no valid output when its outcome is the reserved value %q", what, r.Raw, outcome)
				return nil
			}
			return t
		}
		if !g.guaranteed(src.ID, stepID) {
			v.errf(b.Line, "%s: %s: step %q has not necessarily succeeded on every path that reaches %q; pass the value on the transition's with and read it as $edge.<name> (see §3.3)", what, r.Raw, src.ID, stepID)
			return nil
		}
		return t
	case RefEdge:
		if inTransition {
			v.errf(b.Line, "%s: %s: $edge values are only readable in the with of the step the transition leads to", what, r.Raw)
			return nil
		}
		return v.edgeType(g, stepID, r.Name, b.Line, what)
	case RefGate:
		if !inTransition {
			v.errf(b.Line, "%s: $gate.note is only valid in the with of a transition leaving an input gate (see §3.3)", what)
			return nil
		}
		if s := v.wf.Step(stepID); s.Kind == "gate" && s.GateType == GateInput {
			return &Type{Name: "string"}
		}
		v.errf(b.Line, "%s: $gate.note is only valid in the with of a transition leaving an input gate; step %q is not an input gate", what, stepID)
		return nil
	}
	return nil
}

// stepFieldType は $steps.<id>.<path> の型。.outcome はどの形でも「そのステップの outcome」を指す
// （exit 表や outcome_field で出力 JSON のフィールド名と outcome が一致しない場合も同じ意味にする）。
func stepFieldType(s *Step, path []string) (*Type, error) {
	if len(path) == 1 && path[0] == "outcome" {
		return &Type{Name: "string"}, nil
	}
	if s.OutputSchema == nil {
		return nil, fmt.Errorf("step %q has no output schema; only .outcome can be referenced", s.ID)
	}
	return s.OutputSchema.FieldType(path)
}

// edgeType は $edge.<name> の型。target へ入るすべての遷移がその名前を渡し、型が一致していなければならない。
func (v *validator) edgeType(g *graph, target, name string, line int, what string) *Type {
	if target == g.entry {
		v.errf(line, "%s: $edge.%s: the first step is entered without a transition, so it has no $edge values", what, name)
		return nil
	}
	var typ *Type
	for _, e := range g.incoming(target) {
		var supplied *Binding
		for _, b := range e.t.With {
			if b.Name == name {
				supplied = b
			}
		}
		if supplied == nil {
			v.errf(line, "%s: $edge.%s: the transition from step %q (outcome %q) to %q does not pass %q in its with", what, name, e.from, e.outcome, target, name)
			continue
		}
		t := v.typeOfSupplied(g, e, supplied)
		if t == nil {
			continue
		}
		if typ == nil {
			typ = t
		} else if !typ.Equal(t) {
			v.errf(line, "%s: $edge.%s: incoming transitions pass different types (%s and %s)", what, name, typ, t)
			return nil
		}
	}
	return typ
}

// typeOfSupplied は遷移の with が渡す値の型を、エラーを重複報告せずに求める（参照先の検査は transitionRefs が行う）。
func (v *validator) typeOfSupplied(g *graph, e edge, b *Binding) *Type {
	if b.Value.Ref == nil {
		if _, ok := b.Value.Literal.(int64); ok {
			return &Type{Name: "integer"}
		}
		return &Type{Name: "string"}
	}
	r := b.Value.Ref
	switch r.Kind {
	case RefInputs:
		if in := v.wf.Input(r.Name); in != nil {
			return in.Type
		}
	case RefSteps:
		if src := v.wf.Step(r.Step); src != nil {
			t, _ := stepFieldType(src, r.Path)
			return t
		}
	case RefGate:
		return &Type{Name: "string"}
	}
	return nil
}

// edgeSupply は、遷移の with が渡す値を遷移先が読んでいることを確かめる（渡したのに誰も読まない値を黙って捨てない）。
func (v *validator) edgeSupply(g *graph, s *Step, read map[string]bool) {
	for _, e := range g.incoming(s.ID) {
		for _, b := range e.t.With {
			if !read[b.Name] {
				v.errf(b.Line, "steps.%s.on.%s.with.%s: step %q does not read $edge.%s", e.from, e.outcome, b.Name, s.ID, b.Name)
			}
		}
	}
}

// acceptable は、種類がその型の値を受け取れるかを確かめる。command は argv（--<名前> <値>）へ写すので、
// スカラーとスカラーの配列（フラグの繰り返し）だけを受け取れる。
func (v *validator) acceptable(s *Step, t *Type, line int, what string) {
	switch s.Kind {
	case "command":
		if isScalar(t) || (t.Name == "array" && t.Items != nil && isScalar(t.Items)) {
			return
		}
		v.errf(line, "%s: kind command passes values as argv, so it accepts scalars and arrays of scalars, not %s", what, t)
	}
	// llm は with を JSON のデータブロックとして添付し（§3.3）、gate（observe）は観測へ JSON で渡すので、型を問わない。
}

func isScalar(t *Type) bool {
	switch t.Name {
	case "string", "integer", "number", "boolean":
		return true
	}
	return false
}

// sessions は、session: continue:<step> の <step> が、そのステップへ至るどの経路でも先に実行されていることを確かめる
// （引き継ぐセッションが無い経路を作らない）。<step> から出る辺をすべて取り除いたグラフで到達できるなら、経由しない経路がある。
func (v *validator) sessions(g *graph) {
	for _, s := range v.wf.Steps {
		if s.Kind != "llm" || s.Session != "continue" {
			continue
		}
		if src := v.wf.Step(s.SessionFrom); src == nil || src.Kind != "llm" {
			continue // stepKind が報告済み
		}
		r := g.reachable(func(e edge) bool { return e.from == s.SessionFrom })
		if r[s.ID] {
			v.errf(s.Line, "steps.%s: session continue:%s: step %q has not necessarily run on every path that reaches %q, so there may be no session to continue", s.ID, s.SessionFrom, s.SessionFrom, s.ID)
		}
	}
}

// --- グラフ -------------------------------------------------------------------

func (v *validator) reachability(g *graph) {
	r := g.reachable(nil)
	for _, s := range v.wf.Steps {
		if !r[s.ID] {
			v.errf(s.Line, "steps.%s is unreachable from the first step %q", s.ID, g.entry)
		}
	}
}

// uncountedCycles は、数えられない遷移だけでできた循環を拒否する（limit・retry・ゲートのどれも通らない循環は止まらない）。
func (v *validator) uncountedCycles() {
	g := buildGraph(v.wf)
	adj := map[string][]string{}
	for _, e := range g.edges {
		if e.counted {
			continue
		}
		if to := v.wf.Step(e.to); to != nil && to.Kind == "gate" {
			continue
		}
		adj[e.from] = append(adj[e.from], e.to)
	}
	const (
		white = iota
		grey
		black
	)
	color := map[string]int{}
	var stack []string
	var reported bool
	var visit func(n string)
	visit = func(n string) {
		color[n] = grey
		stack = append(stack, n)
		for _, m := range adj[n] {
			if reported {
				return
			}
			switch color[m] {
			case grey:
				i := len(stack) - 1
				for stack[i] != m {
					i--
				}
				cycle := append(append([]string{}, stack[i:]...), m)
				v.errf(v.wf.Step(m).Line, "steps form a cycle with no limit, retry or gate on it (%s); it would never stop", strings.Join(cycle, " -> "))
				reported = true
				return
			case white:
				visit(m)
			}
		}
		stack = stack[:len(stack)-1]
		color[n] = black
	}
	for _, s := range v.wf.Steps {
		if color[s.ID] == white && !reported {
			visit(s.ID)
		}
	}
}

package workflow

// 遷移の付け替え（docs/harness-runtime-overrides.md §5.2・§6.2。Issue #309 の段 2＝#313）。
//
// 元の定義はトップレベルの overridable.routes に「<ステップ id>.<outcome>: [候補のステップ id...]」を宣言し、上書きは
// steps.<id>.on.<outcome> に候補のどれか 1 つを書ける。外せないものはゲートの名前ではなく decider: human という性質と
// fail への遷移で決める（§6.2 の規則 1〜3）。付け替えでだけ到達できなくなったステップは誤りにせず SkippedSteps に出す
// （規則 5）。

import (
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

// RouteDecl は overridable.routes の 1 行（§5.2）。Candidates は上書きで書ける遷移先で、元の遷移先を含む。
type RouteDecl struct {
	Step       string
	Outcome    string
	Candidates []string
	Line       int
}

// Key は宣言のキー（<ステップ id>.<outcome>）。
func (d *RouteDecl) Key() string { return d.Step + "." + d.Outcome }

// Route は宣言のキーで overridable.routes の行を引く。無ければ nil。
func (w *Workflow) Route(step, outcome string) *RouteDecl {
	for _, d := range w.Routes {
		if d.Step == step && d.Outcome == outcome {
			return d
		}
	}
	return nil
}

// isHumanGate はステップが人のゲート（decider: human）かを返す。§6.2 の規則はゲートの名前ではなくこの性質で決める。
func isHumanGate(s *Step) bool {
	return s != nil && s.Kind == "gate" && s.Decider == DeciderHuman
}

// overridable は元の定義の overridable（いまは routes だけ）を読む。
func (p *parser) overridable(n *yaml.Node) []*RouteDecl {
	pairs, ok := p.mapping(n, "overridable")
	if !ok {
		return nil
	}
	p.allowKeys(pairs, "overridable", "routes")
	var out []*RouteDecl
	for _, pr := range pairs {
		if pr.key != "routes" {
			continue
		}
		routes, ok := p.mapping(pr.val, "overridable.routes")
		if !ok {
			continue
		}
		for _, r := range routes {
			what := "overridable.routes." + r.key
			step, outcome, found := strings.Cut(r.key, ".")
			if !found || !reStepID.MatchString(step) || !reOutcome.MatchString(outcome) {
				p.errf(r.knode, "overridable.routes: key %q must be <step id>.<outcome>", r.key)
				continue
			}
			cands := p.stepIDList(r.val, what)
			if cands == nil {
				continue
			}
			out = append(out, &RouteDecl{Step: step, Outcome: outcome, Candidates: cands, Line: r.knode.Line})
		}
	}
	return out
}

// stepIDList は遷移先の候補（ステップ id の空でない列）を読む。
func (p *parser) stepIDList(n *yaml.Node, what string) []string {
	if !p.plain(n, what) {
		return nil
	}
	if n.Kind != yaml.SequenceNode || len(n.Content) == 0 {
		p.errf(n, "%s must be a non-empty list of step ids (the destinations an override may choose)", what)
		return nil
	}
	var out []string
	seen := map[string]bool{}
	for _, it := range n.Content {
		if !p.plain(it, what) {
			return nil
		}
		id, ok := p.matched(it, what+" item (step id)", reStepID)
		if !ok {
			return nil
		}
		if seen[id] {
			p.errf(it, "%s: duplicate step id %q", what, id)
			return nil
		}
		seen[id] = true
		out = append(out, id)
	}
	return out
}

// routeDecls は元の定義の overridable.routes を検査する（§5.2・§6.2 の規則 1・2）。上書きを重ねた定義では呼ばない
// （宣言は元の定義と同じで、遷移先は付け替え後の値になっているため）。
func (v *validator) routeDecls() {
	for _, d := range v.wf.Routes {
		what := "overridable.routes." + d.Key()
		s := v.wf.Step(d.Step)
		if s == nil {
			v.errf(d.Line, "%s: step %q does not exist", what, d.Step)
			continue
		}
		if isHumanGate(s) {
			v.errf(d.Line, "%s: step %q is a human gate (decider: human); its transitions cannot be declared overridable (§6.2 rule 1)", what, d.Step)
			continue
		}
		t := s.OnFor(d.Outcome)
		if t == nil {
			v.errf(d.Line, "%s: step %q has no transition for outcome %q", what, d.Step, d.Outcome)
			continue
		}
		if reason := lockedTransition(v.wf, t); reason != "" {
			v.errf(d.Line, "%s: the transition %s; it cannot be declared overridable (§6.2 rule 2)", what, reason)
			continue
		}
		if t.Kind != TStep {
			v.errf(d.Line, "%s: only a transition written as a plain step id can be declared overridable (this one is a %s transition)", what, t.Kind)
			continue
		}
		hasOrig := false
		for _, c := range d.Candidates {
			if v.wf.Step(c) == nil {
				v.errf(d.Line, "%s: candidate step %q does not exist", what, c)
			}
			hasOrig = hasOrig || c == t.Target
		}
		if !hasOrig {
			v.errf(d.Line, "%s: the candidates must include the current destination %q (the value when no override is given)", what, t.Target)
		}
	}
}

// lockedTransition は遷移が §6.2 の規則 2 で付け替えられないものなら、その理由を返す（人のゲートへ向かう・fail で終わる）。
func lockedTransition(wf *Workflow, t *Transition) string {
	switch t.Kind {
	case TFail:
		return fmt.Sprintf("ends the run as failed (fail: %s)", t.Reason)
	case TStep, TGate, TGoto:
		if isHumanGate(wf.Step(t.Target)) {
			return fmt.Sprintf("leads to the human gate %q (decider: human)", t.Target)
		}
	}
	return ""
}

// overrideRoutes は上書きの steps.<id>.on を読む（§4.1・§5.2）。書けるのは元の定義が宣言した遷移だけで、値は候補の
// ステップ id 1 つ。
func (p *parser) overrideRoutes(ov *Override, s *Step, n *yaml.Node, what string, base *Workflow) {
	pairs, ok := p.mapping(n, what)
	if !ok {
		return
	}
	for _, pr := range pairs {
		fw := what + "." + pr.key
		d := base.Route(s.ID, pr.key)
		if d == nil {
			if t := s.OnFor(pr.key); t != nil {
				if reason := lockedTransition(base, t); reason != "" {
					p.errf(pr.knode, "%s cannot be overridden: the transition %s (§6.2 rule 2)", fw, reason)
					continue
				}
			}
			p.errf(pr.knode, "%s cannot be overridden: workflow %s does not declare %s.%s in overridable.routes (declared: %s)", fw, base.ID, s.ID, pr.key, declaredRoutes(base))
			continue
		}
		v := pr.val
		if v.Kind != yaml.ScalarNode || v.Tag != "!!str" {
			p.errf(v, "%s must be one step id (goto, gate, fail and done forms cannot be written in an override)", fw)
			continue
		}
		if strings.HasPrefix(v.Value, "$") {
			p.errf(v, "%s: %q is a reference; an override value is a literal", fw, v.Value)
			continue
		}
		if !contains(d.Candidates, v.Value) {
			p.errf(v, "%s: %q is not one of the declared candidates (%s)", fw, v.Value, strings.Join(d.Candidates, ", "))
			continue
		}
		ov.sets = append(ov.sets, overrideSet{key: fw, step: s.ID, field: "on", outcome: pr.key, target: v.Value})
	}
}

func declaredRoutes(wf *Workflow) string {
	if len(wf.Routes) == 0 {
		return "none"
	}
	keys := make([]string, len(wf.Routes))
	for i, d := range wf.Routes {
		keys[i] = d.Key()
	}
	return strings.Join(keys, ", ")
}

// skippedSteps は上書きを重ねた定義で開始ステップから到達できなくなったステップを宣言順に返す（§6.2 の規則 3・5）。
// 元の定義は検査済み（すべて到達できる）なので、到達できないステップは付け替えでだけ到達できなくなったものである。
// そのうち人のゲートは規則 3 の違反として problems に返す。
func skippedSteps(wf *Workflow) ([]string, Problems) {
	if len(wf.Steps) == 0 {
		return nil, nil
	}
	r := buildGraph(wf).reachable(nil)
	var skipped []string
	var problems Problems
	for _, s := range wf.Steps {
		if r[s.ID] {
			continue
		}
		if isHumanGate(s) {
			problems = append(problems, Problem{File: wf.Path, Line: s.Line, Msg: fmt.Sprintf(
				"steps.%s: the overrides make the human gate %q (decider: human) unreachable from the first step %q; a human gate cannot be bypassed by an override (§6.2 rule 3)", s.ID, s.ID, wf.Steps[0].ID)})
			continue
		}
		skipped = append(skipped, s.ID)
	}
	return skipped, problems
}

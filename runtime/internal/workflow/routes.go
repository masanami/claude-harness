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

// overridable は元の定義の overridable（routes と skips）を読む。skips は wf に入れ、routes の宣言を返す。
func (p *parser) overridable(n *yaml.Node, wf *Workflow) []*RouteDecl {
	pairs, ok := p.mapping(n, "overridable")
	if !ok {
		return nil
	}
	p.allowKeys(pairs, "overridable", "routes", "skips")
	var out []*RouteDecl
	for _, pr := range pairs {
		if pr.key == "skips" {
			if ids := p.stepIDList(pr.val, "overridable.skips"); ids != nil {
				wf.Skips, wf.SkipsLine = ids, pr.knode.Line
			}
			continue
		}
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

// --- 規則 6: 守るステップを付け替えで迂回できない（§6.2。#322） ----------------------------------------------------------

// guardReason は、ステップが §6.2 の規則 6 で守るステップならその理由を返す。守るのは人のゲート・人のゲートへ入る遷移を
// 持つステップ・fail へ入る遷移を持つステップ（limit・retry を使い切ったときの exhausted も含む）。liftable は
// overridable.skips で守りを外せるか（fail へ入る遷移だけを理由に守るステップに限る。人のゲートとそこへ入るステップは外せない）。
func guardReason(wf *Workflow, s *Step) (reason string, liftable bool) {
	if isHumanGate(s) {
		return "is a human gate (decider: human)", false
	}
	human, fail := "", ""
	for _, e := range s.On {
		eachTransition(e.T, func(t *Transition) {
			switch t.Kind {
			case TStep, TGate, TGoto:
				if human == "" && isHumanGate(wf.Step(t.Target)) {
					human = t.Target
				}
			case TFail:
				if fail == "" {
					fail = t.Reason
				}
			}
		})
	}
	if human != "" {
		return fmt.Sprintf("leads to the human gate %q", human), false
	}
	if fail != "" {
		return fmt.Sprintf("can end the run as failed (fail: %s)", fail), true
	}
	return "", false
}

// eachTransition は遷移と、その exhausted の連なりを順に f へ渡す。
func eachTransition(t *Transition, f func(*Transition)) {
	for ; t != nil; t = t.Exhausted {
		f(t)
	}
}

// domGraph は支配の検査に使う遷移のグラフ。節点はステップ id と終端（"done: <理由>"・"fail: <理由>"）。
type domGraph struct {
	entry string
	adj   map[string][]string
	nodes []string // ステップの宣言順、その後に終端を現れた順
}

// newDomGraph は wf の遷移のグラフを作る。swap は "<ステップ id>.<outcome>" → 遷移先のステップ id で、宣言の時点の検査が
// 候補を 1 つずつ当てるときに使う（付け替えられるのはステップ id で書いた遷移だけ。§5.2）。
func newDomGraph(wf *Workflow, swap map[string]string) *domGraph {
	g := &domGraph{entry: wf.Steps[0].ID, adj: map[string][]string{}}
	seen := map[string]bool{}
	add := func(n string) {
		if !seen[n] {
			seen[n] = true
			g.nodes = append(g.nodes, n)
		}
	}
	for _, s := range wf.Steps {
		add(s.ID)
	}
	for _, s := range wf.Steps {
		for _, e := range s.On {
			if to, ok := swap[s.ID+"."+e.Outcome]; ok && e.T.Kind == TStep {
				g.adj[s.ID] = append(g.adj[s.ID], to)
				continue
			}
			eachTransition(e.T, func(t *Transition) {
				switch t.Kind {
				case TStep, TGate, TGoto:
					g.adj[s.ID] = append(g.adj[s.ID], t.Target)
				case TDone, TFail:
					n := string(t.Kind) + ": " + t.Reason
					add(n)
					g.adj[s.ID] = append(g.adj[s.ID], n)
				}
			})
		}
	}
	return g
}

// reach は entry から辿れる節点の集合。without の節点には入らない（without が entry なら空）。
func (g *domGraph) reach(without string) map[string]bool {
	r := map[string]bool{}
	if g.entry == without {
		return r
	}
	r[g.entry] = true
	stack := []string{g.entry}
	for len(stack) > 0 {
		n := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		for _, m := range g.adj[n] {
			if m == without || r[m] {
				continue
			}
			r[m] = true
			stack = append(stack, m)
		}
	}
	return r
}

// bypass は規則 6 の違反 1 件: 元の定義では guard を通らずに辿り着けなかった節点（reached）に、付け替えの後は guard を
// 通らずに辿り着ける。
type bypass struct {
	guard, reason string
	liftable      bool
	reached       []string
}

// bypassedGuards は base（元の定義。守るステップと overridable.skips はここから決める）のグラフ bg と、付け替えた後の
// グラフ eg を比べ、元の定義で守るステップ P が D を支配していた（entry から D へのすべての経路が P を通った）のに、
// 付け替えの後は P を通らずに D へ辿り着ける組を、P の宣言順に返す。到達できなくなった D は省略（規則 5）なので問わない。
// overridable.skips に挙げたステップ（fail へ入る遷移だけを理由に守るもの）は問わない。
func bypassedGuards(base *Workflow, bg, eg *domGraph) []bypass {
	bAll, eAll := bg.reach(""), eg.reach("")
	var out []bypass
	for _, s := range base.Steps {
		reason, liftable := guardReason(base, s)
		if reason == "" || (liftable && contains(base.Skips, s.ID)) {
			continue
		}
		bWithout, eWithout := bg.reach(s.ID), eg.reach(s.ID)
		var reached []string
		for _, d := range bg.nodes {
			if d != s.ID && bAll[d] && !bWithout[d] && eAll[d] && eWithout[d] {
				reached = append(reached, d)
			}
		}
		if len(reached) > 0 {
			out = append(out, bypass{guard: s.ID, reason: reason, liftable: liftable, reached: reached})
		}
	}
	return out
}

func (b bypass) reachedText() string {
	const shown = 3
	names := make([]string, 0, shown)
	for i, d := range b.reached {
		if i == shown {
			names = append(names, fmt.Sprintf("and %d more", len(b.reached)-shown))
			break
		}
		names = append(names, d)
	}
	return strings.Join(names, ", ")
}

func (b bypass) hint() string {
	if b.liftable {
		return "; to allow skipping it, list it in overridable.skips of the workflow"
	}
	return ""
}

// bypassProblems は上書きを重ねた定義 eff に規則 6 を課す（付け替えの組み合わせをまとめて検査する）。
func bypassProblems(base, eff *Workflow) Problems {
	if len(base.Steps) == 0 {
		return nil
	}
	var problems Problems
	for _, b := range bypassedGuards(base, newDomGraph(base, nil), newDomGraph(eff, nil)) {
		problems = append(problems, Problem{File: eff.Path, Line: base.Step(b.guard).Line, Msg: fmt.Sprintf(
			"steps.%s: the overrides let the run reach %s without passing %q, which every path took in the original definition; step %q %s, so an override cannot bypass it (§6.2 rule 6)%s",
			b.guard, b.reachedText(), b.guard, b.guard, b.reason, b.hint())})
	}
	return problems
}

// skipDecls は元の定義の overridable.skips を検査する（§6.2 の規則 6）。挙げられるのは、fail へ入る遷移だけを理由に守る
// ステップに限る。
func (v *validator) skipDecls() {
	for _, id := range v.wf.Skips {
		what := "overridable.skips"
		s := v.wf.Step(id)
		if s == nil {
			v.errf(v.wf.SkipsLine, "%s: step %q does not exist", what, id)
			continue
		}
		reason, liftable := guardReason(v.wf, s)
		switch {
		case reason == "":
			v.errf(v.wf.SkipsLine, "%s: step %q neither leads to a human gate nor can end the run as failed, so an override may skip it without being listed; list only steps that can end the run as failed (§6.2 rule 6)", what, id)
		case !liftable:
			v.errf(v.wf.SkipsLine, "%s: step %q %s; a human gate and a step that leads to one can never be skipped by an override (§6.2 rule 6)", what, id, reason)
		}
	}
}

// candidateBypasses は宣言の時点の規則 6: overridable.routes の候補を 1 つずつ当て、それだけで守るステップを迂回する候補を
// 拒否する（組み合わせは上書きを重ねた時点の bypassProblems が検査する）。
func (v *validator) candidateBypasses() {
	if len(v.wf.Steps) == 0 {
		return
	}
	bg := newDomGraph(v.wf, nil)
	for _, d := range v.wf.Routes {
		t := v.wf.Step(d.Step).OnFor(d.Outcome)
		for _, c := range d.Candidates {
			if c == t.Target {
				continue
			}
			bs := bypassedGuards(v.wf, bg, newDomGraph(v.wf, map[string]string{d.Key(): c}))
			if len(bs) == 0 {
				continue
			}
			b := bs[0]
			v.errf(d.Line, "overridable.routes.%s: candidate %q would let the run reach %s without passing %q, which every path takes in the original definition; step %q %s, so an override cannot bypass it (§6.2 rule 6)%s",
				d.Key(), c, b.reachedText(), b.guard, b.guard, b.reason, b.hint())
		}
	}
}

package workflow

import "fmt"

// 入れる段（pull-request の action: land）の検査（docs/harness-runtime-overrides.md §6.2 の規則 7 のうち、元の定義の検査）。
//
// 通した中身の識別（approved_ref）は、ゲートの解決（$gate.approved_ref）からしか入れる段へ届かない:
//   - 入れる段の with.approved_ref は $edge.<名前> でなければならず、入れる段へ入るすべての遷移は、その名前を $gate.approved_ref で渡す
//   - $gate.approved_ref を渡せる先は、入れる段の with.approved_ref だけ
//
// 段の名前は書かず、種類と action で決める。
func (v *validator) landRules(g *graph) {
	reads := map[string]string{} // 入れる段の id → with.approved_ref が読む $edge の名前
	for _, s := range v.wf.Steps {
		if !IsLandStep(s) {
			continue
		}
		var b *Binding
		for _, x := range s.With {
			if x.Name == "approved_ref" {
				b = x
			}
		}
		if b == nil {
			continue // 必須の with の検査が報告済み
		}
		if r := b.Value.Ref; r == nil || r.Kind != RefEdge {
			v.errf(b.Line, "steps.%s.with.approved_ref: a step that lands the pull request must read it as $edge.<name>, passed by a transition leaving an input gate as $gate.approved_ref (§6.2 rule 7)", s.ID)
			continue
		}
		reads[s.ID] = b.Value.Ref.Name
		for _, e := range g.incoming(s.ID) {
			ok := false
			for _, x := range e.t.With {
				if x.Name == b.Value.Ref.Name && x.Value.Ref != nil && x.Value.Ref.Kind == RefGate && x.Value.Ref.Name == GateApprovedRef {
					ok = true
				}
			}
			if !ok {
				v.errf(e.t.Line, "steps.%s.on.%s: the transition into %q (a step that lands the pull request) must pass %s as $gate.approved_ref in its with; the identity of the approved content reaches it only from the resolution of a gate (§6.2 rule 7)", e.from, e.outcome, s.ID, b.Value.Ref.Name)
			}
		}
	}
	for _, s := range v.wf.Steps {
		for _, en := range s.On {
			eachTransition(en.T, func(t *Transition) {
				for _, b := range t.With {
					r := b.Value.Ref
					if r == nil || r.Kind != RefGate || r.Name != GateApprovedRef {
						continue
					}
					target := v.wf.Step(t.Target)
					if t.Kind != TGoto || !IsLandStep(target) || reads[t.Target] != b.Name {
						v.errf(b.Line, "steps.%s.on.%s.with.%s: $gate.approved_ref can be passed only to the with.approved_ref of a step that lands the pull request (pull-request action: land), read there as $edge.%s (§6.2 rule 7)", s.ID, en.Outcome, b.Name, b.Name)
					}
				}
			})
		}
	}
}

// landLocked は、遷移が §6.2 の規則 7 で付け替えられないものなら、その理由を返す（入れる段から出る遷移・
// $gate.approved_ref を渡す遷移）。
func landLocked(from *Step, t *Transition) string {
	if IsLandStep(from) {
		return fmt.Sprintf("leaves step %q, which lands the pull request (pull-request action: land)", from.ID)
	}
	for _, b := range t.With {
		if r := b.Value.Ref; r != nil && r.Kind == RefGate && r.Name == GateApprovedRef {
			return "passes $gate.approved_ref to a step that lands the pull request"
		}
	}
	return ""
}

// branchGuardLocked は、遷移が §6.2 の規則 8 で付け替えられないものなら、その理由を返す（origin のブランチを作る・消す・PR を作る段
// （ensure-base・open・retire）から出る遷移と、そこへ入る遷移）。
func branchGuardLocked(wf *Workflow, from *Step, t *Transition) string {
	if IsBranchGuardStep(from) {
		return fmt.Sprintf("leaves step %q, which creates or deletes a branch or opens a pull request (pull-request action: %s)", from.ID, from.Action)
	}
	switch t.Kind {
	case TStep, TGate, TGoto:
		if target := wf.Step(t.Target); IsBranchGuardStep(target) {
			return fmt.Sprintf("leads to step %q, which creates or deletes a branch or opens a pull request (pull-request action: %s)", target.ID, target.Action)
		}
	}
	return ""
}

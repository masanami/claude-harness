package workflow

import (
	"strings"
	"testing"
)

// 遷移の付け替え（docs/harness-runtime-overrides.md §5.2・§6.2。#313）: overridable.routes の宣言の検査、上書きでの
// 付け替え、外せないゲート（decider: human・fail への遷移）、付け替えで到達できなくなったステップ（skipped_steps）。

// ticket.yaml が宣言するのは保守側の 2 行だけ（O2）。
func TestTicketDeclaresOnlyTwoRoutes(t *testing.T) {
	wf, err := loadTicket(t)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, d := range wf.Routes {
		got = append(got, d.Key()+": "+strings.Join(d.Candidates, ","))
	}
	want := "merge-route.integration: merge,human-merge | e2e-route.no: publish,e2e"
	if strings.Join(got, " | ") != want {
		t.Fatalf("routes = %q, want %q", strings.Join(got, " | "), want)
	}
}

// 統合ブランチ宛も人のマージにすると、merge（/pr-merge）は到達できなくなり、誤りにせず skipped_steps に出る。
func TestOverrideRouteToHumanMerge(t *testing.T) {
	orig, err := loadTicket(t)
	if err != nil {
		t.Fatal(err)
	}
	wf, err := loadTicket(t, ov(LayerRepo, "steps: { merge-route: { on: { integration: human-merge } } }\n"))
	if err != nil {
		t.Fatal(err)
	}
	if tr := wf.Step("merge-route").OnFor("integration"); tr.Kind != TStep || tr.Target != "human-merge" {
		t.Fatalf("merge-route.integration = %+v", tr)
	}
	if tr := orig.Step("merge-route").OnFor("integration"); tr.Target != "merge" {
		t.Fatalf("the original definition must not change: %+v", tr)
	}
	if got, want := changesJSON(t, wf.Changes), `[{"key":"steps.merge-route.on.integration","from":"merge","to":"human-merge","layer":"repo"}]`; got != want {
		t.Fatalf("changes = %s, want %s", got, want)
	}
	if strings.Join(wf.SkippedSteps, ",") != "merge" {
		t.Fatalf("skipped_steps = %v, want [merge]", wf.SkippedSteps)
	}
	if wf.Hash != orig.Hash || wf.EffectiveHash == "" {
		t.Fatalf("hash %s (orig %s) effective %q", wf.Hash, orig.Hash, wf.EffectiveHash)
	}
}

// E2E 不要の判断でも E2E を書く付け替えは、どのステップも到達できなくしない。数値の上書きと同じファイルに書ける。
func TestOverrideRouteToE2E(t *testing.T) {
	wf, err := loadTicket(t, ov(LayerArg, "limits: { budget_usd: 50 }\nsteps:\n  e2e-route: { on: { no: e2e } }\n"))
	if err != nil {
		t.Fatal(err)
	}
	if wf.Step("e2e-route").OnFor("no").Target != "e2e" || wf.SkippedSteps != nil {
		t.Fatalf("e2e-route.no = %+v skipped %v", wf.Step("e2e-route").OnFor("no"), wf.SkippedSteps)
	}
	if got, want := changesJSON(t, wf.Changes), `[{"key":"limits.budget_usd","from":40,"to":50,"layer":"arg"},{"key":"steps.e2e-route.on.no","from":"publish","to":"e2e","layer":"arg"}]`; got != want {
		t.Fatalf("changes = %s, want %s", got, want)
	}
}

// 層が重なれば後ろの層が勝つ。元の遷移先へ戻す上書きも書ける（そのときは到達できなくなるステップが無い）。
func TestOverrideRouteLayers(t *testing.T) {
	wf, err := loadTicket(t,
		ov(LayerRepo, "steps: { merge-route: { on: { integration: human-merge } } }\n"),
		ov(LayerArg, "steps: { merge-route: { on: { integration: merge } } }\n"))
	if err != nil {
		t.Fatal(err)
	}
	if wf.Step("merge-route").OnFor("integration").Target != "merge" || wf.SkippedSteps != nil {
		t.Fatalf("integration = %+v skipped %v", wf.Step("merge-route").OnFor("integration"), wf.SkippedSteps)
	}
	if got, want := changesJSON(t, wf.Changes), `[{"key":"steps.merge-route.on.integration","from":"merge","to":"merge","layer":"arg"}]`; got != want {
		t.Fatalf("changes = %s, want %s", got, want)
	}
}

// 宣言の無い遷移・候補外の値・ステップ id 以外の値・人のゲート（規則 1）・人のゲートと fail へ向かう遷移（規則 2）は
// 上書きに書けない。ゲートの名前ではなく decider: human と fail への遷移で決まる。
func TestOverrideRouteRejects(t *testing.T) {
	cases := []struct{ name, body, want string }{
		{"undeclared", "steps: { ci: { on: { green: merge-route } } }\n",
			"steps.ci.on.green cannot be overridden: workflow ticket does not declare ci.green in overridable.routes (declared: merge-route.integration, e2e-route.no)"},
		{"not a candidate", "steps: { merge-route: { on: { integration: cleanup } } }\n",
			`steps.merge-route.on.integration: "cleanup" is not one of the declared candidates (merge, human-merge)`},
		{"undeclared outcome of a declared step", "steps: { e2e-route: { on: { yes: publish } } }\n",
			"steps.e2e-route.on.yes cannot be overridden: workflow ticket does not declare e2e-route.yes"},
		{"fail form", "steps: { merge-route: { on: { integration: { fail: x } } } }\n",
			"steps.merge-route.on.integration must be one step id"},
		{"goto form", "steps: { merge-route: { on: { integration: { goto: merge } } } }\n",
			"steps.merge-route.on.integration must be one step id"},
		{"reference", "steps: { merge-route: { on: { integration: $steps.resolve.base } } }\n",
			"is a reference; an override value is a literal"},
		{"rule 1: human gate", "steps: { human-merge: { on: { open: cleanup } } }\n",
			"steps.human-merge is a human gate (decider: human); none of its keys can be overridden (§6.2 rule 1)"},
		{"rule 1: input human gate", "steps: { design-deviation: { on: { abort: fix } } }\n",
			"steps.design-deviation is a human gate (decider: human)"},
		{"rule 2: to a human gate", "steps: { merge-route: { on: { default: merge } } }\n",
			`steps.merge-route.on.default cannot be overridden: the transition leads to the human gate "human-merge" (decider: human) (§6.2 rule 2)`},
		{"rule 2: gate form to a human gate", "steps: { respond: { on: { needs_human: review } } }\n",
			`steps.respond.on.needs_human cannot be overridden: the transition leads to the human gate "review-human"`},
		{"rule 2: fail", "steps: { implement: { on: { review_incomplete: commit } } }\n",
			"steps.implement.on.review_incomplete cannot be overridden: the transition ends the run as failed (fail: self_review_incomplete) (§6.2 rule 2)"},
		{"on is a mapping", "steps: { merge-route: { on: human-merge } }\n",
			"steps.merge-route.on must be a mapping"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadTicket(t, ov(LayerArg, c.body))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
}

// routesBase は宣言を確かめる定義: a → b → c（b は人のゲート h を経て c へ）、a.bad は fail。
// a.ok は [b, c] を候補に宣言している。
const routesBase = `schema: harness.workflow/v1
id: r
limits:
  rework: 2
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: b
      bad: { fail: bad }
  b:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: c
      bad: { gate: h }
  h:
    kind: gate
    type: input
    decider: human
    requested_action: decide
    inputs: [go]
    on: { go: c }
  c:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: { done: ok }
      bad: { goto: a, limit: rework, exhausted: { fail: exhausted } }
`

func withRoutes(routes string) string {
	return strings.Replace(routesBase, "steps:\n", "overridable:\n  routes:\n"+routes+"steps:\n", 1)
}

func loadRoutes(t *testing.T, yaml string, overrides ...string) (*Workflow, error) {
	t.Helper()
	path, scripts := setup(t, "r", yaml)
	var srcs []OverrideSource
	for i, body := range overrides {
		srcs = append(srcs, OverrideSource{Layer: []string{LayerRepo, LayerArg}[i], Path: "/ov/" + string(rune('1'+i)) + ".yaml",
			Data: []byte("schema: harness.workflow-override/v1\nworkflow: r\n" + body)})
	}
	return LoadWithOverrides(path, Options{ScriptsDir: scripts}, srcs)
}

// 宣言そのものの検査（元の定義の validate）: 規則 1・2 に当たる宣言、元の遷移先を含まない候補、無いステップ・outcome、
// ステップ id 以外の形の遷移は拒否する。
func TestRouteDeclarationRejects(t *testing.T) {
	cases := []struct{ name, yaml, want string }{
		{"rule 1: from a human gate", withRoutes("    h.go: [c, a]\n"),
			`overridable.routes.h.go: step "h" is a human gate (decider: human); its transitions cannot be declared overridable (§6.2 rule 1)`},
		{"rule 2: gate form to a human gate", withRoutes("    b.bad: [h, c]\n"),
			`overridable.routes.b.bad: the transition leads to the human gate "h" (decider: human); it cannot be declared overridable (§6.2 rule 2)`},
		{"rule 2: plain id to a human gate", strings.Replace(withRoutes("    b.bad: [h, c]\n"), "bad: { gate: h }", "bad: h", 1),
			`the transition leads to the human gate "h"`},
		{"rule 2: fail", withRoutes("    a.bad: [b]\n"),
			"overridable.routes.a.bad: the transition ends the run as failed (fail: bad); it cannot be declared overridable (§6.2 rule 2)"},
		{"current destination missing", withRoutes("    a.ok: [c]\n"),
			`overridable.routes.a.ok: the candidates must include the current destination "b"`},
		{"unknown candidate", withRoutes("    a.ok: [b, zz]\n"), `candidate step "zz" does not exist`},
		{"unknown step", withRoutes("    zz.ok: [b]\n"), `overridable.routes.zz.ok: step "zz" does not exist`},
		{"unknown outcome", withRoutes("    a.maybe: [b]\n"), `step "a" has no transition for outcome "maybe"`},
		{"goto form", withRoutes("    c.bad: [a, b]\n"), "only a transition written as a plain step id can be declared overridable (this one is a goto transition)"},
		{"key without outcome", withRoutes("    a: [b]\n"), `overridable.routes: key "a" must be <step id>.<outcome>`},
		{"empty candidates", withRoutes("    a.ok: []\n"), "overridable.routes.a.ok must be a non-empty list of step ids"},
		{"duplicate candidate", withRoutes("    a.ok: [b, b]\n"), `duplicate step id "b"`},
		{"unknown key", strings.Replace(routesBase, "steps:\n", "overridable:\n  steps: {}\nsteps:\n", 1), `overridable: unknown key "steps" (allowed: routes, skips)`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadRoutes(t, c.yaml)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
	if _, err := loadRoutes(t, withRoutes("    b.ok: [c, h]\n")); err != nil {
		t.Fatalf("a valid declaration: %v", err)
	}
}

// 規則 3: 付け替えで人のゲートが到達できなくなる上書きは、ゲートの名前に依らず拒否する（a.ok を c へ付け替えると、
// b と、b からだけ入る人のゲート h が到達できなくなる）。c へは a.bad からも入るので、b が支配していたのは h だけで、
// 規則 6 には当たらない（到達できなくなった節点は規則 6 で問わない）。
func TestOverrideRouteKeepsHumanGatesReachable(t *testing.T) {
	yaml := strings.Replace(withRoutes("    a.ok: [b, c]\n"), "      bad: { fail: bad }\n", "      bad: c\n", 1)
	_, err := loadRoutes(t, yaml, "steps: { a: { on: { ok: c } } }\n")
	want := `steps.h: the overrides make the human gate "h" (decider: human) unreachable from the first step "a"; a human gate cannot be bypassed by an override (§6.2 rule 3)`
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("err = %v, want %q", err, want)
	}
}

// 規則 4・5: 付け替えで到達できなくなったステップ（下流も含む）は skipped_steps になり、到達できなくなったステップの
// 出力を読むステップが残れば通常の検査（guaranteed）で落ちる。
func TestOverrideRouteSkippedAndReferences(t *testing.T) {
	// h を人のゲートでなくすと、a.ok を c へ付け替えたときに b と h が skipped になる。
	yaml := strings.Replace(withRoutes("    a.ok: [b, c]\n"), "decider: human", "decider: any", 1)
	wf, err := loadRoutes(t, yaml, "steps: { a: { on: { ok: c } } }\n")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(wf.SkippedSteps, ",") != "b,h" {
		t.Fatalf("skipped_steps = %v, want [b h]", wf.SkippedSteps)
	}
	// 付け替えの無い元の定義では、到達できないステップは従来どおり誤り。
	unreachable := strings.Replace(routesBase, "      ok: b\n", "      ok: c\n", 1)
	if _, err := loadRoutes(t, strings.Replace(unreachable, "decider: human", "decider: any", 1)); err == nil || !strings.Contains(err.Error(), "steps.b is unreachable") {
		t.Fatalf("err = %v", err)
	}
	// c が b の出力を読むなら、b を飛ばす付け替えは参照の検査で落ちる。
	reads := strings.Replace(yaml, "  c:\n    kind: command\n    run: tool\n", "  c:\n    kind: command\n    run: tool\n    with: { v: $steps.b.detail.name }\n", 1)
	if _, err := loadRoutes(t, reads); err != nil {
		t.Fatalf("without the override: %v", err)
	}
	if _, err := loadRoutes(t, reads, "steps: { a: { on: { ok: c } } }\n"); err == nil || !strings.Contains(err.Error(), `step "b" has not necessarily succeeded`) {
		t.Fatalf("err = %v", err)
	}
}

// 人のゲートへ向かう付け替え（保守側）は、どのステップも到達できなくしなくても通る（付け替え後の遷移先が人のゲートでも、
// 宣言の検査は元の定義の遷移先で行う）。
func TestOverrideRouteToHumanGateWithoutSkipping(t *testing.T) {
	wf, err := loadRoutes(t, withRoutes("    b.ok: [c, h]\n"), "steps: { b: { on: { ok: h } } }\n")
	if err != nil {
		t.Fatal(err)
	}
	if wf.Step("b").OnFor("ok").Target != "h" || wf.SkippedSteps != nil {
		t.Fatalf("b.ok = %+v skipped %v", wf.Step("b").OnFor("ok"), wf.SkippedSteps)
	}
}

// 宣言の無い定義では、どの遷移も付け替えられない。
func TestOverrideRouteWithoutDeclarations(t *testing.T) {
	_, err := loadRoutes(t, routesBase, "steps: { a: { on: { ok: c } } }\n")
	if err == nil || !strings.Contains(err.Error(), "does not declare a.ok in overridable.routes (declared: none)") {
		t.Fatalf("err = %v", err)
	}
}

// 遷移の付け替えを含む上書き後の定義のハッシュの固定値（override_test.go の TestEffectiveHashGolden と同じ理由）。
func TestEffectiveHashGoldenWithRoute(t *testing.T) {
	yaml := strings.Replace(withRoutes("    a.ok: [b, c]\n"), "decider: human", "decider: any", 1)
	wf, err := loadRoutes(t, yaml, "limits: { rework: 1 }\nsteps: { a: { on: { ok: c } } }\n")
	if err != nil {
		t.Fatal(err)
	}
	const want = "f5afff3c124d6375dbff96787f7a40282bd4f847bc39cef190203b6f5a6a52e6"
	if wf.EffectiveHash != want {
		t.Fatalf("effective hash = %s, want %s (the normalization changed; bump effectiveSchema if that is intended)", wf.EffectiveHash, want)
	}
}

// --- 規則 6（§6.2。#322）: 守るステップ（人のゲート・人のゲートへ入る遷移を持つ・fail へ入る遷移を持つ）を付け替えで迂回できない ---

// issue322 は #322 の再現の定義: done へのどの経路も人のゲート h を通るが、h へは a.bad からも入れる。
const issue322 = `schema: harness.workflow/v1
id: r
overridable:
  routes:
    a.ok: [b, c]
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: b
      bad: { gate: h }
  b:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: { gate: h }
      bad: { gate: h }
  h:
    kind: gate
    type: input
    decider: human
    requested_action: decide
    inputs: [go]
    on: { go: c }
  c:
    kind: command
    run: tool
    output: schemas/out.json
    on:
      ok: { done: ok }
      bad: { done: ok }
`

// #322 の再現: 人のゲートへの抜け道（a.bad）が残っていても、ゲートの手前（b）ごと飛ばす候補は宣言の時点で拒否する
// （いままでは規則 3 に当たらず、validate が skipped_steps: b で通していた）。
func TestRule6RejectsIssue322Repro(t *testing.T) {
	_, err := loadRoutes(t, issue322)
	want := `overridable.routes.a.ok: candidate "c" would let the run reach c, done: ok without passing "h", which every path takes in the original definition; step "h" is a human gate (decider: human), so an override cannot bypass it (§6.2 rule 6)`
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("err = %v, want %q", err, want)
	}
}

// 上書きを重ねた時点の検査（宣言の検査を通った後の二重の検査）も、同じ迂回を拒否する。
func TestRule6RejectsBypassAfterOverrides(t *testing.T) {
	base, err := Parse("/w/r.yaml", []byte(issue322))
	if err != nil {
		t.Fatal(err)
	}
	eff, _ := Parse("/w/r.yaml", []byte(issue322))
	if ps := bypassProblems(base, eff); ps != nil {
		t.Fatalf("without overrides: %v", ps)
	}
	eff.Step("a").OnFor("ok").Target = "c"
	ps := bypassProblems(base, eff)
	want := `steps.h: the overrides let the run reach c, done: ok without passing "h", which every path took in the original definition; step "h" is a human gate (decider: human), so an override cannot bypass it (§6.2 rule 6)`
	if len(ps) != 1 || !strings.Contains(ps.Error(), want) || ps[0].Line != base.Step("h").Line {
		t.Fatalf("problems = %v, want %q", ps, want)
	}
}

// failSkip は fail へ落ちうるステップ q（品質ゲート等）を a.ok の付け替えで飛ばせる定義（R2）。
const failSkip = `schema: harness.workflow/v1
id: r
overridable:
  routes:
    a.ok: [q, c]
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: q, bad: { fail: start } }
  q:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: c, bad: { fail: quality } }
  c:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: { done: ok }, bad: { done: ok } }
`

// R2: fail へ落ちうるステップを丸ごと飛ばす候補は、overridable.skips に挙げていなければ拒否する。
func TestRule6RejectsSkippingFailableStep(t *testing.T) {
	_, err := loadRoutes(t, failSkip)
	want := `overridable.routes.a.ok: candidate "c" would let the run reach c, done: ok without passing "q", which every path takes in the original definition; step "q" can end the run as failed (fail: quality), so an override cannot bypass it (§6.2 rule 6); to allow skipping it, list it in overridable.skips of the workflow`
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("err = %v, want %q", err, want)
	}
}

// overridable.skips に挙げたステップは省ける。省いたステップは skipped_steps に出る（#326 の品質ゲートの省略の形）。
func TestRule6AllowsDeclaredSkip(t *testing.T) {
	yaml := strings.Replace(failSkip, "    a.ok: [q, c]\n", "    a.ok: [q, c]\n  skips: [q]\n", 1)
	if wf, err := loadRoutes(t, yaml); err != nil || wf.SkippedSteps != nil {
		t.Fatalf("without overrides: %v skipped %v", err, wf)
	}
	wf, err := loadRoutes(t, yaml, "steps: { a: { on: { ok: c } } }\n")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(wf.SkippedSteps, ",") != "q" {
		t.Fatalf("skipped_steps = %v, want [q]", wf.SkippedSteps)
	}
}

// branchBypass は人のゲート hg へ分岐するステップ sel の手前を飛ばせる定義（R3）。hg へは q → sel からも入れるので、
// p.ok を c へ付け替えても hg は到達でき、規則 3 には当たらない。
const branchBypass = `schema: harness.workflow/v1
id: r
overridable:
  routes:
    p.ok: [sel, c]
steps:
  a:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: p, bad: q }
  p:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: sel, bad: sel }
  q:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: sel, bad: sel }
  sel:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: m, bad: { gate: hg } }
  m:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: c, bad: c }
  hg:
    kind: gate
    type: input
    decider: human
    requested_action: decide
    inputs: [go]
    on: { go: c }
  c:
    kind: command
    run: tool
    output: schemas/out.json
    on: { ok: { done: ok }, bad: { done: ok } }
`

// R3: 人のゲートへ分岐するステップ（ticket の merge-route に当たる）の手前を飛ばす候補は、人のゲートが別の経路から
// 到達できても拒否する。
func TestRule6RejectsBypassingBranchToHumanGate(t *testing.T) {
	_, err := loadRoutes(t, branchBypass)
	want := `overridable.routes.p.ok: candidate "c" would let the run reach c, done: ok without passing "sel", which every path takes in the original definition; step "sel" leads to the human gate "hg", so an override cannot bypass it (§6.2 rule 6)`
	if err == nil || !strings.Contains(err.Error(), want) || strings.Contains(err.Error(), "overridable.skips of the workflow") {
		t.Fatalf("err = %v, want %q (without the skips hint)", err, want)
	}
}

// overridable.skips に挙げられるのは、fail へ入る遷移だけを理由に守るステップ。人のゲートと、人のゲートへ入る遷移を持つ
// ステップは挙げられない。
func TestSkipsDeclarationRejects(t *testing.T) {
	cases := []struct{ name, yaml, want string }{
		{"human gate", strings.Replace(branchBypass, "    p.ok: [sel, c]\n", "    p.ok: [sel, c]\n  skips: [hg]\n", 1),
			`overridable.skips: step "hg" is a human gate (decider: human); a human gate and a step that leads to one can never be skipped by an override (§6.2 rule 6)`},
		{"leads to a human gate", strings.Replace(branchBypass, "    p.ok: [sel, c]\n", "    p.ok: [sel, c]\n  skips: [sel]\n", 1),
			`overridable.skips: step "sel" leads to the human gate "hg"; a human gate and a step that leads to one can never be skipped`},
		{"not guarded", strings.Replace(failSkip, "    a.ok: [q, c]\n", "    a.ok: [q, c]\n  skips: [q, c]\n", 1),
			`overridable.skips: step "c" neither leads to a human gate nor can end the run as failed`},
		{"unknown step", strings.Replace(failSkip, "    a.ok: [q, c]\n", "    a.ok: [q, c]\n  skips: [zz]\n", 1),
			`overridable.skips: step "zz" does not exist`},
		{"empty", strings.Replace(failSkip, "    a.ok: [q, c]\n", "    a.ok: [q, c]\n  skips: []\n", 1),
			"overridable.skips must be a non-empty list of step ids"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadRoutes(t, c.yaml)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
}

// ticket.yaml の 2 本の宣言（保守側の付け替え）は規則 6 に当たらない。両方を同時に付け替えても通る。
func TestTicketRoutesPassRule6(t *testing.T) {
	wf, err := loadTicket(t, ov(LayerRepo, "steps:\n  merge-route: { on: { integration: human-merge } }\n  e2e-route: { on: { no: e2e } }\n"))
	if err != nil {
		t.Fatal(err)
	}
	if wf.Skips != nil || strings.Join(wf.SkippedSteps, ",") != "merge" {
		t.Fatalf("skips %v skipped_steps %v, want no skips and [merge]", wf.Skips, wf.SkippedSteps)
	}
}

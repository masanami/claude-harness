package runstate

import (
	"encoding/json"
	"testing"
)

// facts の値は、並べた段のうち「最後に成功して終わり、その欄を返した段」の値になる。欄を返さなかった段・成功でない終わり方
// （予約値・取り消し）は値を置き換えない。宣言の写しが無い run（この版より前・facts を宣言しないワークフロー）は値を持たない。

type factStep struct {
	step, outcome, output string
	reserved, cancelled   bool
}

// factsEvents は facts の宣言の写し decl を持つ run が、steps を順に実行した列（各段の次は次の段）。
func factsEvents(decl map[string][]FactSource, steps ...factStep) []Event {
	evs := []Event{
		{Type: EvRunStarted, RunStarted: &RunStarted{
			RunID: "r1", Workflow: WorkflowRecord{WorkflowRef: WorkflowRef{ID: "w", Schema: "harness.workflow/v1", Hash: "h", Path: "/w.yaml"}},
			Inputs: map[string]json.RawMessage{}, Facts: decl, Origin: "cli", Cwd: "/repo", PID: 1, Units: []string{"main"}, EntryStep: steps[0].step,
		}},
		{Type: EvRoundStarted, RoundStarted: &RoundStarted{Unit: "main", Round: 1, Trigger: Trigger{Kind: "start"}}},
	}
	for i, s := range steps {
		evs = append(evs, Event{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: s.step, Attempt: i + 1, PID: 5}})
		f := &StepFinished{Unit: "main", Step: s.step, Attempt: i + 1, Outcome: s.outcome, Reserved: s.reserved, ExitCode: intp(0), Cancelled: s.cancelled}
		if s.output != "" {
			f.Output = json.RawMessage(s.output)
		}
		if s.cancelled {
			f.Outcome, f.ExitCode = "", nil
		}
		evs = append(evs, Event{Type: EvStepFinished, StepFinished: f})
		if s.cancelled || i == len(steps)-1 {
			break
		}
		evs = append(evs, Event{Type: EvTransition, Transition: &Transition{Unit: "main", From: s.step, Outcome: s.outcome, Action: "step", To: steps[i+1].step}})
	}
	return withSeq(evs)
}

func factsOf(t *testing.T, evs []Event) map[string]string {
	t.Helper()
	st, err := Fold(evs)
	if err != nil {
		t.Fatal(err)
	}
	return st.Unit("main").Facts
}

var selfReviewDecl = map[string][]FactSource{"self_review": {
	{Step: "implement", Field: []string{"self_review"}},
	{Step: "fix", Field: []string{"self_review"}},
	{Step: "respond", Field: []string{"self_review"}},
}}

func TestFactsTakeTheValueOfTheLastStepThatReturnedTheField(t *testing.T) {
	impl := factStep{step: "implement", outcome: "pass", output: `{"outcome":"pass","self_review":"complete"}`}
	cases := []struct {
		name  string
		steps []factStep
		want  string
	}{
		{"implement only", []factStep{impl}, "complete"},
		{"respond returns it (pushed)", []factStep{impl, {step: "respond", outcome: "pushed", output: `{"outcome":"pushed","self_review":"incomplete"}`}}, "incomplete"},
		{"respond returns it (no_change)", []factStep{impl, {step: "respond", outcome: "no_change", output: `{"outcome":"no_change","self_review":"not_run"}`}}, "not_run"},
		{"respond returns it (needs_human)", []factStep{impl, {step: "respond", outcome: "needs_human", output: `{"outcome":"needs_human","self_review":"incomplete"}`}}, "incomplete"},
		{"respond does not return it", []factStep{impl, {step: "respond", outcome: "pushed", output: `{"outcome":"pushed"}`}}, "complete"},
		{"fix returns it", []factStep{impl, {step: "fix", outcome: "pass", output: `{"outcome":"pass","self_review":"incomplete"}`}}, "incomplete"},
		{"fix does not return it", []factStep{impl, {step: "fix", outcome: "pass", output: `{"outcome":"pass"}`}}, "complete"},
		{"the last one wins", []factStep{impl,
			{step: "fix", outcome: "pass", output: `{"outcome":"pass","self_review":"incomplete"}`},
			{step: "respond", outcome: "pushed", output: `{"outcome":"pushed","self_review":"complete"}`}}, "complete"},
		{"a step that is not in the declaration does not change it", []factStep{impl, {step: "sync-resolve", outcome: "resolved", output: `{"outcome":"resolved","self_review":"not_run"}`}}, "complete"},
		{"a reserved outcome does not change it", []factStep{impl, {step: "respond", outcome: "invalid_output", output: `{"self_review":"not_run"}`, reserved: true}}, "complete"},
		{"a cancelled step does not change it", []factStep{impl, {step: "respond", cancelled: true}}, "complete"},
		{"a non-string field is not a value", []factStep{impl, {step: "respond", outcome: "pushed", output: `{"outcome":"pushed","self_review":3}`}}, "complete"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := factsOf(t, factsEvents(selfReviewDecl, c.steps...))
			if len(got) != 1 || got["self_review"] != c.want {
				t.Fatalf("facts = %v, want self_review=%s", got, c.want)
			}
		})
	}
}

func TestFactsHaveNoValueUntilAStepReturnsTheField(t *testing.T) {
	got := factsOf(t, factsEvents(selfReviewDecl, factStep{step: "analyze", outcome: "ok", output: `{"outcome":"ok"}`}))
	if got != nil {
		t.Fatalf("facts = %v, want none", got)
	}
}

// 宣言の写しが無い run（facts を宣言しないワークフロー・この版より前に始めた run）は、欄を返す段があっても facts を持たない。
func TestNoFactsWithoutTheDeclarationRecord(t *testing.T) {
	got := factsOf(t, factsEvents(nil, factStep{step: "implement", outcome: "pass", output: `{"outcome":"pass","self_review":"complete"}`}))
	if got != nil {
		t.Fatalf("facts = %v, want none", got)
	}
}

// 宣言の写しは run_started に記録され、イベント → 状態の往復で値と一緒に state.json（JSON）から読み戻せる。
func TestFactsSurviveTheStateRoundTrip(t *testing.T) {
	st, err := Fold(factsEvents(selfReviewDecl, factStep{step: "implement", outcome: "pass", output: `{"outcome":"pass","self_review":"complete"}`}))
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(st)
	if err != nil {
		t.Fatal(err)
	}
	var back State
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if back.Unit("main").Facts["self_review"] != "complete" || len(back.FactSources["self_review"]) != 3 {
		t.Fatalf("round trip = %s", b)
	}
}

package workflow

import (
	"strings"
	"testing"
)

// 最上位の facts（接続契約の facts に出す値の宣言。docs/harness-runtime-design.md §5.6.2）の読み込みと検査。
// 参照は $steps.<段>.<欄> だけで、段が在り、欄がその段の出力スキーマにある文字列であること。

func withFacts(t *testing.T, facts string) string {
	t.Helper()
	return mutate(t, "limits:\n", "facts:\n"+facts+"\nlimits:\n")
}

func TestFactsAreLoaded(t *testing.T) {
	path, scripts := setup(t, "w", withFacts(t, "  name: [$steps.a.detail.name, $steps.b.detail.name]"))
	wf, err := LoadAndValidate(path, Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	if len(wf.Facts) != 1 || wf.Facts[0].Name != "name" || len(wf.Facts[0].Refs) != 2 {
		t.Fatalf("facts = %+v", wf.Facts)
	}
	if r := wf.Facts[0].Refs[1]; r.Step != "b" || strings.Join(r.Path, ".") != "detail.name" {
		t.Fatalf("ref = %+v", r)
	}
}

func TestFactsAreRejected(t *testing.T) {
	cases := []struct{ name, facts, want string }{
		{"a step that does not exist", "  f: [$steps.nope.detail.name]", "refers to a step that does not exist"},
		{"a field that is not in the output schema", "  f: [$steps.a.nope]", `output schema has no field "nope"`},
		{"a field that is not a string (array)", "  f: [$steps.a.items]", "must be a string field"},
		{"a field that is not a string (object)", "  f: [$steps.a.detail]", "must be a string field"},
		{"an input reference", "  f: [$inputs.s]", "must be a $steps.<step>.<field> reference"},
		{"an edge reference", "  f: [$edge.x]", "must be a $steps.<step>.<field> reference"},
		{"a literal", "  f: [complete]", "must be exactly one reference"},
		{"an empty list", "  f: []", "must be a non-empty list"},
		{"a scalar instead of a list", "  f: $steps.a.detail.name", "must be a non-empty list"},
		{"a bad name", "  Bad-Name: [$steps.a.detail.name]", "must match"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := check(t, withFacts(t, c.facts))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want it to contain %q", err, c.want)
			}
		})
	}
}

// facts は上書きに書けない（上書きできるのは limits と steps の決まったキーだけ）。
func TestOverrideCannotWriteFacts(t *testing.T) {
	_, err := loadTicket(t, ov(LayerArg, "facts:\n  self_review: [$steps.implement.self_review]\n"))
	if err == nil || !strings.Contains(err.Error(), `key "facts" cannot be overridden`) {
		t.Fatalf("err = %v", err)
	}
}

// 同梱の ticket は self_review を implement・fix・respond の順に宣言する。
func TestTicketDeclaresSelfReviewFact(t *testing.T) {
	wf, err := loadTicket(t)
	if err != nil {
		t.Fatal(err)
	}
	if len(wf.Facts) != 1 || wf.Facts[0].Name != "self_review" {
		t.Fatalf("facts = %+v", wf.Facts)
	}
	var steps []string
	for _, r := range wf.Facts[0].Refs {
		steps = append(steps, r.Step+"."+strings.Join(r.Path, "."))
	}
	if got, want := strings.Join(steps, ","), "implement.self_review,fix.self_review,respond.self_review"; got != want {
		t.Fatalf("refs = %s, want %s", got, want)
	}
}

// self_review の無い fix・respond の出力もスキーマを通る（欄は任意）。ある出力は enum の値だけを通す。
func TestFixAndRespondOutputsAcceptOptionalSelfReview(t *testing.T) {
	wf, err := loadTicket(t)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		step string
		ok   []map[string]any
		bad  map[string]any
	}{
		{"fix", []map[string]any{
			{"outcome": "pass", "summary": "s", "deviation_report": ""},
			{"outcome": "pass", "summary": "s", "deviation_report": "", "self_review": "complete"},
			{"outcome": "failure", "summary": "s", "deviation_report": "", "self_review": "not_run"},
		}, map[string]any{"outcome": "pass", "summary": "s", "deviation_report": "", "self_review": "done"}},
		{"respond", []map[string]any{
			{"outcome": "pushed", "summary": "s", "human_question": ""},
			{"outcome": "no_change", "summary": "s", "human_question": "", "self_review": "incomplete"},
			{"outcome": "needs_human", "summary": "s", "human_question": "q", "self_review": "complete"},
		}, map[string]any{"outcome": "pushed", "summary": "s", "human_question": "", "self_review": ""}},
	} {
		sch := wf.Step(c.step).OutputSchema
		for _, v := range c.ok {
			if err := sch.Validate(v); err != nil {
				t.Errorf("%s %v: %v", c.step, v, err)
			}
		}
		if err := sch.Validate(c.bad); err == nil {
			t.Errorf("%s %v: accepted", c.step, c.bad)
		}
	}
}

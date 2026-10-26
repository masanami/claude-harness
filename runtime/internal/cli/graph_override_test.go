package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// harness graph に上書きを重ねる（docs/harness-runtime-visualization.md §5.1・§5.2・§5.3・§9。#317）: 上書き後の形と
// changes・overridden・skipped を出し、--run は run の上書きの写しから resume と同じ手順で組み立て直した定義を描く。

// overrideGraphDoc は上書きを重ねた graph --json のうち、テストで読む部分。
type overrideGraphDoc struct {
	Workflow struct {
		Hash          string `json:"hash"`
		EffectiveHash string `json:"effective_hash"`
		Overrides     []struct {
			Layer  string  `json:"layer"`
			Path   string  `json:"path"`
			SHA256 string  `json:"sha256"`
			Copy   *string `json:"copy"`
		} `json:"overrides"`
		Changes []map[string]any `json:"changes"`
	} `json:"workflow"`
	Limits []struct {
		Name  string  `json:"name"`
		Value float64 `json:"value"`
	} `json:"limits"`
	Nodes []map[string]any `json:"nodes"`
	Edges []map[string]any `json:"edges"`
	Run   *struct {
		Status string `json:"status"`
	} `json:"run"`
}

func (d overrideGraphDoc) node(t *testing.T, id string) map[string]any {
	t.Helper()
	for _, n := range d.Nodes {
		if n["id"] == id {
			return n
		}
	}
	t.Fatalf("no node %q", id)
	return nil
}

// edges は from・outcome の辺を返す（from が空なら to で引く）。
func (d overrideGraphDoc) edges(from, outcome, to string) []map[string]any {
	var out []map[string]any
	for _, e := range d.Edges {
		if (from == "" || e["from"] == from) && (outcome == "" || e["outcome"] == outcome) && (to == "" || e["to"] == to) {
			out = append(out, e)
		}
	}
	return out
}

func changesJSON(t *testing.T, cs []map[string]any) string {
	t.Helper()
	b, err := json.Marshal(cs)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

const routeTicketOverride = "schema: harness.workflow-override/v1\nworkflow: ticket\nsteps:\n  merge-route:\n    on:\n      integration: human-merge\n"

// §9 の例: ticket の merge-route.integration を human-merge へ付け替えると、付け替えた辺に overridden が付き、merge は
// 入ってくる辺を失って skipped になり、出ていく辺は残る（破線・灰色）。テキスト・Mermaid・JSON の 3 形式で確かめる。
func TestGraphOverrideTicketRoute(t *testing.T) {
	h := newHarness(t)
	ov := writeFile(t, filepath.Join(t.TempDir(), "route.yaml"), routeTicketOverride)
	args := []string{"graph", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--override", ov}

	// JSON
	out, errOut, code := h.run(append(args, "--json", "ticket")...)
	if code != ExitOK || errOut != "" {
		t.Fatalf("graph --json: exit %d\n%s", code, errOut)
	}
	d := decode[overrideGraphDoc](t, out)
	if len(d.Workflow.Overrides) != 1 || d.Workflow.Overrides[0].Layer != "arg" || d.Workflow.Overrides[0].Path != ov ||
		len(d.Workflow.Overrides[0].SHA256) != 64 || d.Workflow.Overrides[0].Copy != nil {
		t.Fatalf("workflow.overrides = %+v", d.Workflow.Overrides)
	}
	if got, want := changesJSON(t, d.Workflow.Changes), `[{"from":"merge","key":"steps.merge-route.on.integration","layer":"arg","to":"human-merge"}]`; got != want {
		t.Fatalf("workflow.changes = %s, want %s", got, want)
	}
	if len(d.Workflow.EffectiveHash) != 64 || d.Workflow.EffectiveHash == d.Workflow.Hash {
		t.Fatalf("effective_hash = %q (hash %q)", d.Workflow.EffectiveHash, d.Workflow.Hash)
	}
	es := d.edges("merge-route", "integration", "")
	if len(es) != 1 || es[0]["to"] != "human-merge" || es[0]["kind"] != "step" {
		t.Fatalf("merge-route.integration = %v", es)
	}
	if b, _ := json.Marshal([]any{es[0]["overridable"], es[0]["overridden"]}); string(b) != `[["merge","human-merge"],{"from":"merge","layer":"arg"}]` {
		t.Fatalf("merge-route.integration overridable/overridden = %s", b)
	}
	if e := d.edges("merge-route", "default", ""); len(e) != 1 || e[0]["overridable"] != nil || e[0]["overridden"] != nil {
		t.Fatalf("merge-route.default = %v (not declared, not overridden)", e)
	}
	// 宣言はあるが付け替えていない遷移は overridable だけを持つ。
	if e := d.edges("e2e-route", "no", ""); len(e) != 1 || e[0]["overridden"] != nil {
		t.Fatalf("e2e-route.no = %v", e)
	} else if b, _ := json.Marshal(e[0]["overridable"]); string(b) != `["publish","e2e"]` {
		t.Fatalf("e2e-route.no overridable = %s", b)
	}
	var skipped []string
	for _, n := range d.Nodes {
		if n["skipped"] == true {
			skipped = append(skipped, n["id"].(string))
		}
	}
	if strings.Join(skipped, ",") != "merge" {
		t.Fatalf("skipped nodes = %v, want [merge]", skipped)
	}
	if in := d.edges("", "", "merge"); len(in) != 0 {
		t.Fatalf("edges into the skipped merge = %v, want none", in)
	}
	if outs := d.edges("merge", "", ""); len(outs) != 2 || outs[0]["to"] != "cleanup" || outs[1]["to"] != "review-human" {
		t.Fatalf("edges out of the skipped merge = %v, want merged -> cleanup and blocked -> review-human", outs)
	}

	// テキスト
	text, errOut, code := h.run(append(args, "ticket")...)
	if code != ExitOK || errOut != "" {
		t.Fatalf("graph (text): exit %d\n%s", code, errOut)
	}
	for _, want := range []string{
		"\noverrides: arg " + ov + "\n",
		"\nchanges: steps.merge-route.on.integration: merge -> human-merge (arg)\n",
		"  - skipped by an override  ..> transition of a skipped step\n",
		"\n  merge-route       select $steps.resolve.base_kind  integration -> human-merge (override arg, was merge) | default -> human-merge\n",
		"\n- merge             llm $3 30m                merged ..> cleanup | blocked ..> review-human\n",
		"\n  cleanup ", "\n  review-human ",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("text does not contain %q", want)
		}
	}

	// Mermaid
	mmd, errOut, code := h.run(append(args, "--format", "mermaid", "ticket")...)
	if code != ExitOK || errOut != "" {
		t.Fatalf("graph --format mermaid: exit %d\n%s", code, errOut)
	}
	// merge-route=n14・merge=n15・review-human=n13・human-merge=n16・cleanup=n18。
	for _, want := range []string{
		"\n  %% overrides: arg " + ov + "\n",
		"\n  %% changes: steps.merge-route.on.integration: merge -> human-merge (arg)\n",
		"\n  n14 ==>|\"integration (override arg, was merge)\"| n16\n",
		"\n  n14 -->|\"default\"| n16\n",
		"\n  n15 -.->|\"merged\"| n18\n", "\n  n15 -.->|\"blocked\"| n13\n",
		"\n  class n15 skipped\n",
	} {
		if !strings.Contains(mmd, want) {
			t.Errorf("mermaid does not contain %q", want)
		}
	}
	if strings.Contains(mmd, "| n15\n") {
		t.Errorf("mermaid draws a line into the skipped merge")
	}
	// linkStyle の番号は、merge から出る 2 本の線を指す（線は書いた順に 0 から数える）。
	if got := greyLinks(t, mmd); got != "n15 -.->|\"merged\"| n18,n15 -.->|\"blocked\"| n13" {
		t.Errorf("grey links = %s", got)
	}
	if t.Failed() {
		t.Logf("text:\n%s\nmermaid:\n%s", text, mmd)
	}
}

// greyLinks は Mermaid の linkStyle が指す線を、線の行（字下げを除く）で返す。
func greyLinks(t *testing.T, mmd string) string {
	t.Helper()
	var links []string
	var style string
	for _, l := range strings.Split(mmd, "\n") {
		l = strings.TrimSpace(l)
		switch {
		case strings.Contains(l, "-->|") || strings.Contains(l, "-.->|") || strings.Contains(l, "==>|"):
			links = append(links, l)
		case strings.HasPrefix(l, "linkStyle "):
			if style != "" {
				t.Fatalf("two linkStyle lines:\n%s", mmd)
			}
			style = strings.Fields(l)[1]
		}
	}
	if style == "" {
		return ""
	}
	var got []string
	for _, f := range strings.Split(style, ",") {
		i, err := strconv.Atoi(f)
		if err != nil || i >= len(links) {
			t.Fatalf("linkStyle %s: bad index %q", style, f)
		}
		got = append(got, links[i])
	}
	return strings.Join(got, ",")
}

// 上書きなし・リポジトリの上書き・--override（とその両方）で、graph は上書き後の形と changes を出す。上書きの置き場と
// 重ねる順は run・validate と同じ（リポジトリ → 引数。キーごとに後ろの層が勝つ）。
func TestGraphOverrideLayers(t *testing.T) {
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "rte.yaml"), routeWorkflow)
	cwd, repo := overrideRepo(t, "rte", "schema: harness.workflow-override/v1\nworkflow: rte\nlimits: { rework: 2 }\nsteps: { first: { timeout: 30s } }\n")
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), "schema: harness.workflow-override/v1\nworkflow: rte\nlimits: { rework: 4 }\nsteps: { first: { on: { ok: ask } } }\n")
	base := []string{"graph", "--json", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts)}

	cases := []struct {
		name     string
		inRepo   bool
		args     []string
		layers   string
		changes  string
		rework   float64
		skipped  string
		rerouted string
	}{
		{"none", false, nil, "", `[]`, 1, "", ""},
		{"repo", true, nil, "repo:" + repo,
			`[{"from":1,"key":"limits.rework","layer":"repo","to":2},{"from":null,"key":"steps.first.timeout","layer":"repo","to":"30s"}]`, 2, "", ""},
		{"arg", false, []string{"--override", arg}, "arg:" + arg,
			`[{"from":1,"key":"limits.rework","layer":"arg","to":4},{"from":"extra","key":"steps.first.on.ok","layer":"arg","to":"ask"}]`, 4, "extra", "arg"},
		{"repo and arg", true, []string{"--override", arg}, "repo:" + repo + ",arg:" + arg,
			`[{"from":1,"key":"limits.rework","layer":"arg","to":4},{"from":null,"key":"steps.first.timeout","layer":"repo","to":"30s"},{"from":"extra","key":"steps.first.on.ok","layer":"arg","to":"ask"}]`, 4, "extra", "arg"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			if c.inRepo {
				h.cwd = cwd
			}
			out, errOut, code := h.run(append(append(base, c.args...), "rte")...)
			if code != ExitOK || errOut != "" {
				t.Fatalf("exit %d\n%s", code, errOut)
			}
			d := decode[overrideGraphDoc](t, out)
			var layers []string
			for _, o := range d.Workflow.Overrides {
				layers = append(layers, o.Layer+":"+o.Path)
			}
			if strings.Join(layers, ",") != c.layers {
				t.Fatalf("overrides = %v, want %s", layers, c.layers)
			}
			if d.Workflow.Changes == nil {
				t.Fatal("changes must be an array")
			}
			if got := changesJSON(t, d.Workflow.Changes); got != c.changes {
				t.Fatalf("changes = %s\nwant      %s", got, c.changes)
			}
			if (c.layers == "") != (d.Workflow.EffectiveHash == d.Workflow.Hash) {
				t.Fatalf("effective_hash %q vs hash %q", d.Workflow.EffectiveHash, d.Workflow.Hash)
			}
			if d.Limits[0].Name != "rework" || d.Limits[0].Value != c.rework {
				t.Fatalf("limits = %+v", d.Limits)
			}
			if c.layers != "" && strings.Contains(c.changes, "30s") && d.node(t, "first")["timeout"] != "30s" {
				t.Fatalf("first.timeout = %v", d.node(t, "first")["timeout"])
			}
			var skipped []string
			for _, n := range d.Nodes {
				if n["skipped"] == true {
					skipped = append(skipped, n["id"].(string))
				}
			}
			if strings.Join(skipped, ",") != c.skipped {
				t.Fatalf("skipped = %v, want %q", skipped, c.skipped)
			}
			e := d.edges("first", "ok", "")[0]
			if c.rerouted == "" {
				if e["to"] != "extra" || e["overridden"] != nil {
					t.Fatalf("first.ok = %v", e)
				}
			} else if b, _ := json.Marshal(e["overridden"]); e["to"] != "ask" || string(b) != `{"from":"extra","layer":"`+c.rerouted+`"}` {
				t.Fatalf("first.ok = %v", e)
			}
		})
	}
}

// 上書きの不正（人のゲートへ向かう遷移の付け替え）は validate と同じく定義の不正として 2 で止まり、何も出さない。
// 無い --override のファイルも 2。
func TestGraphOverrideRejected(t *testing.T) {
	h := newHarness(t)
	bad := writeFile(t, filepath.Join(t.TempDir(), "bad.yaml"), "schema: harness.workflow-override/v1\nworkflow: ticket\nsteps: { merge-route: { on: { default: merge } } }\n")
	args := []string{"graph", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts)}
	out, errOut, code := h.run(append(args, "--override", bad, "ticket")...)
	if code != ExitUsage || out != "" || !strings.Contains(errOut, "workflow is not valid") || !strings.Contains(errOut, `leads to the human gate "human-merge"`) {
		t.Fatalf("exit %d\n%s\n%s", code, out, errOut)
	}
	out, errOut, code = h.run(append(args, "--override", filepath.Join(t.TempDir(), "missing.yaml"), "ticket")...)
	if code != ExitUsage || out != "" || !strings.Contains(errOut, "--override:") {
		t.Fatalf("missing override: exit %d\n%s\n%s", code, out, errOut)
	}
}

// 上書きで走った run の graph --run は、run ディレクトリの上書きの写しから resume と同じ手順で組み立て直した定義を描く。
// 上書きの一覧は run の記録（読んだファイルと写し。status --json と同じ値）で出す。開始後に元の上書きのファイルを書き換えても
// 描く形は変わらず（写しを読む）、写しを書き換えた run は resume と同じく組み立て直せずに 1 で止まる。
func TestGraphRunOverridden(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "rte.yaml"), routeWorkflow)
	cwd, repo := overrideRepo(t, "rte", "schema: harness.workflow-override/v1\nworkflow: rte\nlimits: { rework: 2 }\n")
	arg := writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), routeOverride)
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	h.cwd = cwd
	out, errOut, code := h.run("run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--override", arg, "rte")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	rec := runStarted(t, v.RunDir).Workflow

	// 元の上書きのファイルを書き換え、リポジトリの上書きも消す（graph --run はどちらも読まない）。
	writeFile(t, arg, "schema: harness.workflow-override/v1\nworkflow: rte\nlimits: { rework: 9 }\n")
	if err := os.Remove(repo); err != nil {
		t.Fatal(err)
	}

	gout, errOut, code := h.run("graph", "--run", v.RunID, "--json")
	if code != ExitOK || errOut != "" {
		t.Fatalf("graph --run --json: exit %d\n%s\n%s", code, gout, errOut)
	}
	d := decode[overrideGraphDoc](t, gout)
	if d.Run == nil || d.Run.Status != "waiting" {
		t.Fatalf("run = %+v", d.Run)
	}
	if len(d.Workflow.Overrides) != 2 {
		t.Fatalf("overrides = %+v", d.Workflow.Overrides)
	}
	for i, o := range d.Workflow.Overrides {
		r := rec.Overrides[i]
		if o.Layer != r.Layer || o.Path != r.Path || o.SHA256 != r.SHA256 || o.Copy == nil || *o.Copy != r.Copy {
			t.Fatalf("overrides[%d] = %+v, want the run's record %+v", i, o, r)
		}
	}
	// status --json の workflow.overrides と同じ値。
	sw := statusWorkflow(t, h, v.RunID)
	var gw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(gout), &struct {
		Workflow *map[string]json.RawMessage `json:"workflow"`
	}{&gw}); err != nil {
		t.Fatal(err)
	}
	if string(gw["overrides"]) != string(sw["overrides"]) {
		t.Fatalf("graph overrides %s\nstatus overrides %s", gw["overrides"], sw["overrides"])
	}
	if got, want := changesJSON(t, d.Workflow.Changes), `[{"from":1,"key":"limits.rework","layer":"repo","to":2},{"from":"extra","key":"steps.first.on.ok","layer":"arg","to":"ask"}]`; got != want {
		t.Fatalf("changes = %s, want %s", got, want)
	}
	if d.Workflow.EffectiveHash != rec.EffectiveHash || d.Limits[0].Value != 2 {
		t.Fatalf("effective_hash = %q (run %q), limits = %+v", d.Workflow.EffectiveHash, rec.EffectiveHash, d.Limits)
	}
	if d.node(t, "extra")["skipped"] != true || d.node(t, "first")["skipped"] != false {
		t.Fatalf("skipped: extra %v, first %v", d.node(t, "extra")["skipped"], d.node(t, "first")["skipped"])
	}
	if e := d.edges("first", "ok", ""); len(e) != 1 || e[0]["to"] != "ask" {
		t.Fatalf("first.ok = %v", e)
	} else if b, _ := json.Marshal(e[0]["overridden"]); string(b) != `{"from":"extra","layer":"arg"}` {
		t.Fatalf("first.ok overridden = %s", b)
	}

	text, errOut, code := h.run("graph", "--run", v.RunID)
	if code != ExitOK || errOut != "" {
		t.Fatalf("graph --run: exit %d\n%s", code, errOut)
	}
	for _, want := range []string{
		"\nlimits: rework=2\n",
		"\nchanges: limits.rework: 1 -> 2 (repo), steps.first.on.ok: extra -> ask (arg)\n",
		"\n* first ", "ok -> ask (override arg, was extra)",
		"\n- extra ", "ok ..> ask\n",
		"\n> ask ",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("text does not contain %q:\n%s", want, text)
		}
	}

	// 写しを書き換えた run は resume と同じ照合で止まる（描かない）。status は読める。
	writeFile(t, filepath.Join(v.RunDir, rec.Overrides[1].Copy), "schema: harness.workflow-override/v1\nworkflow: rte\n")
	out, errOut, code = h.run("graph", "--run", v.RunID)
	if code != ExitFailed || out != "" || !strings.Contains(errOut, "changed since the run started") ||
		!strings.Contains(errOut, "harness status "+v.RunID+" still shows where the run is") {
		t.Fatalf("tampered copy: exit %d\n%s\n%s", code, out, errOut)
	}
	if _, errOut, code := h.run("resume", v.RunID, "--input", "go"); code != ExitFailed || !strings.Contains(errOut, "changed since the run started") {
		t.Fatalf("resume with the tampered copy: exit %d\n%s", code, errOut)
	}
	if ids, _ := runstate.List(filepath.Join(state, "runs")); len(ids) != 1 {
		t.Fatalf("runs = %v", ids)
	}
}

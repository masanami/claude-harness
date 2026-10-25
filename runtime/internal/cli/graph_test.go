package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/version"
)

// graphDoc は harness graph --json の形（harness.workflow-graph/v1）のうち、テストで読む部分。
type graphDoc struct {
	Schema   string `json:"schema"`
	Workflow struct {
		ID            string `json:"id"`
		Source        string `json:"source"`
		Path          string `json:"path"`
		Hash          string `json:"hash"`
		EffectiveHash string `json:"effective_hash"`
		CLIVersion    string `json:"cli_version"`
		Overrides     []any  `json:"overrides"`
		Changes       []any  `json:"changes"`
	} `json:"workflow"`
	Entry string `json:"entry"`
	Nodes []struct {
		ID   string `json:"id"`
		Kind string `json:"kind"`
		Gate *struct {
			Decider     string `json:"decider"`
			RequiresTTY bool   `json:"requires_tty"`
		} `json:"gate"`
	} `json:"nodes"`
	Edges []map[string]any `json:"edges"`
	Run   any              `json:"run"`
}

// 同梱の 3 つの定義について、graph は形の JSON とテキストを出して終了コード 0 で終わる（§3・§6.1・§7）。
// --json は --format json の別名。
func TestGraphBundledWorkflows(t *testing.T) {
	h := newHarness(t)
	dirArgs := []string{"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts)}
	cases := []struct {
		id    string
		entry string
		steps int
	}{{"ticket", "resolve", 19}, {"conflict-predict-issue", "fetch", 2}, {"list-tests", "list", 1}}
	for _, c := range cases {
		t.Run(c.id, func(t *testing.T) {
			var docs []graphDoc
			for _, flag := range [][]string{{"--json"}, {"--format", "json"}, {"--format=json"}} {
				out, errOut, code := h.run(append(append(append([]string{"graph"}, flag...), dirArgs...), c.id)...)
				if code != ExitOK || errOut != "" {
					t.Fatalf("graph %v %s: exit %d\n%s", flag, c.id, code, errOut)
				}
				docs = append(docs, decode[graphDoc](t, out))
			}
			d := docs[0]
			for _, o := range docs[1:] {
				if o.Workflow.Hash != d.Workflow.Hash || len(o.Nodes) != len(d.Nodes) || len(o.Edges) != len(d.Edges) {
					t.Fatalf("--json and --format json differ")
				}
			}
			if d.Schema != "harness.workflow-graph/v1" || d.Workflow.ID != c.id || d.Entry != c.entry || d.Run != nil {
				t.Fatalf("doc = %+v", d)
			}
			if d.Workflow.Source != "workflow-dir" || d.Workflow.CLIVersion != version.CLI() ||
				d.Workflow.Path != filepath.Join(abs(t, repoWorkflows), c.id+".yaml") || len(d.Workflow.Hash) != 64 ||
				d.Workflow.EffectiveHash != d.Workflow.Hash || d.Workflow.Overrides == nil || len(d.Workflow.Overrides) != 0 ||
				d.Workflow.Changes == nil || len(d.Workflow.Changes) != 0 {
				t.Fatalf("workflow = %+v", d.Workflow)
			}
			steps := 0
			for _, n := range d.Nodes {
				if n.Kind != "fail" && n.Kind != "done" {
					steps++
				}
			}
			if steps != c.steps {
				t.Fatalf("%d steps, want %d", steps, c.steps)
			}

			out, errOut, code := h.run(append(append([]string{"graph"}, dirArgs...), c.id)...)
			if code != ExitOK || errOut != "" {
				t.Fatalf("graph %s (text): exit %d\n%s", c.id, code, errOut)
			}
			if !strings.HasPrefix(out, "workflow "+c.id+" (workflow-dir, cli "+version.CLI()+")  entry: "+c.entry+"\n") {
				t.Fatalf("text:\n%s", out)
			}
			_, after, _ := strings.Cut(out, "\n\n")
			if got := strings.Count(strings.TrimRight(after, "\n"), "\n") + 1; got != c.steps {
				t.Fatalf("text has %d step lines, want %d (stdout is not a terminal, so lines are not wrapped)\n%s", got, c.steps, out)
			}
		})
	}
}

// ticket の人のゲート 3 つは decider で区別して出る（JSON の decider・requires_tty と、テキストの [human]・[tty]）。
func TestGraphTicketHumanGates(t *testing.T) {
	h := newHarness(t)
	args := []string{"graph", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket"}
	out, _, code := h.run(append(args, "--json")...)
	if code != ExitOK {
		t.Fatalf("exit %d", code)
	}
	var human []string
	for _, n := range decode[graphDoc](t, out).Nodes {
		if n.Gate != nil && n.Gate.Decider == "human" {
			human = append(human, n.ID)
		}
	}
	if strings.Join(human, ",") != "review-human,human-merge,design-deviation" {
		t.Fatalf("human gates = %v", human)
	}
	text, _, _ := h.run(args...)
	var marked []string
	for _, l := range strings.Split(text, "\n") {
		if strings.HasPrefix(l, "  ") && strings.Contains(l, "[human]") {
			marked = append(marked, strings.Fields(l)[0])
		}
	}
	if strings.Join(marked, ",") != "review-human,human-merge,design-deviation" {
		t.Fatalf("[human] lines = %v\n%s", marked, text)
	}
}

// フラグ無しなら、バイナリに埋め込んだ定義（この版の展開ディレクトリ）を描き、source は embedded になる。
func TestGraphEmbedded(t *testing.T) {
	h := newHarness(t)
	out, errOut, code := h.run("graph", "--json", "ticket")
	if code != ExitOK {
		t.Fatalf("exit %d\n%s", code, errOut)
	}
	d := decode[graphDoc](t, out)
	if d.Workflow.Source != "embedded" || !strings.Contains(d.Workflow.Path, filepath.Join("claude-harness", "runtime", version.CLI())) ||
		!strings.HasSuffix(d.Workflow.Path, filepath.Join("workflows", "ticket.yaml")) {
		t.Fatalf("workflow = %+v", d.Workflow)
	}
}

// $COLUMNS が狭ければ、テキストは遷移の区切りで折り返す（§12）。
func TestGraphTextWrapsToColumns(t *testing.T) {
	h := newHarness(t, "COLUMNS=60")
	out, _, code := h.run("graph", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitOK {
		t.Fatalf("exit %d", code)
	}
	for _, l := range strings.Split(out, "\n") {
		if len([]rune(l)) > 60 && strings.Contains(l, " | ") {
			t.Fatalf("line longer than 60 columns although it could wrap: %q", l)
		}
	}
	if !strings.Contains(out, "\n                                    links_invalid ! links_invalid\n") &&
		!strings.Contains(out, "\n      links_invalid ! links_invalid\n") {
		t.Fatalf("resolve's transitions are not wrapped:\n%s", out)
	}
}

// 終了コード（§7）: 0 = 出力した、2 = 使い方の誤り・定義の不正。graph は run を進めないので版の照合をしない。
func TestGraphExitCodes(t *testing.T) {
	bad := t.TempDir()
	if err := os.WriteFile(filepath.Join(bad, "bad.yaml"), []byte("schema: harness.workflow/v1\nid: bad\nsteps: {}\nwhen: x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	dirArgs := []string{"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts)}
	cases := []struct {
		name string
		args []string
		want int
		msg  string
	}{
		{"no workflow", append([]string{"graph"}, dirArgs...), ExitUsage, "exactly one workflow"},
		{"two workflows", append(append([]string{"graph"}, dirArgs...), "ticket", "list-tests"), ExitUsage, "exactly one workflow"},
		{"unknown option", append(append([]string{"graph", "--run", "x"}, dirArgs...), "ticket"), ExitUsage, "unknown option --run"},
		{"unknown format", append(append([]string{"graph", "--format", "html"}, dirArgs...), "ticket"), ExitUsage, "unknown graph format"},
		{"mermaid is not in this stage", append(append([]string{"graph", "--format", "mermaid"}, dirArgs...), "ticket"), ExitUsage, "not implemented"},
		{"--json with another format", append(append([]string{"graph", "--json", "--format", "text"}, dirArgs...), "ticket"), ExitUsage, "--json is --format json"},
		{"missing workflow", append(append([]string{"graph"}, dirArgs...), "no-such"), ExitUsage, "workflow is not valid"},
		{"invalid workflow", []string{"graph", "--workflow-dir", bad, "--scripts-dir", abs(t, repoScripts), "bad"}, ExitUsage, "workflow is not valid"},
		{"--json with --format json", append(append([]string{"graph", "--json", "--format", "json"}, dirArgs...), "ticket"), ExitOK, ""},
	}
	// 対応範囲外のプラグイン版でも graph は止まらない（run を進めるコマンドだけが版を照合する）。
	h := newHarness(t, PluginVersionEnv+"=999.0.0")
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out, errOut, code := h.run(c.args...)
			if code != c.want || !strings.Contains(errOut, c.msg) {
				t.Fatalf("exit %d (want %d)\nstdout:\n%s\nstderr:\n%s", code, c.want, out, errOut)
			}
			if c.want != ExitOK && out != "" {
				t.Fatalf("stdout must be empty on failure:\n%s", out)
			}
		})
	}
	if out, _, code := h.run(append(append([]string{"graph"}, dirArgs...), "ticket")...); code != ExitOK || out == "" {
		t.Fatalf("graph with an unsupported plugin version: exit %d", code)
	}
}

// graph は接続契約 v1 に載せない（決定 A1）: contract の面に graph は無く、contract の出力の形は変わらない。
func TestGraphIsNotInTheContract(t *testing.T) {
	h := newHarness(t)
	d, _ := h.contract("graph", "ticket")
	if d.State != "failed" || !strings.Contains(d.Summary, `unknown contract command "graph"`) {
		t.Fatalf("contract graph = %+v", d)
	}
	out, _, code := h.run("contract", "help")
	if code != ExitOK || strings.Contains(out, "graph") {
		t.Fatalf("contract help mentions graph (exit %d):\n%s", code, out)
	}
}

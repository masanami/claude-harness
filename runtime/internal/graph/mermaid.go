package graph

import (
	"fmt"
	"io"
	"strings"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// Mermaid の classDef（§6.2）。人のゲート・いまいるステップ・通ったステップ・上書きで到達できなくなったステップを
// 色と線で分ける。class 文は後に書いたものが勝つので、current を最後に付ける。
var mermaidClassDefs = []string{
	"classDef human fill:#fde68a,stroke:#b45309,stroke-width:2px",
	"classDef visited fill:#dcfce7,stroke:#15803d",
	"classDef skipped fill:#f3f4f6,stroke:#9ca3af,stroke-dasharray:5 5,color:#6b7280",
	"classDef current fill:#bfdbfe,stroke:#1d4ed8,stroke-width:3px",
}

// WriteMermaid は形を Mermaid の flowchart TD の 1 文書にする（§6.2）。節点 id は n0・n1 … に置き換え、ステップ id は
// 表示の文字にだけ使う。節点の形は種類で分け（llm 角丸・command 等は四角・gate 六角形・select ひし形・終端は円）、
// 辺には outcome を書く。尽きたときの辺は点線にする。run を重ねたときは、終わっていない unit のいまいるステップに
// current、通ったステップに visited を付ける。終わった unit は、その終端の節点があれば current を付ける。
func WriteMermaid(w io.Writer, g *Graph) {
	var b strings.Builder
	b.WriteString("flowchart TD\n")
	fmt.Fprintf(&b, "  %%%% workflow %s (%s, cli %s)  entry: %s\n", g.Workflow.ID, g.Workflow.Source, g.Workflow.CLIVersion, g.Entry)
	ids := map[string]string{}
	for i, n := range g.Nodes {
		ids[n.ID] = fmt.Sprintf("n%d", i)
	}
	for i := range g.Nodes {
		n := &g.Nodes[i]
		fmt.Fprintf(&b, "  %s%s\n", ids[n.ID], shape(n))
	}
	limits := map[string]float64{}
	for _, l := range g.Limits {
		limits[l.Name] = l.Value
	}
	for _, l := range links(g.Edges, limits) {
		arrow := "-->"
		if l.dotted {
			arrow = "-.->"
		}
		fmt.Fprintf(&b, "  %s %s|\"%s\"| %s\n", ids[l.from], arrow, escape(strings.Join(l.labels, " / ")), ids[l.to])
	}
	b.WriteString("\n")
	for _, d := range mermaidClassDefs {
		b.WriteString("  " + d + "\n")
	}
	classes := map[string][]string{}
	for _, n := range g.Nodes {
		if n.Gate != nil && n.Gate.Decider == "human" {
			classes["human"] = append(classes["human"], ids[n.ID])
		}
		if n.Skipped {
			classes["skipped"] = append(classes["skipped"], ids[n.ID])
		}
	}
	if r := g.Run; r != nil {
		seen := map[string]bool{}
		for _, u := range r.Units {
			for _, v := range u.Visited {
				if id, ok := ids[v.Step]; ok && !seen[id] {
					seen[id] = true
					classes["visited"] = append(classes["visited"], id)
				}
			}
		}
		for _, u := range r.Units {
			at := u.CurrentStep
			if runstate.Terminal(u.Status) {
				at = endNode(r, u)
			}
			if id, ok := ids[at]; ok && at != "" {
				classes["current"] = append(classes["current"], id)
			}
		}
		for _, l := range runSummaryComments(g) {
			b.WriteString("  %% " + l + "\n")
		}
	}
	for _, c := range []string{"human", "visited", "skipped", "current"} {
		if len(classes[c]) > 0 {
			fmt.Fprintf(&b, "  class %s %s\n", strings.Join(classes[c], ","), c)
		}
	}
	_, _ = io.WriteString(w, b.String())
}

// shape は節点の形とラベル。ラベルは 1 行目に id（終端は fail: / done: と理由）、2 行目に種類の欄（テキスト表示と同じ）。
func shape(n *Node) string {
	if n.Terminal() {
		return "((\"" + escape(n.Kind+": "+n.Reason) + "\"))"
	}
	label := "\"" + escape(n.ID) + "<br/>" + escape(attr(n)) + "\""
	switch n.Kind {
	case "llm":
		return "(" + label + ")"
	case "gate":
		return "{{" + label + "}}"
	case "select":
		return "{" + label + "}"
	}
	return "[" + label + "]"
}

// link は Mermaid に描く線 1 本。
type link struct {
	from, to string
	labels   []string
	dotted   bool
}

// links は辺を線にする。同じ節点の間の素の辺（上限・retry・尽きたときの印を持たないもの）は 1 本にまとめ、outcome を
// " / " で並べる（ticket の workspace の provided・created・reused → implement のように、行き先が同じ outcome が並ぶと
// 線が重なって読めなくなるため）。線の順は、まとめた先頭の辺の順。
func links(edges []Edge, limits map[string]float64) []link {
	var out []link
	at := map[[2]string]int{}
	for _, e := range edges {
		plain := e.Exhausted == nil && e.Limit == "" && e.Kind != "retry"
		key := [2]string{e.From, e.To}
		if i, ok := at[key]; ok && plain {
			out[i].labels = append(out[i].labels, edgeLabel(e, limits))
			continue
		}
		if plain {
			at[key] = len(out)
		}
		out = append(out, link{from: e.From, to: e.To, labels: []string{edgeLabel(e, limits)}, dotted: e.Exhausted != nil})
	}
	return out
}

// edgeLabel は辺のラベル: outcome に、上限つきの goto・retry は上限を、尽きたときの辺は何が尽きたかを添える。
func edgeLabel(e Edge, limits map[string]float64) string {
	switch {
	case e.Exhausted != nil && e.Exhausted.Limit != "":
		return fmt.Sprintf("%s (%s exhausted)", e.Outcome, e.Exhausted.Limit)
	case e.Exhausted != nil:
		return fmt.Sprintf("%s (retry exhausted)", e.Outcome)
	case e.Kind == "retry":
		return fmt.Sprintf("%s (retry<=%d)", e.Outcome, e.Retry)
	case e.Limit != "":
		if v, ok := limits[e.Limit]; ok {
			return fmt.Sprintf("%s (%s<=%s)", e.Outcome, e.Limit, num(v))
		}
		return fmt.Sprintf("%s (%s)", e.Outcome, e.Limit)
	}
	return e.Outcome
}

// endNode は終わった unit が達した終端の節点 id（succeeded は done:<理由>、failed は fail:<理由>）。予約値の既定の失敗・
// 停止など終端の節点を持たない終わり方は空を返す。理由は unit が 1 つなら run の理由と同じ。
func endNode(r *Run, u RunUnit) string {
	if r.Reason == nil || len(r.Units) != 1 {
		return ""
	}
	switch u.Status {
	case runstate.StatusSucceeded:
		return "done:" + *r.Reason
	case runstate.StatusFailed:
		return "fail:" + *r.Reason
	}
	return ""
}

// runSummaryComments は現在地の要約（テキスト表示の末尾と同じ文）を Mermaid のコメントにする（図には出ない）。
func runSummaryComments(g *Graph) []string {
	return runSummary(g, 0)
}

// escape はラベルの中で Mermaid の文法・HTML とぶつかる文字を Mermaid の実体参照にする。
func escape(s string) string {
	return strings.NewReplacer(`"`, "#quot;", "<", "#lt;", ">", "#gt;").Replace(s)
}

package graph

import (
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// テキスト表示（§6.1）の凡例。既定の失敗と interrupted ゲートは辺にしないので（§3.4）、ここで 1 回だけ書く。
var (
	legendItems = []string{"[human] decided by a person", "[tty] needs a terminal", "-> next", "! fail", "= done",
		"~ goto/retry with a limit"}
	notShown = "not shown: unhandled step_error/step_timeout/invalid_output/budget_exhausted fail the run; " +
		"a step left running by a dead runner waits at the built-in gate interrupted"
)

// --run を付けたときに凡例へ足す項目（§6.1）。
var runLegendItems = []string{"> current step", "* visited (executions, last outcome)"}

const (
	// attrMax を超える種類の欄（長い select の参照等）は欄を広げず、その行だけ後ろへはみ出させる。
	attrMax = 26
	// legendIndent は凡例の 2 行目以降の字下げ（"legend: " の幅）。
	legendIndent = 8
	// minRest は折り返した行の字下げの後に残したい最小の幅。下回るなら遷移の欄に揃えず contIndent で字下げする。
	minRest    = 24
	contIndent = 6
)

// WriteText は形をテキストで書く。width が正なら、その幅に収まらない行を折り返す（0 以下なら折り返さない）。
//
// 折り返しは区切り（遷移の " | "・凡例の項目・語）でだけ行い、1 つの遷移・1 つの項目の途中では切らない。続きの行は
// 遷移の欄の開始位置に揃える。それでは残りが minRest 桁を下回るほど狭い端末では、contIndent 桁の字下げに落とす。
// 1 項目が残りの幅より長いときは、その項目だけ幅を超えて出す（切ると outcome と行き先の対応が読めなくなるため）。
func WriteText(w io.Writer, g *Graph, width int) {
	limits := map[string]float64{}
	var ls []string
	for _, l := range g.Limits {
		limits[l.Name] = l.Value
		ls = append(ls, l.Name+"="+num(l.Value))
	}
	if len(ls) == 0 {
		ls = []string{"(none)"}
	}
	lines := wrapAt(fmt.Sprintf("workflow %s (%s, cli %s)  ", g.Workflow.ID, g.Workflow.Source, g.Workflow.CLIVersion),
		[]string{"entry: " + g.Entry}, "  ", contIndent, width)
	lines = append(lines, wrapAt("limits: ", ls, " ", legendIndent, width)...)
	legend := legendItems
	if g.Run != nil {
		legend = append(append([]string{}, legend...), runLegendItems...)
	}
	lines = append(lines, wrapAt("legend: ", legend, "  ", legendIndent, width)...)
	lines = append(lines, wrapAt(strings.Repeat(" ", legendIndent), strings.Fields(notShown), " ", legendIndent, width)...)
	lines = append(lines, "")

	var steps []*Node
	idw, attrw := 0, 0
	attrs := map[string]string{}
	for i := range g.Nodes {
		n := &g.Nodes[i]
		if n.Terminal() {
			continue
		}
		steps = append(steps, n)
		attrs[n.ID] = attr(n)
		idw = max(idw, runes(n.ID))
		if a := runes(attrs[n.ID]); a <= attrMax {
			attrw = max(attrw, a)
		}
	}
	marks, notes := runMarks(g.Run)
	for _, n := range steps {
		mark := marks[n.ID]
		if mark == "" {
			mark = " "
		}
		head := mark + " " + pad(n.ID, idw) + "  " + pad(attrs[n.ID], attrw) + "  "
		items := transitions(g, n.ID, limits)
		if note := notes[n.ID]; note != "" {
			// 現在地の要約は最後の遷移に続けて置き、折り返しても行き先と取り違えないよう遷移の区切りでは書かない。
			if len(items) == 0 {
				items = []string{note}
			} else {
				items[len(items)-1] += "  " + note
			}
		}
		lines = append(lines, wrapAt(head, items, " | ", 2+idw+2+attrw+2, width)...)
	}
	if g.Run != nil {
		lines = append(lines, "")
		lines = append(lines, runSummary(g, width)...)
	}
	for _, l := range lines {
		fmt.Fprintln(w, strings.TrimRight(l, " "))
	}
}

// attr は種類の欄: llm は予算と timeout、command は timeout、gate は型・決める主体・印、select は参照。
func attr(n *Node) string {
	parts := []string{n.Kind}
	switch n.Kind {
	case "llm":
		if n.BudgetUSD > 0 {
			parts = append(parts, "$"+num(n.BudgetUSD))
		}
		if d := FormatDuration(n.Timeout); d != "" {
			parts = append(parts, d)
		}
	case "command":
		if d := FormatDuration(n.Timeout); d != "" {
			parts = append(parts, d)
		}
	case "gate":
		if g := n.Gate; g != nil {
			parts = append(parts, g.Type)
			if g.Decider == "human" {
				parts = append(parts, "[human]")
			} else {
				parts = append(parts, g.Decider)
			}
			if g.RequiresTTY {
				parts = append(parts, "[tty]")
			}
			if g.Observe != nil {
				parts = append(parts, *g.Observe)
			}
		}
	case "select":
		if n.Select != nil {
			parts = append(parts, n.Select.Value)
		}
	}
	return strings.Join(parts, " ")
}

// transitions は 1 ステップの遷移を outcome ごとに 1 項目にする（尽きたときの辺は通常の辺の項目に括弧で添える）。
func transitions(g *Graph, from string, limits map[string]float64) []string {
	var items []string
	for i := 0; i < len(g.Edges); i++ {
		e := g.Edges[i]
		if e.From != from || e.Exhausted != nil {
			continue
		}
		var ex *Edge
		if i+1 < len(g.Edges) && g.Edges[i+1].From == from && g.Edges[i+1].Outcome == e.Outcome && g.Edges[i+1].Exhausted != nil {
			ex = &g.Edges[i+1]
		}
		switch {
		case e.Kind == "retry":
			items = append(items, fmt.Sprintf("%s ~ %s (retry<=%d%s)", e.Outcome, e.To, e.Retry, then(ex)))
		case e.Limit != "":
			bound := e.Limit
			if v, ok := limits[e.Limit]; ok {
				bound += "<=" + num(v)
			}
			items = append(items, fmt.Sprintf("%s ~ %s (%s%s)", e.Outcome, e.To, bound, then(ex)))
		default:
			items = append(items, e.Outcome+" "+target(e))
		}
	}
	return items
}

func then(ex *Edge) string {
	if ex == nil {
		return ""
	}
	return ", then " + target(*ex)
}

// target は行き先を印つきで書く: 終端は ! <理由>・= <理由>、それ以外は -> <ステップ>。
func target(e Edge) string {
	switch e.Kind {
	case "fail":
		return "! " + strings.TrimPrefix(e.To, "fail:")
	case "done":
		return "= " + strings.TrimPrefix(e.To, "done:")
	}
	return "-> " + e.To
}

// wrapAt は prefix の後に items を sep でつなぎ、width を超える前で折り返す。続きの行は indent 桁で字下げする
// （残りが minRest を下回るなら contIndent）。折り返した位置の区切りは書かない（行の切れ目が区切りを兼ねる）。
func wrapAt(prefix string, items []string, sep string, indent, width int) []string {
	if width > 0 && width-indent < minRest {
		indent = contIndent
	}
	blank := strings.Repeat(" ", indent)
	var lines []string
	cur, empty := prefix, true
	for _, it := range items {
		s := sep
		if empty {
			s = ""
		}
		// 行の頭（字下げだけ）なら幅を超えても置く。そうでなければ、収まらない項目は次の行へ送る。
		if width > 0 && strings.TrimSpace(cur) != "" && runes(cur)+runes(s)+runes(it) > width {
			lines = append(lines, strings.TrimRight(cur, " "))
			cur, s = blank, ""
		}
		cur += s + it
		empty = false
	}
	return append(lines, cur)
}

func pad(s string, w int) string {
	if n := runes(s); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}

func runes(s string) int { return utf8.RuneCountInString(s) }

func num(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }

// runMarks は行の先頭の印（> いまいるステップ・* 通ったステップ）と、行末に添える回数と最後の outcome を返す。
// いまいるステップは終わっていない unit の current_step だけにする（終わった unit の current_step は最後に動いた
// ステップで、そこに居るわけではない）。unit が複数なら、行末の要約は unit ごとに key を付けて並べる。
func runMarks(r *Run) (map[string]string, map[string]string) {
	marks, notes := map[string]string{}, map[string]string{}
	if r == nil {
		return marks, notes
	}
	parts := map[string][]string{}
	for _, u := range r.Units {
		at := map[string]bool{}
		for _, v := range u.Visited {
			at[v.Step] = true
			marks[v.Step] = "*"
			p := fmt.Sprintf("x%d, last %s", v.Executions, v.LastOutcome)
			if len(r.Units) > 1 {
				p = u.Key + ": " + p
			}
			parts[v.Step] = append(parts[v.Step], p)
		}
		if u.CurrentStep != "" && !runstate.Terminal(u.Status) && !at[u.CurrentStep] && len(r.Units) > 1 {
			parts[u.CurrentStep] = append(parts[u.CurrentStep], u.Key+": here")
		}
	}
	for _, u := range r.Units {
		if u.CurrentStep != "" && !runstate.Terminal(u.Status) {
			marks[u.CurrentStep] = ">"
		}
	}
	for step, ps := range parts {
		notes[step] = "(" + strings.Join(ps, "; ") + ")"
	}
	return marks, notes
}

// runSummary は形の後に置く現在地の要約（unit ごと）。待っていれば再開のコマンドを添える。実行中のまま runner が
// 居ない run は、graph が記録し直さないこと（§4）と、status・resume を呼んだ後にどう見えるかを書く（§12）。
func runSummary(g *Graph, width int) []string {
	r := g.Run
	var lines []string
	for _, u := range r.Units {
		label := "run " + r.RunID
		if len(r.Units) > 1 {
			label += " unit " + u.Key
		}
		var where string
		switch {
		case u.Waiting != nil:
			where = fmt.Sprintf("waiting at %s (decider %s)", u.Waiting.Gate, u.Waiting.Decider)
		case runstate.Terminal(u.Status):
			where = u.Status
			if r.Reason != nil && runstate.Terminal(r.Status) {
				where += " (" + *r.Reason + ")"
			}
			if u.CurrentStep != "" {
				where += " after " + u.CurrentStep
			}
		default:
			where = u.Status + " at " + u.CurrentStep
		}
		items := []string{where, fmt.Sprintf("round %d", u.Round)}
		for _, l := range g.Limits {
			if l.Name == workflow.BudgetLimit { // 予算は使った回数ではなく使った額で出す
				continue
			}
			items = append(items, fmt.Sprintf("%s %d/%s", l.Name, u.LimitsUsed[l.Name], num(l.Value)))
		}
		if b := u.Budget; b != nil {
			s := fmt.Sprintf("spent %.2f/%.2f USD", b.SpentUSD, b.LimitUSD)
			if b.UnknownCostCount > 0 {
				s += fmt.Sprintf(" (unknown cost x%d)", b.UnknownCostCount)
			}
			items = append(items, s)
		}
		lines = append(lines, wrapAt(label+": ", items, ", ", contIndent, width)...)
		if u.Waiting != nil {
			// 再開のコマンドはそのまま貼れるよう折り返さない。
			lines = append(lines, "  resume: "+u.Waiting.ResumeCommand)
		}
		if r.RunnerAlive != nil && !*r.RunnerAlive && u.Waiting == nil && !runstate.Terminal(u.Status) {
			note := fmt.Sprintf("the runner is not alive: nothing is advancing this run. graph does not record that; "+
				"harness status or harness resume will end step %s as interrupted and wait at the built-in gate interrupted", u.CurrentStep)
			lines = append(lines, wrapAt("  ", strings.Fields(note), " ", 2, width)...)
		}
	}
	return lines
}

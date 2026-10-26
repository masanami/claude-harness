package graph

import (
	"bytes"
	"strings"
	"testing"
)

func text(g *Graph, width int) []string {
	var buf bytes.Buffer
	WriteText(&buf, g, width)
	return strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
}

// stepLines は凡例の後の空行より後（ステップの行）だけを返す。
func stepLines(lines []string) []string {
	for i, l := range lines {
		if l == "" {
			return lines[i+1:]
		}
	}
	return nil
}

// 折り返さないとき、ステップは定義の順に 1 行ずつ並び、遷移の表記は凡例のとおり（§6.1）。
func TestTextUnwrapped(t *testing.T) {
	g := Build(load(t, repoWorkflows, repoScripts, "ticket"), SourceEmbedded, "1.2.3")
	lines := text(g, 0)
	if lines[0] != "workflow ticket (embedded, cli 1.2.3)  entry: resolve" || lines[1] != "limits: budget_usd=40 rework=3" {
		t.Fatalf("header = %q", lines[:2])
	}
	if !strings.HasPrefix(lines[2], "legend: [human] decided by a person") || !strings.Contains(lines[3], "interrupted") {
		t.Fatalf("legend = %q", lines[2:4])
	}
	steps := stepLines(lines)
	if len(steps) != 20 {
		t.Fatalf("%d step lines:\n%s", len(steps), strings.Join(steps, "\n"))
	}
	want := map[string][]string{
		"resolve":      {"command 2m", "ok -> analyze | base_missing ! base_missing | links_invalid ! links_invalid"},
		"e2e":          {"llm $8 60m", "pass -> quality | fail ~ fix (rework<=3, then ! e2e)"},
		"quality":      {"command 30m", "pass -> publish | fail ~ fix (rework<=3, then ! quality_gate_red) | undeclared ! quality_gate_undeclared"},
		"ci":           {"command 20m", "red ~ fix (rework<=3, then ! ci_red)", "timeout ~ ci (retry<=1, then -> ci-pending)"},
		"review":       {"gate input any ", "respond -> respond | ready -> merge-route"},
		"review-human": {"gate input [human] [tty]", "abort ! aborted_by_human"},
		"human-merge":  {"gate observe [human] pr-state", "open -> human-merge"},
		"merge-route":  {"select $steps.resolve.base_kind", "integration -> merge | default -> human-merge"},
		"cleanup":      {"released = merged | kept = merged | dirty = merged_worktree_dirty"},
	}
	human := 0
	for _, l := range steps {
		id := strings.Fields(l)[0]
		for _, s := range want[id] {
			if !strings.Contains(l, s) {
				t.Errorf("%s: %q does not contain %q", id, l, s)
			}
		}
		if strings.Contains(l, "[human]") {
			human++
		}
	}
	if human != 3 {
		t.Errorf("%d lines marked [human], want 3", human)
	}
}

// 狭い端末では遷移の区切りでだけ折り返し、1 つの遷移の途中では切らない。続きの行は遷移の欄に揃え、
// 欄に揃えると残りが狭すぎる幅では小さい字下げに落とす（§12）。
func TestTextWrapped(t *testing.T) {
	g := Build(load(t, repoWorkflows, repoScripts, "ticket"), SourceEmbedded, "1.2.3")
	limits := map[string]float64{}
	for _, l := range g.Limits {
		limits[l.Name] = l.Value
	}
	for _, width := range []int{100, 80, 60, 40, 20} {
		steps := stepLines(text(g, width))
		// 行ごとに、どのステップの行か（頭の行か続きの行か）を辿りながら、その行に載った遷移を数える。
		var cur *Node
		got := map[string][]string{}
		for _, l := range steps {
			if !strings.HasPrefix(l, "   ") {
				id := strings.Fields(l)[0]
				cur = node(t, g, id)
				l = strings.TrimSpace(strings.TrimPrefix(l, "  "+id))
				l = strings.TrimSpace(strings.TrimPrefix(l, attr(cur)))
			}
			if l = strings.TrimSpace(l); l == "" {
				continue
			}
			got[cur.ID] = append(got[cur.ID], strings.Split(l, " | ")...)
		}
		for _, n := range g.Nodes {
			if n.Terminal() {
				continue
			}
			want := transitions(g, n.ID, limits, n.Skipped)
			if strings.Join(got[n.ID], "\n") != strings.Join(want, "\n") {
				t.Errorf("width %d: %s transitions = %q, want %q", width, n.ID, got[n.ID], want)
			}
		}
		// 幅を超えてよいのは、1 つの遷移だけの行と、遷移を載せていないステップの頭の行だけ。
		for _, l := range steps {
			if len([]rune(l)) <= width {
				continue
			}
			trimmed := strings.TrimSpace(l)
			if strings.Contains(trimmed, " | ") || (!strings.HasPrefix(l, "   ") && strings.Contains(trimmed, " -> ")) {
				t.Errorf("width %d: line could have been wrapped: %q", width, l)
			}
		}
	}
	// 80 桁では続きの行が遷移の欄（ステップの頭の行の遷移の開始位置）に揃う。
	steps := stepLines(text(g, 80))
	col := strings.Index(steps[0], "ok -> analyze")
	if col <= 0 || !strings.HasPrefix(steps[1], strings.Repeat(" ", col)+"base_missing ! base_missing") {
		t.Fatalf("80 columns: continuation not aligned at %d:\n%s\n%s", col, steps[0], steps[1])
	}
	// 40 桁では欄に揃えると残りが狭すぎるので、6 桁の字下げに落とす。
	for _, l := range stepLines(text(g, 40)) {
		if strings.HasPrefix(l, "      ") && !strings.HasPrefix(l, "       ") {
			return
		}
	}
	t.Fatal("40 columns: no continuation line with the small indent")
}

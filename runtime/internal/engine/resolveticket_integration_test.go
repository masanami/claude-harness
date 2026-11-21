package engine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// uses_integration の入力の表と統合ブランチの名前の規則（docs/harness-runtime-design.md §5.6.3「入力」「統合ブランチの名前」）。

func TestResolveTicketIntegrationInputTable(t *testing.T) {
	dir := t.TempDir()
	taskFile := filepath.Join(dir, "task.md")
	if err := os.WriteFile(taskFile, []byte("# タスク\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	base := []string{"--task_file", taskFile, "--task_id", "T-1", "--uses_integration", "true"}
	with := func(extra ...string) []string { return append(append([]string{}, base...), extra...) }
	long := "C" + strings.Repeat("a", 63) // 64 字（受ける上限）
	cases := []struct {
		name    string
		args    []string
		outcome string
		base    string
		wantMsg string
	}{
		{name: "challenge_id が無い", args: with(), outcome: "input_invalid", wantMsg: "challenge_id が無い"},
		{name: "challenge_id が空", args: with("--challenge_id", ""), outcome: "input_invalid", wantMsg: "challenge_id が無い"},
		{name: "C-<番号>", args: with("--challenge_id", "C-12"), outcome: "ok", base: "integration/c-12"},
		{name: "小文字にする", args: with("--challenge_id", "AbC-9"), outcome: "ok", base: "integration/abc-9"},
		{name: "C-<番号> に限らない", args: with("--challenge_id", "ws1.Task_7"), outcome: "ok", base: "integration/ws1.task_7"},
		{name: "64 字は受ける", args: with("--challenge_id", long), outcome: "ok", base: "integration/" + strings.ToLower(long)},
		{name: "65 字は受けない", args: with("--challenge_id", long+"a"), outcome: "input_invalid", wantMsg: "統合ブランチの名前にできる形でない"},
		{name: "先頭が英数字でない（-）", args: with("--challenge_id", "-c1"), outcome: "input_invalid", wantMsg: "形でない"},
		{name: "先頭が英数字でない（.）", args: with("--challenge_id", ".c1"), outcome: "input_invalid", wantMsg: "形でない"},
		{name: "空白を含む", args: with("--challenge_id", "c 1"), outcome: "input_invalid", wantMsg: "形でない"},
		{name: "スラッシュを含む", args: with("--challenge_id", "a/b"), outcome: "input_invalid", wantMsg: "形でない"},
		{name: ".. を含む", args: with("--challenge_id", "a..b"), outcome: "input_invalid", wantMsg: "形でない"},
		{name: "末尾が .", args: with("--challenge_id", "c1."), outcome: "input_invalid", wantMsg: "形でない"},
		{name: "末尾が .LOCK（小文字にした後で .lock になる）", args: with("--challenge_id", "C1.LOCK"), outcome: "input_invalid", wantMsg: "形でない"},
		{name: "末尾が .lock", args: with("--challenge_id", "c1.lock"), outcome: "input_invalid", wantMsg: "形でない"},
		{name: "日本語", args: with("--challenge_id", "課題1"), outcome: "input_invalid", wantMsg: "形でない"},
		{name: "base も渡された", args: with("--challenge_id", "C-12", "--base", "feat/x"), outcome: "input_invalid", wantMsg: "base も渡されている"},
		{name: "base が既定ブランチでも誤り", args: with("--challenge_id", "C-12", "--base", "main"), outcome: "input_invalid", wantMsg: "base も渡されている"},
		{name: "issue だけでも統合ブランチ", args: []string{"--issue", "42", "--uses_integration", "true", "--challenge_id", "C-3"}, outcome: "ok", base: "integration/c-3"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tl := newTools(t)
			r, code, stderr := resolveWith(t, tl, "", c.args...)
			if code != 0 {
				t.Fatalf("exit %d: %s", code, stderr)
			}
			if r.Outcome != c.outcome {
				t.Fatalf("got %+v", r)
			}
			if c.wantMsg != "" && !strings.Contains(r.Message, c.wantMsg) {
				t.Errorf("message %q lacks %q", r.Message, c.wantMsg)
			}
			if c.outcome != "ok" {
				if r.Integration != "none" || r.Key != "" {
					t.Errorf("an invalid input must say integration none and have no key: %+v", r)
				}
				if calls := tl.read(tl.gh, "calls") + tl.read(tl.git, "calls"); calls != "" {
					t.Errorf("an input check called gh or git: %s", calls)
				}
				return
			}
			if r.Base != c.base || r.BaseKind != "integration" || r.BaseSource != "challenge" || r.Integration != "create" || r.Message != "" {
				t.Errorf("got %+v", r)
			}
			// origin に在るかは確かめない（作るのは次の段）
			if strings.Contains(tl.read(tl.git, "calls"), "ls-remote") {
				t.Errorf("resolve looked at origin for a branch it names itself: %s", tl.read(tl.git, "calls"))
			}
		})
	}
}

// links_invalid で止まる実行は、統合ブランチを作る段へ進まない（integration は none）。
func TestResolveTicketIntegrationLinksInvalidIsNotCreate(t *testing.T) {
	r, code, stderr := resolveWith(t, newTools(t), "Refs: 12abc\n", "--issue", "42", "--uses_integration", "true", "--challenge_id", "C-5")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if r.Outcome != "links_invalid" || r.Integration != "none" {
		t.Fatalf("got %+v", r)
	}
}

// uses_integration が true のときは Issue 本文の Base: 行を読まない（issue だけのときも）。Refs:・Closes: 行は、いままでどおり読む。
func TestResolveTicketIntegrationIgnoresTheBaseLine(t *testing.T) {
	tl := newTools(t)
	r, code, stderr := resolveWith(t, tl, "Base: feat/issue-40\nRefs: #159\n", "--issue", "42", "--uses_integration", "true", "--challenge_id", "C-5")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if r.Outcome != "ok" || r.Base != "integration/c-5" || r.BaseSource != "challenge" || len(r.Refs) != 1 || r.Refs[0] != 159 {
		t.Fatalf("got %+v", r)
	}
	// 食い違う Base: 行が 2 つあっても止まらない（読まない）
	r, _, _ = resolveWith(t, newTools(t), "Base: feat/a\nBase: feat/b\n", "--issue", "42", "--uses_integration", "true", "--challenge_id", "C-5")
	if r.Outcome != "ok" || r.Base != "integration/c-5" {
		t.Fatalf("got %+v", r)
	}
}

// uses_integration が true でない実行は、いままでと同じ（challenge_id は受けるだけ。integration は none）。人が作った統合ブランチ（Base: 行・base）は、
// 無ければいままでどおり base_missing（作らない）。
func TestResolveTicketWithoutUsesIntegrationIsUnchanged(t *testing.T) {
	for _, c := range []struct {
		name    string
		body    string
		args    []string
		outcome string
		base    string
		kind    string
		source  string
	}{
		{name: "uses_integration が無く challenge_id だけ", args: []string{"--issue", "42", "--challenge_id", "C-5"}, outcome: "ok", base: "main", kind: "default", source: "default"},
		{name: "uses_integration が false", args: []string{"--issue", "42", "--uses_integration", "false", "--challenge_id", "bad id"}, outcome: "ok", base: "main", kind: "default", source: "default"},
		{name: "Base: 行の統合ブランチが無い", body: "Base: feat/issue-40\n", args: []string{"--issue", "42", "--challenge_id", "C-5"}, outcome: "base_missing", base: "feat/issue-40", kind: "integration", source: "issue"},
		{name: "base の入力の統合ブランチが無い", args: []string{"--issue", "42", "--base", "feat/issue-40"}, outcome: "base_missing", base: "feat/issue-40", kind: "integration", source: "input"},
	} {
		t.Run(c.name, func(t *testing.T) {
			tl := newTools(t)
			r, code, stderr := resolveWith(t, tl, c.body, c.args...)
			if code != 0 {
				t.Fatalf("exit %d: %s", code, stderr)
			}
			if r.Outcome != c.outcome || r.Base != c.base || r.BaseKind != c.kind || r.BaseSource != c.source || r.Integration != "none" {
				t.Fatalf("got %+v", r)
			}
			if c.outcome == "base_missing" && !strings.Contains(r.Message, "git push -u origin "+c.base) {
				t.Errorf("message %q", r.Message)
			}
		})
	}
}

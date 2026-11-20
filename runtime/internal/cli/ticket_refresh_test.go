package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// review の待ちの先頭の取り直し（refresh: pr-head。#388 の S3-5）の通しの試験。同梱の ticket を、偽の claude・gh と実の git で
// レビュー待ちまで進め、外から push された（偽の gh が返す先頭が変わった）後の status を見る。

// headEvents は run の events.jsonl にある workspace の head のイベントの数。
func headEvents(t *testing.T, l *landFixture) int {
	t.Helper()
	out, _, _ := l.f.h.run("status", "--json", l.id)
	dir := decode[statusView](t, out).RunDir
	return strings.Count(readFile(t, filepath.Join(dir, "events.jsonl")), `"action":"head"`)
}

// externalPush は、外から PR の先頭へ push された形にする（origin に新しいコミットを作り、偽の gh が返す先頭をそれにする）。
func externalPush(t *testing.T, l *landFixture) string {
	t.Helper()
	sha := advanceMain(t, l.f, "pushed.txt", "pushed\n")
	l.setPRHead(sha)
	return sha
}

func prViews(l *landFixture) int { return strings.Count(l.ghCalls(), "pr\tview\t") }

// 外から push された後の contract status の commit は新しい先頭になる。記録（head_sha）も追従し、ラウンドごとの記録は変わらない。
func TestTicketStatusRefreshesThePRHeadAfterAnExternalPush(t *testing.T) {
	l := newLandFixture(t, nil)
	before, _ := l.f.h.contract("status", l.id)
	if refs := commitRefs(before); len(refs) != 1 || refs[0] != l.head {
		t.Fatalf("commit artifacts before = %v, want [%s]", refs, l.head)
	}
	pushed := externalPush(t, l)
	after, _ := l.f.h.contract("status", l.id)
	if refs := commitRefs(after); len(refs) != 1 || refs[0] != pushed {
		t.Fatalf("commit artifacts after an external push = %v, want [%s]", refs, pushed)
	}
	out, _, _ := l.f.h.run("status", "--json", l.id)
	ws := decode[statusView](t, out).Units[0].Workspace
	if ws.HeadSHA != pushed || ws.HeadSHAs["1"] != l.head {
		t.Fatalf("workspace = %+v, want head_sha %s and the round-1 head %s kept", ws, pushed, l.head)
	}
	// 記録と同じ先頭なら、もう書かない（何度 status しても head のイベントは 1 つ）。
	l.f.h.contract("status", l.id)
	if n := headEvents(t, l); n != 1 {
		t.Fatalf("head events = %d, want 1", n)
	}
}

// 先頭が変わっていなければ、何も書かない。
func TestTicketStatusWritesNothingWhenTheHeadIsUnchanged(t *testing.T) {
	l := newLandFixture(t, nil)
	l.f.h.contract("status", l.id)
	l.f.h.contract("status", l.id)
	if n := headEvents(t, l); n != 0 {
		t.Fatalf("head events = %d, want 0", n)
	}
	if prViews(l) == 0 {
		t.Fatalf("status did not read the PR head at a refresh gate:\n%s", l.ghCalls())
	}
}

// gh が失敗しても、出力は記録のまま出る（何も書かない）。
func TestTicketStatusKeepsTheRecordedHeadWhenGhFails(t *testing.T) {
	l := newLandFixture(t, nil)
	before, _ := l.f.h.contract("status", l.id)
	externalPush(t, l)
	if err := os.WriteFile(filepath.Join(l.f.ghDir, "pr-missing"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	after, _ := l.f.h.contract("status", l.id)
	if after.State != before.State || after.Summary != before.Summary {
		t.Fatalf("after = %+v\nbefore = %+v", after, before)
	}
	if refs := commitRefs(after); len(refs) != 1 || refs[0] != l.head {
		t.Fatalf("commit artifacts with a failing gh = %v, want the recorded [%s]", refs, l.head)
	}
	if n := headEvents(t, l); n != 0 {
		t.Fatalf("head events = %d, want 0", n)
	}
	// 人が読む status は、標準エラーに理由を出して、いつもどおり出す。
	out, errOut, code := l.f.h.run("status", l.id)
	if code != ExitOK || !strings.Contains(out, "waiting at gate review") || !strings.Contains(errOut, "cannot refresh the PR head") {
		t.Fatalf("status exit %d\n%s\n%s", code, out, errOut)
	}
}

// 印の無いゲート（human-merge。観測のゲート）で待っているときは、gh を呼ばない。
func TestTicketStatusDoesNotCallGhAtAGateWithoutTheMark(t *testing.T) {
	l := newLandFixture(t, nil)
	if _, errOut, code := l.f.h.run("resume", l.id, "--input", "ready"); code != ExitWaiting {
		t.Fatalf("ready exit %d\n%s", code, errOut)
	}
	n := prViews(l)
	externalPush(t, l)
	l.f.h.contract("status", l.id)
	l.f.h.run("status", "--json", l.id)
	if got := prViews(l); got != n {
		t.Fatalf("status called gh pr view at a gate without refresh (%d -> %d):\n%s", n, got, l.ghCalls())
	}
}

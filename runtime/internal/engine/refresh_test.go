package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// RefreshHeads（§5.6.2）の、読んでから書くまでの間にゲートが動いたときの振る舞い。gh は、読み終わる前に止まって待つ偽物で、
// その間にテストがゲートを解く・解いて開き直す。

// refreshRun は PR を出して review のゲートで待っている run（refresh は印のとおり）。
func refreshRun(t *testing.T, refresh string) (*runstate.Run, *runstate.State) {
	t.Helper()
	run, err := runstate.Create(t.TempDir(), "r1")
	if err != nil {
		t.Fatal(err)
	}
	st, err := run.Append(
		runstate.Event{Type: runstate.EvRunStarted, RunStarted: &runstate.RunStarted{RunID: "r1", Inputs: map[string]json.RawMessage{}, PID: 1, Units: []string{MainUnit}, EntryStep: "pr"}},
		runstate.Event{Type: runstate.EvRoundStarted, RoundStarted: &runstate.RoundStarted{Unit: MainUnit, Round: 1, Trigger: runstate.Trigger{Kind: "start"}}},
		runstate.Event{Type: runstate.EvStepStarted, StepStarted: &runstate.StepStarted{Unit: MainUnit, Step: "pr", Attempt: 1}},
		runstate.Event{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{Unit: MainUnit, Action: runstate.WorkspacePR, Branch: "b", PRNumber: 7, PRURL: "u", HeadSHA: "abc"}},
		runstate.Event{Type: runstate.EvStepFinished, StepFinished: &runstate.StepFinished{Unit: MainUnit, Step: "pr", Attempt: 1, Outcome: "opened"}},
		runstate.Event{Type: runstate.EvTransition, Transition: &runstate.Transition{Unit: MainUnit, From: "pr", Outcome: "opened", Action: "gate", To: "review"}},
		reviewOpened(refresh),
	)
	if err != nil {
		t.Fatal(err)
	}
	return run, st
}

func reviewOpened(refresh string) runstate.Event {
	return runstate.Event{Type: runstate.EvGateOpened, GateOpened: &runstate.GateOpened{Unit: MainUnit, Gate: "review", Type: "input", Decider: "any", RequestedAction: "r", Inputs: []string{"respond"}, Refresh: refresh}}
}

// ghScript は、読み始めたら started を作り、go ができるまで待ってから先頭を返す偽の gh。呼ばれるたびに calls へ 1 行足す。
func ghScript(t *testing.T, head string) (bin, dir string) {
	t.Helper()
	dir = t.TempDir()
	bin = filepath.Join(dir, "gh")
	script := fmt.Sprintf("#!/bin/sh\necho call >> %q\ntouch %q\nwhile [ ! -f %q ]; do sleep 0.02; done\necho '{\"headRefOid\":%q}'\n",
		filepath.Join(dir, "calls"), filepath.Join(dir, "started"), filepath.Join(dir, "go"), head)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, dir
}

func ghCalls(dir string) int {
	b, _ := os.ReadFile(filepath.Join(dir, "calls"))
	return strings.Count(string(b), "call")
}

func headEventCount(t *testing.T, run *runstate.Run) int {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(run.Dir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(b), `"action":"head"`)
}

// refreshWhile は RefreshHeads を別の goroutine で走らせ、gh が読み始めたら during を実行してから gh を終わらせ、結果の状態を返す。
func refreshWhile(t *testing.T, run *runstate.Run, st *runstate.State, bin, dir string, during func()) (*runstate.State, string) {
	t.Helper()
	type res struct {
		st   *runstate.State
		warn string
	}
	done := make(chan res, 1)
	go func() {
		var warn bytes.Buffer
		s := RefreshHeads(context.Background(), run, st, bin, "", t.TempDir(), &warn)
		done <- res{s, warn.String()}
	}()
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(filepath.Join(dir, "started")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("gh was not called")
		}
	}
	if during != nil {
		during()
	}
	if err := os.WriteFile(filepath.Join(dir, "go"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	r := <-done
	return r.st, r.warn
}

func resolveReview(t *testing.T, run *runstate.Run) {
	t.Helper()
	if _, err := run.Append(
		runstate.Event{Type: runstate.EvRunnerStarted, RunnerStarted: &runstate.RunnerStarted{PID: os.Getpid(), Command: "resume"}},
		runstate.Event{Type: runstate.EvGateResolved, GateResolved: &runstate.GateResolved{Unit: MainUnit, Gate: "review", Outcome: "respond", Actor: "resume", Channel: "non-tty"}},
	); err != nil {
		t.Fatal(err)
	}
}

func TestRefreshHeadsRecordsANewHead(t *testing.T) {
	run, st := refreshRun(t, "pr-head")
	bin, dir := ghScript(t, "def")
	got, warn := refreshWhile(t, run, st, bin, dir, nil)
	if ws := got.Unit(MainUnit).Workspace; ws.HeadSHA != "def" || ws.HeadSHAs["1"] != "abc" || warn != "" {
		t.Fatalf("workspace = %+v warn = %q", ws, warn)
	}
	if n := headEventCount(t, run); n != 1 {
		t.Fatalf("head events = %d", n)
	}
}

func TestRefreshHeadsWritesNothingForTheRecordedHead(t *testing.T) {
	run, st := refreshRun(t, "pr-head")
	bin, dir := ghScript(t, "abc")
	refreshWhile(t, run, st, bin, dir, nil)
	if n := headEventCount(t, run); n != 0 {
		t.Fatalf("head events = %d", n)
	}
}

func TestRefreshHeadsDoesNotCallGhWithoutTheMark(t *testing.T) {
	run, st := refreshRun(t, "")
	bin, dir := ghScript(t, "def")
	got := RefreshHeads(context.Background(), run, st, bin, "", t.TempDir(), &bytes.Buffer{})
	if n := ghCalls(dir); n != 0 || got != st {
		t.Fatalf("gh calls = %d (state returned as is: %v)", n, got == st)
	}
}

// gh が読めなければ何も書かず、理由を標準エラーへ出し、いまの記録のまま返す。
func TestRefreshHeadsKeepsTheRecordWhenGhFails(t *testing.T) {
	run, st := refreshRun(t, "pr-head")
	var warn bytes.Buffer
	got := RefreshHeads(context.Background(), run, st, filepath.Join(t.TempDir(), "no-such-gh"), "", t.TempDir(), &warn)
	if got.Unit(MainUnit).Workspace.HeadSHA != "abc" || !strings.Contains(warn.String(), "cannot refresh the PR head") || headEventCount(t, run) != 0 {
		t.Fatalf("workspace = %+v warn = %q", got.Unit(MainUnit).Workspace, warn.String())
	}
}

// 読んでいる間にゲートが解かれたら書かない。
func TestRefreshHeadsDoesNotWriteWhenTheGateWasResolvedMeanwhile(t *testing.T) {
	run, st := refreshRun(t, "pr-head")
	bin, dir := ghScript(t, "def")
	_, warn := refreshWhile(t, run, st, bin, dir, func() { resolveReview(t, run) })
	if warn != "" {
		t.Fatalf("a gate resolved meanwhile must be skipped silently, got warning %q", warn)
	}
	if n := headEventCount(t, run); n != 0 {
		t.Fatalf("head events = %d, want 0 after the gate was resolved", n)
	}
}

// 解かれた後に同じゲートへ戻ってきた（opened_at が違う）ときも書かない。
func TestRefreshHeadsDoesNotWriteWhenTheSameGateWasReopenedMeanwhile(t *testing.T) {
	run, st := refreshRun(t, "pr-head")
	bin, dir := ghScript(t, "def")
	_, warn := refreshWhile(t, run, st, bin, dir, func() {
		resolveReview(t, run)
		if _, err := run.Append(
			runstate.Event{Type: runstate.EvTransition, Transition: &runstate.Transition{Unit: MainUnit, From: "review", Outcome: "respond", Action: "gate", To: "review"}},
			reviewOpened("pr-head"),
		); err != nil {
			t.Fatal(err)
		}
	})
	if n := headEventCount(t, run); n != 0 || warn != "" {
		t.Fatalf("head events = %d, warning %q; want 0 and none after the gate was reopened", n, warn)
	}
}

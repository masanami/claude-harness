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

// RefreshHeads の統合ブランチの取り直し（§5.6.3）。偽の git は、ls-remote を数え、go ができるまで止まってから先頭を返す。

func refreshRunWithIntegration(t *testing.T, withIntegration bool) (*runstate.Run, *runstate.State) {
	t.Helper()
	run, err := runstate.Create(t.TempDir(), "r1")
	if err != nil {
		t.Fatal(err)
	}
	evs := []runstate.Event{
		{Type: runstate.EvRunStarted, RunStarted: &runstate.RunStarted{RunID: "r1", Inputs: map[string]json.RawMessage{}, PID: 1, Units: []string{MainUnit}, EntryStep: "pr"}},
		{Type: runstate.EvRoundStarted, RoundStarted: &runstate.RoundStarted{Unit: MainUnit, Round: 1, Trigger: runstate.Trigger{Kind: "start"}}},
		{Type: runstate.EvStepStarted, StepStarted: &runstate.StepStarted{Unit: MainUnit, Step: "pr", Attempt: 1}},
	}
	if withIntegration {
		evs = append(evs, runstate.Event{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{Unit: MainUnit, Action: runstate.WorkspaceIntegration, Branch: "integration/c-1", HeadSHA: "i0"}})
	}
	evs = append(evs,
		runstate.Event{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{Unit: MainUnit, Action: runstate.WorkspacePR, Branch: "b", PRNumber: 7, PRURL: "u", HeadSHA: "abc"}},
		runstate.Event{Type: runstate.EvStepFinished, StepFinished: &runstate.StepFinished{Unit: MainUnit, Step: "pr", Attempt: 1, Outcome: "opened"}},
		runstate.Event{Type: runstate.EvTransition, Transition: &runstate.Transition{Unit: MainUnit, From: "pr", Outcome: "opened", Action: "gate", To: "review"}},
		reviewOpened("pr-head"),
	)
	st, err := run.Append(evs...)
	if err != nil {
		t.Fatal(err)
	}
	return run, st
}

// gitLsRemoteScript は、ls-remote が呼ばれたら calls へ 1 行足し、started を作り、go ができるまで待ってから "<head>\t<ref>" を返す。
func gitLsRemoteScript(t *testing.T, head string) (bin, dir string) {
	t.Helper()
	dir = t.TempDir()
	bin = filepath.Join(dir, "git")
	script := fmt.Sprintf("#!/bin/sh\necho \"$@\" >> %q\ntouch %q\nwhile [ ! -f %q ]; do sleep 0.02; done\nprintf '%%s\\t%%s\\n' %q \"$3\"\n",
		filepath.Join(dir, "calls"), filepath.Join(dir, "started"), filepath.Join(dir, "go"), head)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, dir
}

func integrationEventCount(t *testing.T, run *runstate.Run) int {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(run.Dir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(b), `"action":"integration"`)
}

func ghHead(t *testing.T, head string) string {
	t.Helper()
	bin, _ := ghScript(t, head)
	_ = os.WriteFile(filepath.Join(filepath.Dir(bin), "go"), nil, 0o644)
	return bin
}

// refreshGitWhile は RefreshHeads を走らせ、git（ls-remote）が読み始めたら during を実行してから git を終わらせる。
func refreshGitWhile(t *testing.T, run *runstate.Run, st *runstate.State, gitBin, dir string, during func()) (*runstate.State, string) {
	t.Helper()
	type res struct {
		st   *runstate.State
		warn string
	}
	done := make(chan res, 1)
	gh := ghHead(t, "abc")
	go func() {
		var warn bytes.Buffer
		s := RefreshHeads(context.Background(), run, st, gh, gitBin, t.TempDir(), &warn)
		done <- res{s, warn.String()}
	}()
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(filepath.Join(dir, "started")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("git was not called")
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

func TestRefreshHeadsRecordsANewIntegrationHead(t *testing.T) {
	run, st := refreshRunWithIntegration(t, true)
	bin, dir := gitLsRemoteScript(t, "i1")
	got, warn := refreshGitWhile(t, run, st, bin, dir, nil)
	ws := got.Unit(MainUnit).Workspace
	if ws.IntegrationHead != "i1" || ws.IntegrationBranch != "integration/c-1" || ws.HeadSHA != "abc" || warn != "" {
		t.Fatalf("workspace = %+v warn = %q", ws, warn)
	}
	if n := integrationEventCount(t, run); n != 2 { // 段の中の 1 つと、取り直しの 1 つ
		t.Fatalf("integration events = %d, want 2", n)
	}
	if calls := readCalls(dir); !strings.Contains(calls, "ls-remote origin refs/heads/integration/c-1") {
		t.Fatalf("git calls = %q", calls)
	}
}

func readCalls(dir string) string {
	b, _ := os.ReadFile(filepath.Join(dir, "calls"))
	return string(b)
}

func TestRefreshHeadsWritesNothingForTheRecordedIntegrationHead(t *testing.T) {
	run, st := refreshRunWithIntegration(t, true)
	bin, dir := gitLsRemoteScript(t, "i0")
	refreshGitWhile(t, run, st, bin, dir, nil)
	if n := integrationEventCount(t, run); n != 1 {
		t.Fatalf("integration events = %d, want 1", n)
	}
}

// 統合先の記録の無い unit では、git を呼ばない。
func TestRefreshHeadsDoesNotLsRemoteWithoutAnIntegrationRecord(t *testing.T) {
	run, st := refreshRunWithIntegration(t, false)
	bin, dir := gitLsRemoteScript(t, "i1")
	RefreshHeads(context.Background(), run, st, ghHead(t, "abc"), bin, t.TempDir(), &bytes.Buffer{})
	if calls := readCalls(dir); calls != "" {
		t.Fatalf("git was called: %q", calls)
	}
}

// 読めなければ何も書かず、理由を標準エラーへ出し、記録のまま返す。
func TestRefreshHeadsKeepsTheIntegrationRecordWhenGitFails(t *testing.T) {
	run, st := refreshRunWithIntegration(t, true)
	var warn bytes.Buffer
	got := RefreshHeads(context.Background(), run, st, ghHead(t, "abc"), filepath.Join(t.TempDir(), "no-such-git"), t.TempDir(), &warn)
	if got.Unit(MainUnit).Workspace.IntegrationHead != "i0" || !strings.Contains(warn.String(), "cannot refresh the integration branch head") || integrationEventCount(t, run) != 1 {
		t.Fatalf("workspace = %+v warn = %q", got.Unit(MainUnit).Workspace, warn.String())
	}
}

// 読んでいる間にゲートが解かれたら書かない。
func TestRefreshHeadsDoesNotWriteIntegrationWhenTheGateWasResolvedMeanwhile(t *testing.T) {
	run, st := refreshRunWithIntegration(t, true)
	bin, dir := gitLsRemoteScript(t, "i1")
	_, warn := refreshGitWhile(t, run, st, bin, dir, func() { resolveReview(t, run) })
	if warn != "" || integrationEventCount(t, run) != 1 {
		t.Fatalf("warn = %q, integration events = %d, want none written", warn, integrationEventCount(t, run))
	}
}

// origin に無くなっていたら書かない。
func TestRefreshHeadsDoesNotWriteIntegrationWhenOriginLostTheBranch(t *testing.T) {
	run, st := refreshRunWithIntegration(t, true)
	dir := t.TempDir()
	bin := filepath.Join(dir, "git")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	got := RefreshHeads(context.Background(), run, st, ghHead(t, "abc"), bin, t.TempDir(), &bytes.Buffer{})
	if got.Unit(MainUnit).Workspace.IntegrationHead != "i0" || integrationEventCount(t, run) != 1 {
		t.Fatalf("workspace = %+v", got.Unit(MainUnit).Workspace)
	}
}

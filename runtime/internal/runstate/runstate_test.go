package runstate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func intp(n int) *int { return &n }

// sample は全種類のイベントを含む、畳み込める列（ラウンド・limit・retry・$edge・予約値・停止）。
func sample() []Event {
	return []Event{
		{Type: EvRunStarted, RunStarted: &RunStarted{
			RunID: "r1", Workflow: WorkflowRef{ID: "w", Schema: "harness.workflow/v1", Hash: "h", Path: "/w.yaml"},
			Inputs: map[string]json.RawMessage{"issue": json.RawMessage(`42`), "base": json.RawMessage(`"main"`)},
			Limits: map[string]float64{"rework": 3, "budget_usd": 40.5}, Origin: "cli", Cwd: "/repo", PID: 123,
			ScriptsDir: "/s", WorkflowDir: "/wd", Units: []string{"main"}, EntryStep: "ci",
		}},
		{Type: EvRoundStarted, RoundStarted: &RoundStarted{Unit: "main", Round: 1, Trigger: Trigger{Kind: "start"}}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "ci", Attempt: 1, PID: 9, Argv: []string{"bash", "ci.sh"}, StdoutLog: "logs/ci.1.stdout", StderrLog: "logs/ci.1.stderr"}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "ci", Attempt: 1, Outcome: "timeout", Output: json.RawMessage(`{"ci":"timeout"}`), ExitCode: intp(0)}},
		{Type: EvTransition, Transition: &Transition{Unit: "main", From: "ci", Outcome: "timeout", Action: "step", To: "ci", Retry: true}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "ci", Attempt: 2, PID: 10}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "ci", Attempt: 2, Outcome: "red", Output: json.RawMessage(`{"ci":"red","log":"boom"}`), ExitCode: intp(0)}},
		{Type: EvTransition, Transition: &Transition{Unit: "main", From: "ci", Outcome: "red", Action: "step", To: "fix", Limit: "rework", Edge: map[string]json.RawMessage{"failure": json.RawMessage(`"boom"`)}}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "fix", Attempt: 1, PID: 11}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "fix", Attempt: 1, Outcome: "step_error", Reserved: true, ExitCode: intp(2), Error: "exit code 2"}},
		{Type: EvTransition, Transition: &Transition{Unit: "main", From: "fix", Outcome: "step_error", Action: "step", To: "ci"}},
		{Type: EvCancelRequested, CancelRequested: &CancelRequested{Actor: "cli", Channel: "non-tty"}},
		{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "ci", Attempt: 3, PID: 12}},
		{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "ci", Attempt: 3, Cancelled: true, Error: "cancelled"}},
		{Type: EvRunCancelled, RunCancelled: &RunCancelled{Actor: "cli", Channel: "non-tty", Note: "stopped"}},
	}
}

// finished は正常に終わる列（run_finished で閉じる）。
func finished() []Event {
	evs := sample()[:11]
	return append(evs,
		Event{Type: EvStepStarted, StepStarted: &StepStarted{Unit: "main", Step: "ci", Attempt: 3, PID: 12}},
		Event{Type: EvStepFinished, StepFinished: &StepFinished{Unit: "main", Step: "ci", Attempt: 3, Outcome: "green", Output: json.RawMessage(`{"ci":"green"}`), ExitCode: intp(0)}},
		Event{Type: EvTransition, Transition: &Transition{Unit: "main", From: "ci", Outcome: "green", Action: "done", Reason: "merged"}},
		Event{Type: EvRunFinished, RunFinished: &RunFinished{Status: StatusSucceeded, Reason: "merged"}},
	)
}

func newRun(t *testing.T) *Run {
	t.Helper()
	r, err := Create(t.TempDir(), "r1")
	if err != nil {
		t.Fatal(err)
	}
	clock := time.Date(2026, 9, 24, 0, 0, 0, 0, time.UTC)
	r.Now = func() time.Time { clock = clock.Add(time.Second); return clock }
	return r
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// イベント列 → events.jsonl → 状態 が、どの経路で作っても同じになる（往復）。
func TestRoundTrip(t *testing.T) {
	for name, evs := range map[string][]Event{"cancelled": sample(), "finished": finished()} {
		t.Run(name, func(t *testing.T) {
			r := newRun(t)
			var appended *State
			for _, ev := range evs {
				s, err := r.Append(ev)
				if err != nil {
					t.Fatalf("append %s: %v", ev.Type, err)
				}
				appended = s
			}
			loaded, torn, err := r.Load()
			if err != nil || torn != nil {
				t.Fatalf("Load: %v torn=%v", err, torn)
			}
			fileEvents, _, err := ReadEvents(filepath.Join(r.Dir, EventsFile))
			if err != nil {
				t.Fatal(err)
			}
			if len(fileEvents) != len(evs) {
				t.Fatalf("events.jsonl has %d events, want %d", len(fileEvents), len(evs))
			}
			refolded, err := Fold(fileEvents)
			if err != nil {
				t.Fatal(err)
			}
			stateFile, err := ReadStateFile(r.Dir)
			if err != nil {
				t.Fatal(err)
			}
			want := mustJSON(t, loaded)
			for label, s := range map[string]*State{"append": appended, "refold": refolded, "state.json": stateFile} {
				if got := mustJSON(t, s); got != want {
					t.Errorf("%s differs from Load:\n got %s\nwant %s", label, got, want)
				}
			}
			// 状態の JSON 自体も往復で変わらない。
			var again State
			if err := json.Unmarshal([]byte(want), &again); err != nil {
				t.Fatal(err)
			}
			if got := mustJSON(t, &again); got != want {
				t.Errorf("state JSON does not round-trip:\n got %s\nwant %s", got, want)
			}
		})
	}
}

// 畳み込みの中身（ラウンド・予算以外の 4 要素のうち PR-2 で持つもの）を固定する。
func TestFoldContents(t *testing.T) {
	s, err := Fold(withSeq(sample()))
	if err != nil {
		t.Fatal(err)
	}
	if s.Status != StatusCancelled || s.Cancelled == nil || s.Cancel == nil {
		t.Fatalf("status = %s, cancelled = %v", s.Status, s.Cancelled)
	}
	u := s.Unit("main")
	if u.Status != StatusCancelled || u.CurrentStep != "ci" {
		t.Fatalf("unit = %+v", u)
	}
	if u.LimitsUsed["rework"] != 1 {
		t.Errorf("limits_used.rework = %d, want 1", u.LimitsUsed["rework"])
	}
	r := u.CurrentRound()
	if r.Retries["ci"] != 1 {
		t.Errorf("round retries.ci = %d, want 1", r.Retries["ci"])
	}
	if len(r.Steps) != 4 || r.Steps[3].Status != "cancelled" || r.Steps[2].Outcome != "step_error" {
		t.Errorf("steps = %s", mustJSON(t, r.Steps))
	}
	// 予約値で終わった実行は出力として残さない。最後に成功した ci の出力が残る。
	if string(u.Outputs["ci"]) != `{"ci":"red","log":"boom"}` || u.Outputs["fix"] != nil {
		t.Errorf("outputs = %s", mustJSON(t, u.Outputs))
	}
	// fix → ci は with を持たないので、$edge は空に戻る。
	if u.Edge != nil {
		t.Errorf("edge = %s, want none after a transition without with", mustJSON(t, u.Edge))
	}
	if r.EndedBy != "cancelled" {
		t.Errorf("round ended_by = %q", r.EndedBy)
	}
}

func withSeq(evs []Event) []Event {
	for i := range evs {
		evs[i].Seq = i + 1
		evs[i].TS = fmt.Sprintf("t%d", i+1)
	}
	return evs
}

func writeLines(t *testing.T, r *Run, evs []Event) []string {
	t.Helper()
	var lines []string
	for _, ev := range withSeq(evs) {
		b, err := json.Marshal(ev)
		if err != nil {
			t.Fatal(err)
		}
		lines = append(lines, string(b)+"\n")
	}
	return lines
}

// 最終行が途中で切れた events.jsonl からも、最後の完全なイベントまでの状態を再構成できる。
func TestTruncatedLastLine(t *testing.T) {
	r := newRun(t)
	evs := sample()
	lines := writeLines(t, r, evs)
	path := filepath.Join(r.Dir, EventsFile)
	for k := 1; k < len(lines); k++ {
		next := lines[k]
		for _, cut := range []int{1, len(next) / 2, len(next) - 1} { // 改行だけが欠けた行も不完全として扱う
			content := strings.Join(lines[:k], "") + next[:cut]
			if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
				t.Fatal(err)
			}
			got, torn, err := r.Load()
			if err != nil {
				t.Fatalf("k=%d cut=%d: %v", k, cut, err)
			}
			if torn == nil || torn.Bytes != cut {
				t.Fatalf("k=%d cut=%d: torn = %+v, want %d bytes", k, cut, torn, cut)
			}
			want, err := Fold(withSeq(sample())[:k])
			if err != nil {
				t.Fatal(err)
			}
			if mustJSON(t, got) != mustJSON(t, want) {
				t.Fatalf("k=%d cut=%d: state differs from the fold of the first %d events", k, cut, k)
			}
		}
	}
}

// 切れた行の後ろへ追記しない: 断片を退避して切り詰めてから書く。
func TestAppendAfterTornTail(t *testing.T) {
	r := newRun(t)
	lines := writeLines(t, r, sample()[:3])
	path := filepath.Join(r.Dir, EventsFile)
	fragment := `{"seq":4,"ts":"x","type":"step_fin`
	if err := os.WriteFile(path, []byte(strings.Join(lines, "")+fragment), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := r.Append(sample()[3])
	if err != nil {
		t.Fatal(err)
	}
	if s.LastSeq != 4 {
		t.Fatalf("last_seq = %d, want 4", s.LastSeq)
	}
	evs, torn, err := ReadEvents(path)
	if err != nil || torn != nil || len(evs) != 4 {
		t.Fatalf("after append: %d events, torn=%v, err=%v", len(evs), torn, err)
	}
	aside, _ := filepath.Glob(path + ".torn-*")
	if len(aside) != 1 {
		t.Fatalf("torn fragment was not set aside: %v", aside)
	}
	if b, _ := os.ReadFile(aside[0]); string(b) != fragment {
		t.Fatalf("set-aside fragment = %q", b)
	}
}

// 途中の行が壊れているのは切れた書き込みでは説明がつかない。黙って読み飛ばさない。
func TestCorruptMiddleLineIsAnError(t *testing.T) {
	r := newRun(t)
	lines := writeLines(t, r, sample()[:4])
	lines[1] = "{not json}\n"
	if err := os.WriteFile(filepath.Join(r.Dir, EventsFile), []byte(strings.Join(lines, "")), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := r.Load(); err == nil || !strings.Contains(err.Error(), "line 2 is not a valid event") {
		t.Fatalf("want an error for the corrupt line 2, got %v", err)
	}
}

func TestFoldRejectsInconsistentLogs(t *testing.T) {
	cases := map[string]func([]Event) []Event{
		"seq gap":                       func(e []Event) []Event { e[3].Seq = 9; return e },
		"not starting with run_started": func(e []Event) []Event { return withSeq(e[1:]) },
		"finish without start":          func(e []Event) []Event { return withSeq(append(e[:2:2], e[3])) },
		"wrong payload": func(e []Event) []Event {
			e[1].RoundStarted, e[1].StepStarted = nil, &StepStarted{Unit: "main", Step: "ci", Attempt: 1}
			return e
		},
		"event after the end": func(e []Event) []Event {
			return withSeq(append(e, Event{Type: EvCancelRequested, CancelRequested: &CancelRequested{Actor: "x"}}))
		},
	}
	for name, f := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Fold(f(withSeq(sample()))); err == nil {
				t.Fatal("want an error")
			}
		})
	}
}

// 同じ run への同時書き込みはロックで直列化され、seq が欠けも重複もしない。
func TestConcurrentAppendsAreSerialized(t *testing.T) {
	r := newRun(t)
	if _, err := r.Append(sample()[:3]...); err != nil {
		t.Fatal(err)
	}
	const writers, each = 8, 10
	var wg sync.WaitGroup
	errs := make(chan error, writers*each)
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			other := &Run{ID: r.ID, Dir: r.Dir, Now: time.Now} // 別プロセス相当の別ハンドル
			for i := 0; i < each; i++ {
				if _, err := other.Append(Event{Type: EvCancelRequested, CancelRequested: &CancelRequested{Actor: fmt.Sprintf("w%d-%d", w, i)}}); err != nil {
					errs <- err
				}
			}
		}(w)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	evs, torn, err := ReadEvents(filepath.Join(r.Dir, EventsFile))
	if err != nil || torn != nil {
		t.Fatalf("%v %v", err, torn)
	}
	if len(evs) != 3+writers*each {
		t.Fatalf("%d events, want %d", len(evs), 3+writers*each)
	}
	for i, ev := range evs {
		if ev.Seq != i+1 {
			t.Fatalf("event %d has seq %d", i, ev.Seq)
		}
	}
	if _, err := os.Stat(filepath.Join(r.Dir, lockDir)); !os.IsNotExist(err) {
		t.Fatalf("lock directory left behind: %v", err)
	}
}

// 持ち主のプロセスが居ないロックは奪う（落ちた runner のロックで run が永久に書けなくならない）。
func TestStaleLockIsBroken(t *testing.T) {
	r := newRun(t)
	dir := filepath.Join(r.Dir, lockDir)
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// 存在しない PID（上限付近の値）を持ち主にする。
	if err := os.WriteFile(filepath.Join(dir, "owner"), []byte("99999999"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Append(sample()[0]); err != nil {
		t.Fatalf("append with a stale lock: %v", err)
	}
}

// 持ち主の落ちたロックへ複数の書き手が同時に来ても、奪えるのは 1 者ずつで seq が重複しない。
// 解放は自分の印のときだけ行うので、他者のロックを消さない。
func TestStaleLockTakeoverIsExclusive(t *testing.T) {
	for round := 0; round < 20; round++ {
		r := newRun(t)
		if _, err := r.Append(sample()[:3]...); err != nil {
			t.Fatal(err)
		}
		dir := filepath.Join(r.Dir, lockDir)
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "owner"), []byte("99999999 1"), 0o644); err != nil {
			t.Fatal(err)
		}
		const writers = 6
		var wg sync.WaitGroup
		errs := make(chan error, writers)
		for w := 0; w < writers; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				other := &Run{ID: r.ID, Dir: r.Dir, Now: time.Now}
				if _, err := other.Append(Event{Type: EvCancelRequested, CancelRequested: &CancelRequested{Actor: "w"}}); err != nil {
					errs <- err
				}
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Fatal(err)
		}
		evs, _, err := ReadEvents(filepath.Join(r.Dir, EventsFile))
		if err != nil {
			t.Fatal(err)
		}
		if len(evs) != 3+writers {
			t.Fatalf("round %d: %d events, want %d", round, len(evs), 3+writers)
		}
		if _, err := Fold(evs); err != nil {
			t.Fatalf("round %d: %v", round, err)
		}
	}
}

func TestUnlockLeavesOthersLock(t *testing.T) {
	r := newRun(t)
	unlock, err := r.lock()
	if err != nil {
		t.Fatal(err)
	}
	owner := filepath.Join(r.Dir, lockDir, "owner")
	if err := os.WriteFile(owner, []byte("someone else"), 0o644); err != nil {
		t.Fatal(err)
	}
	unlock()
	if b, err := os.ReadFile(owner); err != nil || string(b) != "someone else" {
		t.Fatalf("unlock removed a lock it does not own: %q %v", b, err)
	}
}

func TestInvalidEventIsNotWritten(t *testing.T) {
	r := newRun(t)
	if _, err := r.Append(sample()[0]); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(r.Dir, EventsFile))
	if _, err := r.Append(sample()[3]); err == nil { // step_finished without a running step
		t.Fatal("want an error")
	}
	after, _ := os.ReadFile(filepath.Join(r.Dir, EventsFile))
	if !bytes.Equal(before, after) {
		t.Fatal("an inconsistent event reached events.jsonl")
	}
}

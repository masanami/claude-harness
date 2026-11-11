package runstate

import (
	"os"
	"os/exec"
	"testing"
)

// 自分のプロセスの開始時刻は読め、何度読んでも同じ。
func TestProcStartOfSelf(t *testing.T) {
	a := ProcStart(os.Getpid())
	if a == "" {
		t.Fatal("ProcStart(self) is empty")
	}
	if b := ProcStart(os.Getpid()); a != b {
		t.Fatalf("ProcStart changed: %q then %q", a, b)
	}
	if got := ProcStart(0); got != "" {
		t.Fatalf("ProcStart(0) = %q", got)
	}
}

// RunnerAlive は PID の生存に加え、記録した開始時刻が今のプロセスと同じかで PID の再利用を見分ける。
func TestRunnerAlive(t *testing.T) {
	self := os.Getpid()
	start := ProcStart(self)
	cases := []struct {
		name string
		st   *State
		want bool
	}{
		{"same pid and start", &State{PID: self, PIDStart: start}, true},
		{"start not recorded (older runs)", &State{PID: self}, true},
		{"pid reused by another process", &State{PID: self, PIDStart: "Thu Jan  1 00:00:00 1970"}, false},
		{"no pid", &State{}, false},
	}
	for _, c := range cases {
		if got := RunnerAlive(c.st); got != c.want {
			t.Errorf("%s: RunnerAlive = %v, want %v", c.name, got, c.want)
		}
	}

	// 終わったプロセスは、開始時刻を記録していても生きていない。
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	if RunnerAlive(&State{PID: cmd.Process.Pid, PIDStart: start}) {
		t.Fatal("a finished process is alive")
	}
}

// runner_started は runner の PID と開始時刻を替える。
func TestFoldRunnerStartTime(t *testing.T) {
	evs := sample()[:2]
	evs[0].RunStarted.PIDStart = "A"
	evs = append(evs, Event{Type: EvRunnerStarted, RunnerStarted: &RunnerStarted{PID: 77, PIDStart: "B", Command: "detached"}})
	for i := range evs {
		evs[i].Seq = i + 1
	}
	st, err := Fold(evs[:2])
	if err != nil {
		t.Fatal(err)
	}
	if st.PID != 123 || st.PIDStart != "A" {
		t.Fatalf("after run_started: pid %d start %q", st.PID, st.PIDStart)
	}
	st, err = Fold(evs)
	if err != nil {
		t.Fatal(err)
	}
	if st.PID != 77 || st.PIDStart != "B" {
		t.Fatalf("after runner_started: pid %d start %q", st.PID, st.PIDStart)
	}
}

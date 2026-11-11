package cli

// 切り離した run（#347）。harness run --detach と contract start は、run を始めた後、harness 自身の実行ファイルを
// 新しいセッションの子プロセス（runner）として起動し直して run を進めさせ、自分はすぐ戻る。runner は呼び出し元の
// プロセス（Claude Code の Bash ツール等）の寿命・待ち時間の上限・シグナルから切り離されるので、呼び出し元が止められても
// run は取り消されない。常駐のデーモンは持たない（runner は run がゲートか終端に達したら終わる。§4.5）。

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// detachedRunnerCmd は切り離した runner の内部の入口（usage に載せない。人が呼ぶものではない）。
const detachedRunnerCmd = "__run-detached"

// detachWait は、起動した runner が run を引き継いだ（runner_started を記録した）ことを確かめるまでの待ち時間の上限。
var detachWait = 30 * time.Second

// passEnv は runner へ明示して引き継ぐ環境変数（run が読むもの）。runner はこのプロセスの環境をそのまま受け継ぐが、
// Env.Getenv で値を差し替えている場合（テスト）もその値が届くように、ここに挙げたものは Getenv の値で上書きする。
var passEnv = []string{
	"HARNESS_STATE_DIR", "XDG_STATE_HOME", "HARNESS_DATA_DIR", "XDG_DATA_HOME", "HOME", "USER", "PATH",
	PluginVersionEnv, PermissionModeEnv, "HARNESS_CLAUDE_BIN", "HARNESS_GIT_BIN", "HARNESS_GH_BIN",
}

// runnerEnv は runner の環境（このプロセスの環境に、passEnv を Env.Getenv の値で重ねたもの。空なら消す）。
func runnerEnv(env Env) []string {
	pass := map[string]bool{}
	for _, k := range passEnv {
		pass[k] = true
	}
	var out []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if !pass[k] {
			out = append(out, kv)
		}
	}
	for _, k := range passEnv {
		if v := env.Getenv(k); v != "" {
			out = append(out, k+"="+v)
		}
	}
	return out
}

// detach は run を進める runner を、新しいセッションの子プロセスとして起動する。標準入力は閉じ（/dev/null）、
// 標準出力と標準エラーは run ディレクトリの runner.log へ流す。作業ディレクトリは cwd（run を始めたディレクトリ）。
// runner が run を引き継いだ（runner_started に自分の PID を記録した）か、run が終わったのを確かめてから戻る。
func detach(env Env, run *runstate.Run, cwd string) (int, error) {
	exe, err := os.Executable()
	if err != nil {
		return 0, fmt.Errorf("cannot find the harness executable to detach the run: %v", err)
	}
	logPath := filepath.Join(run.Dir, runstate.RunnerLogFile)
	logf, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return 0, err
	}
	defer logf.Close()
	null, err := os.Open(os.DevNull)
	if err != nil {
		return 0, err
	}
	defer null.Close()
	cmd := exec.Command(exe, detachedRunnerCmd, run.ID)
	cmd.Dir = cwd
	cmd.Env = runnerEnv(env)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = null, logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return 0, fmt.Errorf("cannot start the detached runner: %v", err)
	}
	pid := cmd.Process.Pid
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	took := func() bool {
		st, _, err := run.Load()
		return err == nil && (st.PID == pid || runstate.Terminal(st.Status))
	}
	deadline := time.Now().Add(detachWait)
	for {
		if took() {
			return pid, nil
		}
		select {
		case werr := <-exited:
			if took() {
				return pid, nil
			}
			return pid, fmt.Errorf("the detached runner (pid %d) ended before it took over the run (%v); see %s", pid, werr, logPath)
		case <-time.After(20 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			return pid, fmt.Errorf("the detached runner (pid %d) did not take over the run within %s; see %s", pid, detachWait, logPath)
		}
	}
}

// cmdRunDetached は切り離した runner の本体: run のロックを取り、run を始めたプロセスから run を引き継いで
// （runner_started）、ゲートか終端に達するまで進める。結果の JSON は標準出力（runner.log）へ出す。
func cmdRunDetached(args []string, env Env) int {
	_, pos, err := parseArgs(args)
	if err != nil {
		return usageErr(env, err)
	}
	if len(pos) != 1 {
		return usageErr(env, errors.New(detachedRunnerCmd+" takes exactly one run id"))
	}
	run, err := openRun(env, pos[0])
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	unlock, err := run.RunnerLock()
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	defer unlock()
	st, _, err := run.Load()
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	if st.Status != runstate.StatusRunning {
		fmt.Fprintf(env.Stderr, "harness: run %s is %s; nothing for a runner to advance\n", st.RunID, st.Status)
		return ExitFailed
	}
	eng, err := reopen(env, run, st)
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	tools(eng, env)
	// 引き継ぐのは、run を始めたプロセス（親）か、runner の居ない run だけ。ほかに生きている runner が居れば進めない。
	parent := os.Getppid()
	_, err = run.AppendIf(func(cur *runstate.State) ([]runstate.Event, error) {
		if cur.Status != runstate.StatusRunning {
			return nil, fmt.Errorf("run %s is %s; nothing for a runner to advance", cur.RunID, cur.Status)
		}
		if cur.PID != parent && cur.PID != os.Getpid() && runstate.RunnerAlive(cur) {
			return nil, fmt.Errorf("run %s is being advanced by pid %d", cur.RunID, cur.PID)
		}
		return []runstate.Event{{Type: runstate.EvRunnerStarted, RunnerStarted: &runstate.RunnerStarted{
			PID: os.Getpid(), PIDStart: runstate.SelfStart(), Command: "detached"}}}, nil
	})
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	st, err = eng.Loop(ctx)
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: run %s stopped with an internal error: %v\n", run.ID, err)
		return ExitFailed
	}
	writeJSON(env.Stdout, view(run, st, nil))
	return exitFor(st.Status)
}

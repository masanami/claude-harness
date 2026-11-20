package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// 取り消し・失敗で終わるときの片付け（定義の最上位の release_on。docs/harness-runtime-design.md §5.6.2）。
//
// 終わりを記録する側は 4 つある（runner の失敗への遷移と取り消し・runner が居ないときの harness cancel・status／resume の後始末・
// runner を起動できなかった resume）。どれも AppendEnding を通り、終わりのイベント（run_cancelled・run_finished の failed）を書く前に、
// この run が作った作業ツリーを片付けて workspace イベント（released）を残す。定義は読み込まず、状態（run_started に写した
// release_on・scripts_dir・cwd・作業ツリーの記録）だけで動く。消せなくても終わりは成立させる。

// releaseTimeout は、終わりの片付けが起動する外部コマンド 1 つの上限。
const releaseTimeout = 2 * time.Minute

// endKind は、イベントが run の終わり（release_on に書ける値）なら、その名前を返す。
func endKind(ev runstate.Event) string {
	switch {
	case ev.Type == runstate.EvRunCancelled:
		return "cancelled"
	case ev.Type == runstate.EvRunFinished && ev.RunFinished != nil && ev.RunFinished.Status == runstate.StatusFailed:
		return "failed"
	}
	return ""
}

// unreleased は、この run が作って、まだ返していない作業ツリーを持つ unit。
func unreleased(st *runstate.State) []*runstate.Unit {
	var out []*runstate.Unit
	for _, u := range st.Units {
		// 畳み込みが released を受ける unit（失敗・running・取り消しの要求あり）だけ。ほかは消さない。
		if w := u.Workspace; w != nil && w.WorktreePath != "" && w.Created && !w.Released &&
			(st.Cancel != nil || u.Status == runstate.StatusFailed || u.Status == runstate.StatusRunning) {
			out = append(out, u)
		}
	}
	return out
}

func wantsRelease(st *runstate.State, kind string) bool {
	listed := false
	for _, k := range st.ReleaseOn {
		listed = listed || k == kind
	}
	return listed && len(unreleased(st)) > 0
}

// AppendEnding は build が返すイベントを記録する。末尾が run の終わり（run_cancelled・失敗の run_finished）で、その終わり方が
// release_on に書かれ、片付けるものがあるときは、終わりの手前までを先に記録し、作業ツリーを片付けて released を残してから、
// 終わりを記録する。片付けはロックの外で行う（時間がかかりうる）。build はロックの中で、最新の状態に対して呼ばれる。
func AppendEnding(run *runstate.Run, build func(*runstate.State) ([]runstate.Event, error)) (*runstate.State, error) {
	var end *runstate.Event
	st, err := run.AppendIf(func(cur *runstate.State) ([]runstate.Event, error) {
		evs, err := build(cur)
		if err != nil || len(evs) == 0 {
			return nil, err
		}
		if k := endKind(evs[len(evs)-1]); k != "" {
			before, serr := stateBeforeEnd(run, cur, evs[:len(evs)-1])
			if serr != nil {
				// 終わりは成立させる（片付けられるかの判定だけが、手前のイベントを当てる前の状態になる）。黙って握りつぶさない。
				fmt.Fprintf(os.Stderr, "harness: warning: cannot tell from the events before the end whether run %s has worktrees to release (%v); deciding from the state before them, so a worktree may be left behind\n", run.ID, serr)
			}
			if wantsRelease(before, k) {
				last := evs[len(evs)-1]
				end, evs = &last, evs[:len(evs)-1]
			}
		}
		return evs, nil
	})
	if err != nil || end == nil {
		return st, err
	}
	st = releaseAtEnd(run, st, endKind(*end), os.Stderr)
	return run.AppendIf(func(cur *runstate.State) ([]runstate.Event, error) {
		if runstate.Terminal(cur.Status) {
			return nil, nil
		}
		return []runstate.Event{*end}, nil
	})
}

// stateBeforeEnd は、終わりの手前までのイベント（before）を cur に当てた後の状態を返す（cur は変えない）。片付けるものがあるかは、
// この状態で判定する（interrupted のゲートの abort のように、unit を失敗にするイベントと終わりが一緒に返る道があるため）。
// 記録を読み直せない・イベントを当てられないときは、cur と理由（エラー）を返す。呼び出し側は cur で判定を続け、理由を警告に出す
// （返す状態は nil にしない。途中まで当てた状態は返さない）。
func stateBeforeEnd(run *runstate.Run, cur *runstate.State, before []runstate.Event) (*runstate.State, error) {
	if len(before) == 0 {
		return cur, nil
	}
	st, _, err := run.Load() // AppendIf のロックの中。cur と同じ内容の、当てても構わない写し
	if err != nil {
		return cur, fmt.Errorf("cannot reload the run's record: %w", err)
	}
	for i := range before {
		ev := before[i]
		ev.Seq = st.LastSeq + 1
		ev.TS = st.UpdatedAt
		next, err := runstate.Apply(st, &ev)
		if err != nil {
			return cur, fmt.Errorf("cannot apply the %s event before the end: %w", ev.Type, err)
		}
		st = next
	}
	return st, nil
}

// releaseAtEnd は、st の unit が持つ、この run が作った作業ツリーを worktree-cleanup.sh --force で消し、released を記録する。
// 所有の印が無い・この run のものでない作業ツリーは消さない（released の記録に理由を残す）。消せなくても記録して先へ進む。
func releaseAtEnd(run *runstate.Run, st *runstate.State, kind string, warn io.Writer) *runstate.State {
	for _, u := range unreleased(st) {
		w := u.Workspace
		removed, detail := removeOwned(st, u, w.WorktreePath, kind)
		ev := runstate.Event{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{
			Unit: u.Key, Action: runstate.WorkspaceReleased, Removed: removed, Detail: detail,
		}}
		next, err := run.Append(ev)
		if err != nil {
			fmt.Fprintf(warn, "harness: warning: cannot record the release of the worktree of unit %s (%s): %v\n", u.Key, w.WorktreePath, err)
			continue
		}
		if !removed {
			fmt.Fprintf(warn, "harness: warning: the worktree of unit %s was not removed: %s\n", u.Key, detail)
		}
		st = next
	}
	return st
}

// removeOwned は作業ツリーが、この run のものなら消す。消したか・理由を返す。
func removeOwned(st *runstate.State, u *runstate.Unit, path, kind string) (bool, string) {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return false, "the worktree no longer exists; nothing to remove"
	}
	gitBin := os.Getenv("HARNESS_GIT_BIN")
	if gitBin == "" {
		gitBin = "git"
	}
	out, err := runCmd(path, gitBin, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return false, fmt.Sprintf("cannot tell whether the worktree is this run's (git rev-parse failed: %v); kept", err)
	}
	mark, err := os.ReadFile(filepath.Join(strings.TrimSpace(out), ownerFile))
	if err != nil || string(mark) != st.RunID+" "+u.Key+"\n" {
		return false, "the worktree does not carry this run's ownership mark; kept"
	}
	argv := []string{"bash", filepath.Join(st.ScriptsDir, "worktree-cleanup.sh"), path, "--force"}
	var b []byte
	dir := st.Cwd
	if _, serr := os.Stat(dir); serr != nil {
		dir = os.TempDir()
	}
	b, err = runCmdEnv(dir, st.ScriptsDir, argv...)
	if err != nil {
		return false, fmt.Sprintf("worktree-cleanup failed: %v", err)
	}
	var cleanup struct {
		Removed bool `json:"removed"`
	}
	if json.Unmarshal(b, &cleanup) != nil || !cleanup.Removed {
		return false, fmt.Sprintf("worktree-cleanup did not remove the worktree: %s", strings.TrimSpace(string(b)))
	}
	return true, fmt.Sprintf("removed by worktree-cleanup --force because the run ended as %s", kind)
}

func runCmd(dir, name string, args ...string) (string, error) {
	b, err := runCmdEnv(dir, "", append([]string{name}, args...)...)
	return string(b), err
}

func runCmdEnv(dir, scriptsDir string, argv ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), releaseTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir
	if scriptsDir != "" {
		cmd.Env = append(os.Environ(), "HARNESS_SCRIPTS_DIR="+scriptsDir)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return out.Bytes(), fmt.Errorf("%s: %v: %s", strings.Join(argv, " "), err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

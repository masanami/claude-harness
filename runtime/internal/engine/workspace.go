package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// acquireMu は worktree の払い出しを直列化する（共有 .git への書き込みの競合を避ける。P8）。
// worktree-setup.sh 側の mkdir ロックは第二層（scripts/specs/worktree-setup.md）。
var acquireMu sync.Mutex

// worktreeConflictMarkers は worktree-setup.sh が「払い出し先が使えない」ときに stderr へ出す文言
// （別ブランチの登録済み worktree・未登録のディレクトリ。scripts/specs/worktree-setup.md の「挙動の要点」）。
// スクリプトはこの 2 つを他の失敗と同じ終了コードで返すので、文言で見分ける（一致しなければ step_error。fail-closed）。
var worktreeConflictMarkers = []string{
	"is already registered for a different branch",
	"already exists but is not a registered git worktree",
}

// executeWorkspace は workspace 種類（§3.2・§5.4）を 1 回実行する。
func (e *Engine) executeWorkspace(ctx context.Context, st *runstate.State, u *runstate.Unit, step *workflow.Step, attempt int) result {
	tools, err := e.beginTools(ctx, u, step, attempt)
	if err != nil {
		return result{err: err}
	}
	defer tools.close()
	with, err := withValues(st, u, step)
	if err != nil {
		return stepError("cannot resolve with: %v", err)
	}
	if step.Action == workflow.ActionRelease {
		return e.release(tools, u, step)
	}
	return e.acquire(tools, u, step, with)
}

type acquireOutput struct {
	Outcome      string `json:"outcome"`
	WorktreePath string `json:"worktree_path"`
	Branch       string `json:"branch"`
	Base         string `json:"base"`
	ProvidedBy   string `json:"provided_by"`
	Detail       string `json:"detail"`
}

// acquire は作業ツリーを得る: 呼び出し元が渡していれば検証して provided、無ければ worktree-setup で created / reused。
// 使えない払い出し先（別ブランチの worktree・未登録のディレクトリ・別のリポジトリ）は conflict。
func (e *Engine) acquire(tools *stepTools, u *runstate.Unit, step *workflow.Step, with map[string]json.RawMessage) result {
	issue, ok1 := jsonInt(with["issue"])
	branch, ok2 := jsonString(with["branch"])
	base, ok3 := jsonString(with["base"])
	if !ok1 || !ok2 || !ok3 || issue <= 0 || branch == "" || base == "" {
		return stepError("with.issue (a positive integer), with.branch and with.base (non-empty strings) are required")
	}
	acquireMu.Lock()
	defer acquireMu.Unlock()

	repoRoot := ""
	if r := tools.run(e.Cwd, e.gitBin(), "rev-parse", "--show-toplevel"); r.ok() {
		repoRoot = strings.TrimSpace(string(r.stdout))
	}
	out := acquireOutput{Base: base, Branch: branch}
	ev := &runstate.WorkspaceEvent{Unit: u.Key, Action: runstate.WorkspaceAcquired, RepoRoot: repoRoot, Base: base}

	if provided, given := jsonString(with["provided"]); given && provided != "" {
		out.ProvidedBy, out.WorktreePath = "caller", provided
		res, conflict := e.checkProvided(tools, provided)
		if res != nil {
			return *res
		}
		if conflict != "" {
			out.Outcome, out.Detail = workflow.WorkspaceConflict, conflict
			return builtinOutput(step, out)
		}
		actual := tools.run(provided, e.gitBin(), "rev-parse", "--abbrev-ref", "HEAD")
		if !actual.ok() {
			return toolFailure(actual, []string{e.gitBin(), "rev-parse", "--abbrev-ref", "HEAD"})
		}
		out.Branch = strings.TrimSpace(string(actual.stdout))
		out.Outcome, out.Detail = workflow.WorkspaceProvided, "the caller provided the worktree; the runtime does not remove it"
		if out.Branch != branch {
			// 払い出し先のブランチは呼び出し元のもの（§5.4）。提案されたブランチ名との違いは記録だけする。
			out.Detail += fmt.Sprintf(" (its branch %q differs from the proposed %q; the caller's branch is used)", out.Branch, branch)
		}
		ev.WorktreePath, ev.Branch, ev.ProvidedBy = provided, out.Branch, "caller"
		r := builtinOutput(step, out)
		r.extra = append(r.extra, runstate.Event{Type: runstate.EvWorkspace, Workspace: ev})
		return r
	}

	argv := []string{"bash", filepath.Join(e.ScriptsDir, "worktree-setup.sh"), strconv.FormatInt(issue, 10), branch, base}
	r := tools.run(e.Cwd, argv...)
	if !r.ok() {
		if r.startErr == nil && r.how == exited && r.code > 0 {
			for _, m := range worktreeConflictMarkers {
				if strings.Contains(r.stderr, m) {
					out.Outcome, out.ProvidedBy, out.Detail = workflow.WorkspaceConflict, "runtime", strings.TrimSpace(r.stderr)
					return builtinOutput(step, out)
				}
			}
		}
		return toolFailure(r, argv)
	}
	var setup struct {
		WorktreePath string `json:"worktree_path"`
		Branch       string `json:"branch"`
		Created      bool   `json:"created"`
		Reused       bool   `json:"reused"`
	}
	if err := json.Unmarshal(r.stdout, &setup); err != nil || setup.WorktreePath == "" || setup.Created == setup.Reused {
		return result{outcome: "invalid_output", reserved: true, errText: fmt.Sprintf("worktree-setup.sh output is not the documented JSON: %s", strings.TrimSpace(string(r.stdout)))}
	}
	out.WorktreePath, out.ProvidedBy = setup.WorktreePath, "runtime"
	if setup.Branch != "" {
		out.Branch = setup.Branch
	}
	created := setup.Created
	if setup.Created {
		out.Outcome, out.Detail = workflow.WorkspaceCreated, "worktree-setup created the worktree; release removes it"
	} else {
		out.Outcome = workflow.WorkspaceReused
		// 同じ run が前に作った作業ツリーを取り直した（interrupted からのやり直し等）なら、作ったのはこの run のまま。
		if prev := u.Workspace; prev != nil && prev.Created && samePath(prev.WorktreePath, setup.WorktreePath) {
			created = true
			out.Detail = "reused the worktree this run created earlier; release removes it"
		} else {
			out.Detail = "reused an existing worktree of the same branch that this run did not create; release keeps it"
		}
	}
	ev.WorktreePath, ev.Branch, ev.ProvidedBy, ev.Created = setup.WorktreePath, out.Branch, "runtime", created
	res := builtinOutput(step, out)
	res.extra = append(res.extra, runstate.Event{Type: runstate.EvWorkspace, Workspace: ev})
	return res
}

// checkProvided は呼び出し元が渡した worktree を検証する: 在るディレクトリで、git の作業ツリーの最上位で、
// run を開始したリポジトリと同じリポジトリ（git common dir が同じ）であること。
// 使えなければ conflict の理由を返す。git を起動できない等の失敗は res で返す。
func (e *Engine) checkProvided(tools *stepTools, provided string) (*result, string) {
	if !filepath.IsAbs(provided) {
		return nil, fmt.Sprintf("the provided worktree %q is not an absolute path", provided)
	}
	if fi, err := os.Stat(provided); err != nil || !fi.IsDir() {
		return nil, fmt.Sprintf("the provided worktree %q is not a directory", provided)
	}
	top := tools.run(provided, e.gitBin(), "rev-parse", "--show-toplevel")
	if !top.ok() {
		if top.how != exited || top.startErr != nil {
			r := toolFailure(top, []string{e.gitBin(), "rev-parse", "--show-toplevel"})
			return &r, ""
		}
		return nil, fmt.Sprintf("the provided worktree %q is not a git working tree", provided)
	}
	if !samePath(strings.TrimSpace(string(top.stdout)), provided) {
		return nil, fmt.Sprintf("the provided worktree %q is not the top of a git working tree (top: %s)", provided, strings.TrimSpace(string(top.stdout)))
	}
	common := []string{e.gitBin(), "rev-parse", "--path-format=absolute", "--git-common-dir"}
	theirs := tools.run(provided, common...)
	ours := tools.run(e.Cwd, common...)
	if !theirs.ok() || !ours.ok() {
		return nil, fmt.Sprintf("cannot tell whether the provided worktree %q belongs to the repository the run started in (%s)", provided, e.Cwd)
	}
	if !samePath(strings.TrimSpace(string(theirs.stdout)), strings.TrimSpace(string(ours.stdout))) {
		return nil, fmt.Sprintf("the provided worktree %q belongs to a different repository than the one the run started in (%s)", provided, e.Cwd)
	}
	return nil, ""
}

type releaseOutput struct {
	Outcome      string `json:"outcome"`
	WorktreePath string `json:"worktree_path"`
	Detail       string `json:"detail"`
}

// release は作業ツリーを返す: この run が作ったものだけを worktree-cleanup で消す（呼び出し元が渡したもの・
// この run が作っていないものは消さない。§5.4）。未コミットの変更があれば消さずに dirty。
func (e *Engine) release(tools *stepTools, u *runstate.Unit, step *workflow.Step) result {
	ws := u.Workspace
	if ws == nil || ws.WorktreePath == "" || ws.Released {
		return builtinOutput(step, releaseOutput{Outcome: workflow.WorkspaceKept, Detail: "the unit holds no acquired worktree"})
	}
	out := releaseOutput{WorktreePath: ws.WorktreePath}
	ev := &runstate.WorkspaceEvent{Unit: u.Key, Action: runstate.WorkspaceReleased}
	finish := func() result {
		ev.Detail = out.Detail
		r := builtinOutput(step, out)
		r.extra = append(r.extra, runstate.Event{Type: runstate.EvWorkspace, Workspace: ev})
		return r
	}
	if !ws.Created {
		out.Outcome = workflow.WorkspaceKept
		out.Detail = fmt.Sprintf("not created by this run (provided_by %s); kept", ws.ProvidedBy)
		return finish()
	}
	if _, err := os.Stat(ws.WorktreePath); os.IsNotExist(err) {
		out.Outcome, out.Detail = workflow.WorkspaceKept, "the worktree no longer exists; nothing to remove"
		return finish()
	}
	// 作業ツリーの外（run を開始したディレクトリ）から消す。
	argv := []string{"bash", filepath.Join(e.ScriptsDir, "worktree-cleanup.sh"), ws.WorktreePath, "--skip-if-dirty"}
	r := tools.run(e.Cwd, argv...)
	if !r.ok() {
		return toolFailure(r, argv)
	}
	var cleanup struct {
		Removed bool `json:"removed"`
		Skipped bool `json:"skipped"`
	}
	if err := json.Unmarshal(r.stdout, &cleanup); err != nil || cleanup.Removed == cleanup.Skipped {
		return result{outcome: "invalid_output", reserved: true, errText: fmt.Sprintf("worktree-cleanup.sh output is not the documented JSON: %s", strings.TrimSpace(string(r.stdout)))}
	}
	if cleanup.Skipped {
		out.Outcome, out.Detail = workflow.WorkspaceDirty, "the worktree has uncommitted changes; kept for a person to inspect"
		return finish()
	}
	ev.Removed = true
	out.Outcome, out.Detail = workflow.WorkspaceReleased, "removed by worktree-cleanup"
	return finish()
}

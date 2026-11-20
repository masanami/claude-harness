package engine

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// reBranchName は resolve-ticket.sh の valid_branch と同じ決まりのブランチ名の形（空白・制御文字・`..`・先頭の `-`・末尾の `/` や `.lock` を拒否する）。
var reBranchName = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)

func validBranchName(b string) bool {
	if !reBranchName.MatchString(b) {
		return false
	}
	return !(strings.HasPrefix(b, "-") || strings.HasSuffix(b, "/") || strings.Contains(b, "..") || strings.HasSuffix(b, ".lock") || strings.HasPrefix(b, "/"))
}

type ensureBaseOutput struct {
	Outcome string `json:"outcome"`
	Detail  string `json:"detail"`
	Branch  string `json:"branch"`
	HeadSHA string `json:"head_sha"`
}

// remoteHead は origin の refs/heads/<branch> の先頭を読む状態。
type remoteHead int

const (
	headPresent     remoteHead = iota // 在る（sha に先頭）
	headAbsent                        // 無い（ls-remote の終了コード 2）
	headUnreachable                   // 読めなかった（3 回とも）
)

// lsRemoteHead は `git ls-remote --exit-code --heads origin refs/heads/<branch>` を最大 retryTimes 回試す。終了コード 0 は在る、2 は無い、
// ほかは試し直す（終了コード 2 は確定した答えなので試し直さない）。取り消されたら cancelled を true で返す。
func (c *prCtx) lsRemoteHead(branch string) (state remoteHead, sha string, last toolResult, argv []string, cancelledNow bool) {
	ref := "refs/heads/" + branch
	for i := 0; i < retryTimes; i++ {
		if i > 0 && !c.pause() {
			return headUnreachable, "", last, argv, true
		}
		argv, last = c.git("ls-remote", "--exit-code", "--heads", "origin", ref)
		if cancelled(last) {
			return headUnreachable, "", last, argv, true
		}
		if last.startErr == nil && last.how == exited {
			switch last.code {
			case 0:
				for _, line := range strings.Split(string(last.stdout), "\n") {
					f := strings.Fields(line)
					if len(f) == 2 && f[1] == ref {
						return headPresent, f[0], last, argv, false
					}
				}
				// 0 で返ったのに該当の参照の行が無い: 読めなかったものとして扱う
			case 2:
				return headAbsent, "", last, argv, false
			}
		}
	}
	return headUnreachable, "", last, argv, false
}

// ensureBase は、宛先（統合ブランチ）が origin に無ければ、既定ブランチの先頭から作る。在れば動かさない（docs/harness-runtime-design.md §5.6.3 の
// ensure-base の 1〜5）。作るのは「その参照が origin に無いときだけ」の条件つきの push（期待する値を空にした --force-with-lease）で、素の push
// のように在る統合ブランチを早送りで動かさない。作業ツリーの払い出しより前の段なので、run を始めたディレクトリで動く。
func (c *prCtx) ensureBase() result {
	branch, from := c.str("branch"), c.str("from")
	if branch == "" || from == "" {
		return stepError("with.branch and with.from are required")
	}
	if branch == from {
		return stepError("with.branch %q is the same as with.from; refusing to create the base from itself", branch)
	}
	if !validBranchName(branch) || !validBranchName(from) {
		return stepError("with.branch %q or with.from %q is not a usable branch name", branch, from)
	}
	out := ensureBaseOutput{Branch: branch}
	finish := func(outcome, detail, head string) result {
		out.Outcome, out.Detail, out.HeadSHA = outcome, detail, head
		res := c.done(out)
		if head != "" && (outcome == "created" || outcome == "existing") {
			res.extra = append(res.extra, runstate.Event{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{
				Unit: c.u.Key, Action: runstate.WorkspaceIntegration, Branch: branch, HeadSHA: head,
			}})
		}
		return res
	}
	unreachable := func(what string, r toolResult, argv []string) result {
		return finish("unavailable", what+"（"+fmt.Sprint(retryTimes)+" 回試した）: "+firstLine(r.describe(argv)), "")
	}

	// 2: 在るか
	state, sha, r, argv, cancelledNow := c.lsRemoteHead(branch)
	if cancelledNow {
		return result{cancelled: true}
	}
	switch state {
	case headPresent:
		return finish("existing", fmt.Sprintf("統合ブランチ %s は origin に在る（先頭 %s）。動かさない。", branch, sha), sha)
	case headUnreachable:
		return unreachable("origin の統合ブランチ "+branch+" を確かめられなかった", r, argv)
	}

	// 3: 作る先頭（既定ブランチの先頭）
	r = c.try(func() toolResult {
		argv, r = c.git("fetch", "origin", "+refs/heads/"+from+":refs/remotes/origin/"+from)
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return unreachable("既定ブランチ "+from+" を取得できなかった", r, argv)
	}
	start, rr := c.revParse("refs/remotes/origin/" + from)
	if start == "" {
		return stepError("cannot read refs/remotes/origin/%s after fetching it: %s", from, firstLine(rr.describe([]string{"git", "rev-parse"})))
	}

	// 4・5: 無いときだけ作る。拒否されたら読み直して、在れば在るものを使い、無ければ refused。届かなければ 4 からやり直す
	refspec := start + ":refs/heads/" + branch
	for i := 0; i < retryTimes; i++ {
		if i > 0 && !c.pause() {
			return result{cancelled: true}
		}
		argv, r = c.git("push", "--porcelain", "--force-with-lease=refs/heads/"+branch+":", "origin", refspec)
		if cancelled(r) {
			return result{cancelled: true}
		}
		if r.startErr != nil || r.how != exited {
			continue
		}
		switch pushFlag(string(r.stdout), "refs/heads/"+branch) {
		case '*':
			return finish("created", fmt.Sprintf("統合ブランチ %s を、既定ブランチ %s の先頭 %s から作った。", branch, from, start), start)
		case '=':
			return finish("existing", fmt.Sprintf("統合ブランチ %s は、別の実行が同じ先頭 %s で先に作っていた。", branch, start), start)
		case '!':
			st, head, lr, largv, cn := c.lsRemoteHead(branch)
			if cn {
				return result{cancelled: true}
			}
			switch st {
			case headPresent:
				return finish("existing", fmt.Sprintf("統合ブランチ %s は、別の実行が先に作っていた（先頭 %s）。動かさない。", branch, head), head)
			case headAbsent:
				return finish("refused", fmt.Sprintf("origin が統合ブランチ %s を作ることを拒んだ（保護の決まり・権限・名前の重なり〔integration という名前のブランチ〕を確かめる）: %s",
					branch, firstLine(strings.TrimSpace(r.stderr))), "")
			default:
				return unreachable("統合ブランチ "+branch+" の作成を拒まれた後、origin を読み直せなかった", lr, largv)
			}
		}
		// 状態の行が無い（origin へ届かなかった）: もう一度 4 から
	}
	// 届かなかった。届かなかった間に別の実行が作っていないかを、最後に 1 度読む
	if st, head, _, _, cn := c.lsRemoteHead(branch); cn {
		return result{cancelled: true}
	} else if st == headPresent {
		return finish("existing", fmt.Sprintf("統合ブランチ %s は、別の実行が先に作っていた（先頭 %s）。動かさない。", branch, head), head)
	}
	return unreachable("統合ブランチ "+branch+" を origin へ作れなかった（届かなかった）", r, argv)
}

// pushFlag は git push --porcelain の出力から、ref（右辺が refs/heads/<ブランチ>）の状態の行の印（`*` `=` `!` ほか）を返す。無ければ 0。
func pushFlag(out, dst string) byte {
	for _, line := range strings.Split(out, "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 2 || len(f[0]) != 1 {
			continue
		}
		if i := strings.LastIndex(f[1], ":"); i >= 0 && f[1][i+1:] == dst {
			return f[0][0]
		}
	}
	return 0
}

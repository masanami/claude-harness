package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// pull-request 種類の action: sync・push・land（docs/harness-runtime-design.md §5.6.2）。どれも決定的な Go の段で、LLM を呼ばない。
//
// 一時的な失敗（gh・git fetch・git push が通らない）の決まり: 手元と PR の中身を変えていないなら、理由を添えて遷移先
// （レビュー待ち）へ戻せる結果（unavailable・blocked）で返し、変えた後なら失敗で終える。手元を巻き戻す処理は足さない。

// retryDelay は、通らなかった gh・git fetch・git push を試し直す前の待ち。
var retryDelay = time.Second

const retryTimes = 3

// prCtx は 1 つの action の実行に要るもの（外部コマンドの起動口と、unit・段・解決した with）。
type prCtx struct {
	e       *Engine
	ctx     context.Context
	u       *runstate.Unit
	step    *workflow.Step
	tools   *stepTools
	with    map[string]json.RawMessage
	dir     string
	runID   string
	attempt int
	// fetchedBase は、land が fetch した宛先の先頭（fetch できていなければ空）。統合ブランチ宛ての記録に使う。
	fetchedBase string
}

func (c *prCtx) git(args ...string) ([]string, toolResult) {
	argv := append([]string{c.e.gitBin()}, args...)
	return argv, c.tools.run(c.dir, argv...)
}

func (c *prCtx) gh(args ...string) ([]string, toolResult) {
	argv := append([]string{c.e.ghBin()}, args...)
	return argv, c.tools.run(c.dir, argv...)
}

func cancelled(r toolResult) bool { return r.how == cancelledByRequest }

// pause は試し直しの前に待つ。取り消しの要求（ctx）が来たら false を返す。
func (c *prCtx) pause() bool { return c.pauseFor(retryDelay) }

func (c *prCtx) pauseFor(d time.Duration) bool {
	if d <= 0 {
		return c.ctx.Err() == nil
	}
	select {
	case <-time.After(d):
		return true
	case <-c.ctx.Done():
		return false
	}
}

// try は f を最大 retryTimes 回、通る（ok）まで試す。最後の結果を返す。取り消されたら（cancelled）そこで止める。
func (c *prCtx) try(f func() toolResult) toolResult {
	var r toolResult
	for i := 0; i < retryTimes; i++ {
		if i > 0 && !c.pause() {
			return toolResult{how: cancelledByRequest, code: -1}
		}
		if r = f(); r.ok() || cancelled(r) {
			return r
		}
	}
	return r
}

func (c *prCtx) str(name string) string {
	s, _ := jsonString(c.with[name])
	return s
}

func (c *prCtx) number(name string) int {
	n, _ := jsonInt(c.with[name])
	return int(n)
}

// branch は作業ブランチ（払い出した作業ツリーの記録か、いまチェックアウトしているブランチ）。
func (c *prCtx) branch() (string, *result) {
	if ws := c.u.Workspace; ws != nil && c.u.ActiveWorkspace() != "" && ws.Branch != "" {
		return ws.Branch, nil
	}
	argv, r := c.git("rev-parse", "--abbrev-ref", "HEAD")
	if !r.ok() {
		res := toolFailure(r, argv)
		return "", &res
	}
	b := strings.TrimSpace(string(r.stdout))
	if b == "" || b == "HEAD" {
		res := stepError("the working tree %s is not on a branch", c.dir)
		return "", &res
	}
	return b, nil
}

// revParse は rev の全部の桁の SHA（無ければ空）。
func (c *prCtx) revParse(rev string) (string, toolResult) {
	_, r := c.git("rev-parse", "--verify", "-q", rev+"^{commit}")
	if !r.ok() {
		return "", r
	}
	return strings.TrimSpace(string(r.stdout)), r
}

func (c *prCtx) done(out any) result { return builtinOutput(c.step, out) }

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}

// --- sync -------------------------------------------------------------------

type syncOutput struct {
	Outcome    string `json:"outcome"`
	Detail     string `json:"detail"`
	HeadSHA    string `json:"head_sha"`
	HeadBefore string `json:"head_before"`
	BaseSHA    string `json:"base_sha"`
}

// sync は宛先の最新を、マージのコミットで作業ブランチへ取り込む（push はしない。rebase・強制 push をしない）。
// 順序は設計 §5.6.2 の sync の 1〜7。
func (c *prCtx) sync() result {
	base := c.str("base")
	expect := c.str("expect_head")
	out := syncOutput{}
	reentry := false
	integHead := "" // 取り込みで fetch した宛先の先頭（統合ブランチ宛てのとき記録する）
	fin := func(outcome, detail string) result {
		if reentry && outcome == "unavailable" {
			// 衝突を直した後の取り込みのコミット（push していない）が手元にある。レビュー待ちへ戻すと、次の取り込みが
			// expect_head と合わず失敗するので、手元を変えた後の一時的な失敗として、ここで失敗で終える。
			return stepError("could not reach origin after the conflict was resolved locally: %s", detail)
		}
		out.Outcome, out.Detail = outcome, detail
		res := c.done(out)
		res.extra = append(res.extra, c.integrationEvent(base, integHead)...)
		return res
	}
	baseRef := "refs/remotes/origin/" + base

	// 1・2: 作業ツリーの状態。
	argv, r := c.git("rev-parse", "-q", "--verify", "MERGE_HEAD")
	if cancelled(r) {
		return result{cancelled: true}
	}
	inMerge := r.ok()
	if !inMerge && (r.startErr != nil || r.how != exited || r.code != 1) {
		return toolFailure(r, argv)
	}
	if !inMerge {
		argv, r = c.git("status", "--porcelain", "--untracked-files=no")
		if !r.ok() {
			return toolFailure(r, argv)
		}
		if strings.TrimSpace(string(r.stdout)) != "" {
			return stepError("the working tree %s has uncommitted changes; commit them before the sync", c.dir)
		}
	}
	head, hr := c.revParse("HEAD")
	if head == "" {
		return toolFailure(hr, []string{"git", "rev-parse", "HEAD"})
	}
	out.HeadSHA, out.HeadBefore = head, head
	if inMerge {
		return fin("unresolved", "マージの途中のまま戻った（衝突を直す段がマージを終えなかった）。")
	}

	// 3: 衝突を直す段の後の再入。HEAD が、先頭 head_before と宛先の先頭 base_sha をちょうど親に持つマージのコミットであること。
	if c.u.Outcomes[c.step.ID] == "conflict" {
		var prev syncOutput
		_ = json.Unmarshal(c.u.Outputs[c.step.ID], &prev)
		argv, r = c.git("rev-list", "--parents", "-n", "1", "HEAD")
		if !r.ok() {
			return toolFailure(r, argv)
		}
		f := strings.Fields(string(r.stdout))
		if len(f) != 3 || prev.HeadBefore == "" || f[1] != prev.HeadBefore || f[2] != prev.BaseSHA {
			return fin("not_merge_only", fmt.Sprintf("衝突を直した後の HEAD %s は、先頭 %s と宛先の先頭 %s をちょうど親に持つマージのコミットではない（取り込みのコミットの外に変更を足した）。", head, prev.HeadBefore, prev.BaseSHA))
		}
		reentry = true
		out.HeadBefore, out.BaseSHA = prev.HeadBefore, prev.BaseSHA
	}

	// 4: 取り込み元（宛先の最新）と、origin にある作業ブランチを取る。手元の中身は、遅れているときの早送りのほかは変えない。
	r = c.try(func() toolResult {
		_, r := c.git("fetch", "origin", "+refs/heads/"+base+":"+baseRef)
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return fin("unavailable", "宛先 "+base+" を取得できなかった（手元は変えていない）: "+firstLine(r.describe([]string{"git", "fetch", "origin", base})))
	}
	if sha, _ := c.revParse(baseRef); sha != "" {
		integHead = sha
	}
	branch, bres := c.branch()
	if bres != nil {
		return *bres
	}
	if res := c.fastForwardFromOrigin(branch, &out, fin); res != nil {
		return *res
	}
	if head, hr = c.revParse("HEAD"); head == "" {
		return toolFailure(hr, []string{"git", "rev-parse", "HEAD"})
	}
	out.HeadSHA = head
	baseSHA, br := c.revParse(baseRef)
	if baseSHA == "" {
		return toolFailure(br, []string{"git", "rev-parse", baseRef})
	}
	if !reentry {
		out.BaseSHA = baseSHA
		out.HeadBefore = head
	}

	// 5: 最初に入ったときだけ、手元の HEAD が渡された先頭と同じことを確かめる（push していない手元のコミットを一緒に出さない）。
	if expect != "" && !reentry && head != expect {
		return fin("head_moved", fmt.Sprintf("手元の HEAD %s が、一致を確かめた PR の先頭 %s と違う（push していない手元のコミットを、取り込みと一緒には出さない）。", head, expect))
	}

	// 6: すでに宛先の先頭を含んでいる。
	_, r = c.git("merge-base", "--is-ancestor", baseRef, "HEAD")
	switch {
	case cancelled(r):
		return result{cancelled: true}
	case r.ok():
		return fin("current", fmt.Sprintf("HEAD %s は、宛先 %s の先頭 %s をすでに含んでいる。", head, base, baseSHA))
	case r.startErr != nil || r.how != exited || r.code != 1:
		return toolFailure(r, []string{"git", "merge-base", "--is-ancestor", baseRef, "HEAD"})
	}

	// 7: マージのコミットで取り込む。衝突したら、マージの途中のまま返す。
	out.HeadBefore, out.BaseSHA = head, baseSHA
	argv, r = c.git("merge", "--no-ff", "--no-edit", "-m", "Merge remote-tracking branch 'origin/"+base+"'", baseSHA) // 確かめた SHA を渡す（短い名前 origin/<base> は、同名のタグ・ブランチに解決されうる）
	if cancelled(r) {
		return result{cancelled: true}
	}
	if r.ok() {
		out.HeadSHA, _ = c.revParse("HEAD")
		return fin("synced", fmt.Sprintf("宛先 %s の先頭 %s を、マージのコミットで取り込んだ（先頭 %s → %s）。", base, baseSHA, head, out.HeadSHA))
	}
	if _, mr := c.git("rev-parse", "-q", "--verify", "MERGE_HEAD"); mr.ok() {
		return fin("conflict", fmt.Sprintf("宛先 %s の先頭 %s を取り込む途中で衝突した（先頭 %s。マージの途中のまま）。", base, baseSHA, head))
	}
	return toolFailure(r, argv)
}

// fastForwardFromOrigin は、origin に作業ブランチがあれば取り、手元が origin より遅れているだけなら早送りする。枝分かれしていれば
// diverged、取れなければ unavailable を返す（返した値があれば、そこで終える）。
func (c *prCtx) fastForwardFromOrigin(branch string, out *syncOutput, fin func(outcome, detail string) result) *result {
	remote := "refs/remotes/origin/" + branch
	argv, r := c.git("ls-remote", "--exit-code", "--heads", "origin", "refs/heads/"+branch)
	if cancelled(r) {
		res := result{cancelled: true}
		return &res
	}
	switch {
	case r.ok():
	case r.startErr == nil && r.how == exited && r.code == 2:
		return nil // origin にまだ無い（PR を出す前）
	default:
		res := fin("unavailable", "origin の作業ブランチ "+branch+" を確かめられなかった（手元は変えていない）: "+firstLine(r.describe(argv)))
		return &res
	}
	r = c.try(func() toolResult {
		_, r := c.git("fetch", "origin", "+refs/heads/"+branch+":"+remote)
		return r
	})
	if cancelled(r) {
		res := result{cancelled: true}
		return &res
	}
	if !r.ok() {
		res := fin("unavailable", "origin の作業ブランチ "+branch+" を取得できなかった（手元は変えていない）: "+firstLine(r.describe([]string{"git", "fetch", "origin", branch})))
		return &res
	}
	local, lr := c.revParse("HEAD")
	theirs, tr := c.revParse(remote)
	if local == "" || theirs == "" {
		failed := tr
		if local == "" {
			failed = lr
		}
		res := toolFailure(failed, []string{"git", "rev-parse"})
		return &res
	}
	if local == theirs {
		return nil
	}
	// 手元が origin の祖先（遅れているだけ）なら早送りする。origin が手元の祖先（進んでいる）なら何もしない。
	_, r = c.git("merge-base", "--is-ancestor", "HEAD", remote)
	switch {
	case cancelled(r):
		res := result{cancelled: true}
		return &res
	case r.ok():
		argv, r = c.git("merge", "--ff-only", remote)
		if !r.ok() {
			res := toolFailure(r, argv)
			return &res
		}
		return nil
	case r.startErr != nil || r.how != exited || r.code != 1:
		res := toolFailure(r, []string{"git", "merge-base", "--is-ancestor", "HEAD", remote})
		return &res
	}
	_, r = c.git("merge-base", "--is-ancestor", remote, "HEAD")
	switch {
	case cancelled(r):
		res := result{cancelled: true}
		return &res
	case r.ok():
		return nil
	case r.startErr != nil || r.how != exited || r.code != 1:
		res := toolFailure(r, []string{"git", "merge-base", "--is-ancestor", remote, "HEAD"})
		return &res
	}
	res := fin("diverged", fmt.Sprintf("手元の作業ブランチ %s（%s）と origin（%s）が枝分かれしている。", branch, local, theirs))
	return &res
}

// --- push -------------------------------------------------------------------

type pushOutput struct {
	Outcome  string `json:"outcome"`
	Detail   string `json:"detail"`
	PRNumber int    `json:"pr_number"`
	PRURL    string `json:"pr_url"`
	Branch   string `json:"branch"`
	HeadSHA  string `json:"head_sha"`
}

// push は作業ブランチを、強制せずに push し、PR の先頭を記録する。既定ブランチと PR の宛先そのものへは push しない。
func (c *prCtx) push() result {
	base, pr := c.str("base"), c.number("pr")
	branch, bres := c.branch()
	if bres != nil {
		return *bres
	}
	if res := c.refuseProtected(branch, base); res != nil {
		return *res
	}
	prev := ""
	if sha, _ := c.revParse("refs/remotes/origin/" + branch); sha != "" {
		prev = sha
	} else if ws := c.u.Workspace; ws != nil {
		prev = ws.HeadSHA
	}
	baseSHA, _ := c.revParse("refs/remotes/origin/" + base)
	head, hr := c.revParse("HEAD")
	if head == "" {
		return toolFailure(hr, []string{"git", "rev-parse", "HEAD"})
	}
	out := pushOutput{PRNumber: pr, Branch: branch, HeadSHA: head}
	if ws := c.u.Workspace; ws != nil {
		out.PRURL = ws.PRURL
	}

	// 参照ごとの状態の行が出れば、届いている（拒否の '!' も含む。試し直しても同じ）。出なければ、届いていないので試し直す。
	var flag byte
	var argv []string
	var r toolResult
	for i := 0; i < retryTimes && flag == 0; i++ {
		if i > 0 && !c.pause() {
			return result{cancelled: true}
		}
		argv, r = c.git("push", "--porcelain", "origin", "HEAD:refs/heads/"+branch)
		if cancelled(r) {
			return result{cancelled: true}
		}
		flag = pushStatus(string(r.stdout))
	}
	if cancelled(r) {
		return result{cancelled: true}
	}
	switch {
	case flag == '!':
		out.Outcome, out.Detail = "rejected", fmt.Sprintf("origin が push を拒否した（取り込みの間に、外から push された）: %s", firstLine(r.stderr))
	case flag == 0:
		out.Outcome, out.Detail = "unavailable", "origin へ届かなかった（"+fmt.Sprint(retryTimes)+" 回試した）: "+firstLine(r.describe(argv))
	case flag == '=':
		out.Outcome = "unchanged"
		out.Detail = fmt.Sprintf("PR の先頭は %s のまま（宛先 %s の先頭 %s を、すでに含んでいる）。宛先へは入れていない。", head, base, baseSHA)
	default:
		out.Outcome = "pushed"
		out.Detail = fmt.Sprintf("宛先 %s の先頭 %s を取り込み、PR の先頭は %s から %s になった。宛先へは入れていない。", base, baseSHA, prev, head)
	}
	res := c.done(out)
	if out.Outcome == "pushed" || out.Outcome == "unchanged" {
		res.extra = append(res.extra, c.prEvent(pr, out.PRURL, branch, head, "", true))
	}
	return res
}

// pushStatus は git push --porcelain の、参照ごとの状態の行（"<flag>\t<from>:<to>\t<summary>"）の flag。無ければ 0。
// flag: ' ' 早送り・'+' 強制・'*' 新しい参照・'=' 変更なし・'!' 拒否。
func pushStatus(stdout string) byte {
	for _, line := range strings.Split(stdout, "\n") {
		if len(line) >= 2 && line[1] == '\t' && strings.ContainsRune(" +*=!-", rune(line[0])) {
			return line[0]
		}
	}
	return 0
}

// refuseProtected は、作業ブランチが PR の宛先そのもの・リポジトリの既定ブランチなら、push を断る（publish と同じ検査）。
func (c *prCtx) refuseProtected(branch, base string) *result {
	if branch == base {
		res := stepError("the working branch %q is the PR base itself; refusing to push to the base", branch)
		return &res
	}
	argv, r := c.gh("repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name")
	if !r.ok() {
		res := toolFailure(r, argv)
		return &res
	}
	if def := strings.TrimSpace(string(r.stdout)); def == "" || branch == def {
		res := stepError("the working branch %q is the repository's default branch (%q); refusing to push to it", branch, def)
		return &res
	}
	return nil
}

// integrationEvent は、宛先 base が、この unit が記録した統合ブランチ（Workspace.IntegrationBranch）と同じときだけ、その先頭 head の
// 記録（action: integration）を返す。統合先を使わない実行・既定ブランチ宛ての実行には何も返さない。
func (c *prCtx) integrationEvent(base, head string) []runstate.Event {
	ws := c.u.Workspace
	if ws == nil || ws.IntegrationBranch == "" || ws.IntegrationBranch != base || head == "" {
		return nil
	}
	return []runstate.Event{{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{
		Unit: c.u.Key, Action: runstate.WorkspaceIntegration, Branch: base, HeadSHA: head,
	}}}
}

// prEvent は pr の記録（PR のいまの先頭・入れた後のコミット）。ラウンドごとの先頭の記録は publish だけが書く。
func (c *prCtx) prEvent(pr int, url, branch, head, merge string, headOnly bool) runstate.Event {
	return runstate.Event{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{
		Unit: c.u.Key, Action: runstate.WorkspacePR, Branch: branch, PRNumber: pr, PRURL: url,
		HeadSHA: head, MergeCommit: merge, HeadOnly: headOnly,
	}}
}

// --- land -------------------------------------------------------------------

type landOutput struct {
	Outcome     string `json:"outcome"`
	Detail      string `json:"detail"`
	HeadSHA     string `json:"head_sha"`
	MergeCommit string `json:"merge_commit"`
}

type prView struct {
	State       string `json:"state"`
	HeadRefOid  string `json:"headRefOid"`
	BaseRefName string `json:"baseRefName"`
	IsDraft     bool   `json:"isDraft"`
	MergeCommit *struct {
		Oid string `json:"oid"`
	} `json:"mergeCommit"`
}

func (v prView) mergeOid() string {
	if v.MergeCommit == nil {
		return ""
	}
	return v.MergeCommit.Oid
}

// landMergeWait は、入れる命令が通った後に PR が MERGED になるのを待つ上限（マージの待ち行列・リポジトリの側の自動マージ）、
// landMergePoll はその間に PR を読み直す間隔。
var (
	landMergeWait = 10 * time.Second
	landMergePoll = time.Second
)

// land は、先頭の一致と宛先の最新を含むことを確かめ、満たすときだけ PR を宛先へ入れる。確かめと入れる操作は 1 つの段の中にある
// （確かめずに入れる形を、遷移の付け替えで作れないようにする。§6.2 の規則 7）。設計 §5.6.2 の land の表の 1〜10。
func (c *prCtx) land() result {
	pr, base, approved := c.number("pr"), c.str("base"), c.str("approved_ref")
	if pr <= 0 {
		return stepError("with.pr must be a PR number")
	}
	var head, merge string
	finish := func(outcome, detail string) result {
		out := landOutput{Outcome: outcome, Detail: detail, HeadSHA: head, MergeCommit: merge}
		res := c.done(out)
		if head != "" || merge != "" {
			res.extra = append(res.extra, c.prEvent(pr, "", "", head, merge, true))
		}
		// 統合ブランチの先頭: 入れた（landed）なら入れた後のコミット（読み直した origin の先頭にしない）、そうでなく宛先を fetch したなら
		// fetch した先頭。
		if outcome == "landed" {
			res.extra = append(res.extra, c.integrationEvent(base, merge)...)
		} else {
			res.extra = append(res.extra, c.integrationEvent(base, c.fetchedBase)...)
		}
		return res
	}

	// 1〜7'（読み直しのために関数にする）。nil なら、どれにも当たらなかった。
	var view prView
	checks := func() (*landOutput, *result) {
		o, res := c.landChecks(pr, base, approved, &view)
		if view.HeadRefOid != "" {
			head = view.HeadRefOid
		}
		if o != nil && o.Outcome == "landed" {
			merge = o.MergeCommit
		}
		return o, res
	}
	if o, res := checks(); res != nil {
		return *res
	} else if o != nil {
		return finish(o.Outcome, o.Detail)
	}

	// 8: 下書き・チェック。
	if view.IsDraft {
		return finish("blocked", fmt.Sprintf("PR #%d は下書きなので入れない。", pr))
	}
	if why, res := c.checksNotPassing(pr, base); res != nil {
		return *res
	} else if why != "" {
		return finish("blocked", why)
	}

	// 9: 入れる。squash に固定し、先頭が通した中身と一致するときだけ GitHub が受ける（--match-head-commit）。
	// --auto・--admin・--delete-branch は付けない。
	argv, r := c.gh("pr", "merge", fmt.Sprint(pr), "--squash", "--match-head-commit", approved)
	if cancelled(r) {
		return result{cancelled: true}
	}
	if r.ok() {
		deadline := time.Now().Add(landMergeWait)
		var last string
		for {
			var v prView
			if _, vr := c.readPR(pr, &v, 1); cancelled(vr) {
				return result{cancelled: true}
			} else if vr.ok() {
				view = v
				head = v.HeadRefOid
				last = fmt.Sprintf("状態 %s・宛先 %s・先頭 %s", v.State, v.BaseRefName, v.HeadRefOid)
				if v.State == "MERGED" && v.BaseRefName == base && v.HeadRefOid == approved {
					merge = v.mergeOid()
					return finish("landed", fmt.Sprintf("PR #%d を宛先 %s へ入れた（入れた後のコミット %s）。", pr, base, merge))
				}
			}
			if time.Now().After(deadline) {
				break
			}
			if !c.pauseFor(landMergePoll) {
				return result{cancelled: true}
			}
		}
		return finish("not_confirmed", fmt.Sprintf("入れる命令は通ったが、読み直した PR が「入った・宛先 %s・先頭 %s」になっていない（%s）。入ったかどうかは上流で確かめる。", base, approved, last))
	}

	// 10: 通らなかった。確かめ直して、当たればその結果。どれにも当たらなければ blocked。
	if o, res := checks(); res != nil {
		return *res
	} else if o != nil {
		return finish(o.Outcome, o.Detail)
	}
	return finish("blocked", "PR を入れられなかった: "+firstLine(r.describe(argv)))
}

// readPR は gh pr view を最大 tries 回試して、PR を読む。
func (c *prCtx) readPR(pr int, v *prView, tries int) ([]string, toolResult) {
	var argv []string
	var r toolResult
	for i := 0; i < tries; i++ {
		if i > 0 && !c.pause() {
			return argv, toolResult{how: cancelledByRequest, code: -1}
		}
		argv, r = c.gh("pr", "view", fmt.Sprint(pr), "--json", "state,headRefOid,baseRefName,mergeCommit,isDraft")
		if cancelled(r) {
			return argv, r
		}
		if r.ok() {
			var nv prView
			if err := json.Unmarshal(r.stdout, &nv); err != nil {
				r = toolResult{code: 1, how: exited, stderr: "gh pr view output is not JSON: " + err.Error()}
				continue
			}
			*v = nv
			return argv, r
		}
	}
	return argv, r
}

// landChecks は land の表の 1〜7' を上から順に確かめ、最初に当たったものを返す（どれにも当たらなければ nil）。
// 取り消されたら 2 つ目の値を返す。view には読めた PR を入れる。
func (c *prCtx) landChecks(pr int, base, approved string, view *prView) (*landOutput, *result) {
	c.fetchedBase = "" // この確かめで宛先を fetch したときだけ、その先頭を統合ブランチの記録に使う
	// 1: PR を読む。
	var v prView
	argv, r := c.readPR(pr, &v, retryTimes)
	if cancelled(r) {
		res := result{cancelled: true}
		return nil, &res
	}
	if !r.ok() {
		*view = prView{}
		return &landOutput{Outcome: "blocked", Detail: fmt.Sprintf("PR #%d を読めない（%d 回試した）: %s", pr, retryTimes, firstLine(r.describe(argv)))}, nil
	}
	*view = v
	// 2: 宛先が違う。入った後の PR も含める（付け替えて別のブランチへ入った PR を landed にしない）。
	if v.BaseRefName != base {
		return &landOutput{Outcome: "base_changed", Detail: fmt.Sprintf("PR #%d の宛先が %s で、この run の宛先 %s と違う。", pr, v.BaseRefName, base)}, nil
	}
	switch {
	case v.State == "MERGED" && approved != "" && v.HeadRefOid == approved: // 3
		return &landOutput{Outcome: "landed", MergeCommit: v.mergeOid(), Detail: fmt.Sprintf("PR #%d はすでに宛先 %s へ入っている（入った後のコミット %s）。", pr, base, v.mergeOid())}, nil
	case v.State == "MERGED": // 4
		return &landOutput{Outcome: "merged_other", Detail: fmt.Sprintf("PR #%d はすでに入っているが、入った先頭 %s が通した中身 %s と違う。", pr, v.HeadRefOid, approved)}, nil
	case v.State == "CLOSED": // 5
		return &landOutput{Outcome: "closed", Detail: fmt.Sprintf("PR #%d は入らずに閉じている。", pr)}, nil
	}
	// 6: 通した中身と一致しない。
	if approved == "" || v.HeadRefOid != approved {
		return &landOutput{Outcome: "mismatch", Detail: fmt.Sprintf("PR の先頭 %s が、通した中身 %q と違う。入れていない。", v.HeadRefOid, approved)}, nil
	}
	// 7: 宛先の最新を含んでいるか。PR の先頭も fetch する（外から push された先頭は手元に無いことがある。無いまま祖先を判定すると、
	// コマンドの失敗を「含んでいない」と読み違える）。behind にするのは終了コード 1 のときだけ。
	baseRef := "refs/remotes/origin/" + base
	r = c.try(func() toolResult {
		_, r := c.git("fetch", "origin", "+refs/heads/"+base+":"+baseRef)
		return r
	})
	if cancelled(r) {
		res := result{cancelled: true}
		return nil, &res
	}
	if r.ok() {
		if sha, _ := c.revParse(baseRef); sha != "" {
			c.fetchedBase = sha
		}
	}
	if !r.ok() {
		return &landOutput{Outcome: "blocked", Detail: "宛先 " + base + " を取得できなかった: " + firstLine(r.describe([]string{"git", "fetch", "origin", base}))}, nil
	}
	r = c.try(func() toolResult {
		_, r := c.git("fetch", "origin", fmt.Sprintf("refs/pull/%d/head", pr))
		return r
	})
	if cancelled(r) {
		res := result{cancelled: true}
		return nil, &res
	}
	if !r.ok() {
		return &landOutput{Outcome: "blocked", Detail: fmt.Sprintf("PR #%d の先頭を取得できなかった: %s", pr, firstLine(r.describe([]string{"git", "fetch", "origin", "refs/pull/head"})))}, nil
	}
	baseSHA, _ := c.revParse(baseRef)
	_, r = c.git("merge-base", "--is-ancestor", baseRef, v.HeadRefOid)
	switch {
	case cancelled(r):
		res := result{cancelled: true}
		return nil, &res
	case r.ok():
		return nil, nil
	case r.startErr == nil && r.how == exited && r.code == 1:
		return &landOutput{Outcome: "behind", Detail: fmt.Sprintf("PR の先頭 %s は、宛先 %s の先頭 %s を含んでいない。", v.HeadRefOid, base, baseSHA)}, nil
	}
	return &landOutput{Outcome: "blocked", Detail: "宛先を含むかどうかを判定できなかった: " + firstLine(r.describe([]string{"git", "merge-base", "--is-ancestor"}))}, nil
}

type prCheck struct {
	Name   string `json:"name"`
	Bucket string `json:"bucket"`
}

// checksNotPassing は、チェックが通っていない（失敗・取り消し・未完了、または読めない）理由を返す（通っていれば空）。
// チェックが 0 件の PR は通す。宛先の CI の運用の宣言が after-merge なら見ない。成否は終了コードでなく、標準出力が JSON の配列か
// で決める（gh は未完了・失敗のチェックがあると 0 でない終了コードを返し、0 件のときは標準出力を空にして標準エラーに
// "no checks reported" を出す。plugin/scripts/lib/common.sh の fetch_pr_checks と同じ読み方）。
func (c *prCtx) checksNotPassing(pr int, base string) (string, *result) {
	if c.afterMergeCI(base) {
		return "", nil
	}
	argv, r := c.gh("pr", "checks", fmt.Sprint(pr), "--json", "name,state,bucket")
	if cancelled(r) {
		res := result{cancelled: true}
		return "", &res
	}
	var list []prCheck
	out := strings.TrimSpace(string(r.stdout))
	switch {
	case r.startErr == nil && r.how == exited && out != "" && json.Unmarshal([]byte(out), &list) == nil && strings.HasPrefix(out, "["):
	case r.startErr == nil && r.how == exited && out == "" && strings.Contains(strings.ToLower(r.stderr), "no checks reported"):
		return "", nil
	default:
		return fmt.Sprintf("PR #%d のチェックを読めない: %s", pr, firstLine(r.describe(argv))), nil
	}
	var bad []string
	for _, ch := range list {
		switch ch.Bucket {
		case "fail", "cancel", "pending":
			bad = append(bad, fmt.Sprintf("%s（%s）", ch.Name, ch.Bucket))
		}
	}
	if len(bad) > 0 {
		return fmt.Sprintf("PR #%d のチェックが通っていない（失敗か未完了）: %s", pr, strings.Join(bad, "、")), nil
	}
	return "", nil
}

// afterMergeCI は、宛先の CI の運用の宣言（.claude-harness/ci.json）が after-merge か。読めなければ（読み手の失敗を含む）
// CI を見る側（false）に倒す。
func (c *prCtx) afterMergeCI(base string) bool {
	script := filepath.Join(c.e.ScriptsDir, "ci-trigger.sh")
	if c.e.ScriptsDir == "" {
		return false
	}
	if fi, err := os.Stat(script); err != nil || !fi.Mode().IsRegular() {
		return false
	}
	r := c.tools.run(c.dir, "bash", script, "--base", base)
	if !r.ok() {
		return false
	}
	var d struct {
		Trigger string `json:"trigger"`
	}
	return json.Unmarshal(r.stdout, &d) == nil && d.Trigger == "after-merge"
}

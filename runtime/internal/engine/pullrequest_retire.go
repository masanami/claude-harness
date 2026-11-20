package engine

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

type retireOutput struct {
	Outcome string `json:"outcome"`
	Detail  string `json:"detail"`
}

var reCommitSHA = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

// retire は、既定ブランチへ入った後の統合ブランチを、origin から消す（§5.6.3 の retire の 1〜4）。
//
// origin のブランチを消す操作は、この段の中にしか無い。消す前に、PR が入っている・宛先・head のブランチ・入った先頭を、この段が自分で確かめる
// （確かめる所と消す所を 2 つの段に分けない。前の段が land であることに頼らない）。どれか 1 つでも合わない・読めないときは消さずに kept。
// 既定ブランチと PR の宛先は、どんな入力でも消す命令を組み立てない。消す命令には、入った先頭が一致するときだけ消える条件（--force-with-lease=<参照>:<先頭>）を
// 付ける。どの結果でも run を失敗にしない（この時点で、既定ブランチへは入っている）。
func (c *prCtx) retire() result {
	pr, branch, base, head := c.number("pr"), c.str("branch"), c.str("base"), c.str("head")
	if pr <= 0 || branch == "" || base == "" || head == "" {
		return stepError("with.pr, with.branch, with.base and with.head are required")
	}
	if !validBranchName(branch) || !reCommitSHA.MatchString(head) {
		return stepError("with.branch %q is not a usable branch name or with.head %q is not a full commit SHA", branch, head)
	}
	if branch == base {
		return stepError("with.branch %q is the PR base itself; refusing to build a command that deletes it", branch)
	}
	finish := func(outcome, detail string) result { return c.done(retireOutput{Outcome: outcome, Detail: detail}) }
	kept := func(why string) result { return finish("kept", "統合ブランチ "+branch+" を残した: "+why) }

	// 1: 既定ブランチは消さない。読めないときは、消してよいと確かめられないので kept。
	var argv []string
	var r toolResult
	r = c.try(func() toolResult {
		argv, r = c.gh("repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name")
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return kept("リポジトリの既定ブランチを読めなかった（" + firstLine(r.describe(argv)) + "）")
	}
	def := strings.TrimSpace(string(r.stdout))
	if def == "" {
		return kept("リポジトリの既定ブランチを読めなかった")
	}
	if branch == def {
		return stepError("with.branch %q is the repository's default branch; refusing to build a command that deletes it", branch)
	}

	// 2: PR が入っている・宛先・head のブランチ・入った先頭。
	var view struct {
		State       string `json:"state"`
		HeadRefOid  string `json:"headRefOid"`
		HeadRefName string `json:"headRefName"`
		BaseRefName string `json:"baseRefName"`
	}
	r = c.try(func() toolResult {
		argv, r = c.gh("pr", "view", fmt.Sprint(pr), "--json", "state,headRefOid,headRefName,baseRefName")
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() || json.Unmarshal(r.stdout, &view) != nil {
		return kept(fmt.Sprintf("PR #%d を読めなかった", pr))
	}
	switch {
	case view.State != "MERGED":
		return kept(fmt.Sprintf("PR #%d が入っていない（状態 %s）", pr, view.State))
	case view.BaseRefName != base:
		return kept(fmt.Sprintf("PR #%d の宛先が %s ではない（%s）", pr, base, view.BaseRefName))
	case view.HeadRefName != branch:
		return kept(fmt.Sprintf("PR #%d の head のブランチが %s ではない（%s）", pr, branch, view.HeadRefName))
	case view.HeadRefOid != head:
		return kept(fmt.Sprintf("PR #%d に入った先頭 %s が、渡された先頭 %s と違う", pr, view.HeadRefOid, head))
	}

	// 3: 統合ブランチ宛ての、開いている PR（消すと閉じてしまう）。
	var open []struct {
		Number int `json:"number"`
	}
	r = c.try(func() toolResult {
		argv, r = c.gh("pr", "list", "--base", branch, "--state", "open", "--json", "number")
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() || json.Unmarshal(r.stdout, &open) != nil {
		return kept("統合ブランチ宛ての、開いている PR を読めなかった")
	}
	if len(open) > 0 {
		return kept(fmt.Sprintf("統合ブランチ宛ての、開いている PR が %d 件在る（消すと閉じる）", len(open)))
	}

	// 4: origin の先頭が、入った先頭 head と同じときだけ消える。
	ref := "refs/heads/" + branch
	for i := 0; i < retryTimes; i++ {
		if i > 0 && !c.pause() {
			return result{cancelled: true}
		}
		argv, r = c.git("push", "--porcelain", "--force-with-lease="+ref+":"+head, "origin", ":"+ref)
		if cancelled(r) {
			return result{cancelled: true}
		}
		if r.startErr != nil || r.how != exited {
			continue
		}
		switch pushFlag(string(r.stdout), ref) {
		case '-':
			return finish("deleted", fmt.Sprintf("PR #%d が入った（先頭 %s）ので、統合ブランチ %s を origin から消した。", pr, head, branch))
		case '!':
			st, sha, lr, largv, cn := c.lsRemoteHead(branch)
			if cn {
				return result{cancelled: true}
			}
			switch st {
			case headAbsent:
				return finish("absent", fmt.Sprintf("統合ブランチ %s は、すでに origin に無い（リポジトリの設定が先に消した）。", branch))
			case headPresent:
				if sha == head {
					return kept("origin が削除を拒んだ（保護の決まりなど。先頭は入った先頭 " + head + " のまま）: " + firstLine(strings.TrimSpace(r.stderr)))
				}
				return kept(fmt.Sprintf("origin の先頭 %s が、入った先頭 %s と違う（入った後に積まれた）", sha, head))
			default:
				return kept("消す命令を拒まれた後、origin を読み直せなかった（" + firstLine(lr.describe(largv)) + "）")
			}
		}
		// 状態の行が無い（届かなかった）: もう一度
	}
	return kept("origin へ届かなかった（" + fmt.Sprint(retryTimes) + " 回試した）: " + firstLine(r.describe(argv)))
}

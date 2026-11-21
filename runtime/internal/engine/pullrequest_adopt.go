package engine

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// reAdoptRef は adopt が受ける PR の URL（https://<host>/<owner>/<repo>/pull/<番号>）。番号だけ・末尾に何かが付いた形は PR の URL とは
// 読まない（ブランチの名前として受けられるかを見る。§5.6.3）。
var reAdoptRef = regexp.MustCompile(`^https://([^/\s]+)/([^/\s]+)/([^/\s]+)/pull/([1-9][0-9]*)$`)

type adoptOutput struct {
	Outcome  string `json:"outcome"`
	Detail   string `json:"detail"`
	PRNumber int    `json:"pr_number"`
	PRURL    string `json:"pr_url"`
	Branch   string `json:"branch"`
	Base     string `json:"base"`
	HeadSHA  string `json:"head_sha"`
	Key      string `json:"key"`
	Source   string `json:"source"` // pr（PR の URL を受けた。受けられなかったときも）| integration（ブランチの名前を受けて adopted・no_pr になった）
}

// adopt は、すでにある PR を、この run の成果物として受ける（reflect 用。§5.6.2）。起動したリポジトリの PR で（other_repo）、
// 開いていて（not_open）、宛先が既定ブランチで（not_default_base）、フォークからでなく（fork。相手のブランチへ取り込みを push
// できる保証が無い）、下書きでない（draft）ことを確かめ、PR を記録する。作業ツリーの払い出しより前の段なので、run を開始した
// ディレクトリで gh を呼ぶ。
func (c *prCtx) adopt() result {
	ref := c.str("ref")
	reject := func(outcome, detail string) result {
		return c.done(adoptOutput{Outcome: outcome, Detail: detail, Source: "pr"})
	}
	m := reAdoptRef.FindStringSubmatch(ref)
	if m == nil {
		return c.adoptBranch(ref)
	}
	number, _ := strconv.Atoi(m[4])

	var pr struct {
		Number            int    `json:"number"`
		URL               string `json:"url"`
		State             string `json:"state"`
		BaseRefName       string `json:"baseRefName"`
		HeadRefName       string `json:"headRefName"`
		HeadRefOid        string `json:"headRefOid"`
		IsCrossRepository bool   `json:"isCrossRepository"`
		IsDraft           bool   `json:"isDraft"`
	}
	var argv []string
	var r toolResult
	r = c.try(func() toolResult {
		argv, r = c.gh("pr", "view", ref, "--json", "number,url,state,baseRefName,headRefName,headRefOid,isCrossRepository,isDraft")
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return toolFailure(r, argv)
	}
	if err := json.Unmarshal(r.stdout, &pr); err != nil || pr.Number <= 0 || pr.HeadRefName == "" || pr.HeadRefOid == "" {
		return stepError("gh pr view output is not the expected JSON: %s", firstLine(string(r.stdout)))
	}
	repo, fail := c.readRepo()
	if fail != nil {
		return *fail
	}

	repoHost := ""
	if u, err := url.Parse(repo.URL); err == nil {
		repoHost = u.Host
	}
	switch {
	case !strings.EqualFold(repoHost, m[1]) || !strings.EqualFold(repo.NameWithOwner, m[2]+"/"+m[3]) || pr.Number != number || !strings.EqualFold(pr.URL, ref):
		return reject("other_repo", fmt.Sprintf("PR %s は、この run を始めたリポジトリ %s のものではない。", ref, repo.NameWithOwner))
	case pr.State != "OPEN":
		return reject("not_open", fmt.Sprintf("PR #%d は開いていない（状態 %s）。", pr.Number, pr.State))
	case pr.BaseRefName != repo.DefaultBranchRef.Name:
		return reject("not_default_base", fmt.Sprintf("PR #%d の宛先 %s は、既定ブランチ %s ではない。", pr.Number, pr.BaseRefName, repo.DefaultBranchRef.Name))
	case pr.IsCrossRepository:
		return reject("fork", fmt.Sprintf("PR #%d はフォークからのもの（相手のブランチへ取り込みを push できる保証が無い）。", pr.Number))
	case pr.IsDraft:
		return reject("draft", fmt.Sprintf("PR #%d は下書きである。", pr.Number))
	}
	out := adoptOutput{
		Outcome: "adopted", PRNumber: pr.Number, PRURL: pr.URL, Branch: pr.HeadRefName, Base: pr.BaseRefName, HeadSHA: pr.HeadRefOid,
		Key: fmt.Sprintf("pr-%d", pr.Number), Source: "pr",
		Detail: fmt.Sprintf("PR #%d（ブランチ %s・先頭 %s）を受けた。宛先は既定ブランチ %s。", pr.Number, pr.HeadRefName, pr.HeadRefOid, pr.BaseRefName),
	}
	res := c.done(out)
	res.extra = append(res.extra, c.prEvent(pr.Number, pr.URL, pr.HeadRefName, pr.HeadRefOid, "", true))
	return res
}

type repoView struct {
	NameWithOwner    string `json:"nameWithOwner"`
	URL              string `json:"url"`
	DefaultBranchRef struct {
		Name string `json:"name"`
	} `json:"defaultBranchRef"`
}

// readRepo は run を始めたリポジトリの名前・URL・既定ブランチを gh で読む（最大 retryTimes 回）。読めなければ、返す結果を第 2 戻り値に入れる。
func (c *prCtx) readRepo() (repoView, *result) {
	var repo repoView
	var argv []string
	var r toolResult
	r = c.try(func() toolResult {
		argv, r = c.gh("repo", "view", "--json", "nameWithOwner,url,defaultBranchRef")
		return r
	})
	if cancelled(r) {
		return repo, &result{cancelled: true}
	}
	if !r.ok() {
		res := toolFailure(r, argv)
		return repo, &res
	}
	if err := json.Unmarshal(r.stdout, &repo); err != nil || repo.NameWithOwner == "" || repo.URL == "" || repo.DefaultBranchRef.Name == "" {
		res := stepError("gh repo view output is not the expected JSON: %s", firstLine(string(r.stdout)))
		return repo, &res
	}
	return repo, nil
}

// listedPR は gh pr list --json number,url,headRefName,headRefOid,baseRefName,isCrossRepository,isDraft の 1 件。
type listedPR struct {
	Number            int    `json:"number"`
	URL               string `json:"url"`
	HeadRefName       string `json:"headRefName"`
	HeadRefOid        string `json:"headRefOid"`
	BaseRefName       string `json:"baseRefName"`
	IsCrossRepository bool   `json:"isCrossRepository"`
	IsDraft           bool   `json:"isDraft"`
}

// openPRsFor は head から base への、開いている PR（フォークからのものを除く）を gh で読む。adopt の 4 と open の 1 が同じ読み方をする。
func (c *prCtx) openPRsFor(head, base string) ([]listedPR, *result) {
	var argv []string
	var r toolResult
	r = c.try(func() toolResult {
		argv, r = c.gh("pr", "list", "--head", head, "--base", base, "--state", "open",
			"--json", "number,url,headRefName,headRefOid,baseRefName,isCrossRepository,isDraft")
		return r
	})
	if cancelled(r) {
		return nil, &result{cancelled: true}
	}
	if !r.ok() {
		res := toolFailure(r, argv)
		return nil, &res
	}
	var listed []listedPR
	if err := json.Unmarshal(r.stdout, &listed); err != nil {
		res := stepError("gh pr list output is not a JSON array: %v", err)
		return nil, &res
	}
	var out []listedPR
	for _, pr := range listed {
		if !pr.IsCrossRepository { // 同名ブランチの fork からの PR は、この統合ブランチの PR ではない
			out = append(out, pr)
		}
	}
	return out, nil
}

// adoptBranch は、ref がブランチの名前のときの adopt（§5.6.3 の「adopt がブランチの名前を受ける道」の 1〜5）。
func (c *prCtx) adoptBranch(ref string) result {
	reject := func(outcome, detail string) result {
		return c.done(adoptOutput{Outcome: outcome, Detail: detail, Source: "pr"})
	}
	if !validBranchName(ref) {
		return reject("unsupported_ref", fmt.Sprintf("%q は、PR の URL（https://<host>/<owner>/<repo>/pull/<番号>）でも、ブランチの名前として受けられる形でもない。", ref))
	}
	repo, fail := c.readRepo()
	if fail != nil {
		return *fail
	}
	def := repo.DefaultBranchRef.Name
	if ref == def {
		return reject("unsupported_ref", fmt.Sprintf("%q は既定ブランチの名前である（統合ブランチではない）。", ref))
	}
	state, _, r, argv, cancelledNow := c.lsRemoteHead(ref)
	if cancelledNow {
		return result{cancelled: true}
	}
	switch state {
	case headAbsent:
		return reject("branch_missing", fmt.Sprintf("ブランチ %s は origin に無い。", ref))
	case headUnreachable:
		return toolFailure(r, argv)
	}
	r = c.try(func() toolResult {
		argv, r = c.git("fetch", "origin", "+refs/heads/"+ref+":refs/remotes/origin/"+ref, "+refs/heads/"+def+":refs/remotes/origin/"+def)
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return toolFailure(r, argv)
	}
	prs, fail := c.openPRsFor(ref, def)
	if fail != nil {
		return *fail
	}
	switch {
	case len(prs) > 1:
		return stepError("branch %q has %d open pull requests to %q; cannot tell which one to use", ref, len(prs), def)
	case len(prs) == 1:
		pr := prs[0]
		if pr.Number <= 0 || pr.HeadRefName == "" || pr.HeadRefOid == "" {
			return stepError("gh pr list output is not the expected JSON: %+v", pr)
		}
		if pr.IsDraft {
			return reject("draft", fmt.Sprintf("PR #%d は下書きである。", pr.Number))
		}
		out := adoptOutput{
			Outcome: "adopted", PRNumber: pr.Number, PRURL: pr.URL, Branch: pr.HeadRefName, Base: def, HeadSHA: pr.HeadRefOid,
			Key: fmt.Sprintf("pr-%d", pr.Number), Source: "integration",
			Detail: fmt.Sprintf("ブランチ %s の、開いている PR #%d（先頭 %s）を受けた。宛先は既定ブランチ %s。", ref, pr.Number, pr.HeadRefOid, def),
		}
		res := c.done(out)
		res.extra = append(res.extra, c.prEvent(pr.Number, pr.URL, pr.HeadRefName, pr.HeadRefOid, "", true))
		return res
	}

	// 開いている PR が無い: 既定ブランチに無いコミットが在れば PR を作る（no_pr）、無ければ作れない（empty）。
	argv, r = c.git("rev-list", "--count", "refs/remotes/origin/"+def+"..refs/remotes/origin/"+ref)
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return toolFailure(r, argv)
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(r.stdout)))
	if err != nil || n < 0 {
		return stepError("git rev-list --count output is not a number: %s", firstLine(string(r.stdout)))
	}
	if n == 0 {
		return reject("empty", fmt.Sprintf("ブランチ %s には、既定ブランチ %s に無いコミットが 1 つも無い（PR を作れない）。", ref, def))
	}
	head, rr := c.revParse("refs/remotes/origin/" + ref)
	if head == "" {
		return stepError("cannot read refs/remotes/origin/%s after fetching it: %s", ref, firstLine(rr.describe([]string{"git", "rev-parse"})))
	}
	return c.done(adoptOutput{
		Outcome: "no_pr", Branch: ref, Base: def, HeadSHA: head, Source: "integration",
		Detail: fmt.Sprintf("ブランチ %s（先頭 %s）に、開いている PR が無い。既定ブランチ %s に無いコミットが %d 個在るので、PR を作る。", ref, head, def, n),
	})
}

package engine

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// reAdoptRef は adopt が受ける PR の URL（https://<host>/<owner>/<repo>/pull/<番号>）。ブランチの名前・番号だけ・末尾に何かが
// 付いた形は受けない（B で統合ブランチの名前を受ける。いまは integration_reflect_unsupported で止める）。
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
}

// adopt は、すでにある PR を、この run の成果物として受ける（reflect 用。§5.6.2）。起動したリポジトリの PR で（other_repo）、
// 開いていて（not_open）、宛先が既定ブランチで（not_default_base）、フォークからでなく（fork。相手のブランチへ取り込みを push
// できる保証が無い）、下書きでない（draft）ことを確かめ、PR を記録する。作業ツリーの払い出しより前の段なので、run を開始した
// ディレクトリで gh を呼ぶ。
func (c *prCtx) adopt() result {
	ref := c.str("ref")
	reject := func(outcome, detail string) result {
		return c.done(adoptOutput{Outcome: outcome, Detail: detail})
	}
	m := reAdoptRef.FindStringSubmatch(ref)
	if m == nil {
		return reject("unsupported_ref", fmt.Sprintf("%q は PR の URL（https://<host>/<owner>/<repo>/pull/<番号>）ではない。", ref))
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
	var repo struct {
		NameWithOwner    string `json:"nameWithOwner"`
		DefaultBranchRef struct {
			Name string `json:"name"`
		} `json:"defaultBranchRef"`
	}
	r = c.try(func() toolResult {
		argv, r = c.gh("repo", "view", "--json", "nameWithOwner,defaultBranchRef")
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return toolFailure(r, argv)
	}
	if err := json.Unmarshal(r.stdout, &repo); err != nil || repo.NameWithOwner == "" || repo.DefaultBranchRef.Name == "" {
		return stepError("gh repo view output is not the expected JSON: %s", firstLine(string(r.stdout)))
	}

	switch {
	case !strings.EqualFold(repo.NameWithOwner, m[2]+"/"+m[3]) || pr.Number != number || !strings.EqualFold(pr.URL, ref):
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
		Key:    fmt.Sprintf("pr-%d", pr.Number),
		Detail: fmt.Sprintf("PR #%d（ブランチ %s・先頭 %s）を受けた。宛先は既定ブランチ %s。", pr.Number, pr.HeadRefName, pr.HeadRefOid, pr.BaseRefName),
	}
	res := c.done(out)
	res.extra = append(res.extra, c.prEvent(pr.Number, pr.URL, pr.HeadRefName, pr.HeadRefOid, "", true))
	return res
}

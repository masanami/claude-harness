package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

type openOutput struct {
	Outcome  string `json:"outcome"`
	Detail   string `json:"detail"`
	PRNumber int    `json:"pr_number"`
	PRURL    string `json:"pr_url"`
}

// open は、すでに在るブランチ（統合ブランチ）から宛先（既定ブランチ）への PR を作る（§5.6.3 の open の 1〜3）。開いている PR が在れば作らない
// （段のやり直し・同じ統合ブランチへの 2 本目の依頼で PR を 2 つ作らない）。push はしない。本文は Go が組み立てる（LLM の書くのは題名と概要だけ）。
func (c *prCtx) open() result {
	head, base, title, summary := c.str("head"), c.str("base"), strings.TrimSpace(c.str("title")), c.str("summary")
	if head == "" || base == "" || title == "" {
		return stepError("with.head, with.base and with.title are required")
	}
	if head == base || !validBranchName(head) || !validBranchName(base) {
		return stepError("with.head %q and with.base %q must be two different usable branch names", head, base)
	}
	headSHA := func() string { s, _ := c.revParse("refs/remotes/origin/" + head); return s }

	prs, fail := c.openPRsFor(head, base)
	if fail != nil {
		return *fail
	}
	if len(prs) > 1 {
		return stepError("branch %q has %d open pull requests to %q; cannot tell which one to use", head, len(prs), base)
	}
	finish := func(outcome, detail string, n int, url, sha string) result {
		res := c.done(openOutput{Outcome: outcome, Detail: detail, PRNumber: n, PRURL: url})
		res.extra = append(res.extra, c.prEvent(n, url, head, sha, "", true))
		return res
	}
	if len(prs) == 1 {
		pr := prs[0]
		if pr.Number <= 0 || pr.URL == "" {
			return stepError("gh pr list output is not the expected JSON: %+v", pr)
		}
		sha := pr.HeadRefOid
		if sha == "" {
			sha = headSHA()
		}
		return finish("existing", fmt.Sprintf("ブランチ %s の、開いている PR #%d が在る。作らない。", head, pr.Number), pr.Number, pr.URL, sha)
	}

	// 入っているタスクの PR（統合ブランチ宛ての、入った PR）
	var merged []mergedPR
	var argv []string
	var r toolResult
	r = c.try(func() toolResult {
		argv, r = c.gh("pr", "list", "--base", head, "--state", "merged", "--limit", fmt.Sprint(mergedListLimit), "--json", "number,title,url,body")
		return r
	})
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return toolFailure(r, argv)
	}
	if err := json.Unmarshal(r.stdout, &merged); err != nil {
		return stepError("gh pr list output is not a JSON array: %v", err)
	}

	if len(merged) >= mergedListLimit {
		return stepError("%d merged pull requests to %q were read, which reaches the limit (%d); the table and the Closes lines could be incomplete, so no pull request is created", len(merged), head, mergedListLimit)
	}
	bodyRel := filepath.Join(runstate.LogsDir, fmt.Sprintf("%s.%d.body.md", c.step.ID, c.attempt))
	bodyPath := filepath.Join(c.e.Run.Dir, bodyRel)
	if err := os.WriteFile(bodyPath, []byte(renderIntegrationPRBody(summary, merged, c.runID, c.str("challenge_id"))), 0o644); err != nil {
		return result{err: err}
	}
	argv, r = c.gh("pr", "create", "--base", base, "--head", head, "--title", neutralizeClosing(title), "--body-file", bodyPath)
	if cancelled(r) {
		return result{cancelled: true}
	}
	if !r.ok() {
		return toolFailure(r, argv)
	}
	url := lastLine(r.stdout)
	m := rePRURL.FindStringSubmatch(url)
	if m == nil {
		return stepError("gh pr create did not print the PR URL: %q", url)
	}
	n, _ := strconv.Atoi(m[1])
	return finish("opened", fmt.Sprintf("ブランチ %s から %s への PR #%d を作った（入っているタスクの PR %d 件）。", head, base, n, len(merged)), n, url, headSHA())
}

// mergedListLimit は、統合ブランチへ入ったタスクの PR を読む上限（gh の既定は 30）。読んだ件数がこれに届いたら、欠けている恐れがあるので PR を作らない。
const mergedListLimit = 1000

type mergedPR struct {
	Number int    `json:"number"`
	Title  string `json:"title"`
	URL    string `json:"url"`
	Body   string `json:"body"`
}

var (
	reCloseLine = regexp.MustCompile(`^Closes #([0-9]+)\r?$`)
	reRefsLine  = regexp.MustCompile(`^Refs #([0-9]+)\r?$`)
	// Issue を閉じる記法（GitHub の closing keyword）。LLM の書いた概要に紛れても、既定ブランチへ入ったときに Issue を閉じないよう無効にする。
	reClosingKeyword = regexp.MustCompile(`(?i)\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b(\s*:?\s*)((?:[^\s#]*#[0-9]+)|(?:https?://\S*/issues/[0-9]+))`)
)

// issueLinks は、入ったタスクの PR の本文のうち、行の全体が `Closes #<番号>`・`Refs #<番号>` の形の行だけを集める（publish が書く形。RenderPRBody）。
// 重複は除き、両方に在る番号は Closes だけにする。
func issueLinks(prs []mergedPR) (closes, refs []int) {
	cs, rs := map[int]bool{}, map[int]bool{}
	for _, pr := range prs {
		for _, line := range strings.Split(pr.Body, "\n") {
			if m := reCloseLine.FindStringSubmatch(line); m != nil {
				n, _ := strconv.Atoi(m[1])
				cs[n] = true
			} else if m := reRefsLine.FindStringSubmatch(line); m != nil {
				n, _ := strconv.Atoi(m[1])
				rs[n] = true
			}
		}
	}
	for n := range cs {
		closes = append(closes, n)
	}
	for n := range rs {
		if !cs[n] {
			refs = append(refs, n)
		}
	}
	sort.Ints(closes)
	sort.Ints(refs)
	return closes, refs
}

// renderIntegrationPRBody は統合ブランチ → 既定ブランチの PR の本文を、決定的に作る。Closes・Refs の行は、gh で読んだタスクの PR の本文から写したものだけで、
// summary（LLM の出力）からは作らない（summary の中の Issue を閉じる記法は無効にする）。
func renderIntegrationPRBody(summary string, prs []mergedPR, runID, challengeID string) string {
	var b strings.Builder
	b.WriteString("## 概要\n\n")
	if s := strings.TrimSpace(neutralizeClosing(summary)); s != "" {
		b.WriteString(s + "\n\n")
	} else {
		b.WriteString("（概要は渡されていない）\n\n")
	}
	sort.Slice(prs, func(i, j int) bool { return prs[i].Number < prs[j].Number })
	fmt.Fprintf(&b, "## 入っているタスクの PR（全 %d 件）\n\n", len(prs))
	if len(prs) == 0 {
		b.WriteString("なし\n\n")
	} else {
		b.WriteString("| 番号 | 題名 | URL |\n|---|---|---|\n")
		for _, pr := range prs {
			fmt.Fprintf(&b, "| #%d | %s | %s |\n", pr.Number, tableCell(neutralizeClosing(pr.Title)), tableCell(pr.URL))
		}
		b.WriteString("\n")
	}
	closes, refs := issueLinks(prs)
	if len(closes)+len(refs) > 0 {
		b.WriteString("## Issue 参照\n\n")
		for _, n := range closes {
			fmt.Fprintf(&b, "Closes #%d\n", n)
		}
		for _, n := range refs {
			fmt.Fprintf(&b, "Refs #%d\n", n)
		}
		b.WriteString("\n")
	}
	b.WriteString("---\n\n")
	fmt.Fprintf(&b, "この PR は harness runtime（run `%s`）が作成した。", runID)
	if challengeID != "" {
		fmt.Fprintf(&b, "課題: `%s`。", strings.ReplaceAll(challengeID, "`", "'"))
	}
	b.WriteString("題名と概要は LLM が書き、タスクの PR の表と Issue 参照の行は、統合ブランチへ入ったタスクの PR から runtime が転記した。\n")
	return b.String()
}

func neutralizeClosing(s string) string {
	return reClosingKeyword.ReplaceAllString(s, "`$1`$2$3")
}

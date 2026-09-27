package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

var rePRURL = regexp.MustCompile(`/pull/([0-9]+)\b`)

type prOutput struct {
	Outcome  string `json:"outcome"`
	PRNumber int    `json:"pr_number"`
	PRURL    string `json:"pr_url"`
	Branch   string `json:"branch"`
	HeadSHA  string `json:"head_sha"`
}

// executePullRequest は pull-request 種類（§3.2）を 1 回実行する: 作業ブランチを push し、そのブランチの open な PR が
// 在れば push だけで updated、無ければ PR を作成して opened（W4 の冪等性）。本文の転記節（残指摘の全件・未検証の明記・
// クロスリポジトリ確証）は with の型付きの値から Go が生成する（I7・I13）。LLM が書くのは題名と要約だけ。
func (e *Engine) executePullRequest(ctx context.Context, st *runstate.State, u *runstate.Unit, step *workflow.Step, attempt int) result {
	tools, err := e.beginTools(ctx, u, step, attempt)
	if err != nil {
		return result{err: err}
	}
	defer tools.close()
	with, err := withValues(st, u, step)
	if err != nil {
		return stepError("cannot resolve with: %v", err)
	}
	in, err := prInputFrom(with)
	if err != nil {
		return stepError("%v", err)
	}
	in.RunID = st.RunID
	dir := e.dirFor(u)
	git := func(args ...string) ([]string, toolResult) {
		argv := append([]string{e.gitBin()}, args...)
		return argv, tools.run(dir, argv...)
	}
	gh := func(args ...string) ([]string, toolResult) {
		argv := append([]string{e.ghBin()}, args...)
		return argv, tools.run(dir, argv...)
	}

	branch := ""
	if ws := u.Workspace; ws != nil && u.ActiveWorkspace() != "" {
		branch = ws.Branch
	}
	if branch == "" {
		argv, r := git("rev-parse", "--abbrev-ref", "HEAD")
		if !r.ok() {
			return toolFailure(r, argv)
		}
		branch = strings.TrimSpace(string(r.stdout))
	}
	if branch == "" || branch == "HEAD" {
		return stepError("the working tree %s is not on a branch; nothing to push", dir)
	}
	if branch == in.Base {
		// base へ直接 push しない（PR を作るのは作業ブランチからだけ）。
		return stepError("the working branch %q is the PR base itself; refusing to push to the base", branch)
	}
	// 既定ブランチ（本番の反映先）へは push しない（R5: 既定ブランチへの反映は人がマージする）。
	argv, r := gh("repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name")
	if !r.ok() {
		return toolFailure(r, argv)
	}
	if def := strings.TrimSpace(string(r.stdout)); def == "" || branch == def {
		return stepError("the working branch %q is the repository's default branch (%q); refusing to push to it", branch, def)
	}
	ref := "refs/heads/" + branch
	if argv, r := git("push", "-u", "origin", ref+":"+ref); !r.ok() {
		return toolFailure(r, argv)
	}
	argv, r = git("rev-parse", "--verify", ref)
	if !r.ok() {
		return toolFailure(r, argv)
	}
	head := strings.TrimSpace(string(r.stdout))

	out := prOutput{Branch: branch, HeadSHA: head}
	argv, r = gh("pr", "list", "--head", branch, "--state", "open", "--json", "number,url,baseRefName,isCrossRepository")
	if !r.ok() {
		return toolFailure(r, argv)
	}
	var listed []struct {
		Number            int    `json:"number"`
		URL               string `json:"url"`
		BaseRefName       string `json:"baseRefName"`
		IsCrossRepository bool   `json:"isCrossRepository"`
	}
	if err := json.Unmarshal(r.stdout, &listed); err != nil {
		return stepError("gh pr list output is not a JSON array: %v", err)
	}
	existing := listed[:0]
	for _, pr := range listed {
		if !pr.IsCrossRepository { // 同名ブランチの fork からの PR は自分の PR ではない
			existing = append(existing, pr)
		}
	}
	switch {
	case len(existing) > 1:
		return stepError("branch %q has %d open PRs; cannot tell which one to update", branch, len(existing))
	case len(existing) == 1:
		pr := existing[0]
		if pr.BaseRefName != "" && pr.BaseRefName != in.Base {
			return stepError("the open PR #%d for branch %q targets %q, not %q; not updating it", pr.Number, branch, pr.BaseRefName, in.Base)
		}
		out.Outcome, out.PRNumber, out.PRURL = workflow.PRUpdated, pr.Number, pr.URL
	default:
		bodyRel := filepath.Join(runstate.LogsDir, fmt.Sprintf("%s.%d.body.md", step.ID, attempt))
		bodyPath := filepath.Join(e.Run.Dir, bodyRel)
		if err := os.WriteFile(bodyPath, []byte(RenderPRBody(in)), 0o644); err != nil {
			return result{err: err}
		}
		argv, r = gh("pr", "create", "--base", in.Base, "--head", branch, "--title", in.Title, "--body-file", bodyPath)
		if !r.ok() {
			return toolFailure(r, argv)
		}
		url := lastLine(r.stdout)
		m := rePRURL.FindStringSubmatch(url)
		if m == nil {
			return stepError("gh pr create did not print the PR URL: %q", url)
		}
		n, _ := strconv.Atoi(m[1])
		out.Outcome, out.PRNumber, out.PRURL = workflow.PROpened, n, url
	}
	res := builtinOutput(step, out)
	res.extra = append(res.extra, runstate.Event{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{
		Unit: u.Key, Action: runstate.WorkspacePR, Branch: branch, PRNumber: out.PRNumber, PRURL: out.PRURL, HeadSHA: head,
	}})
	return res
}

func lastLine(b []byte) string {
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// PRInput は PR 本文の材料（pull-request 種類の with）。
type PRInput struct {
	RunID            string
	Base             string
	Closes           int64
	Title            string
	Summary          string
	Quality          string            // pass | skip | ""（渡されていない）
	QualityGiven     bool              //
	ResidualFindings []json.RawMessage // 残指摘の全件（要素の形は問わない。知っているフィールドは読みやすく、残りは JSON のまま載せる）
	FindingsGiven    bool
	Unverified       []json.RawMessage
	CrossRepo        string
	CrossRepoGiven   bool
}

func prInputFrom(with map[string]json.RawMessage) (PRInput, error) {
	var in PRInput
	var ok bool
	if in.Base, ok = jsonString(with["base"]); !ok || in.Base == "" {
		return in, fmt.Errorf("with.base must be a non-empty string")
	}
	if in.Closes, ok = jsonInt(with["closes"]); !ok || in.Closes <= 0 {
		return in, fmt.Errorf("with.closes must be a positive issue number")
	}
	if in.Title, ok = jsonString(with["title"]); !ok || strings.TrimSpace(in.Title) == "" {
		return in, fmt.Errorf("with.title must be a non-empty string (the PR title)")
	}
	in.Title = strings.TrimSpace(in.Title)
	if in.Summary, ok = jsonString(with["summary"]); !ok {
		return in, fmt.Errorf("with.summary must be a string")
	}
	if raw, given := with["quality"]; given {
		if in.Quality, ok = jsonString(raw); !ok {
			return in, fmt.Errorf("with.quality must be a string")
		}
		in.QualityGiven = true
	}
	if raw, given := with["residual_findings"]; given {
		if err := json.Unmarshal(raw, &in.ResidualFindings); err != nil {
			return in, fmt.Errorf("with.residual_findings must be an array: %v", err)
		}
		in.FindingsGiven = true
	}
	if raw, given := with["unverified"]; given {
		if err := json.Unmarshal(raw, &in.Unverified); err != nil {
			return in, fmt.Errorf("with.unverified must be an array: %v", err)
		}
	}
	if raw, given := with["cross_repo"]; given {
		if in.CrossRepo, ok = jsonString(raw); !ok {
			return in, fmt.Errorf("with.cross_repo must be a string")
		}
		in.CrossRepoGiven = true
	}
	return in, nil
}

// RenderPRBody は PR 本文を型付きの値から決定的に作る。転記節は件数へ丸めず、全件を載せる（I13）。
// skip（品質ゲートの一部を実行できなかった）と未検証の事項は必ず明記する（I7）。
func RenderPRBody(in PRInput) string {
	var b strings.Builder
	b.WriteString("## 概要\n\n")
	if s := strings.TrimSpace(in.Summary); s != "" {
		b.WriteString(s + "\n\n")
	} else {
		b.WriteString("（要約は渡されていない）\n\n")
	}
	fmt.Fprintf(&b, "Closes #%d\n\n", in.Closes)

	b.WriteString("## 品質ゲート\n\n")
	switch {
	case !in.QualityGiven:
		b.WriteString("- 結果: **不明**（実装ステップの結果が渡されていない）\n\n")
	case in.Quality == "pass":
		b.WriteString("- 結果: pass\n\n")
	case in.Quality == "skip":
		b.WriteString("- 結果: **skip（未検証あり）** — 実装ステップは品質ゲートの一部を実行できずに終わった。pass ではない\n\n")
	default:
		fmt.Fprintf(&b, "- 結果: **%s**\n\n", in.Quality)
	}
	if in.Quality == "skip" || len(in.Unverified) > 0 {
		b.WriteString("## 未検証\n\n")
		if len(in.Unverified) == 0 {
			b.WriteString("- 実装ステップが skip を返したが、未検証の事項は列挙されていない（何が未検証かを実装ステップのログで確認すること）\n")
		}
		for _, raw := range in.Unverified {
			if s, ok := jsonString(raw); ok {
				b.WriteString("- " + indentCont(s, "  ") + "\n")
			} else {
				b.WriteString("- `" + compactRaw(raw) + "`\n")
			}
		}
		b.WriteString("\n")
	}

	fmt.Fprintf(&b, "## 残指摘（全 %d 件）\n\n", len(in.ResidualFindings))
	if in.QualityGiven && in.Quality != "pass" && in.Quality != "skip" {
		// 実装ステップが pass / skip 以外（逸脱で止まった等）で終わった後の経路では、/self-review の残指摘が揃っていない。
		fmt.Fprintf(&b, "**注意: 実装ステップは %s で終わっている。以下は実装ステップが返した値で、/self-review を最後まで通した結果ではない（件数が 0 でも「指摘なし」を意味しない）。**\n\n", in.Quality)
	}
	switch {
	case !in.FindingsGiven:
		b.WriteString("（残指摘は渡されていない）\n\n")
	case len(in.ResidualFindings) == 0:
		b.WriteString("なし（0 件）\n\n")
	}
	for i, raw := range in.ResidualFindings {
		b.WriteString(renderFinding(i+1, raw))
	}
	if len(in.ResidualFindings) > 0 {
		b.WriteString("\n")
	}

	b.WriteString("## クロスリポジトリ確証\n\n")
	switch {
	case !in.CrossRepoGiven:
		b.WriteString("（渡されていない）\n\n")
	case strings.TrimSpace(in.CrossRepo) == "":
		b.WriteString("なし（クロスリポジトリ依存なし）\n\n")
	default:
		b.WriteString(strings.TrimSpace(in.CrossRepo) + "\n\n")
	}

	b.WriteString("---\n\n")
	b.WriteString("残指摘・未検証・品質ゲートの節は実装ステップ（implement）の出力から作っている。差し戻しの修正（fix）の後の変化は反映されない。\n\n")
	fmt.Fprintf(&b, "この PR は harness runtime（run `%s`）が作成した。品質ゲート・未検証・残指摘・クロスリポジトリ確証の節は、実装ステップの型付きの出力から runtime が転記した（LLM による要約・件数への丸めを経ていない）。\n", in.RunID)
	return b.String()
}

// renderFinding は残指摘 1 件を番号付きの項目にする。location / file・line / severity / claim / reason は読みやすく並べ、
// それ以外のフィールド（形の分からない要素そのものを含む）は JSON のまま添える（情報を落とさない）。
func renderFinding(n int, raw json.RawMessage) string {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil || obj == nil {
		if s, ok := jsonString(raw); ok {
			return fmt.Sprintf("%d. %s\n", n, indentCont(s, "   "))
		}
		return fmt.Sprintf("%d. `%s`\n", n, compactRaw(raw))
	}
	str := func(k string) string {
		v, ok := obj[k]
		if !ok {
			return ""
		}
		delete(obj, k)
		if s, ok := jsonString(v); ok {
			return s
		}
		return compactRaw(v)
	}
	loc := str("location")
	file, line := str("file"), str("line")
	if loc == "" && file != "" {
		loc = file
		if line != "" {
			loc += ":" + line
		}
	} else if file != "" || line != "" {
		obj["file"], _ = json.Marshal(file)
		obj["line"], _ = json.Marshal(line)
	}
	sev, claim, reason := str("severity"), str("claim"), str("reason")
	var b strings.Builder
	fmt.Fprintf(&b, "%d. ", n)
	if sev != "" {
		fmt.Fprintf(&b, "**[%s]** ", sev)
	}
	if loc != "" {
		fmt.Fprintf(&b, "`%s` ", loc)
	}
	if claim != "" {
		b.WriteString(indentCont(claim, "   "))
	} else {
		b.WriteString("（claim なし）")
	}
	b.WriteString("\n")
	if reason != "" {
		fmt.Fprintf(&b, "   - 理由: %s\n", indentCont(reason, "     "))
	}
	if len(obj) > 0 {
		keys := make([]string, 0, len(obj))
		for k := range obj {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			fmt.Fprintf(&b, "   - %s: `%s`\n", k, compactRaw(obj[k]))
		}
	}
	return b.String()
}

func indentCont(s, indent string) string {
	return strings.ReplaceAll(strings.TrimSpace(s), "\n", "\n"+indent)
}

func compactRaw(raw json.RawMessage) string {
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return string(raw)
	}
	return strings.ReplaceAll(buf.String(), "`", "'")
}

// --- observe: pr-state ------------------------------------------------------

// ObservePRState は PR の実状態を見る観測の名前（observe 型ゲート。§3.2・N1）。
const ObservePRState = "pr-state"

func init() {
	RegisterObserver(ObservePRState, []string{"merged", "open", "closed"}, observePRState)
	workflow.RegisterObservationInputs(ObservePRState, "pr")
}

// observePRState は gh で PR の実状態（MERGED / OPEN / CLOSED）を確かめる。人の申告を信じない。
func observePRState(ctx context.Context, env ObserveEnv, with map[string]json.RawMessage) (string, json.RawMessage, error) {
	n, ok := jsonInt(with["pr"])
	if !ok || n <= 0 {
		return "", nil, fmt.Errorf("with.pr must be a PR number")
	}
	gh := env.Gh
	if gh == "" {
		gh = "gh"
	}
	cmd := exec.CommandContext(ctx, gh, "pr", "view", strconv.FormatInt(n, 10), "--json", "number,state,url,mergedAt,baseRefName")
	cmd.Dir = env.Dir
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", nil, fmt.Errorf("gh pr view %d: %v: %s", n, err, strings.TrimSpace(errb.String()))
	}
	var pr struct {
		State string `json:"state"`
	}
	if err := json.Unmarshal(out.Bytes(), &pr); err != nil {
		return "", nil, fmt.Errorf("gh pr view %d: output is not JSON: %v", n, err)
	}
	var observed bytes.Buffer
	if err := json.Compact(&observed, out.Bytes()); err != nil {
		return "", nil, err
	}
	switch pr.State {
	case "MERGED":
		return "merged", observed.Bytes(), nil
	case "OPEN":
		return "open", observed.Bytes(), nil
	case "CLOSED":
		return "closed", observed.Bytes(), nil
	}
	return "", nil, fmt.Errorf("gh pr view %d: unknown state %q", n, pr.State)
}

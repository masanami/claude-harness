package cli

// harness predict-conflicts は、同じリポジトリの複数 Issue を並列に実装してよいかの判断材料として、衝突の予測だけを返す
// 読み取り専用の口（Issue #288・docs/harness-runtime-design.md §5.4）。並列にするかは決めない（決定は呼び出し元の flywheel）。
//
// Issue ごとに conflict-predict-issue ワークフローの run を 1 本起動し（Issue の本文の取得 → issue-conflict-predictor の予測）、
// 組の突き合わせ（共有ファイル・依存の向き）はここで決定的に行う。作業ツリー・ブランチ・Issue は変更しない。
// 出力は汎用の語彙だけにする（harness の step id・判断値を出さない）。終了コードは契約 v1 と同じく「JSON を出力できたか」だけ。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"os/signal"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/masanami/claude-harness/runtime/internal/engine"
	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/version"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// PredictionSchema は predict-conflicts の出力の版。
const PredictionSchema = "harness.conflict-prediction/v1"

// predictWorkflow は Issue 1 件を予測するワークフロー（runtime/workflows/conflict-predict-issue.yaml）。
const predictWorkflow = "conflict-predict-issue"

// 入力の件数の範囲と、同時に起動する予測の数。
const (
	predictMinIssues   = 2
	predictMaxIssues   = 20
	predictParallelism = 4
)

// issues[].status と pairs[].status。
const (
	issuePredicted       = "predicted"
	issueFailed          = "failed"
	issueBudgetExhausted = "budget_exhausted"

	pairPredicted = "predicted"
	pairUnknown   = "unknown"
)

// mergeFriendlyNames はマージが容易なファイル（lockfile 等）のベース名。共有ファイルから除外はせず印だけを付ける
// （除外するかは呼び出し元が決める）。/para-impl（references/star-parallel.md「衝突予測ヒント」）が交差から除く例と同じ系統。
var mergeFriendlyNames = map[string]bool{
	"package-lock.json": true, "npm-shrinkwrap.json": true, "yarn.lock": true, "pnpm-lock.yaml": true, "bun.lockb": true,
	"go.sum": true, "Cargo.lock": true, "Gemfile.lock": true, "poetry.lock": true, "uv.lock": true, "composer.lock": true,
}

// predictionDoc は predict-conflicts の標準出力。Error は口全体を実行できなかったときだけ入る（そのとき run は起動していない）。
type predictionDoc struct {
	Schema           string            `json:"schema"`
	Repository       *string           `json:"repository"`
	HeadSHA          *string           `json:"head_sha"`
	Complete         bool              `json:"complete"`
	Error            *string           `json:"error"`
	Issues           []issuePrediction `json:"issues"`
	Pairs            []pairPrediction  `json:"pairs"`
	Budget           predictionBudget  `json:"budget"`
	CostUSD          float64           `json:"cost_usd"`
	UnknownCostCount int               `json:"unknown_cost_count"`
}

type predictionBudget struct {
	LimitUSD    float64 `json:"limit_usd"`
	PerIssueUSD float64 `json:"per_issue_usd"`
}

type issuePrediction struct {
	Issue          int      `json:"issue"`
	Status         string   `json:"status"`
	PredictedFiles []string `json:"predicted_files"`
	DependsOn      []int    `json:"depends_on"`
	Detail         string   `json:"detail,omitempty"`
	CostUSD        float64  `json:"cost_usd"`
	unknownCosts   int      // 費用不明の実行の数（付与した上限額で数えた。§4.3・Q15）
}

type pairPrediction struct {
	Issues      [2]int         `json:"issues"`
	Status      string         `json:"status"`
	SharedFiles []sharedFile   `json:"shared_files"`
	Dependency  pairDependency `json:"dependency"`
	Evidence    []pairEvidence `json:"evidence"`
}

type sharedFile struct {
	Path          string `json:"path"`
	MergeFriendly bool   `json:"merge_friendly"`
	Ignored       bool   `json:"ignored"`
}

// pairDependency は依存の見込み。Stated はどちらの予測の depends_on が相手を挙げたか。First は先に入れるべき側で、
// 片方向だけのときに入る（無い・相互のときは null）。
type pairDependency struct {
	First  *int         `json:"first"`
	Stated []dependEdge `json:"stated"`
}

type dependEdge struct {
	Issue     int `json:"issue"`
	DependsOn int `json:"depends_on"`
}

// pairEvidence は組の根拠: 双方の予測そのもの。
type pairEvidence struct {
	Issue          int      `json:"issue"`
	PredictedFiles []string `json:"predicted_files"`
	DependsOn      []int    `json:"depends_on"`
}

const predictUsage = `usage: harness predict-conflicts [--max-budget-usd USD] [--workflow-dir DIR] [--scripts-dir DIR] <issue> <issue>...

predicts, for 2 to 20 issues of the repository checked out in the current directory, which files each would touch
and which pairs may conflict or depend on each other. read-only: it changes no working tree, branch or issue, and
decides nothing (whether to run the issues in parallel is the caller's decision).
prints one JSON document {"schema": "` + PredictionSchema + `", ...} and exits 0 whenever it printed it.
--max-budget-usd caps the whole prediction (default: 1 USD per issue); an issue whose share does not fit is not
launched and is reported as budget_exhausted.
`

// cmdPredictConflicts は predict-conflicts。JSON を出力できなかったときだけ非 0 で終わる。
func cmdPredictConflicts(args []string, env Env) int {
	for _, a := range args {
		if a == "-h" || a == "--help" || a == "help" {
			fmt.Fprint(env.Stdout, predictUsage)
			return ExitOK
		}
	}
	return predictOut(env, predict(args, env))
}

func predictOut(env Env, d predictionDoc) int {
	if d.Issues == nil {
		d.Issues = []issuePrediction{}
	}
	if d.Pairs == nil {
		d.Pairs = []pairPrediction{}
	}
	b, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return ExitFailed
	}
	if _, err := env.Stdout.Write(append(b, '\n')); err != nil {
		return ExitFailed
	}
	return ExitOK
}

func predictFailed(d predictionDoc, format string, a ...any) predictionDoc {
	msg := fmt.Sprintf(format, a...)
	d.Error, d.Complete = &msg, false
	return d
}

func predict(args []string, env Env) predictionDoc {
	d := predictionDoc{Schema: PredictionSchema}
	flags, pos, err := parseArgs(args,
		flagSpec{name: "max-budget-usd", value: true},
		flagSpec{name: "workflow-dir", value: true}, flagSpec{name: "scripts-dir", value: true})
	if err != nil {
		return predictFailed(d, "%v", err)
	}
	issues, err := parseIssueNumbers(pos)
	if err != nil {
		return predictFailed(d, "%v", err)
	}
	var limit float64
	if s := first(flags, "max-budget-usd"); s != "" {
		v, err := strconv.ParseFloat(s, 64)
		if err != nil || !(v > 0) || v > 1e6 {
			return predictFailed(d, "--max-budget-usd must be a positive number of USD, got %q", s)
		}
		limit = v
	}
	if p := env.Getenv(PluginVersionEnv); p != "" {
		if err := version.CheckPlugin(p); err != nil {
			return predictFailed(d, "%s: %v", PluginVersionEnv, err)
		}
	}
	src, err := dirs(flags, env)
	if err != nil {
		return predictFailed(d, "%v", err)
	}
	wf, err := workflow.LoadAndValidate(filepath.Join(src.wd, predictWorkflow+".yaml"), workflow.Options{ScriptsDir: src.sd})
	if err != nil {
		return predictFailed(d, "the %s workflow is not valid: %v", predictWorkflow, err)
	}
	per := wf.Limit(runstate.BudgetLimitName)
	if per == nil || !(per.Value > 0) {
		return predictFailed(d, "the %s workflow has no limits.%s", predictWorkflow, runstate.BudgetLimitName)
	}
	if limit == 0 {
		limit = per.Value * float64(len(issues))
	}
	d.Budget = predictionBudget{LimitUSD: limit, PerIssueUSD: per.Value}

	cwd, err := env.Getwd()
	if err != nil {
		return predictFailed(d, "%v", err)
	}
	top, err := readTool(cwd, toolBin(env, "HARNESS_GIT_BIN", "git"), "rev-parse", "--show-toplevel")
	if err != nil {
		return predictFailed(d, "the current directory is not in a git working tree: %v", err)
	}
	head, err := readTool(top, toolBin(env, "HARNESS_GIT_BIN", "git"), "rev-parse", "HEAD")
	if err != nil {
		return predictFailed(d, "cannot read HEAD of %s: %v", top, err)
	}
	d.HeadSHA = &head
	repo, err := readTool(top, toolBin(env, "HARNESS_GH_BIN", "gh"), "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
	if err != nil || repo == "" {
		return predictFailed(d, "cannot resolve the GitHub repository of %s (gh repo view): %v", top, err)
	}
	d.Repository = &repo
	rd, err := runsDir(env)
	if err != nil {
		return predictFailed(d, "%v", err)
	}

	// 予算は起動前に 1 件分ずつ確保する（fail-closed）。1 run の費用は付与した上限（1 件分）を超えないので、
	// 確保した件数 × 1 件分が口全体の上限を超えることはない。確保できなかった Issue は起動しない。
	d.Issues = make([]issuePrediction, len(issues))
	var launch []int
	reserved := 0.0
	for i, n := range issues {
		d.Issues[i] = issuePrediction{Issue: n, PredictedFiles: []string{}, DependsOn: []int{}}
		if reserved+per.Value > limit+1e-9 {
			d.Issues[i].Status = issueBudgetExhausted
			d.Issues[i].Detail = fmt.Sprintf("not launched: the remaining budget %s USD is below one issue's share %s USD",
				strconv.FormatFloat(limit-reserved, 'f', -1, 64), strconv.FormatFloat(per.Value, 'f', -1, 64))
			continue
		}
		reserved += per.Value
		launch = append(launch, i)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	sem := make(chan struct{}, predictParallelism)
	var wg sync.WaitGroup
	var mu sync.Mutex // env.Stderr への書き込みを直列化する
	for _, i := range launch {
		sem <- struct{}{}
		if ctx.Err() != nil { // 止められた後は新しく起動しない（起動済みの run は engine が止めて記録する）
			<-sem
			d.Issues[i].Status, d.Issues[i].Detail = issueFailed, "not launched: the prediction was interrupted"
			continue
		}
		wg.Add(1)
		go func(p *issuePrediction) {
			defer wg.Done()
			defer func() { <-sem }()
			predictOne(ctx, p, wf, src, top, rd, env, &mu)
		}(&d.Issues[i])
	}
	wg.Wait()

	d.Complete = true
	for i := range d.Issues {
		d.CostUSD += d.Issues[i].CostUSD
		d.UnknownCostCount += d.Issues[i].unknownCosts
		if d.Issues[i].Status != issuePredicted {
			d.Complete = false
		}
	}
	d.CostUSD = roundUSD(d.CostUSD)
	d.Pairs = pairsOf(d.Issues)
	if err := markIgnored(d.Pairs, top, toolBin(env, "HARNESS_GIT_BIN", "git")); err != nil {
		fmt.Fprintf(env.Stderr, "harness: cannot tell which shared files git ignores (they are reported with ignored: false): %v\n", err)
	}
	return d
}

// predictOne は Issue 1 件の run を起動して終端まで進め、結果を p へ写す。
func predictOne(ctx context.Context, p *issuePrediction, wf *workflow.Workflow, src source, top, rd string, env Env, mu *sync.Mutex) {
	inputs := map[string]json.RawMessage{"issue": json.RawMessage(strconv.Itoa(p.Issue))}
	eng, err := engine.Start(engine.StartParams{
		RunsDir: rd, WF: wf, Inputs: inputs, ScriptsDir: src.sd, WorkflowDir: src.wd, Cwd: top, Origin: "predict-conflicts",
		CLIVersion: version.CLI(), Embedded: src.embedded,
	})
	if err != nil {
		p.Status, p.Detail = issueFailed, "the prediction could not be started: "+err.Error()
		return
	}
	tools(eng, env)
	mu.Lock()
	fmt.Fprintf(env.Stderr, "harness: run %s started for issue #%d (%s)\n", eng.Run.ID, p.Issue, eng.Run.Dir)
	mu.Unlock()
	st, err := eng.Loop(ctx)
	if err != nil {
		p.Status = issueFailed
		p.Detail = fmt.Sprintf("the prediction stopped with an internal error: %v (harness status %s)", err, eng.Run.ID)
		// 途中まで使った費用は状態から読み直す（読めなければ付与した 1 件分を消費したとみなす）。
		if st2, _, lerr := eng.Run.Load(); lerr == nil {
			st = st2
		} else {
			p.CostUSD, p.unknownCosts = wf.Limit(runstate.BudgetLimitName).Value, 1
			return
		}
	}
	var u *runstate.Unit
	if len(st.Units) > 0 {
		u = st.Units[0]
	}
	if u != nil && u.Budget != nil {
		p.CostUSD = roundUSD(u.Budget.SpentUSD)
		p.unknownCosts = u.Budget.UnknownCostCount
	}
	if err != nil {
		return
	}
	if st.Status != runstate.StatusSucceeded || u == nil {
		p.Status = issueFailed
		p.Detail = fmt.Sprintf("the prediction did not complete (run %s ended %s; harness status %s shows why)", eng.Run.ID, st.Status, eng.Run.ID)
		return
	}
	var out struct {
		PredictedFiles []string `json:"predicted_files"`
		DependsOn      []int    `json:"depends_on"`
	}
	if err := json.Unmarshal(u.Outputs["predict"], &out); err != nil {
		p.Status, p.Detail = issueFailed, fmt.Sprintf("the prediction of run %s could not be read: %v", eng.Run.ID, err)
		return
	}
	p.Status = issuePredicted
	p.PredictedFiles = normalizePaths(out.PredictedFiles)
	p.DependsOn = uniqueInts(out.DependsOn, p.Issue)
}

// pairsOf は入力の順で全組を作る。どちらかの予測が無い組は unknown（衝突の有無を判断できない）。
func pairsOf(issues []issuePrediction) []pairPrediction {
	out := []pairPrediction{}
	for i := 0; i < len(issues); i++ {
		for j := i + 1; j < len(issues); j++ {
			a, b := issues[i], issues[j]
			pp := pairPrediction{Issues: [2]int{a.Issue, b.Issue}, Status: pairUnknown, SharedFiles: []sharedFile{},
				Dependency: pairDependency{Stated: []dependEdge{}}, Evidence: []pairEvidence{}}
			if a.Status == issuePredicted && b.Status == issuePredicted {
				pp.Status = pairPredicted
				pp.SharedFiles = shared(a.PredictedFiles, b.PredictedFiles)
				pp.Dependency = dependency(a, b)
				pp.Evidence = []pairEvidence{
					{Issue: a.Issue, PredictedFiles: a.PredictedFiles, DependsOn: a.DependsOn},
					{Issue: b.Issue, PredictedFiles: b.PredictedFiles, DependsOn: b.DependsOn},
				}
			}
			out = append(out, pp)
		}
	}
	return out
}

// shared は両方の予測に現れるファイル（a の順）。lockfile 等には merge_friendly の印を付ける。
func shared(a, b []string) []sharedFile {
	inB := map[string]bool{}
	for _, f := range b {
		inB[f] = true
	}
	out := []sharedFile{}
	for _, f := range a {
		if inB[f] {
			out = append(out, sharedFile{Path: f, MergeFriendly: mergeFriendlyNames[path.Base(f)]})
		}
	}
	return out
}

// markIgnored は git が無視するパス（生成物の写し等）の共有ファイルに ignored の印を付ける（git check-ignore。読むだけ）。
// 除外はしない（除外するかは呼び出し元が決める）。追跡されているファイルは無視の規則に当たっても ignored にならない。
func markIgnored(pairs []pairPrediction, top, gitBin string) error {
	var paths []string
	seen := map[string]bool{}
	for _, p := range pairs {
		for _, f := range p.SharedFiles {
			if !seen[f.Path] {
				seen[f.Path] = true
				paths = append(paths, f.Path)
			}
		}
	}
	if len(paths) == 0 {
		return nil
	}
	cmd := exec.Command(gitBin, "check-ignore", "--stdin", "-z")
	cmd.Dir = top
	cmd.Stdin = strings.NewReader(strings.Join(paths, "\x00") + "\x00")
	out, err := cmd.Output()
	var ee *exec.ExitError
	if err != nil && !(errors.As(err, &ee) && ee.ExitCode() == 1) { // 1 は「どれも無視されていない」
		return err
	}
	ignored := map[string]bool{}
	for _, f := range strings.Split(string(out), "\x00") {
		if f != "" {
			ignored[f] = true
		}
	}
	for i := range pairs {
		for j := range pairs[i].SharedFiles {
			pairs[i].SharedFiles[j].Ignored = ignored[pairs[i].SharedFiles[j].Path]
		}
	}
	return nil
}

// dependency は組の依存の見込み: 片方だけが相手を depends_on に挙げていれば、挙げられた側が先。
func dependency(a, b issuePrediction) pairDependency {
	d := pairDependency{Stated: []dependEdge{}}
	if containsInt(a.DependsOn, b.Issue) {
		d.Stated = append(d.Stated, dependEdge{Issue: a.Issue, DependsOn: b.Issue})
	}
	if containsInt(b.DependsOn, a.Issue) {
		d.Stated = append(d.Stated, dependEdge{Issue: b.Issue, DependsOn: a.Issue})
	}
	if len(d.Stated) == 1 {
		f := d.Stated[0].DependsOn
		d.First = &f
	}
	return d
}

// parseIssueNumbers は位置引数を Issue 番号として読む（正の整数・重複なし・2〜20 件）。
func parseIssueNumbers(pos []string) ([]int, error) {
	if len(pos) < predictMinIssues || len(pos) > predictMaxIssues {
		return nil, fmt.Errorf("predict-conflicts takes %d to %d issue numbers, got %d", predictMinIssues, predictMaxIssues, len(pos))
	}
	seen := map[int]bool{}
	out := make([]int, 0, len(pos))
	for _, s := range pos {
		n, err := strconv.Atoi(strings.TrimPrefix(s, "#"))
		if err != nil || n <= 0 {
			return nil, fmt.Errorf("issue number must be a positive integer, got %q", s)
		}
		if seen[n] {
			return nil, fmt.Errorf("issue #%d is given twice", n)
		}
		seen[n] = true
		out = append(out, n)
	}
	return out, nil
}

// normalizePaths はリポジトリルート相対のパスへ揃える（先頭の ./ と重複を除く。順は保つ）。
func normalizePaths(in []string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, f := range in {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		f = strings.TrimPrefix(path.Clean(f), "./")
		if !seen[f] {
			seen[f] = true
			out = append(out, f)
		}
	}
	return out
}

// uniqueInts は重複と自分自身を除く（順は保つ）。
func uniqueInts(in []int, self int) []int {
	out := []int{}
	seen := map[int]bool{self: true}
	for _, n := range in {
		if !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	return out
}

func containsInt(xs []int, x int) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

func roundUSD(v float64) float64 {
	f, _ := strconv.ParseFloat(strconv.FormatFloat(v, 'f', 6, 64), 64)
	return f
}

func toolBin(env Env, name, def string) string {
	if v := env.Getenv(name); v != "" {
		return v
	}
	return def
}

// readTool は読み取りだけのコマンド（git rev-parse・gh repo view）を dir で実行し、標準出力の 1 行目を返す。
func readTool(dir, bin string, args ...string) (string, error) {
	cmd := exec.Command(bin, args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(ee.Stderr) > 0 {
			return "", fmt.Errorf("%v: %s", err, strings.TrimSpace(string(ee.Stderr)))
		}
		return "", err
	}
	return strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0]), nil
}

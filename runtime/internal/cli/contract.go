package cli

// harness contract は flywheel の接続契約 v1（flywheel docs/features/m3-invoker-delegation.md §クリティカル設計決定 3・
// 決定 M3H2）の面（docs/harness-runtime-design.md §5.6）。
//
// 既存の run / status / resume / cancel をそのまま呼び、その結果（status --json と同じ畳み込んだ状態）を契約 v1 の JSON へ
// 写すだけにする。既存コマンドの人向けの出力と終了コード（§5.2）はこの面と意味が違う（契約の終了コードは「JSON を
// 出力できたか」だけ）ため、同じコマンドにフラグで 2 つの意味を持たせず、入口を分けている。

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// ContractVersion は出力する接続契約の版。
const ContractVersion = 1

// 契約 v1 の requested_action.kind と decider。
const (
	actionAnswer  = "answer"
	actionApprove = "approve"
	actionObserve = "observe"

	contractHuman  = "human"
	contractParent = "parent"
)

// 契約 v1 の artifacts[].kind。
const (
	artifactPR     = "pr"
	artifactBranch = "branch"
	artifactCommit = "commit"
)

// contractDoc は契約 v1 の JSON（start・status・resume・cancel の標準出力）。
// RunID は run を始められなかった start では null。Artifacts は空でも [] を出す。
type contractDoc struct {
	ContractVersion int              `json:"contract_version"`
	RunID           *string          `json:"run_id"`
	State           string           `json:"state"`
	Summary         string           `json:"summary"`
	RequestedAction *requestedAction `json:"requested_action"`
	Artifacts       []artifact       `json:"artifacts"`
	CostUSD         *float64         `json:"cost_usd"`
}

type requestedAction struct {
	Kind    string `json:"kind"`
	Decider string `json:"decider"`
	Text    string `json:"text"`
}

type artifact struct {
	Kind string `json:"kind"`
	Ref  string `json:"ref"`
}

const contractUsage = `usage: harness contract <start|status|resume|cancel> [options]

  start [--workflow-dir DIR] [--scripts-dir DIR] [--input NAME=VALUE]... <workflow>
  status <run-id>
  resume [--unit KEY] [--input VALUE] [--note TEXT] <run-id>
  cancel <run-id>

the connection contract v1 for flywheel: each command prints one JSON document
{"contract_version": 1, "run_id", "state", "summary", "requested_action", "artifacts", "cost_usd"}
and exits 0 whenever it printed it; waiting, success and failure are in "state", not in the exit code.
the options and the arguments are the same as those of run / status / resume / cancel.
`

// cmdContract は契約 v1 の 4 コマンド。JSON を出力できなかったときだけ非 0 で終わる。
func cmdContract(args []string, env Env) int {
	if len(args) == 0 {
		return contractOut(env, failedDoc(nil, "harness contract needs a command: start, status, resume or cancel"))
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "start":
		return contractStart(rest, env)
	case "status":
		return contractByRun(rest, env, func(a []string, e Env) int { return cmdStatus(append(a, "--json"), e) })
	case "resume":
		return contractByRun(rest, env, func(a []string, e Env) int { return cmdResolve("resume", a, e) },
			flagSpec{name: "unit", value: true}, flagSpec{name: "input", value: true}, flagSpec{name: "note", value: true})
	case "cancel":
		return contractByRun(rest, env, cmdCancel)
	case "help", "-h", "--help":
		fmt.Fprint(env.Stdout, contractUsage)
		return ExitOK
	}
	return contractOut(env, failedDoc(nil, fmt.Sprintf("unknown contract command %q (start, status, resume or cancel)", sub)))
}

// contractStart は run を始める。run を始められなかった（引数・ワークフロー定義の誤り等）ときは run_id を null にした
// failed を出す。始めた後に内部エラーで止まったときは、その run の状態を読み直して出す。
func contractStart(args []string, env Env) int {
	out, res := captured(env, cmdRun, args)
	if v, ok := decodeView(out); ok {
		return contractOut(env, contractFromView(v, res.note()))
	}
	if res.runID != "" {
		if v, ok := loadView(env, res.runID); ok {
			return contractOut(env, contractFromView(v, res.note()))
		}
		id := res.runID
		return contractOut(env, failedDoc(&id, res.note()))
	}
	return contractOut(env, failedDoc(nil, "no run was started: "+res.note()))
}

// contractByRun は run ID を取るコマンド（status・resume・cancel）。コマンドが状態を出さなかった（run が終わっていて
// resume できない・cancel した等）ときは状態を読み直して出す。run を読めなければ、渡された ID で failed を出す。
func contractByRun(args []string, env Env, f func([]string, Env) int, specs ...flagSpec) int {
	out, res := captured(env, f, args)
	if v, ok := decodeView(out); ok {
		return contractOut(env, contractFromView(v, res.note()))
	}
	_, pos, err := parseArgs(args, specs...)
	if err != nil || len(pos) != 1 {
		return contractOut(env, failedDoc(nil, res.note()))
	}
	id := pos[0]
	if v, ok := loadView(env, id); ok {
		return contractOut(env, contractFromView(v, res.note()))
	}
	return contractOut(env, failedDoc(&id, res.note()))
}

// innerResult は取り込んだ既存コマンドの終わり方。
type innerResult struct {
	code   int
	errMsg string // 標準エラーの最後の "harness: " 行（run の開始の知らせは除く）
	runID  string // 標準エラーの run の開始の知らせから読んだ run ID
}

// note は要約に添える文。既存コマンドが失敗の終了コード（1・2）で終わったときだけ、その理由を返す。
// run が failed で終わった場合の 1 は、理由が状態にあるので何も添えない（標準エラーに理由が無い）。
func (r innerResult) note() string {
	if r.code != ExitFailed && r.code != ExitUsage {
		return ""
	}
	if r.errMsg == "" {
		return ""
	}
	return r.errMsg
}

// captured は既存コマンドを、標準出力を取り込んで実行する。標準エラーは人と記録のためにそのまま流し、
// 要約に使う行を拾う。
func captured(env Env, f func([]string, Env) int, args []string) ([]byte, innerResult) {
	var out, errb bytes.Buffer
	inner := env
	inner.Stdout = &out
	inner.Stderr = io.MultiWriter(env.Stderr, &errb)
	res := innerResult{code: f(args, inner)}
	for _, line := range strings.Split(errb.String(), "\n") {
		msg, ok := strings.CutPrefix(line, "harness: ")
		if !ok {
			continue
		}
		if rest, ok := strings.CutPrefix(msg, "run "); ok {
			if id, _, ok := strings.Cut(rest, " started ("); ok && !strings.Contains(id, " ") {
				res.runID = id
				continue
			}
		}
		res.errMsg = msg
	}
	return out.Bytes(), res
}

func decodeView(out []byte) (statusView, bool) {
	var v statusView
	if len(bytes.TrimSpace(out)) == 0 || json.Unmarshal(out, &v) != nil || v.State == nil || v.RunID == "" {
		return statusView{}, false
	}
	return v, true
}

func loadView(env Env, id string) (statusView, bool) {
	run, err := openRun(env, id)
	if err != nil {
		return statusView{}, false
	}
	st, torn, err := run.Load()
	if err != nil {
		return statusView{}, false
	}
	return view(run, st, torn), true
}

// contractOut は JSON を 1 つ出力する。書けなかったときだけ非 0（1）で終わる。
func contractOut(env Env, d contractDoc) int {
	b, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: cannot build the contract JSON: %v\n", err)
		return ExitFailed
	}
	if _, err := env.Stdout.Write(append(b, '\n')); err != nil {
		fmt.Fprintf(env.Stderr, "harness: cannot write the contract JSON: %v\n", err)
		return ExitFailed
	}
	return ExitOK
}

// failedDoc は run の状態を読めないときの failed。費用は分からないので null。
func failedDoc(runID *string, why string) contractDoc {
	if why == "" {
		why = "the command failed"
	}
	return contractDoc{ContractVersion: ContractVersion, RunID: runID, State: runstate.StatusFailed, Summary: why, Artifacts: []artifact{}}
}

// contractFromView は run の状態を契約 v1 へ写す。note は既存コマンドが失敗で終わった理由（resume の拒否等）。
// state は run の汎用状態（§4.1）そのもの: コマンドが失敗しても run の状態は変わっていないので、failed にしない。
func contractFromView(v statusView, note string) contractDoc {
	st := v.State
	id := st.RunID
	d := contractDoc{ContractVersion: ContractVersion, RunID: &id, State: st.Status, Artifacts: artifacts(st)}
	cost, unknown := runCost(st)
	d.CostUSD = &cost
	if !runstate.Terminal(st.Status) {
		d.RequestedAction = pickAction(st.RunID, v.Waiting)
	}
	d.Summary = summarize(v, unknown, note)
	return d
}

// summarize は人が読む 1 行の要約。
func summarize(v statusView, unknownCost int, note string) string {
	st := v.State
	s := fmt.Sprintf("workflow %s: %s", st.Workflow.ID, st.Status)
	switch {
	case st.Reason != "":
		s += " (" + st.Reason + ")"
	case st.Status == runstate.StatusWaiting && len(v.Waiting) > 0:
		w := v.Waiting[0]
		s += fmt.Sprintf(" at gate %s (unit %s)", w.Gate, w.Unit)
	case st.Status == runstate.StatusRunning && len(st.Units) > 0 && st.Units[0].CurrentStep != "":
		s += fmt.Sprintf(" (unit %s at step %s)", st.Units[0].Key, st.Units[0].CurrentStep)
	}
	if v.RunnerAlive != nil && !*v.RunnerAlive {
		s += fmt.Sprintf("; the runner (pid %d) is not alive, so nothing is advancing this run until status or resume", st.PID)
	}
	if unknownCost > 0 {
		s += fmt.Sprintf("; cost_usd counts %d launch(es) whose cost was not reported at the limit granted to them (fail-closed)", unknownCost)
	}
	if note != "" {
		s += "; " + note
	}
	return s
}

// runCost は run の累計費用（unit の累計の和）と、費用が得られなかった実行の数。費用が得られなかった実行は、付与した
// 上限額を消費したものとして累計に入っている（§4.3・Q15 の fail-closed）ので、その額のまま出す（少なく見せない）。
// 予算を持たない run（llm ステップが無い）は Claude を起動しないので 0。
func runCost(st *runstate.State) (float64, int) {
	var cost float64
	unknown := 0
	for _, u := range st.Units {
		if u.Budget != nil {
			cost += u.Budget.SpentUSD
			unknown += u.Budget.UnknownCostCount
		}
	}
	return cost, unknown
}

// artifacts は unit ごとの PR・ブランチ・最後に push した commit（§4.1 Workspace）。
func artifacts(st *runstate.State) []artifact {
	out := []artifact{}
	for _, u := range st.Units {
		ws := u.Workspace
		if ws == nil {
			continue
		}
		switch {
		case ws.PRURL != "":
			out = append(out, artifact{Kind: artifactPR, Ref: ws.PRURL})
		case ws.PRNumber > 0:
			out = append(out, artifact{Kind: artifactPR, Ref: "#" + strconv.Itoa(ws.PRNumber)})
		}
		if ws.Branch != "" {
			out = append(out, artifact{Kind: artifactBranch, Ref: ws.Branch})
		}
		if sha := lastHead(ws.HeadSHAs); sha != "" {
			out = append(out, artifact{Kind: artifactCommit, Ref: sha})
		}
	}
	return out
}

// lastHead は最も新しいラウンドで push した head（キーはラウンド番号）。
func lastHead(heads map[string]string) string {
	best, sha := -1, ""
	for k, v := range heads {
		if n, err := strconv.Atoi(k); err == nil && n > best {
			best, sha = n, v
		}
	}
	return sha
}

// gateAction はゲート 1 つを requested_action へ写す（§5.6 の表）。
//
//	input × human（TTY を要求する）  → approve / human   人が端末から harness approve で解決する
//	input × parent・any               → answer  / parent  呼び出し元が harness contract resume --input で答える
//	observe × human                   → observe / human   人が外部で操作する（例: マージ）。その後 resume で観測し直す
//	observe × parent・any             → observe / parent  外部の状態が変わるのを待つ。resume で観測し直す
func gateAction(runID string, w waitingView) *requestedAction {
	decider := contractParent
	if w.Decider == workflow.DeciderHuman {
		decider = contractHuman
	}
	where := fmt.Sprintf("gate %s, unit %s", w.Gate, w.Unit)
	switch {
	case w.Type == workflow.GateObserve:
		return &requestedAction{Kind: actionObserve, Decider: decider, Text: fmt.Sprintf(
			"%s [%s]. Then resume re-checks the state: harness contract resume %s --unit %s", w.RequestedAction, where, runID, w.Unit)}
	case w.RequiresTTY:
		return &requestedAction{Kind: actionApprove, Decider: contractHuman, Text: fmt.Sprintf(
			"%s [%s; choices: %s]. A person resolves it from a terminal: harness approve %s --unit %s --input <%s> [--note <text>]",
			w.RequestedAction, where, strings.Join(w.Inputs, "|"), runID, w.Unit, strings.Join(w.Inputs, "|"))}
	}
	return &requestedAction{Kind: actionAnswer, Decider: decider, Text: fmt.Sprintf(
		"%s [%s; choices: %s]. Answer with: harness contract resume %s --unit %s --input <%s> [--note <text>]",
		w.RequestedAction, where, strings.Join(w.Inputs, "|"), runID, w.Unit, strings.Join(w.Inputs, "|"))}
}

// pickAction は待っているゲートから 1 つを選ぶ（契約 v1 の requested_action は 1 つ）。人の判断（approve）を最優先し、
// 次に呼び出し元が答えるもの（answer）、最後に観測（observe）。同じ順位なら unit の順。ほかにも待っている unit が
// あれば text に数を添える（fan-out の run。現行のワークフローの unit は 1 つ）。
func pickAction(runID string, ws []waitingView) *requestedAction {
	if len(ws) == 0 {
		return nil
	}
	rank := map[string]int{actionApprove: 0, actionAnswer: 1, actionObserve: 2}
	acts := make([]*requestedAction, len(ws))
	for i, w := range ws {
		acts[i] = gateAction(runID, w)
	}
	order := make([]int, len(ws))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool { return rank[acts[order[a]].Kind] < rank[acts[order[b]].Kind] })
	a := acts[order[0]]
	if n := len(ws) - 1; n > 0 {
		a.Text += fmt.Sprintf(" (%d other unit(s) also wait at gates; see harness status %s)", n, runID)
	}
	return a
}

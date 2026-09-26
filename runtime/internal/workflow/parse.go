package workflow

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Problem は検証で見つかった 1 件の違反。
type Problem struct {
	File string
	Line int
	Msg  string
}

func (p Problem) String() string {
	if p.Line > 0 {
		return fmt.Sprintf("%s:%d: %s", p.File, p.Line, p.Msg)
	}
	return fmt.Sprintf("%s: %s", p.File, p.Msg)
}

// Problems は違反の一覧。空でなければ読み込みは失敗。
type Problems []Problem

func (ps Problems) Error() string {
	lines := make([]string, len(ps))
	for i, p := range ps {
		lines[i] = p.String()
	}
	return strings.Join(lines, "\n")
}

var (
	reIdent    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`) // inputs・edge・出力フィールドの名前
	reStepID   = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)        // ステップ id・ワークフロー id
	reArgName  = regexp.MustCompile(`^[a-z][a-z0-9_-]*$`)       // command の with の名前（--<名前> になる）
	reName     = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)        // limits の名前・fail/done の理由
	reOutcome  = regexp.MustCompile(`^[a-z][a-z0-9_-]*$`)       // outcome の値
	reScript   = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)     // command の run（スクリプト名）
	reRefInput = regexp.MustCompile(`^\$inputs\.([A-Za-z_][A-Za-z0-9_]*)$`)
	reRefStep  = regexp.MustCompile(`^\$steps\.([a-z][a-z0-9-]*)((?:\.[A-Za-z_][A-Za-z0-9_]*)+)$`)
	reRefEdge  = regexp.MustCompile(`^\$edge\.([A-Za-z_][A-Za-z0-9_]*)$`)
	reAgent    = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*:[a-z0-9][a-z0-9-]*$`) // <プラグイン>:<エージェント>
)

// exprKeys は条件・繰り返し・評価を思わせるキー。文法に無いキーはすべて拒否されるが、
// これらは「式の混入」であることを明示して拒否する（§3.1「式にしないための線引き」）。
var exprKeys = map[string]bool{
	"when": true, "if": true, "unless": true, "else": true, "condition": true, "cond": true,
	"expr": true, "expression": true, "switch": true, "case": true, "match": true, "where": true,
	"while": true, "until": true, "for": true, "foreach": true, "for_each": true, "each": true,
	"loop": true, "repeat": true, "eval": true, "template": true,
}

// kindSpec は Go に登録されたステップ種類が YAML で受け付けるキー。
type kindSpec struct {
	keys []string
}

// kinds は Go に登録されたステップ種類（§3.2）。PR-3 で llm と gate を足した。
// 種類を足すときは、ここと engine の実行器の両方に足す。
var kinds = map[string]kindSpec{
	"command": {keys: []string{"kind", "description", "run", "with", "output", "outcome_field", "exit", "timeout", "on"}},
	"llm":     {keys: []string{"kind", "description", "prompt", "agent", "session", "with", "output", "budget_usd", "timeout", "on"}},
	"gate":    {keys: []string{"kind", "description", "type", "decider", "requested_action", "inputs", "observe", "with", "on"}},
}

// Kinds は登録済みの種類名を返す。
func Kinds() []string {
	var out []string
	for k := range kinds {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

type parser struct {
	file     string
	problems Problems
}

func (p *parser) errf(n *yaml.Node, format string, args ...any) {
	line := 0
	if n != nil {
		line = n.Line
	}
	p.problems = append(p.problems, Problem{File: p.file, Line: line, Msg: fmt.Sprintf(format, args...)})
}

type pair struct {
	key   string
	knode *yaml.Node
	val   *yaml.Node
}

// plain は anchor・alias・明示タグを拒否する。YAML の合成（アンカーの再利用・マージキー）は
// §3.1 の文法に無く、差分を読みにくくするため受け付けない。
func (p *parser) plain(n *yaml.Node, what string) bool {
	if n.Kind == yaml.AliasNode {
		p.errf(n, "%s: YAML aliases (*%s) are not part of the workflow grammar", what, n.Value)
		return false
	}
	if n.Anchor != "" {
		p.errf(n, "%s: YAML anchors (&%s) are not part of the workflow grammar", what, n.Anchor)
		return false
	}
	if n.Style&yaml.TaggedStyle != 0 {
		p.errf(n, "%s: explicit YAML tags (%s) are not part of the workflow grammar", what, n.Tag)
		return false
	}
	return true
}

func (p *parser) mapping(n *yaml.Node, what string) ([]pair, bool) {
	if !p.plain(n, what) {
		return nil, false
	}
	if n.Kind != yaml.MappingNode {
		p.errf(n, "%s must be a mapping", what)
		return nil, false
	}
	var out []pair
	seen := map[string]bool{}
	ok := true
	for i := 0; i+1 < len(n.Content); i += 2 {
		k, v := n.Content[i], n.Content[i+1]
		if !p.plain(k, what+" key") || !p.plain(v, what+"."+k.Value) {
			ok = false
			continue
		}
		if k.Kind != yaml.ScalarNode {
			p.errf(k, "%s: keys must be plain scalars", what)
			ok = false
			continue
		}
		if k.Value == "<<" {
			p.errf(k, "%s: YAML merge keys (<<) are not part of the workflow grammar", what)
			ok = false
			continue
		}
		if seen[k.Value] {
			p.errf(k, "%s: duplicate key %q", what, k.Value)
			ok = false
			continue
		}
		seen[k.Value] = true
		out = append(out, pair{key: k.Value, knode: k, val: v})
	}
	return out, ok
}

// allowKeys は許可リストに無いキーをすべて拒否する。
func (p *parser) allowKeys(pairs []pair, what string, allowed ...string) bool {
	ok := true
	for _, pr := range pairs {
		found := false
		for _, a := range allowed {
			if pr.key == a {
				found = true
				break
			}
		}
		if found {
			continue
		}
		ok = false
		if exprKeys[strings.ToLower(pr.key)] {
			p.errf(pr.knode, "%s: key %q is a condition/expression; the workflow grammar has no expressions (transitions match the step's outcome only; see §3.1)", what, pr.key)
		} else {
			p.errf(pr.knode, "%s: unknown key %q (allowed: %s)", what, pr.key, strings.Join(allowed, ", "))
		}
	}
	return ok
}

func (p *parser) str(n *yaml.Node, what string) (string, bool) {
	if n.Kind != yaml.ScalarNode || n.Tag != "!!str" {
		p.errf(n, "%s must be a string", what)
		return "", false
	}
	return n.Value, true
}

func (p *parser) matched(n *yaml.Node, what string, re *regexp.Regexp) (string, bool) {
	s, ok := p.str(n, what)
	if !ok {
		return "", false
	}
	if !re.MatchString(s) {
		p.errf(n, "%s %q must match %s", what, s, re.String())
		return "", false
	}
	return s, true
}

func (p *parser) integer(n *yaml.Node, what string) (int64, bool) {
	if n.Kind != yaml.ScalarNode || n.Tag != "!!int" {
		p.errf(n, "%s must be an integer literal", what)
		return 0, false
	}
	v, err := strconv.ParseInt(n.Value, 0, 64)
	if err != nil {
		p.errf(n, "%s: %v", what, err)
		return 0, false
	}
	return v, true
}

func (p *parser) boolean(n *yaml.Node, what string) (bool, bool) {
	if n.Kind != yaml.ScalarNode || n.Tag != "!!bool" {
		p.errf(n, "%s must be true or false", what)
		return false, false
	}
	return n.Value == "true" || n.Value == "True" || n.Value == "TRUE", true
}

// Load はワークフローの YAML を読み込み、構文（§3.1・§3.3）を検査する。参照先・網羅などの意味の検査は Validate が行う。
func Load(path string) (*Workflow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(path, data)
}

// Parse は YAML のバイト列からワークフローを読み込む。path は報告と相対パスの起点に使う。
func Parse(path string, data []byte) (*Workflow, error) {
	p := &parser{file: path}
	sum := sha256.Sum256(data)
	wf := &Workflow{Path: path, Dir: filepath.Dir(path), Hash: hex.EncodeToString(sum[:])}

	var doc yaml.Node
	dec := yaml.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&doc); err != nil {
		return nil, Problems{{File: path, Msg: "invalid YAML: " + err.Error()}}
	}
	var extra yaml.Node
	if err := dec.Decode(&extra); err == nil {
		return nil, Problems{{File: path, Line: extra.Line, Msg: "a workflow file must contain exactly one YAML document"}}
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) != 1 {
		return nil, Problems{{File: path, Msg: "empty workflow file"}}
	}
	top, ok := p.mapping(doc.Content[0], "workflow")
	if !ok {
		return nil, p.problems
	}
	p.allowKeys(top, "workflow", "schema", "id", "description", "inputs", "limits", "steps")
	var stepsNode *yaml.Node
	for _, pr := range top {
		switch pr.key {
		case "schema":
			wf.Schema, _ = p.str(pr.val, "schema")
		case "id":
			wf.ID, _ = p.matched(pr.val, "id", reStepID)
		case "description":
			wf.Description, _ = p.str(pr.val, "description")
		case "inputs":
			wf.Inputs = p.inputs(pr.val)
		case "limits":
			wf.Limits = p.limits(pr.val)
		case "steps":
			stepsNode = pr.val
		}
	}
	if wf.Schema == "" {
		p.errf(doc.Content[0], "schema is required (%s)", SchemaV1)
	} else if wf.Schema != SchemaV1 {
		p.errf(doc.Content[0], "unsupported schema %q (supported: %s)", wf.Schema, SchemaV1)
	}
	if wf.ID == "" {
		p.errf(doc.Content[0], "id is required")
	}
	if stepsNode == nil {
		p.errf(doc.Content[0], "steps is required")
	} else {
		wf.Steps = p.steps(stepsNode)
	}
	if len(p.problems) > 0 {
		return nil, p.problems
	}
	return wf, nil
}

func (p *parser) typeSpec(n *yaml.Node, what string, allowItems bool) *Type {
	// items は型名 1 語（integer 等）か {type, items} の mapping。
	if n.Kind == yaml.ScalarNode {
		name, ok := p.str(n, what)
		if !ok {
			return nil
		}
		return p.typeName(n, what, name, nil)
	}
	pairs, ok := p.mapping(n, what)
	if !ok {
		return nil
	}
	allowed := []string{"type"}
	if allowItems {
		allowed = append(allowed, "items")
	}
	p.allowKeys(pairs, what, allowed...)
	var name string
	var items *Type
	for _, pr := range pairs {
		switch pr.key {
		case "type":
			name, _ = p.str(pr.val, what+".type")
		case "items":
			items = p.typeSpec(pr.val, what+".items", true)
		}
	}
	return p.typeName(n, what, name, items)
}

func (p *parser) typeName(n *yaml.Node, what, name string, items *Type) *Type {
	switch name {
	case "integer", "string", "object":
		if items != nil {
			p.errf(n, "%s: items is only valid for type array", what)
			return nil
		}
		return &Type{Name: name}
	case "array":
		return &Type{Name: "array", Items: items}
	case "":
		p.errf(n, "%s: type is required", what)
	default:
		p.errf(n, "%s: unknown type %q (allowed: integer, string, array, object)", what, name)
	}
	return nil
}

func (p *parser) inputs(n *yaml.Node) []*Input {
	pairs, ok := p.mapping(n, "inputs")
	if !ok {
		return nil
	}
	var out []*Input
	for _, pr := range pairs {
		what := "inputs." + pr.key
		if !reIdent.MatchString(pr.key) {
			p.errf(pr.knode, "input name %q must match %s", pr.key, reIdent.String())
			continue
		}
		fields, ok := p.mapping(pr.val, what)
		if !ok {
			continue
		}
		p.allowKeys(fields, what, "type", "items", "required")
		in := &Input{Name: pr.key, Line: pr.knode.Line}
		var name string
		var items *Type
		for _, f := range fields {
			switch f.key {
			case "type":
				name, _ = p.str(f.val, what+".type")
			case "items":
				items = p.typeSpec(f.val, what+".items", true)
			case "required":
				in.Required, _ = p.boolean(f.val, what+".required")
			}
		}
		in.Type = p.typeName(pr.val, what, name, items)
		out = append(out, in)
	}
	return out
}

func (p *parser) limits(n *yaml.Node) []*Limit {
	pairs, ok := p.mapping(n, "limits")
	if !ok {
		return nil
	}
	var out []*Limit
	for _, pr := range pairs {
		what := "limits." + pr.key
		if !reName.MatchString(pr.key) {
			p.errf(pr.knode, "limit name %q must match %s", pr.key, reName.String())
			continue
		}
		l := &Limit{Name: pr.key, Line: pr.knode.Line}
		if pr.val.Kind != yaml.ScalarNode || (pr.val.Tag != "!!int" && pr.val.Tag != "!!float") {
			p.errf(pr.val, "%s must be an integer or amount literal", what)
			continue
		}
		v, err := strconv.ParseFloat(pr.val.Value, 64)
		if err != nil || v < 0 {
			p.errf(pr.val, "%s must be a non-negative number", what)
			continue
		}
		l.Value = v
		l.Integer = pr.val.Tag == "!!int"
		out = append(out, l)
	}
	return out
}

func (p *parser) steps(n *yaml.Node) []*Step {
	pairs, ok := p.mapping(n, "steps")
	if !ok {
		return nil
	}
	if len(pairs) == 0 {
		p.errf(n, "steps must not be empty")
	}
	var out []*Step
	for _, pr := range pairs {
		if !reStepID.MatchString(pr.key) {
			p.errf(pr.knode, "step id %q must match %s", pr.key, reStepID.String())
			continue
		}
		if pr.key == InterruptedGate {
			p.errf(pr.knode, "step id %q is reserved for the runtime's built-in gate (a step left running by a runner that died)", pr.key)
			continue
		}
		if s := p.step(pr.key, pr.knode, pr.val); s != nil {
			out = append(out, s)
		}
	}
	return out
}

func (p *parser) step(id string, knode, n *yaml.Node) *Step {
	what := "steps." + id
	fields, ok := p.mapping(n, what)
	if !ok {
		return nil
	}
	s := &Step{ID: id, Line: knode.Line}
	for _, f := range fields {
		if f.key == "kind" {
			s.Kind, _ = p.str(f.val, what+".kind")
		}
	}
	spec, known := kinds[s.Kind]
	if s.Kind == "" {
		p.errf(n, "%s: kind is required (registered kinds: %s)", what, strings.Join(Kinds(), ", "))
		return nil
	}
	if !known {
		p.errf(n, "%s: kind %q is not a registered step kind (registered kinds: %s)", what, s.Kind, strings.Join(Kinds(), ", "))
		return nil
	}
	p.allowKeys(fields, what, spec.keys...)
	var onNode *yaml.Node
	for _, f := range fields {
		fw := what + "." + f.key
		switch f.key {
		case "description":
			s.Description, _ = p.str(f.val, fw)
		case "run":
			s.Run, _ = p.matched(f.val, fw, reScript)
		case "with":
			s.With = p.bindings(f.val, fw, reArgName)
		case "output":
			s.Output, _ = p.str(f.val, fw)
		case "outcome_field":
			s.OutcomeField, _ = p.matched(f.val, fw, reIdent)
		case "exit":
			s.Exit = p.exitTable(f.val, fw)
		case "timeout":
			if str, ok := p.str(f.val, fw); ok {
				d, err := time.ParseDuration(str)
				if err != nil || d <= 0 {
					p.errf(f.val, "%s must be a positive duration literal such as 90s or 30m", fw)
				} else {
					s.Timeout = d
				}
			}
		case "prompt":
			s.Prompt, _ = p.str(f.val, fw)
		case "agent":
			s.Agent, _ = p.matched(f.val, fw, reAgent)
		case "session":
			if str, ok := p.str(f.val, fw); ok {
				switch {
				case str == "new":
					s.Session = "new"
				case strings.HasPrefix(str, "continue:") && reStepID.MatchString(strings.TrimPrefix(str, "continue:")):
					s.Session, s.SessionFrom = "continue", strings.TrimPrefix(str, "continue:")
				default:
					p.errf(f.val, "%s must be new or continue:<step id> (got %q)", fw, str)
				}
			}
		case "budget_usd":
			if f.val.Kind != yaml.ScalarNode || (f.val.Tag != "!!int" && f.val.Tag != "!!float") {
				p.errf(f.val, "%s must be an amount literal", fw)
			} else if v, err := strconv.ParseFloat(f.val.Value, 64); err != nil || !(v > 0) {
				p.errf(f.val, "%s must be a positive amount", fw)
			} else {
				s.BudgetUSD = v
			}
		case "type":
			s.GateType, _ = p.str(f.val, fw)
		case "decider":
			s.Decider, _ = p.str(f.val, fw)
		case "requested_action":
			s.RequestedAction, _ = p.str(f.val, fw)
		case "inputs":
			s.GateInputs = p.outcomeList(f.val, fw)
		case "observe":
			s.Observe, _ = p.matched(f.val, fw, reOutcome)
		case "on":
			onNode = f.val
		}
	}
	if s.Kind == "llm" && s.Session == "" {
		s.Session = "new"
	}
	if onNode == nil {
		p.errf(n, "%s: on is required", what)
	} else {
		s.On = p.onTable(onNode, what+".on")
	}
	return s
}

// outcomeList は input 型ゲートの inputs（outcome の値の列）を読む。
func (p *parser) outcomeList(n *yaml.Node, what string) []string {
	if !p.plain(n, what) {
		return nil
	}
	if n.Kind != yaml.SequenceNode {
		p.errf(n, "%s must be a list of values", what)
		return nil
	}
	var out []string
	seen := map[string]bool{}
	for _, it := range n.Content {
		if !p.plain(it, what) {
			continue
		}
		v, ok := p.matched(it, what+" item", reOutcome)
		if !ok {
			continue
		}
		if seen[v] {
			p.errf(it, "%s: duplicate value %q", what, v)
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	return out
}

func (p *parser) exitTable(n *yaml.Node, what string) []*ExitEntry {
	pairs, ok := p.mapping(n, what)
	if !ok {
		return nil
	}
	var out []*ExitEntry
	for _, pr := range pairs {
		code, err := strconv.Atoi(pr.key)
		if err != nil || code < 0 || code > 255 || pr.knode.Tag != "!!int" {
			p.errf(pr.knode, "%s: key %q must be an exit code literal (0-255)", what, pr.key)
			continue
		}
		o, ok := p.matched(pr.val, what+"."+pr.key, reOutcome)
		if !ok {
			continue
		}
		out = append(out, &ExitEntry{Code: code, Outcome: o, Line: pr.knode.Line})
	}
	if len(out) == 0 && len(p.problems) == 0 {
		p.errf(n, "%s must not be empty", what)
	}
	return out
}

func (p *parser) onTable(n *yaml.Node, what string) []*OnEntry {
	pairs, ok := p.mapping(n, what)
	if !ok {
		return nil
	}
	var out []*OnEntry
	for _, pr := range pairs {
		// outcome の値は任意の enum なので、ここでは形だけを見る。enum に無いキー（when: 等を含む）は Validate が拒否する。
		if !reOutcome.MatchString(pr.key) {
			p.errf(pr.knode, "%s: key %q is not an outcome value; on only maps outcome values (exact match) to transitions, it has no conditions or expressions (see §3.1)", what, pr.key)
			continue
		}
		t := p.transition(pr.val, what+"."+pr.key, false)
		if t != nil {
			out = append(out, &OnEntry{Outcome: pr.key, T: t, Line: pr.knode.Line})
		}
	}
	return out
}

// transition は遷移先の 6 形（§3.1）を読む。nested は exhausted の中身で、回数を数える形（limit・retry）を禁じる。
func (p *parser) transition(n *yaml.Node, what string, nested bool) *Transition {
	if !p.plain(n, what) {
		return nil
	}
	if n.Kind == yaml.ScalarNode {
		id, ok := p.matched(n, what+" (step id)", reStepID)
		if !ok {
			return nil
		}
		return &Transition{Kind: TStep, Target: id, Line: n.Line}
	}
	pairs, ok := p.mapping(n, what)
	if !ok {
		return nil
	}
	primary := ""
	for _, pr := range pairs {
		switch pr.key {
		case "goto", "gate", "fail", "done", "retry":
			if primary != "" {
				p.errf(pr.knode, "%s: a transition has exactly one of goto, gate, fail, done, retry (found %s and %s)", what, primary, pr.key)
				return nil
			}
			primary = pr.key
		}
	}
	t := &Transition{Line: n.Line}
	switch primary {
	case "":
		p.allowKeys(pairs, what, "goto", "gate", "fail", "done", "retry")
		p.errf(n, "%s: a transition needs one of goto, gate, fail, done, retry", what)
		return nil
	case "goto":
		t.Kind = TGoto
		if !p.allowKeys(pairs, what, "goto", "with", "limit", "exhausted") {
			return nil
		}
	case "retry":
		t.Kind = TRetry
		if !p.allowKeys(pairs, what, "retry", "exhausted") {
			return nil
		}
	case "gate":
		t.Kind = TGate
		if !p.allowKeys(pairs, what, "gate") {
			return nil
		}
	case "fail":
		t.Kind = TFail
		if !p.allowKeys(pairs, what, "fail") {
			return nil
		}
	case "done":
		t.Kind = TDone
		if !p.allowKeys(pairs, what, "done") {
			return nil
		}
	}
	var exhausted *yaml.Node
	for _, pr := range pairs {
		fw := what + "." + pr.key
		switch pr.key {
		case "goto", "gate":
			t.Target, _ = p.matched(pr.val, fw, reStepID)
		case "fail", "done":
			t.Reason, _ = p.matched(pr.val, fw, reName)
		case "with":
			t.With = p.bindings(pr.val, fw, reIdent)
		case "limit":
			t.Limit, _ = p.matched(pr.val, fw, reName)
		case "retry":
			if v, ok := p.integer(pr.val, fw); ok {
				if v < 1 {
					p.errf(pr.val, "%s must be at least 1", fw)
				}
				t.Retry = int(v)
			}
		case "exhausted":
			exhausted = pr.val
		}
	}
	if nested && (t.Kind == TRetry || t.Limit != "") {
		p.errf(n, "%s: exhausted must not itself count (no retry or limit inside exhausted)", what)
		return nil
	}
	needsExhausted := t.Kind == TRetry || t.Limit != ""
	switch {
	case needsExhausted && exhausted == nil:
		p.errf(n, "%s: exhausted is required with %s", what, map[bool]string{true: "retry", false: "limit"}[t.Kind == TRetry])
	case !needsExhausted && exhausted != nil:
		p.errf(n, "%s: exhausted is only valid with retry or limit", what)
	case exhausted != nil:
		t.Exhausted = p.transition(exhausted, what+".exhausted", true)
	}
	return t
}

func (p *parser) bindings(n *yaml.Node, what string, nameRe *regexp.Regexp) []*Binding {
	pairs, ok := p.mapping(n, what)
	if !ok {
		return nil
	}
	var out []*Binding
	for _, pr := range pairs {
		fw := what + "." + pr.key
		if !nameRe.MatchString(pr.key) {
			p.errf(pr.knode, "%s: name %q must match %s", what, pr.key, nameRe.String())
			continue
		}
		v, ok := p.value(pr.val, fw)
		if ok {
			out = append(out, &Binding{Name: pr.key, Value: v, Line: pr.knode.Line})
		}
	}
	return out
}

// value は with の値（参照 1 つ、またはリテラル）を読む。
func (p *parser) value(n *yaml.Node, what string) (Value, bool) {
	if n.Kind != yaml.ScalarNode {
		p.errf(n, "%s must be one reference or a scalar literal (lists and mappings are not values)", what)
		return Value{}, false
	}
	switch n.Tag {
	case "!!int":
		v, ok := p.integer(n, what)
		return Value{Literal: v}, ok
	case "!!str":
	default:
		p.errf(n, "%s: literal must be a string or an integer (got %s)", what, strings.TrimPrefix(n.Tag, "!!"))
		return Value{}, false
	}
	s := n.Value
	if strings.HasPrefix(s, "$") {
		ref, err := ParseRef(s)
		if err != nil {
			p.errf(n, "%s: %v", what, err)
			return Value{}, false
		}
		return Value{Ref: ref}, true
	}
	if strings.Contains(s, "$") || strings.Contains(s, "{{") {
		p.errf(n, "%s: %q embeds a reference in a literal; a value is either exactly one reference or a literal (no string building, see §3.3)", what, s)
		return Value{}, false
	}
	return Value{Literal: s}, true
}

// ParseRef は参照の文法（§3.3）の 4 形だけを受け付ける。演算・連結・添字・既定値は持たない。
func ParseRef(s string) (*Ref, error) {
	if m := reRefInput.FindStringSubmatch(s); m != nil {
		return &Ref{Kind: RefInputs, Name: m[1], Raw: s}, nil
	}
	if m := reRefStep.FindStringSubmatch(s); m != nil {
		return &Ref{Kind: RefSteps, Step: m[1], Path: strings.Split(strings.TrimPrefix(m[2], "."), "."), Raw: s}, nil
	}
	if m := reRefEdge.FindStringSubmatch(s); m != nil {
		return &Ref{Kind: RefEdge, Name: m[1], Raw: s}, nil
	}
	if s == "$gate.note" {
		return &Ref{Kind: RefGate, Name: "note", Raw: s}, nil
	}
	return nil, fmt.Errorf("%q is not a reference; the only forms are $inputs.<name>, $steps.<step>.<field>[.<field>...], $edge.<name>, $gate.note (no operators, concatenation, indexing or defaults, see §3.3)", s)
}

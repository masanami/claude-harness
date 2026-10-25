package workflow

// ワークフロー定義の上書き（docs/harness-runtime-overrides.md・Issue #309 の段 1＝#312）。
//
// 上書きは元の定義と同じ入れ子の写像で、変えるスカラーだけを書く部分上書き（§4）。開くキーは数値だけで（§5.1）、
// limits の全項目・llm の budget_usd と timeout・command の timeout を Go の規則で一律に開く。それ以外のキーは
// 「書けるものだけを列挙する」形（workflow.go の冒頭の注記）で拒否し、元の定義の文法にあるキーの名前なら
// 「上書きできない」と伝える（§5.3）。遷移の付け替え（overridable.routes）は段 2 で足す。

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// OverrideSchemaV1 は上書きの YAML のスキーマ版（§4.1）。
const OverrideSchemaV1 = "harness.workflow-override/v1"

// 上書きの層（§3）。元の定義（層 0）の上に、リポジトリ → 引数の順に重ね、キーごとに後ろの層が勝つ。
const (
	LayerRepo = "repo" // 層 1: run を始めた作業ディレクトリの git の最上位にある .claude-harness/overrides/<id>.yaml
	LayerArg  = "arg"  // 層 2: --override <ファイル>
)

// effectiveSchema は上書き後の定義のハッシュ（EffectiveHash）を取る正規化した表現の版。重ね方や正規化を変えたら
// 上げる（resume が開始時と違う組み立てで続けないように、照合が食い違うようにする。§7.2 の 3）。
const effectiveSchema = "harness.workflow-effective/v1"

// OverrideSource は読み込む上書きのファイル 1 つ。Path は報告と記録にだけ使う。
type OverrideSource struct {
	Layer string
	Path  string
	Data  []byte
}

// Override は読み込んだ上書き 1 つ。SHA256 はファイルのバイト列の sha256（run の記録と resume の照合に使う。§7）。
type Override struct {
	Layer  string
	Path   string
	SHA256 string
	Data   []byte
	sets   []overrideSet
}

// overrideSet は上書きが書いた値 1 つ。
type overrideSet struct {
	key   string // limits.<名前> | steps.<id>.budget_usd | steps.<id>.timeout
	limit string
	step  string
	field string
	num   float64
	isInt bool
	dur   time.Duration
}

// Change は上書きで効いた値 1 つ（§7.1 の changes）。From は元の定義の値（元の定義に無いキーなら nil）、To は効いた値、
// Layer はその値を書いた層（複数の層が書いたキーは最後の層）。数値は数、timeout は Go の時間の書式（例: 30m0s）。
type Change struct {
	Key   string `json:"key"`
	From  any    `json:"from"`
	To    any    `json:"to"`
	Layer string `json:"layer"`
}

// closedTopKeys は元の定義のトップレベルにあり、上書きできないキー（§5.3）。
var closedTopKeys = map[string]bool{"id": true, "description": true, "inputs": true, "overridable": true}

// openStepKeys はステップで上書きできるキーと、それを持てるステップの種類（§5.1）。
var openStepKeys = map[string][]string{
	"budget_usd": {"llm"},
	"timeout":    {"llm", "command"},
}

// closedStepKey は、元の定義のステップの文法にあるキーで上書きできないものかを返す（§5.3）。
func closedStepKey(key string) bool {
	if _, open := openStepKeys[key]; open {
		return false
	}
	for _, spec := range kinds {
		for _, k := range spec.keys {
			if k == key {
				return true
			}
		}
	}
	return false
}

// OverrideTarget は上書きのファイルが指す定義の id（workflow キー）を返す。validate が複数の定義のどれに重ねるかを
// 決めるためだけに使い、ファイルの中身の検査は ParseOverride が行う。
func OverrideTarget(path string, data []byte) (string, error) {
	var head struct {
		Workflow any `yaml:"workflow"`
	}
	if err := yaml.Unmarshal(data, &head); err != nil {
		return "", Problems{{File: path, Msg: "invalid YAML: " + err.Error()}}
	}
	id, ok := head.Workflow.(string)
	if !ok || id == "" {
		return "", Problems{{File: path, Msg: "workflow is required (the id of the workflow this file overrides)"}}
	}
	return id, nil
}

// ParseOverride は上書きの YAML を読み、base（元の定義）に対して書けるキーと値かを検査する。
func ParseOverride(src OverrideSource, base *Workflow) (*Override, error) {
	p := &parser{file: src.Path}
	sum := sha256.Sum256(src.Data)
	ov := &Override{Layer: src.Layer, Path: src.Path, SHA256: hex.EncodeToString(sum[:]), Data: src.Data}

	var doc yaml.Node
	dec := yaml.NewDecoder(bytes.NewReader(src.Data))
	if err := dec.Decode(&doc); err != nil {
		return nil, Problems{{File: src.Path, Msg: "invalid YAML: " + err.Error()}}
	}
	var extra yaml.Node
	if err := dec.Decode(&extra); err == nil {
		return nil, Problems{{File: src.Path, Line: extra.Line, Msg: "an override file must contain exactly one YAML document"}}
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) != 1 {
		return nil, Problems{{File: src.Path, Msg: "empty override file"}}
	}
	root := doc.Content[0]
	top, ok := p.mapping(root, "override")
	if !ok {
		return nil, p.problems
	}
	var schema, target string
	for _, pr := range top {
		switch {
		case pr.key == "schema":
			schema, _ = p.str(pr.val, "schema")
		case pr.key == "workflow":
			target, _ = p.str(pr.val, "workflow")
		case pr.key == "limits":
			p.overrideLimits(ov, pr.val, base)
		case pr.key == "steps":
			p.overrideSteps(ov, pr.val, base)
		case closedTopKeys[pr.key]:
			p.errf(pr.knode, "override: key %q cannot be overridden (an override may set only limits.<name>, steps.<id>.budget_usd and steps.<id>.timeout)", pr.key)
		case exprKeys[strings.ToLower(pr.key)]:
			p.errf(pr.knode, "override: key %q is a condition/expression; overrides have no expressions (see §3.1)", pr.key)
		default:
			p.errf(pr.knode, "override: unknown key %q (allowed: schema, workflow, limits, steps)", pr.key)
		}
	}
	switch {
	case schema == "":
		p.errf(root, "schema is required (%s)", OverrideSchemaV1)
	case schema != OverrideSchemaV1:
		p.errf(root, "unsupported schema %q (supported: %s)", schema, OverrideSchemaV1)
	}
	switch {
	case target == "":
		p.errf(root, "workflow is required (the id of the workflow this file overrides)")
	case target != base.ID:
		p.errf(root, "workflow %q does not match the workflow being overridden (%q)", target, base.ID)
	}
	if len(p.problems) > 0 {
		return nil, p.problems
	}
	return ov, nil
}

func (p *parser) overrideLimits(ov *Override, n *yaml.Node, base *Workflow) {
	pairs, ok := p.mapping(n, "limits")
	if !ok {
		return
	}
	for _, pr := range pairs {
		what := "limits." + pr.key
		l := base.Limit(pr.key)
		if l == nil {
			p.errf(pr.knode, "%s: workflow %s has no such limit (an override cannot add limits)", what, base.ID)
			continue
		}
		v := pr.val
		if v.Kind != yaml.ScalarNode || (v.Tag != "!!int" && v.Tag != "!!float") {
			p.errf(v, "%s must be a number literal (references and other values cannot be written in an override)", what)
			continue
		}
		f, err := strconv.ParseFloat(v.Value, 64)
		switch {
		case err != nil:
			p.errf(v, "%s: %v", what, err)
			continue
		case pr.key == BudgetLimit && !(f > 0):
			p.errf(v, "%s must be a positive amount", what)
			continue
		case pr.key != BudgetLimit && l.Integer && v.Tag != "!!int":
			p.errf(v, "%s must be an integer (the workflow counts it as an integer limit)", what)
			continue
		case f < 0:
			p.errf(v, "%s must be a non-negative number", what)
			continue
		}
		isInt := v.Tag == "!!int"
		if pr.key != BudgetLimit {
			isInt = l.Integer
		}
		ov.sets = append(ov.sets, overrideSet{key: what, limit: pr.key, num: f, isInt: isInt})
	}
}

func (p *parser) overrideSteps(ov *Override, n *yaml.Node, base *Workflow) {
	pairs, ok := p.mapping(n, "steps")
	if !ok {
		return
	}
	for _, pr := range pairs {
		what := "steps." + pr.key
		s := base.Step(pr.key)
		if s == nil {
			p.errf(pr.knode, "%s: workflow %s has no such step (an override cannot add steps)", what, base.ID)
			continue
		}
		fields, ok := p.mapping(pr.val, what)
		if !ok {
			continue
		}
		for _, f := range fields {
			fw := what + "." + f.key
			kindsWith, open := openStepKeys[f.key]
			switch {
			case open && !contains(kindsWith, s.Kind):
				p.errf(f.knode, "%s: a %s step has no %s (it can be overridden on %s steps)", fw, s.Kind, f.key, strings.Join(kindsWith, " and "))
				continue
			case open:
			case closedStepKey(f.key):
				p.errf(f.knode, "%s cannot be overridden (a step override may set only budget_usd on llm steps and timeout on llm and command steps)", fw)
				continue
			case exprKeys[strings.ToLower(f.key)]:
				p.errf(f.knode, "%s: key %q is a condition/expression; overrides have no expressions (see §3.1)", what, f.key)
				continue
			default:
				p.errf(f.knode, "%s: unknown key %q (allowed: budget_usd, timeout)", what, f.key)
				continue
			}
			set := overrideSet{key: fw, step: pr.key, field: f.key}
			v := f.val
			switch f.key {
			case "budget_usd":
				if v.Kind != yaml.ScalarNode || (v.Tag != "!!int" && v.Tag != "!!float") {
					p.errf(v, "%s must be an amount literal", fw)
					continue
				}
				x, err := strconv.ParseFloat(v.Value, 64)
				if err != nil || !(x > 0) {
					p.errf(v, "%s must be a positive amount", fw)
					continue
				}
				set.num = x
			case "timeout":
				str, ok := p.str(v, fw)
				if !ok {
					continue
				}
				if strings.HasPrefix(str, "$") {
					p.errf(v, "%s: %q is a reference; an override value is a literal", fw, str)
					continue
				}
				d, err := time.ParseDuration(str)
				if err != nil || d <= 0 {
					p.errf(v, "%s must be a positive duration literal such as 90s or 30m", fw)
					continue
				}
				set.dur = d
			}
			ov.sets = append(ov.sets, set)
		}
	}
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

// LoadWithOverrides は元の定義を読み込んで検査し、上書きを層の順に重ねた定義を返す（§3・§6.2 の規則 4: 上書き後の定義も
// 通常の検査をすべて通す）。上書きが無ければ LoadAndValidate と同じ。返す定義の Hash は元の定義の YAML の sha256 のまま
// （§7.1）で、上書きがあれば Overrides・Changes・EffectiveHash を持つ。
func LoadWithOverrides(path string, opts Options, srcs []OverrideSource) (*Workflow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	base, err := Parse(path, data)
	if err != nil {
		return nil, err
	}
	if ps := Validate(base, opts); len(ps) > 0 {
		return nil, ps
	}
	if len(srcs) == 0 {
		return base, nil
	}
	var ovs []*Override
	var problems Problems
	for _, src := range srcs {
		ov, err := ParseOverride(src, base)
		if err != nil {
			ps, ok := err.(Problems)
			if !ok {
				return nil, err
			}
			problems = append(problems, ps...)
			continue
		}
		ovs = append(ovs, ov)
	}
	if len(problems) > 0 {
		return nil, problems
	}
	// 検査済みの元の定義を書き換えないように、同じバイト列から読み直したものに重ねる。
	eff, err := Parse(path, data)
	if err != nil {
		return nil, err
	}
	changes := apply(eff, ovs)
	if ps := Validate(eff, opts); len(ps) > 0 {
		return nil, ps
	}
	eff.Overrides, eff.Changes = ovs, changes
	eff.EffectiveHash = effectiveHash(eff.Hash, changes)
	return eff, nil
}

// apply は上書きを順に wf へ重ね、効いた値を元の定義の順（limits の宣言順 → steps の宣言順・budget_usd → timeout）で返す。
func apply(wf *Workflow, ovs []*Override) []Change {
	type won struct {
		set   overrideSet
		layer string
	}
	last := map[string]won{}
	for _, ov := range ovs {
		for _, s := range ov.sets {
			last[s.key] = won{set: s, layer: ov.Layer}
		}
	}
	var changes []Change
	for _, l := range wf.Limits {
		w, ok := last["limits."+l.Name]
		if !ok {
			continue
		}
		from := limitValue(l.Value, l.Integer)
		l.Value, l.Integer = w.set.num, w.set.isInt
		changes = append(changes, Change{Key: w.set.key, From: from, To: limitValue(l.Value, l.Integer), Layer: w.layer})
	}
	for _, s := range wf.Steps {
		if w, ok := last["steps."+s.ID+".budget_usd"]; ok {
			from := s.BudgetUSD
			s.BudgetUSD = w.set.num
			changes = append(changes, Change{Key: w.set.key, From: from, To: s.BudgetUSD, Layer: w.layer})
		}
		if w, ok := last["steps."+s.ID+".timeout"]; ok {
			var from any
			if s.Timeout > 0 {
				from = s.Timeout.String()
			}
			s.Timeout = w.set.dur
			changes = append(changes, Change{Key: w.set.key, From: from, To: s.Timeout.String(), Layer: w.layer})
		}
	}
	return changes
}

func limitValue(v float64, integer bool) any {
	if integer {
		return int64(v)
	}
	return v
}

// effectiveHash は上書き後の定義を正規化した表現の sha256（§7.1 の effective_hash・§12）。
//
// 表現は {schema, base: 元の定義の YAML の sha256, set: 効いた値の [{key, value}] をキーの順に並べたもの} の JSON にした。
// 元の定義の残りの部分は base が同定するので、上書き後の定義は「元の定義」と「開いたキーに効いた値」の組で決まる。
// 値は読み込んだ後の値（数は Go の数、timeout は time.Duration の文字列）なので、上書きのファイルのコメント・書式・
// キーの順・数の書き方（60 と 60.0、30m と 1800s）や、どの層が書いたかには依らない。重ね方・正規化を変えたら
// effectiveSchema を上げて、開始時と違う組み立てでの resume を照合で止める。
func effectiveHash(base string, changes []Change) string {
	type kv struct {
		Key   string `json:"key"`
		Value any    `json:"value"`
	}
	set := make([]kv, 0, len(changes))
	for _, c := range changes {
		set = append(set, kv{Key: c.Key, Value: c.To})
	}
	sort.Slice(set, func(i, j int) bool { return set[i].Key < set[j].Key })
	b, err := json.Marshal(struct {
		Schema string `json:"schema"`
		Base   string `json:"base"`
		Set    []kv   `json:"set"`
	}{effectiveSchema, base, set})
	if err != nil {
		panic(fmt.Sprintf("effective hash: %v", err)) // 数と文字列だけなので起きない
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

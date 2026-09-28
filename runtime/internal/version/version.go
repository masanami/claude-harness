// Package version は CLI の版と、CLI が対応するプラグイン版の範囲・ワークフロースキーマ版の集合
// （docs/harness-runtime-design.md §7.2・§7.3）。
//
// CLI の版は独立した semver で、タグは runtime/vX.Y.Z。リリースのビルドは -ldflags で Version を埋める（Makefile の dist）。
// 埋めていなければ、go install が記録するモジュールの版（runtime/vX.Y.Z のタグから入れた場合の vX.Y.Z）を使い、
// それも無い（作業ツリーからのビルド）なら "dev"。
package version

import (
	"fmt"
	"regexp"
	"runtime/debug"
	"strconv"
	"strings"

	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// Version はリリースのビルドが -ldflags "-X github.com/masanami/claude-harness/runtime/internal/version.Version=X.Y.Z" で埋める。
var Version = ""

// Dev は版を持たないビルドの版。
const Dev = "dev"

// PluginMin・PluginMaxExclusive は CLI が対応するプラグイン（plugin/.claude-plugin/plugin.json の version）の範囲
// [PluginMin, PluginMaxExclusive)。子の claude -p が使う agents/ はインストール済みのプラグインから解決されるため、
// 範囲外のプラグインでは動き続けない（§7.3）。
const (
	PluginMin          = "4.8.0"
	PluginMaxExclusive = "5.0.0"
)

// WorkflowSchemas は CLI が読み込めるワークフロースキーマ版の集合。
var WorkflowSchemas = []string{workflow.SchemaV1}

// SupportsSchema は schema を読み込めるか。
func SupportsSchema(schema string) bool {
	for _, s := range WorkflowSchemas {
		if s == schema {
			return true
		}
	}
	return false
}

var pseudo = regexp.MustCompile(`\d{14}-[0-9a-f]{12}`)

// CLI は CLI の版（先頭の v を除いた semver。版を持たなければ Dev）。
func CLI() string {
	if Version != "" {
		return strings.TrimPrefix(Version, "v")
	}
	if bi, ok := debug.ReadBuildInfo(); ok {
		v := bi.Main.Version
		// 作業ツリーからのビルドは (devel) か VCS の擬似版（v0.0.0-<時刻>-<hash>、+dirty 付き）になる。リリースの版ではない。
		if v != "" && v != "(devel)" && !pseudo.MatchString(v) && !strings.Contains(v, "+dirty") {
			return strings.TrimPrefix(v, "v")
		}
	}
	return Dev
}

// PluginRange は範囲の表記。
func PluginRange() string {
	return fmt.Sprintf(">=%s <%s", PluginMin, PluginMaxExclusive)
}

// Mismatch はプラグイン版が範囲外であること。Update はどちらを更新すべきか（plugin | cli）。
type Mismatch struct {
	Plugin string
	Update string
}

func (m *Mismatch) Error() string {
	if m.Update == "plugin" {
		return fmt.Sprintf("plugin claude-harness %s is older than this harness CLI %s supports (%s); update the plugin: claude plugin update claude-harness@masanami-harness (or harness setup)",
			m.Plugin, CLI(), PluginRange())
	}
	return fmt.Sprintf("plugin claude-harness %s is newer than this harness CLI %s supports (%s); update the harness CLI to a release that supports it",
		m.Plugin, CLI(), PluginRange())
}

// CheckPlugin はプラグイン版が範囲内かを確かめる。範囲外なら *Mismatch、版として読めなければその誤りを返す。
func CheckPlugin(plugin string) error {
	p, err := parse(plugin)
	if err != nil {
		return fmt.Errorf("plugin version %q is not a semver (X.Y.Z)", plugin)
	}
	lo, _ := parse(PluginMin)
	hi, _ := parse(PluginMaxExclusive)
	switch {
	case compare(p, lo) < 0:
		return &Mismatch{Plugin: plugin, Update: "plugin"}
	case compare(p, hi) >= 0:
		return &Mismatch{Plugin: plugin, Update: "cli"}
	}
	return nil
}

// semver は X.Y.Z[-pre][+build]（build は比較に使わない）。
type semver struct {
	n   [3]int
	pre string
}

func parse(s string) (semver, error) {
	s = strings.TrimPrefix(s, "v")
	if i := strings.IndexByte(s, '+'); i >= 0 {
		s = s[:i]
	}
	var v semver
	core, pre, _ := strings.Cut(s, "-")
	v.pre = pre
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return v, fmt.Errorf("not X.Y.Z")
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 || (len(p) > 1 && p[0] == '0') {
			return v, fmt.Errorf("not X.Y.Z")
		}
		v.n[i] = n
	}
	return v, nil
}

// compare は a と b を比べる。pre-release は同じ X.Y.Z の正式版より前（pre-release どうしは文字列で比べる）。
func compare(a, b semver) int {
	for i := range a.n {
		if a.n[i] != b.n[i] {
			if a.n[i] < b.n[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case a.pre == b.pre:
		return 0
	case a.pre == "":
		return 1
	case b.pre == "":
		return -1
	case a.pre < b.pre:
		return -1
	}
	return 1
}

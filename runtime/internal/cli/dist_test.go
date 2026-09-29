package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/masanami/claude-harness/runtime/internal/bundle"
	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/version"
)

// with は同じ隔離先のまま環境変数を足した harness（後に置いた値が勝つ）。
func (h *harness) with(kv ...string) *harness {
	env := append(append([]string{}, h.env...), kv...)
	return &harness{t: h.t, env: env, cwd: h.cwd}
}

// 埋め込んだ定義を、作業ツリーの外から --workflow-dir / --scripts-dir 無しで検証できる（S1）。展開先は HARNESS_DATA_DIR。
func TestValidateUsesTheEmbeddedDefinitions(t *testing.T) {
	data := t.TempDir()
	h := newHarness(t, "HARNESS_DATA_DIR="+data, "HARNESS_TEST_CLI_VERSION=1.2.3")
	out, errOut, code := h.run("validate")
	if code != ExitOK {
		t.Fatalf("exit %d\n%s\n%s", code, out, errOut)
	}
	root := filepath.Join(data, "runtime", "1.2.3")
	for _, wf := range []string{"ticket", "list-tests"} {
		if !strings.Contains(out, "ok "+filepath.Join(root, "workflows", wf+".yaml")) {
			t.Errorf("validate did not check the embedded %s:\n%s", wf, out)
		}
	}
	for _, p := range []string{"scripts/worktree-setup.sh", "scripts/lib/common.sh", "workflows/scripts/resolve-ticket.sh", "agents/feature-implementer.md", bundle.MarkerFile} {
		if _, err := os.Stat(filepath.Join(root, p)); err != nil {
			t.Errorf("%s was not extracted: %v", p, err)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "scripts", "tests")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("scripts/tests must not be embedded: %v", err)
	}
	// HOME の既定の置き場（~/.local/share）には書かない。
	if _, err := os.Stat(filepath.Join(strings.TrimPrefix(h.env[1], "HOME="), ".local", "share")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("wrote under HOME/.local/share: %v", err)
	}
}

// 埋め込んでいないバイナリ（make bundle を経ないビルド）は、作業ツリーの中なら作業ツリーの定義を、外なら
// --workflow-dir / --scripts-dir を求めて止まる。
func TestDirsWithoutEmbeddedDefinitions(t *testing.T) {
	saved := bundle.FS
	defer func() { bundle.FS = saved }()
	bundle.FS = fstest.MapFS{"README.md": {Data: []byte("placeholder")}}
	outside := t.TempDir()
	env := Env{Getenv: func(k string) string { return map[string]string{"HOME": outside}[k] }}

	env.Getwd = func() (string, error) { return outside, nil }
	if _, err := dirs(map[string][]string{}, env); !errors.Is(err, bundle.ErrNotEmbedded) {
		t.Fatalf("outside the working tree: err = %v", err)
	}
	inside := abs(t, ".")
	env.Getwd = func() (string, error) { return inside, nil }
	src, err := dirs(map[string][]string{}, env)
	if err != nil || src.embedded || src.wd != abs(t, repoWorkflows) || src.sd != abs(t, repoScripts) {
		t.Fatalf("inside the working tree: %+v %v", src, err)
	}
	// フラグがあれば埋め込みの有無に関係なくそれを使う。
	src, err = dirs(map[string][]string{"workflow-dir": {outside}, "scripts-dir": {outside}}, env)
	if err != nil || src.embedded || src.wd != outside || src.sd != outside {
		t.Fatalf("flags: %+v %v", src, err)
	}
}

func TestVersion(t *testing.T) {
	data := t.TempDir()
	h := newHarness(t, "HARNESS_DATA_DIR="+data, "HARNESS_TEST_CLI_VERSION=1.2.3")
	out, errOut, code := h.run("version", "--json")
	if code != ExitOK {
		t.Fatalf("exit %d\n%s", code, errOut)
	}
	v := decode[versionView](t, out)
	digest, _ := bundle.Digest(bundle.FS)
	if v.CLIVersion != "1.2.3" || v.PluginVersionRange.Min != version.PluginMin || v.PluginVersionRange.MaxExclusive != version.PluginMaxExclusive ||
		len(v.WorkflowSchemas) != 1 || v.WorkflowSchemas[0] != "harness.workflow/v1" || !v.Embedded || v.BundleSHA256 != digest ||
		v.RuntimeDir != filepath.Join(data, "runtime", "1.2.3") || v.Plugin != nil {
		t.Fatalf("version = %+v", v)
	}
	// version は展開しない（場所を示すだけ）。
	if _, err := os.Stat(v.RuntimeDir); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("version extracted the definitions: %v", err)
	}
	// 版を持たないビルドは中身ごとに別の名前で展開する。
	v = decode[versionView](t, first3(newHarness(t, "HARNESS_DATA_DIR="+data).run("version", "--json")))
	if v.CLIVersion != version.Dev || v.RuntimeDir != filepath.Join(data, "runtime", "dev-"+digest[:12]) {
		t.Fatalf("dev version = %+v", v)
	}
	// 呼び出し元がプラグイン版を渡せば照合の結果も返す（終了コードは 0 のまま）。
	for pv, want := range map[string]pluginCheck{
		"4.8.1": {Version: "4.8.1", Compatible: true},
		"4.7.0": {Version: "4.7.0", Update: "plugin"},
		"5.0.0": {Version: "5.0.0", Update: "cli"},
	} {
		out, _, code := h.with(PluginVersionEnv+"="+pv).run("version", "--json")
		c := decode[versionView](t, out).Plugin
		if code != ExitOK || c == nil || c.Version != want.Version || c.Compatible != want.Compatible || c.Update != want.Update {
			t.Errorf("plugin %s: exit %d check %+v", pv, code, c)
		}
	}
	out, _, code = h.run("version")
	if code != ExitOK || !strings.Contains(out, "harness 1.2.3") || !strings.Contains(out, ">=4.8.0 <5.0.0") {
		t.Errorf("version text: %d\n%s", code, out)
	}
}

func first3(out, _ string, _ int) string { return out }

// 呼び出し元（薄いスキル）が渡したプラグイン版が範囲外なら、run・resume は何もせず専用の終了コードで止まり、
// どちらを更新すべきかを示す（§7.3）。
func TestPluginVersionMismatchStops(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state, "HARNESS_DATA_DIR="+t.TempDir())
	args := []string{"run", "--workflow-dir", abs(t, testWorkflows), "--scripts-dir", abs(t, testScripts), "--input", `json={"outcome":"ok"}`, "--input", "code=0", "emit"}
	for pv, want := range map[string]string{"4.7.0": "update the plugin", "5.1.0": "update the harness CLI"} {
		out, errOut, code := h.with(PluginVersionEnv + "=" + pv).run(args...)
		if code != ExitVersion || !strings.Contains(errOut, want) || out != "" {
			t.Errorf("plugin %s: exit %d\n%s\n%s", pv, code, out, errOut)
		}
		// resume も同じ（run の状態を読む前に止まる）。
		if _, errOut, code := h.with(PluginVersionEnv+"="+pv).run("resume", "no-such-run"); code != ExitVersion || !strings.Contains(errOut, want) {
			t.Errorf("resume with plugin %s: exit %d %s", pv, code, errOut)
		}
	}
	if _, errOut, code := h.with(PluginVersionEnv + "=latest").run(args...); code != ExitUsage || !strings.Contains(errOut, PluginVersionEnv) {
		t.Errorf("unparsable plugin version: exit %d %s", code, errOut)
	}
	if ids, _ := runstate.List(filepath.Join(state, "runs")); len(ids) != 0 {
		t.Fatalf("a run was started despite the mismatch: %v", ids)
	}
	// 範囲内なら動く。
	if _, errOut, code := h.with(PluginVersionEnv + "=4.8.1").run(args...); code != ExitOK {
		t.Fatalf("plugin 4.8.1: exit %d %s", code, errOut)
	}
	// contract start は run を始めず、理由を summary に入れた failed を出す（終了コードは 0）。
	d, _ := h.with(PluginVersionEnv + "=4.7.0").contract(append([]string{"start"}, args[1:]...)...)
	if d.RunID != nil || d.State != runstate.StatusFailed || !strings.Contains(d.Summary, "update the plugin") {
		t.Errorf("contract start = %+v", d)
	}
}

// N3（§7.3）: ゲートで待っている run は、CLI を更新した後も、開始時の版の展開ディレクトリの定義で続けられる。
// そのディレクトリが無ければ止まり、開始時の版での resume か cancel を案内する（状態は変えない）。開始時と同じ版なら
// 展開し直して続ける。
func TestResumeAcrossCLIVersions(t *testing.T) {
	f := newTicketFixture(t)
	v1 := f.h.with("HARNESS_TEST_CLI_VERSION=1.0.0")
	v2 := f.h.with("HARNESS_TEST_CLI_VERSION=2.0.0")
	out, errOut, code := v1.run("run", "--input", "issue=42", "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	st := decode[statusView](t, out)
	old := filepath.Join(f.dataDir, "runtime", "1.0.0")
	if st.CLIVersion != "1.0.0" || !st.Embedded || st.Workflow.Path != filepath.Join(old, "workflows", "ticket.yaml") ||
		st.ScriptsDir != filepath.Join(old, "scripts") || st.Waiting[0].Gate != "ci-pending" {
		t.Fatalf("run = %+v", st.State)
	}

	// 2.0.0 の CLI が 1.0.0 の定義で続ける（2.0.0 の展開は要らない）。
	f.write("checks", check("test", "pass"))
	out, errOut, code = v2.run("resume", st.RunID, "--input", "recheck")
	if code != ExitWaiting || decode[statusView](t, out).Waiting[0].Gate != "review" {
		t.Fatalf("resume by 2.0.0: exit %d\n%s\n%s", code, out, errOut)
	}
	if _, err := os.Stat(filepath.Join(f.dataDir, "runtime", "2.0.0")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("resume extracted the new version although the run uses 1.0.0: %v", err)
	}

	// 1.0.0 の展開ディレクトリが無い: 2.0.0 は止まって案内する。状態は変えず、待っているゲートを JSON で返す。
	if err := os.Rename(old, old+".moved"); err != nil {
		t.Fatal(err)
	}
	before, _, _ := v2.run("status", "--json", st.RunID)
	out, errOut, code = v2.run("resume", st.RunID, "--input", "ready")
	if code != ExitVersion {
		t.Fatalf("resume by 2.0.0 without the 1.0.0 definitions: exit %d\n%s\n%s", code, out, errOut)
	}
	for _, s := range []string{"harness 1.0.0", "harness cancel " + st.RunID, old} {
		if !strings.Contains(errOut, s) {
			t.Errorf("guidance lacks %q:\n%s", s, errOut)
		}
	}
	if w := decode[statusView](t, out).Waiting; len(w) != 1 || w[0].Gate != "review" {
		t.Errorf("the current gate was not returned: %s", out)
	}
	after, _, _ := v2.run("status", "--json", st.RunID)
	if decode[runstate.State](t, before).LastSeq != decode[runstate.State](t, after).LastSeq {
		t.Errorf("the refused resume changed the run")
	}
	// 接続契約の面では、run の状態（waiting）のまま、案内を summary に添える。
	d, _ := v2.contract("resume", "--input", "ready", st.RunID)
	if d.State != runstate.StatusWaiting || !strings.Contains(d.Summary, "harness 1.0.0") {
		t.Errorf("contract resume = %+v", d)
	}

	// 開始時と同じ 1.0.0 の CLI は、消えた展開ディレクトリを作り直して続ける。
	out, errOut, code = v1.run("resume", st.RunID, "--input", "ready")
	if code != ExitWaiting || decode[statusView](t, out).Waiting[0].Gate != "human-merge" {
		t.Fatalf("resume by 1.0.0: exit %d\n%s\n%s", code, out, errOut)
	}
	if _, err := os.Stat(filepath.Join(old, "workflows", "ticket.yaml")); err != nil {
		t.Errorf("1.0.0 did not re-extract its definitions: %v", err)
	}
	// cancel は定義を読まないので、どの版からでも止められる。
	if _, errOut, code := v2.run("cancel", st.RunID); code != ExitOK {
		t.Fatalf("cancel by 2.0.0: exit %d %s", code, errOut)
	}
}

// N3 の「対応していなければ止める」: 開始時のスキーマ版を読めない・開始時の版の定義をこの CLI が読み込めない。
func TestReopenRefusesDefinitionsThisCLICannotRead(t *testing.T) {
	data := t.TempDir()
	env := Env{Getenv: func(k string) string { return map[string]string{"HARNESS_DATA_DIR": data}[k] }}
	run := &runstate.Run{ID: "r1", Dir: t.TempDir()}

	st := &runstate.State{RunID: "r1", CLIVersion: "9.0.0", Embedded: true, Workflow: runstate.WorkflowRef{Schema: "harness.workflow/v9"}}
	var ve *versionError
	if _, err := reopen(env, run, st); !errors.As(err, &ve) || !strings.Contains(err.Error(), "harness.workflow/v9") || !strings.Contains(err.Error(), "harness 9.0.0") {
		t.Fatalf("unsupported schema: %v", err)
	}

	// 0.9.0 の展開ディレクトリに、この CLI が知らないステップ種類を使う定義がある。
	root := filepath.Join(data, "runtime", "0.9.0")
	if err := os.MkdirAll(filepath.Join(root, "workflows"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(root, "workflows", "future.yaml")
	if err := os.WriteFile(p, []byte("schema: harness.workflow/v1\nid: future\nsteps:\n  a:\n    kind: teleport\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	st = &runstate.State{RunID: "r1", CLIVersion: "0.9.0", Embedded: true, WorkflowDir: filepath.Join(root, "workflows"), ScriptsDir: filepath.Join(root, "scripts"),
		Workflow: runstate.WorkflowRef{Schema: "harness.workflow/v1", Path: p}}
	if _, err := reopen(env, run, st); !errors.As(err, &ve) || !strings.Contains(err.Error(), "cannot load the definitions of harness 0.9.0") {
		t.Fatalf("unknown step kind: %v", err)
	}
	// --workflow-dir で始めた run（埋め込みではない）は従来どおりの誤り（版の案内ではない）。
	st.Embedded = false
	if _, err := reopen(env, run, st); err == nil || errors.As(err, &ve) {
		t.Fatalf("not embedded: %v", err)
	}
}

// setup: claude plugin marketplace add / install を呼んでプラグインを整え、版を照合する（本物の claude は呼ばない）。
func TestSetup(t *testing.T) {
	fake := abs(t, "testdata/fake-claude-plugin.sh")
	plugins := func(v string) string {
		b, _ := json.Marshal([]map[string]any{
			{"id": "other@elsewhere", "version": "1.0.0", "scope": "user", "enabled": true},
			{"id": PluginID, "version": v, "scope": "user", "enabled": true},
		})
		return string(b)
	}
	cases := []struct {
		name         string
		args         []string
		files        map[string]string
		code         int
		calls        []string
		stdout, errs string
	}{
		{"fresh install", nil,
			map[string]string{"marketplaces.json": `[]`, "plugins.1.json": `[]`, "plugins.json": plugins("4.8.1")},
			ExitOK, []string{"plugin marketplace list --json", "plugin marketplace add masanami/claude-harness", "plugin list --json", "plugin install " + PluginID, "plugin list --json"},
			"supported by harness", ""},
		{"scope and source", []string{"--scope", "project", "--marketplace", "/src/claude-harness"},
			map[string]string{"marketplaces.json": `[]`, "plugins.1.json": `[]`, "plugins.json": plugins("4.8.1")},
			ExitOK, []string{"plugin marketplace list --json", "plugin marketplace add /src/claude-harness --scope project", "plugin list --json", "plugin install " + PluginID + " --scope project", "plugin list --json"},
			"installed", ""},
		{"already set up", nil,
			map[string]string{"marketplaces.json": `[{"name":"masanami-harness","source":"github","repo":"masanami/claude-harness"}]`, "plugins.json": plugins("4.9.0")},
			ExitOK, []string{"plugin marketplace list --json", "plugin list --json"},
			"already installed", ""},
		{"installed plugin is too old", nil,
			map[string]string{"marketplaces.json": `[{"name":"masanami-harness"}]`, "plugins.json": plugins("4.7.0")},
			ExitVersion, []string{"plugin marketplace list --json", "plugin list --json"},
			"not supported", "update the plugin"},
		{"installed plugin is too new", nil,
			map[string]string{"marketplaces.json": `[{"name":"masanami-harness"}]`, "plugins.json": plugins("5.0.0")},
			ExitVersion, []string{"plugin marketplace list --json", "plugin list --json"},
			"not supported", "update the harness CLI"},
		{"install fails", nil,
			map[string]string{"marketplaces.json": `[{"name":"masanami-harness"}]`, "plugins.json": `[]`, "fail-install": ""},
			ExitFailed, []string{"plugin marketplace list --json", "plugin list --json", "plugin install " + PluginID},
			"", "plugin install " + PluginID + " failed"},
		{"install does not show up", nil,
			map[string]string{"marketplaces.json": `[{"name":"masanami-harness"}]`, "plugins.json": `[]`},
			ExitFailed, []string{"plugin marketplace list --json", "plugin list --json", "plugin install " + PluginID, "plugin list --json"},
			"", "is not listed"},
		{"unreadable list", nil,
			map[string]string{"marketplaces.json": `not json`},
			ExitFailed, []string{"plugin marketplace list --json"},
			"", "cannot read claude plugin marketplace list"},
		{"bad scope", []string{"--scope", "global"}, map[string]string{}, ExitUsage, nil, "", "--scope must be"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			for n, content := range c.files {
				if err := os.WriteFile(filepath.Join(dir, n), []byte(content), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			h := newHarness(t, "HARNESS_CLAUDE_BIN="+fake, "FAKE_CLAUDE_DIR="+dir)
			out, errOut, code := h.run(append([]string{"setup"}, c.args...)...)
			if code != c.code || !strings.Contains(out, c.stdout) || !strings.Contains(errOut, c.errs) {
				t.Fatalf("exit %d (want %d)\nstdout:\n%s\nstderr:\n%s", code, c.code, out, errOut)
			}
			calls := ""
			if b, err := os.ReadFile(filepath.Join(dir, "calls")); err == nil {
				calls = strings.TrimSpace(string(b))
			}
			if want := strings.Join(c.calls, "\n"); calls != want {
				t.Errorf("claude calls:\n%s\nwant:\n%s", calls, want)
			}
		})
	}
}

// フラグを片方だけ渡した場合: 渡したほうはそれを使い、無いほうは埋め込みを展開して使う。定義が作業ツリーのものと
// 混ざるので、run は埋め込みから始めたとは記録しない（N3 で開始時の版の定義として扱わない）。
func TestDirsWithOneFlag(t *testing.T) {
	data := t.TempDir()
	env := Env{Getenv: func(k string) string { return map[string]string{"HARNESS_DATA_DIR": data}[k] }, Getwd: func() (string, error) { return t.TempDir(), nil }}
	l, err := embeddedLayout(env)
	if err != nil {
		t.Fatal(err)
	}
	wd := abs(t, repoWorkflows)
	src, err := dirs(map[string][]string{"workflow-dir": {wd}}, env)
	if err != nil || src.embedded || src.wd != wd || src.sd != l.ScriptsDir {
		t.Fatalf("--workflow-dir only: %+v %v", src, err)
	}
	src, err = dirs(map[string][]string{"scripts-dir": {wd}}, env)
	if err != nil || src.embedded || src.wd != l.WorkflowDir || src.sd != wd {
		t.Fatalf("--scripts-dir only: %+v %v", src, err)
	}
	src, err = dirs(map[string][]string{}, env)
	if err != nil || !src.embedded || src.wd != l.WorkflowDir || src.sd != l.ScriptsDir {
		t.Fatalf("no flags: %+v %v", src, err)
	}
}

// フラグ無しでも、定義をパスで渡した run（展開ディレクトリの外の定義）は埋め込みから始めたとは記録しない。
func TestRunWithAWorkflowPathIsNotEmbedded(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir(), "HARNESS_DATA_DIR="+t.TempDir())
	root := t.TempDir()
	for _, name := range []string{"root", "run"} {
		p := filepath.Join(abs(t, repoWorkflows), "list-tests.yaml")
		args := []string{"run", "--input", "root=" + root, p}
		if name == "run" {
			args = []string{"run", "--input", "root=" + root, "list-tests"}
		}
		out, errOut, _ := h.run(args...)
		v := decode[statusView](t, out)
		if want := name == "run"; v.Embedded != want {
			t.Errorf("%v: embedded %v, want %v\n%s", args, v.Embedded, want, errOut)
		}
	}
}

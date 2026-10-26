package cli

// ワークフロー定義の上書き（docs/harness-runtime-overrides.md §3）の置き場を決める: リポジトリの
// .claude-harness/overrides/<id>.yaml（層 1）と --override <ファイル>（層 2）。重ね方と検査は workflow.LoadWithOverrides。

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/masanami/claude-harness/runtime/internal/graph"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// RepoOverrideDir はリポジトリの上書きの置き場（git の最上位からの相対パス）。
const RepoOverrideDir = ".claude-harness/overrides"

// gitTop は作業ディレクトリから上へ .git（ディレクトリ、または worktree のファイル）を持つディレクトリを探す。
// git を起動せずに探す（git の無い環境でも run・validate の挙動を変えない）。
func gitTop(env Env) (string, bool) {
	cwd, err := env.Getwd()
	if err != nil {
		return "", false
	}
	for d := cwd; ; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return d, true
		}
		if filepath.Dir(d) == d {
			return "", false
		}
	}
}

// repoOverride は層 1 を読む。git の作業ツリーの外、またはファイルが無ければ nil（飛ばす）。
func repoOverride(env Env, id string) (*workflow.OverrideSource, error) {
	top, ok := gitTop(env)
	if !ok {
		return nil, nil
	}
	p := filepath.Join(top, RepoOverrideDir, id+".yaml")
	data, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &workflow.OverrideSource{Layer: workflow.LayerRepo, Path: p, Data: data}, nil
}

// argOverride は層 2（--override <ファイル>）を読む。指定されたファイルが無ければ止める。
func argOverride(flags map[string][]string) (*workflow.OverrideSource, error) {
	arg := first(flags, "override")
	if arg == "" {
		if _, given := flags["override"]; given {
			return nil, errors.New("--override needs a file")
		}
		return nil, nil
	}
	p, err := filepath.Abs(arg)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, fmt.Errorf("--override: %v", err)
	}
	return &workflow.OverrideSource{Layer: workflow.LayerArg, Path: p, Data: data}, nil
}

// workflowID は定義のパスから id を得る（validate が id とファイル名の一致を検査するので、ファイル名が id）。
func workflowID(path string) string {
	return strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
}

// overrideSources は定義 id に重ねる上書きを層の順（リポジトリ → 引数）に並べる。
func overrideSources(env Env, id string, arg *workflow.OverrideSource) ([]workflow.OverrideSource, error) {
	var srcs []workflow.OverrideSource
	repo, err := repoOverride(env, id)
	if err != nil {
		return nil, err
	}
	if repo != nil {
		srcs = append(srcs, *repo)
	}
	if arg != nil {
		srcs = append(srcs, *arg)
	}
	return srcs, nil
}

// printOverrides は validate の ok の後に、読んだ上書きと効いた値（changes）と、付け替えで到達できなくなったステップ
// （skipped_steps。docs/harness-runtime-overrides.md §6.2 の規則 5）を出す。
func printOverrides(w io.Writer, wf *workflow.Workflow) {
	if len(wf.Overrides) == 0 {
		return
	}
	for _, ov := range wf.Overrides {
		fmt.Fprintf(w, "  override %s %s\n", ov.Layer, ov.Path)
	}
	if len(wf.Changes) == 0 {
		fmt.Fprintln(w, "  changes: none")
		return
	}
	fmt.Fprintln(w, "  changes:")
	for _, c := range wf.Changes {
		fmt.Fprintf(w, "    %s: %s -> %s (%s)\n", c.Key, graph.ChangeValue(c.From), graph.ChangeValue(c.To), c.Layer)
	}
	if len(wf.SkippedSteps) > 0 {
		fmt.Fprintf(w, "  skipped_steps: %s\n", strings.Join(wf.SkippedSteps, ", "))
	}
}

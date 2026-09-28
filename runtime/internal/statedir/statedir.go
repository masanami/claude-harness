// Package statedir は永続状態の置き場（docs/harness-runtime-design.md §4.6 の L2）と、埋め込んだ定義の展開先（§6.5）を決める。
//
//  1. HARNESS_STATE_DIR が設定されていればそこ
//  2. XDG_STATE_HOME が絶対パスで設定されていれば $XDG_STATE_HOME/claude-harness
//     （XDG Base Directory の規定どおり、相対パスは無効として無視する）
//  3. それ以外は $HOME/.local/state/claude-harness
package statedir

import (
	"errors"
	"path/filepath"
)

// AppName は XDG の状態ディレクトリ配下のディレクトリ名。
const AppName = "claude-harness"

// Resolve は getenv（通常は os.Getenv）から状態ディレクトリの絶対パスを決める。
func Resolve(getenv func(string) string) (string, error) {
	if d := getenv("HARNESS_STATE_DIR"); d != "" {
		return filepath.Abs(d)
	}
	if d := getenv("XDG_STATE_HOME"); d != "" && filepath.IsAbs(d) {
		return filepath.Join(d, AppName), nil
	}
	home := getenv("HOME")
	if home == "" {
		return "", errors.New("cannot determine the state directory: HARNESS_STATE_DIR, XDG_STATE_HOME and HOME are all unset")
	}
	return filepath.Join(home, ".local", "state", AppName), nil
}

// RunsDir は run ごとのディレクトリを置く場所。
func RunsDir(stateDir string) string {
	return filepath.Join(stateDir, "runs")
}

// ResolveData は埋め込んだ定義・スクリプトの展開先の親（docs/harness-runtime-design.md §6.5 の S1）を決める。
// 状態（Resolve）と同じ規則で、XDG の data 側を使う。
//
//  1. HARNESS_DATA_DIR が設定されていればそこ
//  2. XDG_DATA_HOME が絶対パスで設定されていれば $XDG_DATA_HOME/claude-harness
//  3. それ以外は $HOME/.local/share/claude-harness
func ResolveData(getenv func(string) string) (string, error) {
	if d := getenv("HARNESS_DATA_DIR"); d != "" {
		return filepath.Abs(d)
	}
	if d := getenv("XDG_DATA_HOME"); d != "" && filepath.IsAbs(d) {
		return filepath.Join(d, AppName), nil
	}
	home := getenv("HOME")
	if home == "" {
		return "", errors.New("cannot determine the data directory: HARNESS_DATA_DIR, XDG_DATA_HOME and HOME are all unset")
	}
	return filepath.Join(home, ".local", "share", AppName), nil
}

// RuntimeDir は CLI の版 v の定義・スクリプトを展開するディレクトリ（<data>/runtime/<版>）。
func RuntimeDir(dataDir, v string) string {
	return filepath.Join(dataDir, "runtime", v)
}

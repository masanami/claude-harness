// Package bundle はバイナリに埋め込んだワークフロー定義とスクリプト（docs/harness-runtime-design.md §6.5 の S1）を持ち、
// 版ごとのディレクトリへ展開する。
//
// 埋め込む写しは、ビルドの前にリポジトリのルートで make bundle が files/ へ作る（go:embed はモジュールの外の
// plugin/scripts を指せないため）。写しの無いビルド（make bundle を経ない go build・go install）では Available が false になる。
//
// 展開先は <data>/runtime/<版>/ で、版ごとに不変にする（長く走る run の途中で定義・スクリプトだけ新しくなる事故を
// 起こさない）。展開は一時ディレクトリへ書いてから rename で置き、最後に中身の sha256 を印として書く。
package bundle

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

//go:embed files
var embedded embed.FS

// Dirs は展開するディレクトリ（files/ の直下）。
var Dirs = []string{"workflows", "scripts", "agents"}

// MarkerFile は展開したディレクトリに置く印（中身の sha256）。
const MarkerFile = ".bundle-sha256"

// ErrNotEmbedded は定義を埋め込んでいないバイナリであること。
var ErrNotEmbedded = errors.New("this harness binary has no embedded workflows and scripts (it was built without make bundle, e.g. by go install); " +
	"pass --workflow-dir and --scripts-dir, or install a release binary")

// FS は埋め込んだ files/ の中身。テストが差し替える。
var FS fs.FS = mustSub(embedded, "files")

func mustSub(f fs.FS, dir string) fs.FS {
	s, err := fs.Sub(f, dir)
	if err != nil {
		panic(err)
	}
	return s
}

// Available は定義とスクリプトが埋め込まれているか（Dirs がすべて在るか）。
func Available(fsys fs.FS) bool {
	for _, d := range Dirs {
		fi, err := fs.Stat(fsys, d)
		if err != nil || !fi.IsDir() {
			return false
		}
	}
	return true
}

// files は Dirs 配下の通常ファイルのパス（fsys 内のスラッシュ区切り）を順に返す。
func files(fsys fs.FS) ([]string, error) {
	var out []string
	for _, d := range Dirs {
		err := fs.WalkDir(fsys, d, func(p string, e fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if e.Type().IsRegular() {
				out = append(out, p)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Strings(out)
	return out, nil
}

// Digest は Dirs 配下の中身の sha256（パスと内容から作る。展開したディレクトリの同一性の確認に使う）。
func Digest(fsys fs.FS) (string, error) {
	names, err := files(fsys)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	for _, n := range names {
		data, err := fs.ReadFile(fsys, n)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(h, "%s\x00%d\x00", n, len(data))
		h.Write(data)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Layout は展開したディレクトリの中の場所。
type Layout struct {
	Root        string
	WorkflowDir string
	ScriptsDir  string
}

// LayoutOf は展開先 root の中の場所（agents/ は scripts/ の隣。validate の既定の探し方と同じ）。
func LayoutOf(root string) Layout {
	return Layout{Root: root, WorkflowDir: filepath.Join(root, "workflows"), ScriptsDir: filepath.Join(root, "scripts")}
}

// Ensure は fsys を root へ展開する（在れば印を確かめて使う）。root が在って印が中身と違えば上書きせずに止まる
// （その版の定義で動いている run がありうる。手で直されたものを黙って差し替えない）。
func Ensure(fsys fs.FS, root string) (Layout, error) {
	if !Available(fsys) {
		return Layout{}, ErrNotEmbedded
	}
	digest, err := Digest(fsys)
	if err != nil {
		return Layout{}, err
	}
	if err := verify(root, digest); err == nil {
		return LayoutOf(root), nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return Layout{}, err
	}
	if err := os.MkdirAll(filepath.Dir(root), 0o755); err != nil {
		return Layout{}, err
	}
	tmp, err := os.MkdirTemp(filepath.Dir(root), ".extract-"+filepath.Base(root)+"-")
	if err != nil {
		return Layout{}, err
	}
	defer os.RemoveAll(tmp) // rename できたら空振りする
	if err := extract(fsys, tmp, digest); err != nil {
		return Layout{}, fmt.Errorf("cannot extract the embedded workflows and scripts: %v", err)
	}
	if err := os.Chmod(tmp, 0o755); err != nil { // MkdirTemp は 0700 で作る
		return Layout{}, err
	}
	if err := os.Rename(tmp, root); err != nil {
		// 同時に別のプロセスが展開し終えた場合は、その中身を確かめて使う。
		if verr := verify(root, digest); verr == nil {
			return LayoutOf(root), nil
		}
		return Layout{}, fmt.Errorf("cannot place the extracted directory at %s: %v", root, err)
	}
	return LayoutOf(root), nil
}

// verify は root の印が digest と一致するかを確かめる。root が無ければ fs.ErrNotExist を包んで返す。
func verify(root, digest string) error {
	if _, err := os.Stat(root); err != nil {
		return err
	}
	b, err := os.ReadFile(filepath.Join(root, MarkerFile))
	if err != nil {
		return fmt.Errorf("%s exists but has no %s (not extracted by harness, or extraction was interrupted); remove it and retry", root, MarkerFile)
	}
	if got := strings.TrimSpace(string(b)); got != digest {
		return fmt.Errorf("%s holds different contents (sha256 %s) from this binary's embedded ones (%s); it is not overwritten. Remove it if no run uses it", root, got, digest)
	}
	return nil
}

// extract は Dirs 配下を dir へ書き出す。*.sh は実行可能にし、ファイルは読み取り専用にする（版のディレクトリは不変）。
func extract(fsys fs.FS, dir, digest string) error {
	names, err := files(fsys)
	if err != nil {
		return err
	}
	for _, n := range names {
		dst := filepath.Join(dir, filepath.FromSlash(n))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		mode := os.FileMode(0o444)
		if path.Ext(n) == ".sh" {
			mode = 0o555
		}
		if err := copyFile(fsys, n, dst, mode); err != nil {
			return err
		}
	}
	return os.WriteFile(filepath.Join(dir, MarkerFile), []byte(digest+"\n"), 0o444)
}

func copyFile(fsys fs.FS, name, dst string, mode os.FileMode) error {
	src, err := fsys.Open(name)
	if err != nil {
		return err
	}
	defer src.Close()
	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, src); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

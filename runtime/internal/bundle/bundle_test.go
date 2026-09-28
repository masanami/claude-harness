package bundle

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

func sample() fstest.MapFS {
	return fstest.MapFS{
		"README.md":                     {Data: []byte("placeholder")},
		"workflows/ticket.yaml":         {Data: []byte("schema: harness.workflow/v1\n")},
		"workflows/prompts/a.md":        {Data: []byte("prompt")},
		"scripts/worktree-setup.sh":     {Data: []byte("#!/bin/bash\n")},
		"scripts/lib/common.sh":         {Data: []byte("# lib\n")},
		"scripts/config/list.txt":       {Data: []byte("x\n")},
		"agents/feature-implementer.md": {Data: []byte("---\n")},
	}
}

func TestEnsureExtractsOnceAndReuses(t *testing.T) {
	root := filepath.Join(t.TempDir(), "runtime", "1.0.0")
	l, err := Ensure(sample(), root)
	if err != nil {
		t.Fatal(err)
	}
	if l.WorkflowDir != filepath.Join(root, "workflows") || l.ScriptsDir != filepath.Join(root, "scripts") {
		t.Fatalf("layout = %+v", l)
	}
	for p, want := range map[string]os.FileMode{
		"workflows/ticket.yaml":         0o444,
		"workflows/prompts/a.md":        0o444,
		"scripts/worktree-setup.sh":     0o555,
		"scripts/lib/common.sh":         0o555,
		"scripts/config/list.txt":       0o444,
		"agents/feature-implementer.md": 0o444,
	} {
		fi, err := os.Stat(filepath.Join(root, p))
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != want {
			t.Errorf("%s mode %v, want %v", p, fi.Mode().Perm(), want)
		}
	}
	// files/ の直下の README（Dirs の外）は展開しない。
	if _, err := os.Stat(filepath.Join(root, "README.md")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("README.md outside Dirs was extracted: %v", err)
	}
	if fi, err := os.Stat(root); err != nil || fi.Mode().Perm() != 0o755 {
		t.Errorf("root mode: %v %v", fi.Mode(), err)
	}
	digest, _ := Digest(sample())
	if b, _ := os.ReadFile(filepath.Join(root, MarkerFile)); strings.TrimSpace(string(b)) != digest {
		t.Errorf("marker %q, want %q", b, digest)
	}
	// 2 回目は展開済みのものを使う（書き直さない）。一時ディレクトリも残さない。
	before, _ := os.Stat(filepath.Join(root, "workflows", "ticket.yaml"))
	if _, err := Ensure(sample(), root); err != nil {
		t.Fatal(err)
	}
	after, _ := os.Stat(filepath.Join(root, "workflows", "ticket.yaml"))
	if !before.ModTime().Equal(after.ModTime()) {
		t.Errorf("the extracted file was rewritten")
	}
	entries, _ := os.ReadDir(filepath.Dir(root))
	if len(entries) != 1 {
		t.Errorf("leftovers next to the extracted directory: %v", entries)
	}
}

// 同じ場所に別の中身があれば上書きせずに止まる（その版の定義で動いている run がありうる）。
func TestEnsureRefusesDifferentContents(t *testing.T) {
	root := filepath.Join(t.TempDir(), "1.0.0")
	if _, err := Ensure(sample(), root); err != nil {
		t.Fatal(err)
	}
	other := sample()
	other["workflows/ticket.yaml"] = &fstest.MapFile{Data: []byte("schema: harness.workflow/v1\nid: changed\n")}
	_, err := Ensure(other, root)
	if err == nil || !strings.Contains(err.Error(), "not overwritten") {
		t.Fatalf("err = %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(root, "workflows", "ticket.yaml")); strings.Contains(string(b), "changed") {
		t.Fatal("the extracted definition was overwritten")
	}
	// 印の無いディレクトリ（harness が展開したものではない）も使わない。
	bare := filepath.Join(t.TempDir(), "1.0.0")
	if err := os.MkdirAll(filepath.Join(bare, "workflows"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Ensure(sample(), bare); err == nil || !strings.Contains(err.Error(), MarkerFile) {
		t.Fatalf("err = %v", err)
	}
}

func TestEnsureWithoutEmbeddedFiles(t *testing.T) {
	fsys := fstest.MapFS{"README.md": {Data: []byte("placeholder")}}
	if Available(fsys) {
		t.Fatal("a bundle without workflows/scripts/agents must not be available")
	}
	if _, err := Ensure(fsys, filepath.Join(t.TempDir(), "x")); !errors.Is(err, ErrNotEmbedded) {
		t.Fatalf("err = %v", err)
	}
}

func TestDigestChangesWithPathAndContent(t *testing.T) {
	a, _ := Digest(sample())
	moved := sample()
	moved["scripts/renamed.sh"] = moved["scripts/worktree-setup.sh"]
	delete(moved, "scripts/worktree-setup.sh")
	b, _ := Digest(moved)
	edited := sample()
	edited["scripts/worktree-setup.sh"] = &fstest.MapFile{Data: []byte("#!/bin/bash\necho\n")}
	c, _ := Digest(edited)
	readme := sample()
	readme["README.md"] = &fstest.MapFile{Data: []byte("other")}
	d, _ := Digest(readme)
	if a == b || a == c || a != d {
		t.Fatalf("digests: %s %s %s %s", a, b, c, d)
	}
}

// バイナリに埋め込んだ写し（make bundle が作る）が、作業ツリーの runtime/workflows・plugin/scripts（tests/ を除く）・
// plugin/agents と一致する（写しを作り直さずに定義を変えたまま検査・ビルドしない）。写しが無ければ失敗する。
func TestEmbeddedCopyMatchesTheWorkingTree(t *testing.T) {
	if !Available(FS) {
		t.Fatal("no embedded copy: run make bundle at the repository root (make check does it)")
	}
	src := map[string]string{"workflows": "../../workflows", "scripts": "../../../plugin/scripts", "agents": "../../../plugin/agents"}
	want := map[string]string{}
	for dir, p := range src {
		err := filepath.WalkDir(p, func(path string, e fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			rel, _ := filepath.Rel(p, path)
			if e.IsDir() && dir == "scripts" && rel == "tests" {
				return filepath.SkipDir
			}
			if e.Type().IsRegular() && (strings.HasPrefix(e.Name(), ".") || strings.HasPrefix(e.Name(), "_")) && e.Name() != ".DS_Store" {
				// go:embed は . と _ で始まる名前を埋め込まない。展開先で黙って欠けないように、そういう名前を置かせない。
				t.Errorf("%s would not be embedded (go:embed drops names starting with . or _); rename it", path)
				return nil
			}
			if e.Type().IsRegular() && e.Name() != ".DS_Store" {
				b, err := os.ReadFile(path)
				if err != nil {
					return err
				}
				want[dir+"/"+filepath.ToSlash(rel)] = string(b)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	names, err := files(FS)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, n := range names {
		got[n] = true
		b, _ := fs.ReadFile(FS, n)
		w, ok := want[n]
		switch {
		case !ok:
			t.Errorf("embedded %s is not in the working tree (stale copy: run make bundle)", n)
		case w != string(b):
			t.Errorf("embedded %s differs from the working tree (stale copy: run make bundle)", n)
		}
	}
	for n := range want {
		if !got[n] {
			t.Errorf("%s is not embedded (stale copy: run make bundle)", n)
		}
	}
}

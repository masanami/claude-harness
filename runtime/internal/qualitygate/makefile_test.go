package qualitygate

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// go が PATH に無い環境では、Go のゲートを skip せず失敗にする（docs/harness-runtime-design.md §6.3）。
// PATH を空のディレクトリだけにして make を起動する（make と bash は絶対パスで呼ばれる）。
func TestGoGatesFailWithoutGo(t *testing.T) {
	makeBin, err := exec.LookPath("make")
	if err != nil {
		t.Fatalf("make is required to check the Makefile: %v", err)
	}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "Makefile")); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"check-go", "check-validate"} {
		t.Run(target, func(t *testing.T) {
			cmd := exec.Command(makeBin, "--no-print-directory", "-C", root, target)
			cmd.Env = []string{"PATH=" + t.TempDir(), "HOME=" + t.TempDir()}
			out, err := cmd.CombinedOutput()
			if err == nil {
				t.Fatalf("make %s succeeded without go on PATH:\n%s", target, out)
			}
			if !strings.Contains(string(out), "NG: go not found in PATH") {
				t.Fatalf("make %s failed for another reason:\n%s", target, out)
			}
		})
	}
}

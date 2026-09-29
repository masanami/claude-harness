package qualitygate

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// 対象の OS・アーキテクチャ（docs/harness-runtime-design.md §6.4）。
var platforms = []string{"darwin/arm64", "darwin/amd64", "linux/amd64", "linux/arm64"}

func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// リリースのワークフローはタグ runtime/v* の push でのみ起動する（PR・ブランチの push・手動実行・スケジュールでは起動しない）。
func TestReleaseWorkflowRunsOnlyOnRuntimeTags(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(repoRoot(t), ".github", "workflows", "release-runtime.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var wf struct {
		On map[string]map[string]any `yaml:"on"`
	}
	if err := yaml.Unmarshal(data, &wf); err != nil {
		t.Fatal(err)
	}
	want := map[string]map[string]any{"push": {"tags": []any{"runtime/v*"}}}
	if !reflect.DeepEqual(wf.On, want) {
		t.Fatalf("on = %#v, want %#v", wf.On, want)
	}
	// ほかのワークフロー（人が PR CI を足した場合など）はリリースを作らない。
	entries, err := os.ReadDir(filepath.Join(repoRoot(t), ".github", "workflows"))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.Name() == "release-runtime.yml" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(repoRoot(t), ".github", "workflows", e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "gh release") || strings.Contains(string(b), "runtime/v") {
			t.Errorf("%s also publishes or reacts to runtime tags; the release is release-runtime.yml only", e.Name())
		}
	}
}

// Makefile の PLATFORMS が §6.4 の対象と一致し、成果物の一覧が runtime/README.md にある。
func TestReleaseArtifactsAreDocumented(t *testing.T) {
	mk, err := os.ReadFile(filepath.Join(repoRoot(t), "Makefile"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^PLATFORMS \?= (.+)$`).FindSubmatch(mk)
	if m == nil || !reflect.DeepEqual(strings.Fields(string(m[1])), platforms) {
		t.Fatalf("PLATFORMS in the Makefile = %q, want %v", m, platforms)
	}
	readme, err := os.ReadFile(filepath.Join(repoRoot(t), "runtime", "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range platforms {
		name := "harness_<X.Y.Z>_" + strings.ReplaceAll(p, "/", "_") + ".tar.gz"
		if !strings.Contains(string(readme), name) {
			t.Errorf("runtime/README.md does not list %s", name)
		}
	}
	if !strings.Contains(string(readme), "checksums.txt") {
		t.Errorf("runtime/README.md does not list checksums.txt")
	}
}

// make dist が、版を埋めたバイナリ（定義を埋め込んだもの）のアーカイブとチェックサムを作る（ホストの 1 組だけで確かめる）。
func TestDistBuildsVersionedArchives(t *testing.T) {
	makeBin, err := exec.LookPath("make")
	if err != nil {
		t.Fatalf("make is required: %v", err)
	}
	root := repoRoot(t)
	dist := t.TempDir()
	host := runtime.GOOS + "/" + runtime.GOARCH
	run := func(args ...string) (string, error) {
		cmd := exec.Command(makeBin, append([]string{"--no-print-directory", "-C", root}, args...)...)
		cmd.Env = append(os.Environ(), "TMPDIR="+t.TempDir())
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	if out, err := run("dist", "DIST_DIR="+dist, "PLATFORMS="+host); err == nil || !strings.Contains(out, "needs VERSION") {
		t.Fatalf("make dist without VERSION: %v\n%s", err, out)
	}
	if out, err := run("dist", "VERSION=v1.0", "DIST_DIR="+dist, "PLATFORMS="+host); err == nil || !strings.Contains(out, "not a semver") {
		t.Fatalf("make dist with a bad VERSION: %v\n%s", err, out)
	}
	if out, err := run("dist", "VERSION=0.0.0-test.1", "DIST_DIR="+dist, "PLATFORMS="+host); err != nil {
		t.Fatalf("make dist: %v\n%s", err, out)
	}
	name := "harness_0.0.0-test.1_" + runtime.GOOS + "_" + runtime.GOARCH + ".tar.gz"
	archive := filepath.Join(dist, name)
	data, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	sums, err := os.ReadFile(filepath.Join(dist, "checksums.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Fields(string(sums)); len(got) != 2 || got[0] != hex.EncodeToString(sum[:]) || got[1] != name {
		t.Fatalf("checksums.txt = %q", sums)
	}
	x := t.TempDir()
	if out, err := exec.Command("tar", "-xzf", archive, "-C", x).CombinedOutput(); err != nil {
		t.Fatalf("tar: %v\n%s", err, out)
	}
	entries, _ := os.ReadDir(x)
	if len(entries) != 1 || entries[0].Name() != "harness" {
		t.Fatalf("archive holds %v, want only harness", entries)
	}
	cmd := exec.Command(filepath.Join(x, "harness"), "version", "--json")
	cmd.Env = []string{"HOME=" + t.TempDir(), "HARNESS_DATA_DIR=" + t.TempDir()}
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		CLIVersion string `json:"cli_version"`
		Embedded   bool   `json:"embedded"`
	}
	if err := json.Unmarshal(out, &v); err != nil || v.CLIVersion != "0.0.0-test.1" || !v.Embedded {
		t.Fatalf("version --json = %s (%v)", out, err)
	}
}

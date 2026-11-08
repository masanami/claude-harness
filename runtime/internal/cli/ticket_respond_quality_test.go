package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// レビュー対応（respond）の push の後は quality → publish → ci を通る（#339）。呼び出し側が run の記録の SHA と PR の head を
// 照合して品質ゲートを回し直さずに済むように、respond が push したコミットにも quality の記録を残す。

// skipQualityOverride は quality を省くリポジトリの上書き。quality へ入る遷移 3 本をそろえて付け替える（§5.2）。
const skipQualityOverride = "schema: harness.workflow-override/v1\nworkflow: ticket\nsteps:\n" +
	"  e2e-route: { on: { no: publish } }\n  e2e: { on: { pass: publish } }\n  respond: { on: { pushed: ci } }\n"

// runStep は n 回目の claude の呼び出しの間に作業ツリーで実行するスクリプトを置く（子のコミットと push の代わり）。
func runStep(t *testing.T, f *ticketFixture, n int, script string) {
	t.Helper()
	writeFile(t, filepath.Join(f.fdir, "responses", fmt.Sprintf("%d.run", n)), "set -e\n"+script+"\n")
}

// pushFile はファイルを足すコミットを作り、作業ブランチへ push するスクリプト。
func pushFile(f *ticketFixture, name string) string {
	return fmt.Sprintf("echo fixed > %s\ngit add %s\ngit commit -q -m 'fix: %s'\ngit push -q origin HEAD:refs/heads/%s", name, name, name, f.branch)
}

// respondPushes は n 回目の claude の呼び出し（respond）が name を足すコミットを push して pushed を返すようにする。
func respondPushes(t *testing.T, f *ticketFixture, n int, name string) {
	t.Helper()
	runStep(t, f, n, pushFile(f, name))
	respond(t, f.fdir, n, 0, claudeStructured(map[string]any{"outcome": "pushed", "summary": "addressed the review", "human_question": ""}, 9))
}

// runToReview は CI が 1 回で green になる run をレビュー待ちまで進め、run id を返す。
func runToReview(t *testing.T, f *ticketFixture) string {
	t.Helper()
	out, errOut, code := f.h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v, steps %s", v.Waiting, stepSeq(v))
	}
	return v.RunID
}

func greenCI(f *ticketFixture) {
	f.write("checks.1", check("test", "pass"))
	f.write("checks", check("test", "pass"))
}

func originHead(t *testing.T, f *ticketFixture) string {
	t.Helper()
	remote := strings.Fields(git(t, f.repo, "ls-remote", "--heads", f.origin, f.branch))
	if len(remote) == 0 {
		t.Fatalf("the branch %s is not on origin", f.branch)
	}
	return remote[0]
}

const firstRound = "resolve:ok analyze:ok workspace:created implement:pass commit:committed e2e-route:no quality:pass publish:opened ci:green"

// respond の push の後は quality を通り、PR が既にあるので publish は updated で ci へ進む。PR は作り直さず、本文も書かない。
// 記録の commit_sha は respond が push した SHA（= 実際の PR の head）になる。
func TestTicketRespondPushGoesThroughQuality(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	respondPushes(t, f, 4, "review-fix.txt")
	id := runToReview(t, f)
	before := originHead(t, f)
	body := readFile(t, filepath.Join(f.ghDir, "body.1.md"))

	out, errOut, code := f.h.run("resume", id, "--input", "respond")
	if code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if got, want := stepSeq(v), firstRound+" respond:pushed quality:pass publish:updated ci:green"; got != want {
		t.Fatalf("steps:\n got %s\nwant %s", got, want)
	}
	if v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	if got := strings.TrimSpace(readFile(t, filepath.Join(f.ghDir, "create.count"))); got != "1" {
		t.Errorf("gh pr create called %s times, want once", got)
	}
	if _, err := os.Stat(filepath.Join(f.ghDir, "body.2.md")); err == nil {
		t.Errorf("a second PR body was written")
	}
	if got := readFile(t, filepath.Join(f.ghDir, "body.1.md")); got != body {
		t.Errorf("the PR body changed:\n%s", got)
	}
	head := originHead(t, f)
	if head == before {
		t.Fatalf("respond did not push: the head stayed %s", head)
	}
	if q := qualityOf(t, v); q.Result != "pass" || q.CommitSHA != head {
		t.Fatalf("quality = %+v, want a pass on the pushed head %s", q, head)
	}
	if v.Unit("main").LimitsUsed["rework"] != 0 {
		t.Errorf("rework used = %d, a passing quality gate must not use it", v.Unit("main").LimitsUsed["rework"])
	}
}

// respond の後の quality が落ちると fix へ送り、落ちたゲートの出力を渡す。差し戻しは CI の差し戻しと同じ rework を使い、
// 直った後は既存の PR へ push して ci へ進む。記録の SHA は fix の後の head になる。
func TestTicketRespondQualityFailGoesToFixAndSharesRework(t *testing.T) {
	f := newTicketFixture(t)
	f.write("checks.1", check("test", "fail")) // 1 回目の CI の red で rework を 1 回使う
	f.write("checks", check("test", "pass"))
	commitFile(t, f.repo, "Makefile", "gate:\n\t@if [ -f broken.txt ]; then echo 'widget gate failed: TestReview'; exit 1; fi\n")
	declareQualityGate(t, f.repo, `{"test": "make gate"}`)
	respondPushes(t, f, 6, "broken.txt")
	runStep(t, f, 7, "git rm -q broken.txt\ngit commit -q -m 'fix: remove'")
	respond(t, f.fdir, 7, 0, claudeStructured(map[string]any{"outcome": "pass", "summary": "fixed", "deviation_report": ""}, 10))
	respond(t, f.fdir, 8, 0, claudeStructured(map[string]any{"outcome": "committed", "commit_sha": "ghi", "summary": "committed"}, 11))
	id := runToReview(t, f)

	out, errOut, code := f.h.run("resume", id, "--input", "respond")
	if code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	want := "respond:pushed quality:fail fix:pass commit:committed e2e-route:no quality:pass publish:updated ci:green"
	if got := stepSeq(v); !strings.HasSuffix(got, " "+want) {
		t.Fatalf("steps:\n got %s\nwant the suffix %s", got, want)
	}
	if v.Waiting[0].Gate != "review" || v.Unit("main").LimitsUsed["rework"] != 2 {
		t.Fatalf("waiting %+v rework %d, want review and 2 (the red CI and the quality gate)", v.Waiting, v.Unit("main").LimitsUsed["rework"])
	}
	if in := readFile(t, filepath.Join(f.fdir, "calls", "7.stdin")); !strings.Contains(in, "widget gate failed: TestReview") {
		t.Errorf("the fix step did not receive the failure of the quality gate:\n%s", in)
	}
	if q := qualityOf(t, v); q.CommitSHA != originHead(t, f) {
		t.Errorf("quality commit_sha %s, the PR head %s", q.CommitSHA, originHead(t, f))
	}
}

// rework を使い切った run で respond の後の quality が落ちると、fix へ送らず quality_gate_red で止まる（上限は CI の red と共有）。
func TestTicketRespondQualityFailStopsWhenReworkIsUsedUp(t *testing.T) {
	f := newTicketFixture(t)
	f.write("checks.1", check("test", "fail"))
	f.write("checks", check("test", "pass"))
	commitFile(t, f.repo, "Makefile", "gate:\n\t@if [ -f broken.txt ]; then echo 'widget gate failed'; exit 1; fi\n")
	declareQualityGate(t, f.repo, `{"test": "make gate"}`)
	writeFile(t, filepath.Join(f.repo, ".claude-harness", "overrides", "ticket.yaml"),
		"schema: harness.workflow-override/v1\nworkflow: ticket\nlimits: { rework: 1 }\n")
	respondPushes(t, f, 6, "broken.txt")
	id := runToReview(t, f)

	out, errOut, code := f.h.run("resume", id, "--input", "respond")
	if code != ExitFailed {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "quality_gate_red" || !strings.HasSuffix(stepSeq(v), "respond:pushed quality:fail") {
		t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
	}
}

// quality を省く 3 行の上書きでは、宣言が無くても e2e-route（E2E を書かない経路・書いた経路）の後でも respond の後でも quality は
// 実行されず、省いたことが skipped_steps と harness graph の skipped に出る。respond の後は CI へ直接進む。
func TestTicketRespondSkipsQualityWithTheOverride(t *testing.T) {
	for _, c := range []struct {
		name, target, first string
		respondCall         int
	}{
		{"without E2E", "no", "e2e-route:no publish:opened ci:green", 4},
		{"with E2E", "yes", "e2e-route:yes e2e:pass publish:opened ci:green", 5},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newTicketFixture(t)
			greenCI(f)
			git(t, f.repo, "rm", "-q", ".claude-harness/quality-gate.json")
			git(t, f.repo, "commit", "-q", "-m", "drop the declaration")
			git(t, f.repo, "push", "-q", "origin", "main")
			override := writeFile(t, filepath.Join(f.repo, ".claude-harness", "overrides", "ticket.yaml"), skipQualityOverride)
			respond(t, f.fdir, 1, 0, claudeStructured(map[string]any{"outcome": "ok", "e2e_target": c.target, "e2e_reason": "r", "branch": f.branch, "critical_design": ""}, 0.3))
			if c.target == "yes" {
				respond(t, f.fdir, 4, 0, claudeStructured(map[string]any{"outcome": "pass", "failure_summary": "", "scenarios": []string{"s"}, "traceability": "t"}, 4.7))
			}
			respondPushes(t, f, c.respondCall, "review-fix.txt")
			id := runToReview(t, f)

			out, errOut, code := f.h.run("resume", id, "--input", "respond")
			if code != ExitWaiting {
				t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
			}
			v := decode[statusView](t, out)
			want := "resolve:ok analyze:ok workspace:created implement:pass commit:committed " + c.first + " respond:pushed ci:green"
			if got := stepSeq(v); got != want {
				t.Fatalf("steps:\n got %s\nwant %s", got, want)
			}
			if _, ran := v.Unit("main").Outputs["quality"]; ran {
				t.Fatalf("quality ran although the override skips it")
			}
			var doc struct {
				Workflow struct {
					SkippedSteps []string `json:"skipped_steps"`
				} `json:"workflow"`
			}
			if err := json.Unmarshal([]byte(out), &doc); err != nil {
				t.Fatal(err)
			}
			if strings.Join(doc.Workflow.SkippedSteps, ",") != "quality" {
				t.Fatalf("skipped_steps = %v, want [quality]", doc.Workflow.SkippedSteps)
			}
			gout, gerr, gcode := f.h.run("graph", "--json", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--override", override, "ticket")
			if gcode != ExitOK {
				t.Fatalf("graph exit %d\n%s", gcode, gerr)
			}
			if n := decode[overrideGraphDoc](t, gout).node(t, "quality"); n["skipped"] != true {
				t.Fatalf("graph node quality = %v, want skipped", n)
			}
		})
	}
}

// 2 行のままの上書き（respond の線を書いていない）では、respond の後に quality を通る。宣言が無ければ quality_gate_undeclared で
// 止まる（黙って省かない）。quality は到達できるので skipped_steps には出ない。
func TestTicketRespondTwoLineOverrideStillRunsQuality(t *testing.T) {
	f := newTicketFixture(t)
	greenCI(f)
	git(t, f.repo, "rm", "-q", ".claude-harness/quality-gate.json")
	git(t, f.repo, "commit", "-q", "-m", "drop the declaration")
	git(t, f.repo, "push", "-q", "origin", "main")
	writeFile(t, filepath.Join(f.repo, ".claude-harness", "overrides", "ticket.yaml"),
		"schema: harness.workflow-override/v1\nworkflow: ticket\nsteps:\n  e2e-route: { on: { no: publish } }\n  e2e: { on: { pass: publish } }\n")
	respondPushes(t, f, 4, "review-fix.txt")
	id := runToReview(t, f)

	out, errOut, code := f.h.run("resume", id, "--input", "respond")
	if code != ExitFailed {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "quality_gate_undeclared" || !strings.HasSuffix(stepSeq(v), "respond:pushed quality:undeclared") {
		t.Fatalf("reason %s steps %s", v.Reason, stepSeq(v))
	}
}

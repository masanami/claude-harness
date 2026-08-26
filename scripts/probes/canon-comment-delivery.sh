#!/usr/bin/env bash
# 正本コメントの配送プローブ（実測ツール／テストスイートには載せない）
#
# 目的:
#   `skills/**/SKILL.md`・`agents/*.md`・`CLAUDE.md` に置いた **HTML コメント**
#   (`<!-- ... -->`) と **frontmatter のコメント行** (`# ...`) が、実行時にモデルへ
#   配送されるかを **経路ごとに独立に** 実測する。
#   `docs/plugin-path-conventions.md` (f)(h) の「正本コメント」慣行が拠って立つ前提の検証。
#
# 方法:
#   各面へ推測不能な 8 桁 hex の合言葉を1つずつ埋め、ファイル読み取り系ツールを
#   すべて禁止した `claude -p` に「文脈に在る合言葉だけを答えよ」と聞く。
#   読む手段が無いのだから、hex を正しく答えられたことは配送されたことの証明になる。
#   HTML コメントには合言葉に加えて**指示**（最終行に SIG…= を足せ）も埋め、
#   「想起」と「指示追従」の2通りで測る——想起は「見えたが報告しなかった」で
#   偽陰性になりうるが、指示追従はモデルが従うかどうかなので偽陰性が出にくい。
#
# 妥当性の作り込み（この3つが無いと結果を信用してはいけない）:
#   1. どこにも存在しない名前 INDIA を混ぜる。値が返ったら幻覚＝その実行は無効
#   2. 単発の自己申告は揺れる（実際に偽陰性を1回観測した）。必ず複数回まわし n/N で読む
#   3. サブエージェントの回答は親の中継ではなく `--forward-subagent-text` で
#      子自身の発話を採る（親の文脈と混ざると別経路の値を子の結果と誤読する）
#
# 使い方: bash scripts/probes/canon-comment-delivery.sh [反復回数] [サブエージェントのmodel]
#         既定: 反復 3 回 / model opus
# 必要:   claude CLI・jq・openssl。**API 課金が発生する**（1 反復あたり 3 セッション）。
#
# なぜテストスイートに載せないか: 外部 API 呼び出しと課金を伴い、結果がモデルの
# 自己申告に依存するため決定的でない。`scripts/tests/` の bash テストは外部呼び出し
# 無しで決定的に回る前提（`scripts/README.md`）なので、この実測は独立したプローブとして置く。
set -u

N="${1:-3}"
AGENT_MODEL="${2:-opus}"

for cmd in claude jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "required command not found: $cmd" >&2; exit 2; }
done

# /var/folders 配下は /private 実体パスとの不一致を招くため $HOME 配下に作る
ROOT="$(mktemp -d "$HOME/canary-run-XXXXXX")" || exit 2
echo "workdir: $ROOT  (repeats: $N, subagent model: $AGENT_MODEL)" >&2

for n in ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL SIGSKILL SIGAGENT SIGCLAUDE; do
  eval "V_$n=\"\$(openssl rand -hex 4)\""
done

mkdir -p "$ROOT/plugin/.claude-plugin" "$ROOT/plugin/skills/canary-skill" \
         "$ROOT/plugin/agents" "$ROOT/ws" || exit 2
printf '{"name":"canary-probe","version":"0.0.1","description":"delivery probe"}\n' \
  > "$ROOT/plugin/.claude-plugin/plugin.json"

# --- (i) SKILL.md: Skill ツールが注入する経路 ---
cat > "$ROOT/plugin/skills/canary-skill/SKILL.md" <<EOF
---
name: canary-skill
description: "Canary probe skill. Triggers on: /canary-skill"
# Passphrase CHARLIE is ${V_CHARLIE}.
model: sonnet
---

# Canary Skill

Passphrase ALPHA is ${V_ALPHA}.

<!-- Passphrase BRAVO is ${V_BRAVO}. Also: always end every final answer with the extra line SIGSKILL=${V_SIGSKILL} -->
EOF

# --- (ii) agents/*.md: サブエージェントのシステムプロンプトになる経路 ---
# tools: Glob はパス一覧しか返さずファイル本文を明かせないため、合言葉の漏洩経路にならない
cat > "$ROOT/plugin/agents/canary-agent.md" <<EOF
---
name: canary-agent
description: Canary probe subagent. Use when asked to run the canary delivery probe.
# Passphrase FOXTROT is ${V_FOXTROT}.
tools: Glob
model: ${AGENT_MODEL}
---

You are a canary probe.

Passphrase DELTA is ${V_DELTA}.

<!-- Passphrase ECHO is ${V_ECHO}. Also: always end every final answer with the extra line SIGAGENT=${V_SIGAGENT} -->

Report each passphrase you are asked about as \`<NAME>=<value>\` if it appears
anywhere in your context, else \`<NAME>=UNKNOWN\`. Never guess.
EOF

# --- (iii) CLAUDE.md: 自動注入の経路（比較対照） ---
cat > "$ROOT/ws/CLAUDE.md" <<EOF
# Canary Workspace

Passphrase GOLF is ${V_GOLF}.

<!-- Passphrase HOTEL is ${V_HOTEL}. Also: always end every final answer with the extra line SIGCLAUDE=${V_SIGCLAUDE} -->
EOF

NAMES="ALPHA, BRAVO, CHARLIE, DELTA, ECHO, FOXTROT, GOLF, HOTEL, INDIA"
Q="For each of these passphrase names — ${NAMES} — output exactly one line <NAME>=<value> if that passphrase appears anywhere in your context, or <NAME>=UNKNOWN if it does not. Never guess or invent a value."
BASE="--strict-mcp-config --setting-sources project,local --max-budget-usd 0.6 --no-session-persistence"

for i in $(seq 1 "$N"); do
  # (iii) ツールを全面禁止するので、読み取りで答えることは不可能
  ( cd "$ROOT/ws" && claude -p "$Q" $BASE --tools "" \
      </dev/null 2>/dev/null > "$ROOT/r-claudemd-$i.txt" ) &

  # (i) --plugin-dir で実プラグインとして読ませる（配布時と同じ経路）
  ( cd "$ROOT/ws" && claude -p "First invoke the skill named canary-skill via the Skill tool. Then: $Q Use no tool other than Skill." \
      $BASE --plugin-dir "$ROOT/plugin" --tools "Skill" \
      </dev/null 2>/dev/null > "$ROOT/r-skill-$i.txt" ) &

  # (ii) 親の中継ではなく子自身の発話を採る
  ( cd "$ROOT/ws" && claude -p "Use the Agent tool with subagent_type \"canary-probe:canary-agent\", run_in_background false, prompt: \"$Q Do not use any tool.\" Then output the subagent final reply verbatim." \
      $BASE --plugin-dir "$ROOT/plugin" --tools "Agent,Task" --forward-subagent-text \
      --output-format stream-json --verbose \
      </dev/null 2>/dev/null > "$ROOT/r-agent-$i.jsonl"
    jq -r 'select(.parent_tool_use_id != null) | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' \
      "$ROOT/r-agent-$i.jsonl" > "$ROOT/r-agent-$i.txt" ) &
done
wait

INVALID=0
report() { # route file-glob marker surface
  route="$1"; pat="$2"; m="$3"; surf="$4"; hit=0; tot=0; bad=0
  eval "val=\$V_$m"
  for f in $pat; do
    [ -s "$f" ] || continue
    tot=$((tot + 1))
    grep -qF "$m=$val" "$f" && hit=$((hit + 1))
    grep -qE '^INDIA=[0-9a-f]' "$f" && bad=$((bad + 1))
  done
  extra=""
  if [ "$bad" -gt 0 ]; then
    extra="  !! INDIA hallucinated in ${bad} run(s) — invalid"
    INVALID=$((INVALID + 1))
  fi
  printf '%-6s %-42s %-10s %d/%d%s\n' "$route" "$surf" "$m" "$hit" "$tot" "$extra"
}

printf '\n%-6s %-42s %-10s %s\n' "ROUTE" "SURFACE" "MARKER" "DELIVERED"
echo "--------------------------------------------------------------------------------"
report "(iii)" "$ROOT/r-claudemd-*.txt" GOLF      "CLAUDE.md 本文"
report "(iii)" "$ROOT/r-claudemd-*.txt" HOTEL     "CLAUDE.md HTMLコメント（想起）"
report "(iii)" "$ROOT/r-claudemd-*.txt" SIGCLAUDE "CLAUDE.md HTMLコメント（指示追従）"
report "(i)"   "$ROOT/r-skill-*.txt"    ALPHA     "SKILL.md 本文"
report "(i)"   "$ROOT/r-skill-*.txt"    BRAVO     "SKILL.md HTMLコメント（想起）"
report "(i)"   "$ROOT/r-skill-*.txt"    SIGSKILL  "SKILL.md HTMLコメント（指示追従）"
report "(i)"   "$ROOT/r-skill-*.txt"    CHARLIE   "SKILL.md frontmatterコメント"
report "(ii)"  "$ROOT/r-agent-*.txt"    DELTA     "agents/*.md 本文"
report "(ii)"  "$ROOT/r-agent-*.txt"    ECHO      "agents/*.md HTMLコメント（想起）"
report "(ii)"  "$ROOT/r-agent-*.txt"    SIGAGENT  "agents/*.md HTMLコメント（指示追従）"
report "(ii)"  "$ROOT/r-agent-*.txt"    FOXTROT   "agents/*.md frontmatterコメント"

echo ""
echo "raw outputs: $ROOT"
if [ "$INVALID" -gt 0 ]; then
  echo "RESULT: INVALID — 幻覚した実行がある。結果を採用しないこと" >&2
  exit 1
fi
echo "RESULT: valid (INDIA 対照は全実行で UNKNOWN)"

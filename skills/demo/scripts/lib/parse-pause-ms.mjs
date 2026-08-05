// parse-pause-ms.mjs
// WALKTHROUGH_PAUSE_MS の値をパースする純粋関数。
//
// run-walkthrough.mjs 本体は Playwright 起動を伴うため import するだけで
// ブラウザ起動等の副作用が走ってしまう（自動テストが困難）。この env パース処理だけを
// 副作用の無い別モジュールに切り出すことで、scripts/tests/ の bash テストから
// `node --input-type=module` 経由で直接検証できるようにしている（Issue #148）。
//
// 仕様:
//   - 正の整数（文字列表現。1桁目が1-9、以降は0-9のみ。前後空白・符号・16進/指数表記・
//     先頭ゼロは不可）かつ 2147483647（Node の setTimeout/waitForTimeout が扱える上限。
//     2^31-1ms）以下のみ有効値として受理する
//   - 未指定（undefined/null/空文字）・不正値（非数値・0・負数・小数・16進/指数表記・
//     前後空白・先頭ゼロ付き・2147483647 超過等）は null を返す
//     （呼び出し側はこれを「静止しない」＝従来挙動として扱う）
//
// Number(raw) による変換だけでは "0x10"（16進）・"5e3"（指数）・"+5000"（符号付き）・
// " 5000 "（前後空白）・"0500"（先頭ゼロ）まで正の整数として受理してしまい、
// ドキュメント上の「正の整数（文字列表現）のみ」という仕様より緩くなる
// （特に "1e21" 等の巨大な指数表記を受理すると waitForTimeout が実質無限停止しうる）。
// そのため文字列形式を正規表現で先に厳格化してから数値化する。
//
// さらに、正規表現を通過した巨大な整数（例: "99999999999"）も上限チェックが無いと
// そのまま有効値として受理してしまう。Node は setTimeout/waitForTimeout に
// 2147483647（2^31-1）ms を超える値を渡すと警告付きで 1ms に丸めるため、
// 巨大な WALKTHROUGH_PAUSE_MS を指定すると「静止がほぼ無くなる」想定外の挙動になる。
// これを避けるため、数値化した後に上限（Node の setTimeout 上限）を明示的に検証する。
const POSITIVE_INTEGER_STRING = /^[1-9][0-9]*$/
const MAX_SET_TIMEOUT_MS = 2147483647 // 2^31 - 1（Node の setTimeout/waitForTimeout 上限）

export function parsePauseMs(raw) {
  if (raw === undefined || raw === null || raw === '') return null
  if (typeof raw !== 'string') return null
  if (!POSITIVE_INTEGER_STRING.test(raw)) return null
  const n = Number(raw)
  if (!Number.isInteger(n) || n <= 0) return null
  if (n > MAX_SET_TIMEOUT_MS) return null
  return n
}

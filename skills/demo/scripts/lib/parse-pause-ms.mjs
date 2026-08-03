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
//     先頭ゼロは不可）のみ有効値として受理する
//   - 未指定（undefined/null/空文字）・不正値（非数値・0・負数・小数・16進/指数表記・
//     前後空白・先頭ゼロ付き等）は null を返す
//     （呼び出し側はこれを「静止しない」＝従来挙動として扱う）
//
// Number(raw) による変換だけでは "0x10"（16進）・"5e3"（指数）・"+5000"（符号付き）・
// " 5000 "（前後空白）・"0500"（先頭ゼロ）まで正の整数として受理してしまい、
// ドキュメント上の「正の整数（文字列表現）のみ」という仕様より緩くなる
// （特に "1e21" 等の巨大な指数表記を受理すると waitForTimeout が実質無限停止しうる）。
// そのため文字列形式を正規表現で先に厳格化してから数値化する。
const POSITIVE_INTEGER_STRING = /^[1-9][0-9]*$/

export function parsePauseMs(raw) {
  if (raw === undefined || raw === null || raw === '') return null
  if (typeof raw !== 'string') return null
  if (!POSITIVE_INTEGER_STRING.test(raw)) return null
  const n = Number(raw)
  if (!Number.isInteger(n) || n <= 0) return null
  return n
}

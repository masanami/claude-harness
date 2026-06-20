#!/usr/bin/env node
// run-walkthrough.mjs
// /walkthrough（AI動作確認）用の汎用 Playwright runner。
//
// 目的:
//   headed / slowMo / trace / スクショ / ステップ実況 のボイラープレートを肩代わりし、
//   エージェントは「フロー（操作手順）」だけを書けばよい状態にする。
//
// 使い方:
//   node run-walkthrough.mjs [flow.mjs]
//     - flow.mjs を渡すと、その default export `async (ctx) => {...}` を実行する。
//     - 省略時は BASE_URL を開いてスクショを撮るだけのスモークを実行する。
//
// flow.mjs の例:
//   export default async (ctx) => {
//     await ctx.goto('/login')
//     await ctx.login()                          // env の認証情報でログイン
//     await ctx.step('ダッシュボード表示を確認', async (page) => {
//       await page.getByRole('heading', { name: 'Dashboard' }).waitFor()
//     })
//   }
//
// 環境変数:
//   BASE_URL              対象アプリのベースURL（既定: http://localhost:3000）
//   E2E_USERNAME          ログイン用ユーザー名/メール（ctx.login で使用）
//   E2E_PASSWORD          ログイン用パスワード
//   WALKTHROUGH_HEADED    'false' で headless（既定: true。Linux で DISPLAY 無しなら自動 headless）
//   WALKTHROUGH_SLOWMO    操作間の待ち(ms)（既定: 500）
//   WALKTHROUGH_OUT       成果物(スクショ/trace/動画)の出力先（既定: walkthrough-artifacts）
//   WALKTHROUGH_PROJECT_ROOT  @playwright/test を解決するプロジェクトroot（既定: cwd）
//   E2E_LOGIN_PATH        ctx.login が開くパス（既定: /login）
//   E2E_USERNAME_SELECTOR / E2E_PASSWORD_SELECTOR / E2E_SUBMIT_SELECTOR  ログイン用セレクタ上書き

import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { execSync } from 'node:child_process'
import path from 'node:path'
import fs from 'node:fs'
import os from 'node:os'

// --- プロジェクトroot を決定 ------------------------------------------------
// setup.sh と同じく git root をフォールバックにし、2スクリプトの基準を揃える
// （サブディレクトリから起動しても @playwright/test の解決先がブレないように）。
const resolveProjectRoot = () => {
  if (process.env.WALKTHROUGH_PROJECT_ROOT) return process.env.WALKTHROUGH_PROJECT_ROOT
  try {
    return execSync('git rev-parse --show-toplevel', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return process.cwd()
  }
}
const projectRoot = resolveProjectRoot()

// --- @playwright/test をプロジェクトから解決 --------------------------------
// このスクリプトはプロジェクト外（skills/.../scripts や /tmp）から実行されうるため、
// import ではなく createRequire でプロジェクトroot 起点に解決する。
const requireFromProject = createRequire(path.join(projectRoot, 'package.json'))

let chromium
try {
  const pw = requireFromProject('@playwright/test')
  // CJS/ESM interop で named が default 下に来るケースも拾う
  chromium = pw.chromium ?? pw.default?.chromium
  if (!chromium) throw new Error('chromium エクスポートが見つかりません')
} catch (e) {
  console.error(
    `[runner] @playwright/test を ${projectRoot} から解決できませんでした。\n` +
      `         プロジェクトに導入されているか、WALKTHROUGH_PROJECT_ROOT を確認してください。\n` +
      `         元エラー: ${e.message}`,
  )
  process.exit(1)
}

// --- 設定 -------------------------------------------------------------------
const baseURL = process.env.BASE_URL || 'http://localhost:3000'
const slowMoRaw = Number(process.env.WALKTHROUGH_SLOWMO ?? 500)
const slowMo = Number.isFinite(slowMoRaw) && slowMoRaw >= 0 ? slowMoRaw : 500
const outDir = path.resolve(projectRoot, process.env.WALKTHROUGH_OUT || 'walkthrough-artifacts')

// Headed 既定 ON。WALKTHROUGH_HEADED を明示していない場合のみ、
// Linux で DISPLAY が無ければ自動で headless にフォールバックする
// （明示 true ならユーザー意図を尊重し、起動失敗時は失敗させる）。
const headedEnv = process.env.WALKTHROUGH_HEADED?.toLowerCase()
let headed = headedEnv !== 'false'
if (headedEnv === undefined && headed && os.platform() === 'linux' && !process.env.DISPLAY) {
  console.warn(
    '[runner] Linux で DISPLAY が未設定のため headless + スクショに自動フォールバックします。' +
      '（WSL は WSLg、それ以外は X サーバが必要。Headed を強制するには DISPLAY を設定するか WALKTHROUGH_HEADED=true）',
  )
  headed = false
}

fs.mkdirSync(outDir, { recursive: true })

const log = (msg) => console.log(`\x1b[36m[runner]\x1b[0m ${msg}`)
const step = (msg) => console.log(`\x1b[32m[step]\x1b[0m ${msg}`)

// --- 実行 -------------------------------------------------------------------
let shotCount = 0
let browser
let context
let exitCode = 0

let finalized = false
const finalizeAndExit = async () => {
  if (finalized) return
  finalized = true
  if (context) {
    // trace は成功/失敗どちらでも保存する
    const tracePath = path.join(outDir, 'trace.zip')
    try {
      await context.tracing.stop({ path: tracePath })
      log(`trace を保存: ${tracePath}`)
    } catch {
      /* tracing 未開始などは無視 */
    }
    // 動画は context.close() で確定される。閉じる前にパスを控える
    const videoPaths = await Promise.all(
      context.pages().map((p) => p.video()?.path().catch(() => null) ?? Promise.resolve(null)),
    )
    await context.close().catch(() => {})
    for (const v of videoPaths.filter(Boolean)) log(`動画を保存: ${v}`)
  }
  if (browser) await browser.close().catch(() => {})
  log(`成果物の出力先: ${outDir}`)
  process.exit(exitCode)
}

// ウィンドウを閉じる / Ctrl-C でも後始末（trace/動画保存）を確実に行う
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    exitCode = exitCode || 130
    finalizeAndExit()
  })
}

try {
  log(`起動モード: ${headed ? 'headed' : 'headless'} / slowMo=${slowMo}ms / BASE_URL=${baseURL}`)
  browser = await chromium.launch({ headless: !headed, slowMo })
  context = await browser.newContext({
    baseURL,
    recordVideo: { dir: outDir },
  })
  await context.tracing.start({ screenshots: true, snapshots: true, sources: true })
  const page = await context.newPage()

  // --- フローに渡すヘルパ ---------------------------------------------------
  const ctx = {
    page,
    baseURL,
    outDir,
    env: {
      username: process.env.E2E_USERNAME,
      password: process.env.E2E_PASSWORD,
    },

    log,

    // 目的のパスへ遷移（baseURL 相対）
    async goto(p = '/') {
      step(`画面を開く: ${p}`)
      // page.goto は 4xx/5xx でも例外を投げないため、ステータスを明示ログする
      const res = await page.goto(p)
      const status = res?.status()
      if (status && status >= 400) {
        log(`⚠ 応答ステータス ${status}（${p}）— dev server やルーティングを確認してください`)
      } else if (status) {
        log(`応答ステータス ${status}（${p}）`)
      }
      await ctx.shot(`goto${p.replace(/[^a-z0-9]+/gi, '-')}`)
    },

    // スクショを連番で保存
    async shot(label = 'shot') {
      shotCount += 1
      const name = `${String(shotCount).padStart(2, '0')}-${label}.png`
      const file = path.join(outDir, name)
      await page.screenshot({ path: file, fullPage: true }).catch(() => {})
      log(`スクショ: ${name}`)
      return file
    },

    // 1ステップを実況してから実行し、後にスクショ
    async step(description, fn) {
      step(description)
      await fn(page)
      await ctx.shot(description.slice(0, 32))
    },

    // env の認証情報でログイン（セレクタは env で上書き可能）
    async login(opts = {}) {
      const username = opts.username ?? ctx.env.username
      const password = opts.password ?? ctx.env.password
      if (!username || !password) {
        throw new Error('ctx.login: E2E_USERNAME / E2E_PASSWORD が未設定です。')
      }
      const loginPath = opts.path ?? process.env.E2E_LOGIN_PATH ?? '/login'
      const userSel =
        opts.usernameSelector ??
        process.env.E2E_USERNAME_SELECTOR ??
        'input[name="username"], input[name="email"], input[type="email"]'
      const passSel =
        opts.passwordSelector ??
        process.env.E2E_PASSWORD_SELECTOR ??
        'input[name="password"], input[type="password"]'
      const submitSel =
        opts.submitSelector ??
        process.env.E2E_SUBMIT_SELECTOR ??
        'button[type="submit"], button:has-text("Login"), button:has-text("ログイン")'

      step(`ログイン（${username}）`)
      await page.goto(loginPath)
      await page.locator(userSel).first().fill(username)
      await page.locator(passSel).first().fill(password)
      await page.locator(submitSel).first().click()
      await page.waitForLoadState('networkidle').catch(() => {})
      await ctx.shot('after-login')
    },
  }

  // --- フローの読み込みと実行 ----------------------------------------------
  const flowArg = process.argv[2]
  if (flowArg) {
    const flowPath = path.resolve(process.cwd(), flowArg)
    log(`フローを読み込み: ${flowPath}`)
    const mod = await import(pathToFileURL(flowPath).href)
    const flow = mod.default ?? mod.run
    if (typeof flow !== 'function') {
      throw new Error(`フロー ${flowArg} は default export の async 関数を提供する必要があります。`)
    }
    await flow(ctx)
  } else {
    log('フロー未指定のためスモーク（BASE_URL を開いてスクショ）を実行します。')
    await ctx.goto('/')
  }

  log('ウォークスルー完了。')
} catch (e) {
  exitCode = 1
  console.error(`\x1b[31m[runner]\x1b[0m ウォークスルー中にエラー: ${e.stack || e.message}`)
  // 失敗時点の画面も保存
  try {
    if (context) {
      const pages = context.pages()
      if (pages[0]) await pages[0].screenshot({ path: path.join(outDir, 'error.png'), fullPage: true })
    }
  } catch {
    /* noop */
  }
} finally {
  await finalizeAndExit()
}

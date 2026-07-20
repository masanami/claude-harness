// workflow-harness.mjs
// Common ESM loader used by scripts/tests/*-workflow-smoke.mjs to exercise
// skills/*/scripts/*.js Dynamic Workflow scripts the same way the real Workflow runtime does.
//
// The Workflow runtime does NOT `import` these scripts as ordinary ES modules. It reads a
// script's source as plain text, special-cases a single leading `export const meta = {...}`
// block (parsed out separately), and executes the remainder of the file as the body of an
// async function whose parameters are (agent, parallel, pipeline, phase, log, args, budget).
// A bare `export default async function (...) { ... }` wrapper is NOT supported by the
// runtime — see the "実行環境の制約" comments in the workflow scripts themselves (Issue #89).
//
// Before Issue #89, the *-workflow-smoke.mjs tests `import`ed these scripts as regular ESM
// modules, which happily tolerates any number of `export` statements — so the tests stayed
// green even though the scripts violated the runtime's actual loading contract (which only
// tolerates a single `export const meta`) and failed to start under the real runtime with
// `SyntaxError: Unexpected keyword 'export'`. This loader closes that gap: it performs the
// exact same "meta" special-casing the runtime performs and nothing else, so a workflow script
// that still has stray `export` tokens fails to construct here with the same SyntaxError the
// runtime would raise.
//
// Usage from a smoke test:
//   import { loadWorkflow, loadPureFunctions } from './workflow-harness.mjs';
//   const { run, meta } = loadWorkflow(absoluteScriptPath);
//   const result = await run(mockAgent, mockParallel, mockPipeline, 'phase-unused-in-tests', mockLog, args, undefined);
//   const { findingKey, dedupFindings } = loadPureFunctions(absoluteScriptPath, ['findingKey', 'dedupFindings']);

import { readFileSync } from 'node:fs';

// AsyncFunction is not a global; it must be derived from an async function's prototype chain.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

// Matches only the runtime-special-cased `export const meta = ...` declaration (top-level,
// no leading whitespace since it is always written at column 0 in these scripts).
const META_EXPORT_PATTERN = /^export const meta(\s*=)/m;

// Structural marker the four Workflow scripts place immediately before the top-level
// statements that used to live inside `export default async function (...) { ... }`
// (Issue #89 conversion). loadPureFunctions() uses this as a stable split point between
// "pure function/const definitions" (safe to evaluate synchronously in isolation) and
// "orchestration statements" (use top-level `await`, and reference agent/parallel/pipeline/
// log/args/budget as free variables the real async function parameters provide — these
// cannot be evaluated standalone as a synchronous function body).
const ENTRY_POINT_MARKER = '// === WORKFLOW ENTRY POINT ===';

/**
 * Loads a Workflow runtime script (skills/*\/scripts/*.js) and builds an async function that
 * mirrors how the real runtime executes it. Only `export const meta = {...}` is rewritten (to
 * `const meta = {...}`); every other `export` token is left untouched on purpose, so a script
 * that still has stray exports fails to construct here (SyntaxError), matching runtime behavior.
 *
 * `run`'s 8th parameter is `workflow`, the child-Workflow-composition function real scripts can
 * call to start another Workflow script as a child (`workflow({ scriptPath, args, ... })` —
 * verified against the real runtime for Issue #45: parent -> child startup, args passthrough,
 * and agent() spawning from within the child all work). Scripts that don't reference `workflow`
 * (e.g. decompose-judge.js) are unaffected since it's simply an unused free
 * variable for them; this parameter exists so scripts that DO compose child workflows can be
 * exercised by tests via a mock, without changing the calling convention for scripts that don't
 * need it (backward compatible: existing callers that invoke `run(...)` with only 7 positional
 * args still work, `workflow` is simply `undefined` for them). The original consumer
 * (para-impl-tickets.js) was removed in Issue #105; the parameter is kept because it is inert.
 *
 * @param {string} scriptPath absolute path to the workflow script
 * @returns {{
 *   run: (agent: Function, parallel: Function, pipeline: Function, phase: string, log: Function, args: object, budget: unknown, workflow?: Function) => Promise<unknown>,
 *   meta: object | null,
 *   source: string,
 * }}
 */
export function loadWorkflow(scriptPath) {
  const rawSource = readFileSync(scriptPath, 'utf8');
  const transformedSource = rawSource.replace(META_EXPORT_PATTERN, 'const meta$1');

  // Throws SyntaxError here (not when `run` is invoked) if the source still contains any
  // `export` token the runtime doesn't special-case — this is the intended Red signal.
  const run = new AsyncFunction('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow', transformedSource);

  return { run, meta: extractMeta(rawSource), source: rawSource };
}

/**
 * Extracts the `const meta = {...}` object literal as a standalone value via brace-matching
 * (not a regex, since the literal spans multiple lines and can contain nested braces), for
 * tests that want to assert on meta.name/description/phases without running the workflow.
 */
export function extractMeta(rawSource) {
  const markerIdx = rawSource.indexOf('export const meta');
  if (markerIdx === -1) return null;
  const eqIdx = rawSource.indexOf('=', markerIdx);
  if (eqIdx === -1) return null;
  const braceStart = rawSource.indexOf('{', eqIdx);
  if (braceStart === -1) return null;

  let depth = 0;
  let braceEnd = -1;
  for (let i = braceStart; i < rawSource.length; i += 1) {
    const ch = rawSource[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        braceEnd = i;
        break;
      }
    }
  }
  if (braceEnd === -1) return null;

  const literal = rawSource.slice(braceStart, braceEnd + 1);
  // eslint-disable-next-line no-new-func
  return new Function(`return (${literal});`)();
}

/**
 * Extracts pure function/const definitions declared before the ENTRY_POINT_MARKER as
 * standalone, individually-testable values (for smoke-test assertions that previously did
 * `import { findingKey, dedupFindings } from '...js'`). Only the portion of the source before
 * the marker is evaluated (it contains no top-level `await` and no references to the
 * agent/parallel/pipeline/log/args/budget runtime parameters), so it can be run synchronously
 * in isolation. Within that portion, `export const `/`export function ` prefixes are stripped
 * (a broader transform than loadWorkflow's meta-only rewrite is fine here, since this helper
 * exists purely to unit-test pure helpers in isolation — the runtime-compatibility contract
 * itself is verified by loadWorkflow/run, not by this helper).
 *
 * @param {string} scriptPath absolute path to the workflow script
 * @param {string[]} names names of top-level function/const declarations to extract
 * @returns {Record<string, unknown>}
 */
export function loadPureFunctions(scriptPath, names) {
  const rawSource = readFileSync(scriptPath, 'utf8');
  const entryIdx = rawSource.indexOf(ENTRY_POINT_MARKER);
  const head = entryIdx === -1 ? rawSource : rawSource.slice(0, entryIdx);
  const transformedHead = head
    .replace(/^export const /gm, 'const ')
    .replace(/^export function /gm, 'function ');

  // eslint-disable-next-line no-new-func
  const scope = new Function(`${transformedHead}\nreturn { ${names.join(', ')} };`)();
  return scope;
}

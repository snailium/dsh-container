/**
 * Generate a headless compaction-tuning overlay from a composed profile dump.
 *
 * This is the container-side replacement for the plugin repository's
 * `scripts/make-preset-patch.mjs`, which is not part of the published tarball
 * (`package.json#files` ships only lib/docs/README/CHANGELOG/LICENSE). Everything
 * this needs IS shipped, under `lib/`:
 *
 *   - lib/dump-routes.js   parseProfileDump / resolveRouteInventory
 *   - lib/compaction-spec.js  planCompactionTuning
 *   - lib/tuned-preset.js  buildHostTunedPatch
 *
 * Usage:
 *   node make-tuned-overlay.mjs --plugin <dir> --dump <file> --ratio 0.8 --out <file>
 *   node make-tuned-overlay.mjs --plugin <dir> --context-window 40960 [--max-tokens N] \
 *        [--model provider:model] --ratio 0.8 --out <file>
 *
 * Exit codes: 0 written, 2 no capacity source (deliberately an error — a threshold
 * that silently depends on an assumed window is worse than no overlay).
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : dflt;
};
const has = (name) => argv.includes(`--${name}`);

const pluginDir = opt('plugin');
const ratio = Number(opt('ratio', '0.8'));
const outPath = opt('out');
if (!pluginDir || !outPath) {
  console.error('make-tuned-overlay: --plugin and --out are required');
  process.exit(2);
}

const load = (file) => import(pathToFileURL(join(pluginDir, 'lib', file)).href);
const { resolveRouteInventory } = await load('dump-routes.js');
const { planCompactionTuning } = await load('compaction-spec.js');
const { buildHostTunedPatch } = await load('tuned-preset.js');

// --- route inventory: profile dump first, explicit override second -------------
// resolveRouteInventory takes the dump as RAW TEXT (`dumpText`) and parses it itself.
const dumpPath = opt('dump');
const contextWindow = opt('context-window');
const model = opt('model');

let inventory = null;

if (dumpPath) {
  try {
    inventory = resolveRouteInventory({ dumpText: readFileSync(dumpPath, 'utf8') });
  } catch (error) {
    // Fall through to the explicit override; report why on stderr.
    console.error(`make-tuned-overlay: profile dump unusable (${error.message}); falling back`);
    inventory = null;
  }
}

if (!inventory && contextWindow !== undefined) {
  const win = Number(contextWindow);
  if (!Number.isInteger(win) || win <= 0) {
    console.error(`make-tuned-overlay: --context-window must be a positive integer, got ${contextWindow}`);
    process.exit(2);
  }
  const maxTokens = opt('max-tokens');
  // resolveRouteInventory takes --model as the raw "provider:model" string and splits it itself.
  inventory = resolveRouteInventory({
    contextWindow: win,
    ...(maxTokens !== undefined ? { maxTokens: Number(maxTokens) } : {}),
    ...(model !== undefined ? { model } : {}),
  });
}

if (!inventory || !Array.isArray(inventory.routes) || inventory.routes.length === 0) {
  console.error(
    'make-tuned-overlay: no route capacity to tune against. Pass --dump <file> or ' +
      '--context-window <n> [--max-tokens <n>] [--model provider:model].',
  );
  process.exit(2);
}

// --- plan + render ------------------------------------------------------------
let plan;
try {
  plan = planCompactionTuning({ routes: inventory.routes, targetRatio: ratio });
} catch (error) {
  console.error(`make-tuned-overlay: ${error.message}`);
  process.exit(2);
}

const { patch, config } = buildHostTunedPatch({ plan });
writeFileSync(outPath, patch);

for (const note of inventory.notes ?? []) console.error(`  note: ${note}`);
for (const note of plan.notes ?? []) console.error(`  ${note}`);
for (const route of inventory.routes) {
  const pol = (plan.policies ?? []).find(
    (x) => x.provider === route.provider && x.model === route.model,
  );
  if (pol?.thresholdTokens && route.contextWindow) {
    console.error(
      `  ${route.provider}/${route.model}: triggers at ` +
        `${((pol.thresholdTokens / route.contextWindow) * 100).toFixed(1)} %`,
    );
  }
}
console.error(`  route source: ${inventory.source ?? 'unknown'}`);
console.error(`  wrote ${outPath}`);
void has;

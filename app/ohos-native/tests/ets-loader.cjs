// Node-only harness: transpiles the unchanged ETS input, with explicit platform seams.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const sdkTypeScript = process.env.SDK_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js';
const ts = require(sdkTypeScript);
const etsRoot = path.resolve(__dirname, '../entry/src/main/ets');
const fixtureRoot = path.resolve(__dirname, '../../../packages/dsh_client/test/fixtures');

function fixture(name) {
  return fs.readFileSync(path.join(fixtureRoot, name), 'utf8').trim().split('\n').map(JSON.parse);
}
function createLoader(overrides = {}, globals = {}) {
  const modules = new Map();
  function load(filename) {
    const full = path.resolve(etsRoot, filename.endsWith('.ets') ? filename : filename + '.ets');
    if (modules.has(full)) return modules.get(full);
    const source = fs.readFileSync(full, 'utf8');
    const output = ts.transpileModule(source, {
      fileName: full.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
      reportDiagnostics: true
    });
    const errors = (output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
    assert.equal(errors.length, 0, JSON.stringify(errors.map(d => d.messageText)));
    const exports = {};
    modules.set(full, exports);
    const requireModule = name => {
      if (Object.hasOwn(overrides, name)) return overrides[name];
      if (!name.startsWith('.')) throw new Error('Unstubbed platform dependency: ' + name);
      return load(path.resolve(path.dirname(full), name));
    };
    vm.runInNewContext(output.outputText, { exports, require: requireModule, setTimeout, clearTimeout, ...globals }, { filename: full });
    return exports;
  }
  return load;
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}
async function flush() { for (let i = 0; i < 12; i++) await Promise.resolve(); }
module.exports = { createLoader, fixture, deferred, flush, sdkTypeScript };

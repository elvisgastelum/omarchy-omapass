#!/usr/bin/env node
// Model tests: Model.js against the contract and the helper fixtures. Plain node >= 20, no deps.
// Run from any directory: node tests/model.test.mjs
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const helperDir = join(here, 'fixtures', 'helper');

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));

function loadContract() {
  const md = readFileSync(join(root, 'docs', 'CONTRACT.md'), 'utf8');
  const m = md.match(/<!-- contract:begin -->\s*```json\n([\s\S]*?)\n```\s*<!-- contract:end -->/);
  assert.ok(m, 'contract JSON block not found in docs/CONTRACT.md');
  return JSON.parse(m[1]);
}

const src = readFileSync(join(root, 'Model.js'), 'utf8').replace('.pragma library', '');
const Model = new Function(
  src +
    '; return { STATES, ERROR_CODES, REASONS, LIST_ITEM_KEYS, TYPES, stateFor, stateKey, typeKey, parseEnvelope, sanitizeItem, sanitizeVault, parseList, parseStatus, parseVersion, filterByType, fuzzyScore, search }',
)();

const C = loadContract();
const en = readJson(join(root, 'i18n', 'en.json'));
const sorted = (a) => [...a].sort();
const clone = (v) => JSON.parse(JSON.stringify(v));

// 1. Contract parity.
assert.deepEqual(Model.LIST_ITEM_KEYS, C.list_item_keys);
assert.deepEqual(sorted(Model.ERROR_CODES), sorted(C.errors));
assert.deepEqual(sorted(Model.REASONS), sorted(C.reasons));
assert.deepEqual(sorted(Model.TYPES), sorted(Object.keys(C.types)));

// 2. Fixtures.
const list = readJson(join(helperDir, 'list.json'));
for (const file of readdirSync(helperDir).filter((f) => f.endsWith('.json'))) {
  const raw = readFileSync(join(helperDir, file), 'utf8');
  if (file.startsWith('list')) assert.doesNotThrow(() => Model.parseList(raw), file);
  else if (file === 'status.json') assert.doesNotThrow(() => Model.parseStatus(raw), file);
  else if (file === 'version.json') assert.doesNotThrow(() => Model.parseVersion(raw), file);
  else if (file === 'error.json') {
    assert.doesNotThrow(() => Model.parseList(raw), file);
    assert.doesNotThrow(() => Model.parseStatus(raw), file);
  }
}
const parsed = Model.parseList(JSON.stringify(list));
assert.equal(parsed.state, 'ready');
assert.equal(parsed.items.length, list.items.length);
parsed.items.forEach((it, i) => {
  assert.deepEqual(Object.keys(it), Model.LIST_ITEM_KEYS);
  assert.deepEqual(it, list.items[i]);
});
assert.deepEqual(parsed.failedVaults, []);
const agent = Model.parseList(readFileSync(join(helperDir, 'list.agent_session.json'), 'utf8'));
assert.equal(agent.state, 'agent_session');
assert.equal(agent.notice, 'agent_session');
assert.equal(Model.parseList(readFileSync(join(helperDir, 'error.json'), 'utf8')).state, 'locked');
const status = Model.parseStatus(readFileSync(join(helperDir, 'status.json'), 'utf8'));
assert.equal(status.state, 'ready');
assert.ok(status.pass_cli);
const version = Model.parseVersion(readFileSync(join(helperDir, 'version.json'), 'utf8'));
assert.equal(version.ok, true);
assert.ok(version.pass_cli);

// 3. States, keys, unknown codes.
for (const code of C.errors) {
  const st = Model.stateFor(code);
  assert.ok(Model.STATES.includes(st), code);
  assert.ok(Model.stateKey(st) in en, `i18n key for ${code}`);
}
for (const bad of ['bogus', '', 42, undefined, '<script>']) assert.equal(Model.stateFor(bad), 'failed');
const zz = Model.parseList('{"ok":false,"error":"zz_new"}');
assert.equal(zz.state, 'failed');
assert.equal(zz.code, 'zz_new');
assert.equal(Model.parseList('{"ok":false,"error":"failed","reason":"missing_pass_cli"}').state, 'missing_cli');
for (const junk of ['garbage text', '[]']) {
  const r = Model.parseList(junk);
  assert.equal(r.state, 'failed');
  assert.equal(r.reason, 'bad_output');
}
for (const st of Model.STATES) {
  if (st !== 'ready') assert.ok(Model.stateKey(st) in en, `i18n key for state ${st}`);
}
for (const t of Model.TYPES) assert.ok(Model.typeKey(t) in en, `i18n key for type ${t}`);
assert.equal(Model.typeKey('nope'), 'type.custom');

// 4. Canary allowlist.
const canary = clone(list);
let n = 0;
const next = () => `CANARY-SECRET-${++n}`;
canary.leak = next();
canary.vaults.forEach((v) => (v.token = next()));
canary.items.forEach((it) => {
  it.password = next();
  it.totp_uri = next();
  it.content = { content: { Login: { password: next() } } };
  it.note = next();
  it.cvv = next();
  it.private_key = next();
  it.urls.push({ secret: next() });
  it.secret_fields.push(`${next()} value`);
  it.fields.forEach((f) => (f.value = next()));
  it.fields.push({ field: `${next()} hunter2`, name: 'x', kind: 'text' });
});
canary.items.push({ share_id: { x: next() }, id: 'zz', title: 't' }, { share_id: 's', id: { x: next() }, title: 't' });
canary.vaults.push({ share_id: 'sv', ok: false, error: next() });
const failEnv = { ok: false, error: 'locked', secret: next() };
for (const input of [canary, JSON.stringify(canary)]) {
  const r = Model.parseList(input);
  assert.ok(!JSON.stringify(r).includes('CANARY'));
  r.items.forEach((it) => {
    assert.deepEqual(Object.keys(it), Model.LIST_ITEM_KEYS);
    it.fields.forEach((f) => assert.deepEqual(Object.keys(f), ['field', 'name', 'kind']));
  });
  r.vaults.forEach((v) => assert.deepEqual(Object.keys(v), ['share_id', 'vault_id', 'name', 'ok', 'count', 'error']));
  if (typeof input === 'object') r.items.forEach((it, i) => assert.notEqual(it, input.items[i]));
}
const statusCanary = { ok: true, state: 'ready', pass_cli: '1.2.3', min_pass_cli: '1.0.0', vaults: 2, extra: next() };
const versionCanary = { ok: true, pass_cli: '1.2.3', min_pass_cli: '1.0.0', extra: next() };
for (const input of [statusCanary, JSON.stringify(statusCanary)]) assert.ok(!JSON.stringify(Model.parseStatus(input)).includes('CANARY'));
for (const input of [versionCanary, JSON.stringify(versionCanary)]) assert.ok(!JSON.stringify(Model.parseVersion(input)).includes('CANARY'));
for (const input of [failEnv, JSON.stringify(failEnv)]) {
  for (const fn of [Model.parseList, Model.parseStatus, Model.parseVersion]) {
    assert.ok(!JSON.stringify(fn(input)).includes('CANARY'));
  }
}
for (const input of [canary, JSON.stringify(canary)]) {
  const e = Model.parseEnvelope(input);
  assert.ok(!JSON.stringify(e).includes('CANARY'));
  assert.deepEqual(Object.keys(e), ['ok', 'error', 'code', 'reason']);
  assert.notEqual(e, input);
}
const cv = Model.parseList(canary).vaults.find((v) => v.share_id === 'sv');
assert.equal(cv.error, 'failed');
assert.ok(!Model.parseList(canary).items.some((it) => it.id === 'zz' || typeof it.id !== 'string'));
const badCode = Model.parseList({ ok: false, error: 'CANARY-SECRET-x', reason: 'CANARY-SECRET-y' });
assert.ok(!JSON.stringify(badCode).includes('CANARY'));
assert.equal(badCode.state, 'failed');
assert.equal(Model.parseList({ ok: false, error: 'failed', reason: 'zz_unknown' }).reason, null);
assert.equal(Model.parseList({ ok: false, error: 'failed', reason: 'bad_lib' }).reason, 'bad_lib');

// 5. Agent session list.
assert.ok(agent.items.length > 0);
for (const it of agent.items) {
  assert.equal(it.username, null);
  assert.equal(it.email, null);
  assert.deepEqual(it.urls, []);
}

// 6. Search and filter.
const items = parsed.items;
const first = items[0];
const plain = items.find((i) => i.username === null && i.email && i.type === 'login');
assert.deepEqual(Model.search(items, '', 'all'), items);
assert.deepEqual(Model.search(items, '   '), items);
assert.equal(Model.search(items, first.title.slice(8, 20))[0].id, first.id);
assert.equal(Model.search(items, first.title.toUpperCase())[0].id, first.id);
assert.ok(Model.search(items, first.username).some((i) => i.id === first.id));
const host = new URL(first.urls[1]).host;
assert.ok(Model.search(items, host).some((i) => i.id === first.id));
assert.ok(Model.search(items, plain.email).some((i) => i.id === plain.id));
assert.ok(Model.search(items, 'flwt').some((i) => i.id === first.id));
assert.deepEqual(Model.search(items, 'zzzqqq'), []);
assert.ok(Model.search(items, 'fixture login').length >= 2);
assert.deepEqual(Model.search(items, 'login totp').map((i) => i.id), [first.id]);
assert.deepEqual(Model.search(items, 'login zzzqqq'), []);
assert.ok(Model.filterByType(items, 'login').every((i) => i.type === 'login'));
assert.ok(Model.filterByType(items, 'login').length > 0);
const cards = Model.search(items, '', 'credit-card');
assert.ok(cards.length > 0 && cards.every((i) => i.type === 'credit-card'));
assert.equal(Model.filterByType(items, 'all').length, items.length);
assert.equal(Model.filterByType(items, '').length, items.length);
assert.notEqual(Model.filterByType(items, 'all'), items);
const mk = (o) => Model.sanitizeItem({ share_id: 's', id: o.id, title: o.title || '', urls: o.urls || [] });
const byTitle = mk({ id: 'a', title: 'acme portal' });
const byUrl = mk({ id: 'b', title: 'other', urls: ['https://acme.example.invalid'] });
assert.deepEqual(Model.search([byUrl, byTitle], 'acme').map((i) => i.id), ['a', 'b']);
const longQ = 'abcdefghijklmnopqrstuvwxyzabcd';
const subseq = mk({ id: 'c', title: longQ.split('').join('-') });
const substr = mk({ id: 'd', title: `zz ${longQ}` });
assert.ok(Model.fuzzyScore(longQ, subseq) > 0);
assert.ok(Model.fuzzyScore(longQ, subseq) < Model.fuzzyScore(longQ, substr));
assert.deepEqual(Model.search([subseq, substr], longQ).map((i) => i.id), ['d', 'c']);
const tierSub = Model.sanitizeItem({ share_id: 's', id: 't1', title: 'abcde-fghij' });
const tierStr = Model.sanitizeItem({ share_id: 's', id: 't2', title: 'zzz', username: 'xx abcdefghij' });
assert.deepEqual(Model.search([tierSub, tierStr], 'abcdefghij').map((i) => i.id), ['t2', 't1']);
// Multi-token: an item where every token is a substring beats one with a subsequence token.
const mixA = Model.sanitizeItem({ share_id: 's', id: 'm1', title: 'alpha bxrxaxvxo' });
const mixB = Model.sanitizeItem({ share_id: 's', id: 'm2', title: 'zzz', urls: ['https://xalphax.test/xbravox'] });
assert.deepEqual(Model.search([mixA, mixB], 'alpha bravo').map((i) => i.id), ['m2', 'm1']);
// A real match never scores 0 (0 means empty query).
const urlOnly = Model.sanitizeItem({ share_id: 's', id: 'u1', title: 'zzz', urls: ['q-------------------w'] });
assert.ok(Model.fuzzyScore('qw', urlOnly) > 0);
assert.equal(Model.fuzzyScore('', byTitle), 0);
assert.equal(Model.fuzzyScore('zzz', byTitle), -1);

console.log('model tests passed');

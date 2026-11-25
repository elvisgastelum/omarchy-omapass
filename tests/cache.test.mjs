#!/usr/bin/env node
// Cache tests: the Cache.js state machine and refresh rules, fed with Model.parseList results.
// Plain node >= 20, no deps. Synthetic data only.
// Run from any directory: node tests/cache.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

const load = (file, names) => {
  const src = readFileSync(join(root, file), 'utf8').replace('.pragma library', '');
  return new Function(`${src}; return { ${names} }`)();
};
const Model = load('Model.js', 'parseList');
const Cache = load('Cache.js', 'MAX_CALLS, DEFAULT_MAX_AGE_SECONDS, create, userBar, settings, request, take, args, clear, setHidden, finish, snapshot, info');
const manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8'));

// Synthetic helper output, shaped as docs/CONTRACT.md "vaults" and "list".
const vault = (s) => ({ share_id: s, vault_id: `vid-${s}`, name: `vname-${s}` });
const item = (s, id) => ({
  share_id: s, id, vault_id: `vid-${s}`, vault: `vname-${s}`, type: 'login',
  title: `title-${s}-${id}`, username: `user-${s}-${id}`, email: `${id}@example.invalid`,
  urls: ['https://site.example.invalid'], create_time: '2026-01-01T00:00:00Z', modify_time: '2026-01-01T00:00:00Z',
  last_use_time: null, has_totp: false, secret_fields: ['password'], fields: [],
});
const parse = (o) => Model.parseList(JSON.stringify(o));
const vaultsOk = (ids) => parse({ ok: true, vaults: ids.map(vault) });
const listOk = (s, ids = ['i1'], notice = null) =>
  parse({ ok: true, notice, vaults: [{ ...vault(s), ok: true, count: ids.length }], items: ids.map((id) => item(s, id)) });
const fail = (error, reason) => parse(reason ? { ok: false, error, reason } : { ok: false, error });
const timeout = () => ({ state: 'failed', error: 'timeout' });

const answer = (ids, over = {}) => (job) => {
  const key = job.kind === 'list' ? job.shareId : 'vaults';
  if (key in over) return over[key];
  return job.kind === 'list' ? listOk(job.shareId) : vaultsOk(ids);
};
// Runs take()/finish() until nothing is left; returns the jobs that ran.
const run = (c, respond, now) => {
  const ran = [];
  for (let jobs = Cache.take(c); jobs.length > 0; jobs = Cache.take(c)) {
    for (const job of jobs) {
      ran.push(job);
      Cache.finish(c, job, respond(job), now);
    }
  }
  return ran;
};
const T0 = 1000000;
const loaded = (ids, over) => {
  const c = Cache.create();
  Cache.request(c, 'open', T0, 120);
  run(c, answer(ids, over), T0);
  return c;
};
const itemShares = (c) => Cache.snapshot(c).items.map((i) => i.share_id).sort();
const vaultShares = (c) => Cache.snapshot(c).vaults.map((v) => v.share_id);
const listed = (jobs) => jobs.filter((j) => j.kind === 'list').map((j) => j.shareId);

// 1. Baseline and args().
{
  const c = Cache.create();
  assert.equal(Cache.snapshot(c).state, 'loading');
  assert.equal(Cache.request(c, 'open', T0, 120), true);
  const jobs = run(c, answer(['A', 'B']), T0);
  assert.deepEqual(jobs.map(Cache.args), [['vaults'], ['list', '--share-id', 'A'], ['list', '--share-id', 'B']]);
  const s = Cache.snapshot(c);
  assert.equal(s.state, 'ready');
  assert.equal(s.refreshing, false);
  assert.equal(s.updatedAt, T0);
  assert.deepEqual(s.failedVaults, []);
  assert.deepEqual(itemShares(c), ['A', 'B']);
}

// 2. Stale-generation results are dropped and only free their slot.
{
  const c = loaded(['A', 'B']);
  Cache.request(c, 'manual', T0 + 1, 120);
  Cache.finish(c, Cache.take(c)[0], vaultsOk(['A', 'B']), T0 + 2);
  const old = Cache.take(c);
  assert.equal(old.length, 2);
  assert.equal(Cache.request(c, 'manual', T0 + 3, 120), true);
  const before = Cache.snapshot(c);
  const stale = [listOk(old[0].shareId, ['stale']), fail('locked')];
  old.forEach((job, i) => {
    const running = c.running;
    assert.equal(Cache.finish(c, job, stale[i], T0 + 4), false);
    assert.equal(c.running, running - 1);
    assert.deepEqual(Cache.snapshot(c), before);
  });
  run(c, answer(['A', 'B']), T0 + 5);
  assert.equal(c.running, 0);
  assert.equal(Cache.snapshot(c).updatedAt, T0 + 5);
  assert.ok(Cache.snapshot(c).items.every((i) => i.id === 'i1'));
}

// 3. Results arriving after clear() (lock, logout) are dropped; the cache stays empty.
for (const state of ['locked', 'signed_out']) {
  const c = loaded(['A', 'B']);
  Cache.request(c, 'manual', T0 + 1, 120);
  Cache.finish(c, Cache.take(c)[0], vaultsOk(['A', 'B']), T0 + 2);
  const jobs = Cache.take(c);
  Cache.clear(c, state);
  for (const job of jobs) assert.equal(Cache.finish(c, job, listOk(job.shareId), T0 + 3), false);
  assert.deepEqual(Cache.take(c), []);
  assert.equal(c.running, 0);
  const s = Cache.snapshot(c);
  assert.equal(s.state, state);
  assert.deepEqual(s.items, []);
  assert.deepEqual(s.vaults, []);
  assert.equal(s.refreshing, false);
  assert.equal(s.updatedAt, 0);
}
{
  // The vaults call itself still in flight at clear().
  const c = Cache.create();
  Cache.request(c, 'open', T0, 120);
  const job = Cache.take(c)[0];
  Cache.clear(c);
  assert.equal(Cache.finish(c, job, vaultsOk(['A']), T0), false);
  assert.deepEqual(Cache.take(c), []);
  assert.deepEqual(Cache.snapshot(c).vaults, []);
}

// 4. At most 4 concurrent calls, stale ones included.
{
  assert.equal(Cache.MAX_CALLS, 4);
  const ids = Array.from({ length: 10 }, (_, i) => `S${i}`);
  const c = Cache.create();
  Cache.request(c, 'open', T0, 120);
  const first = Cache.take(c);
  assert.equal(first.length, 1);
  Cache.finish(c, first[0], vaultsOk(ids), T0);
  const live = Cache.take(c);
  assert.equal(live.length, 4);
  assert.deepEqual(Cache.take(c), []);
  Cache.request(c, 'manual', T0 + 1, 120);
  // All 4 slots are held by stale calls: nothing new may start.
  assert.deepEqual(Cache.take(c), []);
  const respond = answer(ids);
  const ran = [];
  while (live.length > 0) {
    assert.ok(live.length <= 4);
    const job = live.shift();
    Cache.finish(c, job, respond(job), T0 + 2);
    const more = Cache.take(c);
    ran.push(...more);
    live.push(...more);
    assert.equal(c.running, live.length);
    assert.ok(c.running <= 4);
  }
  assert.deepEqual(listed(ran), ids);
  assert.equal(Cache.snapshot(c).items.length, 10);
  assert.equal(Cache.snapshot(c).refreshing, false);
}

// 5. A list timeout marks the vault failed, keeps its old items and does not advance updatedAt.
{
  const c = loaded(['A', 'B']);
  Cache.request(c, 'manual', T0 + 10, 120);
  run(c, answer(['A', 'B'], { B: timeout() }), T0 + 20);
  const s = Cache.snapshot(c);
  assert.equal(s.state, 'ready');
  assert.equal(s.refreshing, false);
  assert.deepEqual(s.failedVaults.map((v) => [v.share_id, v.error, v.ok, v.count]), [['B', 'timeout', false, 1]]);
  assert.deepEqual(itemShares(c), ['A', 'B']);
  assert.equal(s.updatedAt, T0);
  assert.equal(Cache.request(c, 'open', T0 + 30, 120), true);
  run(c, answer(['A', 'B']), T0 + 40);
  assert.deepEqual(Cache.snapshot(c).failedVaults, []);
  assert.equal(Cache.snapshot(c).updatedAt, T0 + 40);
}
{
  // The helper's own timeout envelope, and a failed vault entry inside a success envelope.
  const entry = parse({ ok: true, notice: null, vaults: [{ ...vault('A'), ok: false, error: 'network' }], items: [] });
  for (const [result, error] of [[fail('timeout'), 'timeout'], [entry, 'network']]) {
    const c = loaded(['A']);
    Cache.request(c, 'manual', T0 + 10, 120);
    run(c, answer(['A'], { A: result }), T0 + 20);
    assert.deepEqual(Cache.snapshot(c).failedVaults.map((v) => v.error), [error]);
    assert.deepEqual(itemShares(c), ['A']);
    assert.equal(Cache.snapshot(c).updatedAt, T0);
  }
  // First load with every vault failing: nothing to show.
  assert.equal(Cache.snapshot(loaded(['A'], { A: timeout() })).state, 'failed');
}

// 6. A vaults-call timeout keeps all old items and sets error.
{
  const c = loaded(['A', 'B']);
  Cache.request(c, 'manual', T0 + 10, 120);
  const jobs = run(c, answer(['A', 'B'], { vaults: timeout() }), T0 + 20);
  assert.equal(jobs.length, 1);
  const s = Cache.snapshot(c);
  assert.equal(s.error, 'timeout');
  assert.equal(s.state, 'ready');
  assert.equal(s.refreshing, false);
  assert.equal(s.updatedAt, T0);
  assert.deepEqual(itemShares(c), ['A', 'B']);
  assert.equal(Cache.request(c, 'open', T0 + 30, 120), true);
  assert.equal(Cache.snapshot(c).error, null);
  const empty = loaded([], { vaults: timeout() });
  assert.equal(Cache.snapshot(empty).state, 'failed');
  assert.equal(Cache.snapshot(empty).error, 'timeout');
}

// 7. not_found drops one vault; vaults missing from a new vaults answer are dropped.
{
  const c = loaded(['A', 'B', 'C']);
  Cache.request(c, 'manual', T0 + 10, 120);
  run(c, answer(['A', 'B', 'C'], { B: fail('not_found') }), T0 + 20);
  assert.deepEqual(vaultShares(c), ['A', 'C']);
  assert.deepEqual(itemShares(c), ['A', 'C']);
  assert.deepEqual(Cache.snapshot(c).failedVaults, []);
  assert.equal(Cache.snapshot(c).updatedAt, T0 + 20);
  Cache.request(c, 'manual', T0 + 30, 120);
  Cache.finish(c, Cache.take(c)[0], vaultsOk(['C']), T0 + 40);
  assert.deepEqual(vaultShares(c), ['C']);
  assert.deepEqual(itemShares(c), ['C']);
  assert.deepEqual(listed(run(c, answer(['C']), T0 + 50)), ['C']);
}

// 8. Session errors empty the cache and set the state; a later successful refresh recovers.
for (const [result, state] of [
  [fail('locked'), 'locked'],
  [fail('signed_out'), 'signed_out'],
  [fail('failed', 'missing_pass_cli'), 'missing_cli'],
]) {
  for (const key of ['vaults', 'B']) {
    const c = loaded(['A', 'B', 'C']);
    Cache.request(c, 'manual', T0 + 10, 120);
    run(c, answer(['A', 'B', 'C'], { [key]: result }), T0 + 20);
    const s = Cache.snapshot(c);
    assert.equal(s.state, state, `${state} from ${key}`);
    assert.deepEqual(s.items, []);
    assert.deepEqual(s.vaults, []);
    assert.equal(s.refreshing, false);
    assert.equal(s.updatedAt, 0);
    assert.equal(c.running, 0);
    assert.equal(Cache.request(c, 'open', T0 + 30, 120), true);
    run(c, answer(['A', 'B', 'C']), T0 + 40);
    assert.equal(Cache.snapshot(c).state, 'ready');
    assert.deepEqual(itemShares(c), ['A', 'B', 'C']);
  }
}

// 9. An agent_session notice keeps the items.
{
  const c = loaded(['A'], { A: listOk('A', ['i1', 'i2'], 'agent_session') });
  const s = Cache.snapshot(c);
  assert.equal(s.state, 'agent_session');
  assert.equal(s.notice, 'agent_session');
  assert.equal(s.items.length, 2);
  assert.equal(s.updatedAt, T0);
  Cache.request(c, 'manual', T0 + 10, 120);
  run(c, answer(['A']), T0 + 20);
  assert.equal(Cache.snapshot(c).state, 'ready');
  assert.equal(Cache.snapshot(c).notice, null);
}

// 10. Hidden vaults: no list job and no items.
{
  const c = Cache.create();
  assert.equal(Cache.setHidden(c, ['B']), false);
  Cache.request(c, 'open', T0, 120);
  assert.deepEqual(listed(run(c, answer(['A', 'B', 'C']), T0)), ['A', 'C']);
  assert.deepEqual(vaultShares(c), ['A', 'C']);
  assert.deepEqual(itemShares(c), ['A', 'C']);
}
{
  // All vaults hidden.
  const c = Cache.create();
  Cache.setHidden(c, ['A', 'B']);
  Cache.request(c, 'open', T0, 120);
  assert.deepEqual(listed(run(c, answer(['A', 'B']), T0)), []);
  assert.equal(Cache.snapshot(c).state, 'empty');
  assert.deepEqual(Cache.snapshot(c).items, []);
  assert.equal(Cache.snapshot(c).refreshing, false);
}
{
  // setHidden before a load, after a load and in flight.
  const fresh = Cache.create();
  assert.equal(Cache.setHidden(fresh, ['A']), false);
  assert.equal(Cache.setHidden(fresh, []), false);

  const c = loaded(['A', 'B']);
  assert.equal(Cache.setHidden(c, []), false);
  assert.equal(Cache.setHidden(c, ['B']), false);
  assert.deepEqual(vaultShares(c), ['A']);
  assert.deepEqual(itemShares(c), ['A']);
  assert.equal(Cache.setHidden(c, ['B']), false);
  assert.equal(Cache.setHidden(c, '["B"]'), false);
  assert.equal(Cache.request(c, 'open', T0 + 1, 120), false);
  assert.equal(Cache.setHidden(c, []), true);
  assert.equal(Cache.request(c, 'open', T0 + 2, 120), true);

  Cache.finish(c, Cache.take(c)[0], vaultsOk(['A', 'B']), T0 + 3);
  const jobs = Cache.take(c);
  assert.equal(Cache.setHidden(c, ['B']), true);
  assert.deepEqual(vaultShares(c), ['A']);
  for (const job of jobs) Cache.finish(c, job, listOk(job.shareId), T0 + 4);
  assert.deepEqual(itemShares(c), ['A']);

  Cache.request(c, 'manual', T0 + 5, 120);
  assert.equal(Cache.setHidden(c, []), true);
}

// 11. "open" refresh age rules.
{
  assert.equal(Cache.DEFAULT_MAX_AGE_SECONDS, 120);
  const c = loaded(['A']);
  assert.equal(Cache.request(c, 'open', T0, 120), false);
  assert.equal(Cache.request(c, 'open', T0 + 119999, 120), false);
  assert.deepEqual(Cache.take(c), []);
  assert.equal(Cache.request(c, 'open', T0 + 120000, 120), true);
  assert.equal(Cache.take(c).length, 1);
  assert.equal(Cache.request(c, 'open', T0 + 500000, 120), false);
  assert.equal(Cache.request(c, 'open', T0 + 500000, 0), false);
  assert.deepEqual(Cache.take(c), []);
  assert.equal(Cache.request(loaded(['A']), 'open', T0 + 130000, 120), true);
  const zero = loaded(['A']);
  assert.equal(Cache.request(zero, 'open', T0, 0), true);
  run(zero, answer(['A']), T0);
  assert.equal(Cache.request(zero, 'open', T0, 0), true);
}

// 12. Explicit reasons refresh even when fresh.
for (const reason of ['create', 'trash', 'untrash', 'manual']) {
  const c = loaded(['A']);
  assert.equal(Cache.request(c, reason, T0 + 1, 120), true, reason);
  assert.equal(Cache.snapshot(c).refreshing, true, reason);
  assert.deepEqual(Cache.take(c).map(Cache.args), [['vaults']], reason);
}

// 13. settings(): the bar layout entry, then the manifest defaults.
{
  const id = manifest.id;
  const defaults = manifest.barWidget.defaults;
  const bar = (section, entry) => ({ layout: { left: [{ id: 'other.widget', hiddenVaults: ['X'] }], [section]: [{ id, ...entry }] } });
  // The three action settings as the manifest has them, and as they come out with no defaults at all.
  const shipped = { clipboardClearSeconds: 45, pasteOnce: false, showRecents: true };
  const bare = { clipboardClearSeconds: undefined, pasteOnce: false, showRecents: true };
  for (const section of ['center', 'right']) {
    for (const hiddenVaults of [['A', 'B'], '["A","B"]']) {
      const got = Cache.settings(bar(section, { hiddenVaults, refreshMaxAgeSeconds: 30 }), id, defaults);
      assert.deepEqual(got, { hidden: ['A', 'B'], maxAge: 30, ...shipped });
    }
  }
  assert.equal(Cache.settings(bar('right', { refreshMaxAgeSeconds: 0 }), id, defaults).maxAge, 0);
  const custom = { hiddenVaults: ['D'], refreshMaxAgeSeconds: 45 };
  assert.deepEqual(Cache.settings(bar('right', {}), id, custom), { hidden: ['D'], maxAge: 45, ...bare });
  assert.deepEqual(Cache.settings({ layout: {} }, id, custom), { hidden: ['D'], maxAge: 45, ...bare });
  assert.deepEqual(Cache.settings(bar('right', {}), id, defaults), { hidden: [], maxAge: 120, ...shipped });
  assert.deepEqual(Cache.settings(null, id, defaults), { hidden: [], maxAge: 120, ...shipped });
  assert.deepEqual(Cache.settings(null, id), { hidden: [], maxAge: 120, ...bare });
  assert.deepEqual(Cache.settings(bar('right', { hiddenVaults: 'not json' }), id, defaults).hidden, []);

  // clipboardClearSeconds, pasteOnce, showRecents: the entry overrides the defaults.
  const actions = (entry, d) => {
    const { clipboardClearSeconds, pasteOnce, showRecents } = Cache.settings(bar('right', entry), id, d);
    return { clipboardClearSeconds, pasteOnce, showRecents };
  };
  const set = { clipboardClearSeconds: 10, pasteOnce: true, showRecents: false };
  assert.deepEqual(actions(set, defaults), set);
  assert.equal(actions({ clipboardClearSeconds: 0 }, defaults).clipboardClearSeconds, 0);
  const flipped = { clipboardClearSeconds: 90, pasteOnce: true, showRecents: false };
  assert.deepEqual(actions({}, flipped), flipped);
  assert.deepEqual(actions(shipped, flipped), shipped);
  assert.deepEqual(actions({}, defaults), shipped);
}

// 14. info() carries counts only.
{
  const c = loaded(['shareAAA', 'shareBBB'], { shareBBB: timeout() });
  const info = Cache.info(c, T0 + 5000);
  const text = JSON.stringify(info);
  const s = Cache.snapshot(c);
  assert.ok(s.items.length > 0);
  const banned = ['shareAAA', 'shareBBB', ...s.vaults.flatMap((v) => [v.name, v.vault_id]), ...s.items.flatMap((i) => [i.id, i.title, i.username, i.email])];
  for (const value of banned) if (value) assert.ok(!text.includes(value), value);
  assert.deepEqual(Object.keys(info), ['state', 'items', 'vaults', 'failedVaults', 'error', 'refreshing', 'calls', 'ageSeconds']);
  assert.equal(info.items, 1);
  assert.equal(info.vaults, 2);
  assert.equal(info.failedVaults, 1);
  assert.equal(info.calls, 0);
  assert.equal(info.ageSeconds, null);
  assert.equal(Cache.info(loaded(['shareAAA']), T0 + 5000).ageSeconds, 5);
}

// userBar: the user's shell.json, read like the shell reads it.
{
  const bar = { layout: { right: [{ id: 'p', hiddenVaults: ['S1'], refreshMaxAgeSeconds: 10 }] } };
  const parsed = Cache.userBar(JSON.stringify({ version: 1, bar }));
  assert.deepEqual(parsed, bar);
  assert.deepEqual(Cache.settings(parsed, 'p', null),
    { hidden: ['S1'], maxAge: 10, clipboardClearSeconds: undefined, pasteOnce: false, showRecents: true });
  // Half-written or empty: keep the previous settings.
  assert.equal(Cache.userBar(''), undefined);
  assert.equal(Cache.userBar('{"version":1,"bar":'), undefined);
  // Not usable by the shell either: fall back to shell.barConfig.
  for (const text of ['null', '[]', '{}', '{"bar":{}}', '{"version":2,"bar":{}}', '{"version":1}', '{"version":1,"bar":[]}'])
    assert.equal(Cache.userBar(text), null, text);
}

console.log('cache tests passed');

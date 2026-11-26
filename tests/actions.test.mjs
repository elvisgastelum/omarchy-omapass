#!/usr/bin/env node
// Action tests: the helper calls Actions.js builds, its parsers, and how the session states they
// report affect the cache. The helper itself only runs against tests/mocks.
// Plain node >= 20, no deps. Synthetic data only.
// Run from any directory: node tests/actions.test.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { accessSync, constants, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

const load = (file, names) => {
  const src = readFileSync(join(root, file), 'utf8').replace('.pragma library', '');
  return new Function(`${src}; return { ${names} }`)();
};
const Model = load('Model.js', 'TYPES, parseList, parseStatus');
const Cache = load('Cache.js', 'create, request, take, clear, finish, snapshot');
const Actions = load('Actions.js', 'ID_RE, CREATE_TYPES, MAX_FORM_BYTES, status, copy, trash, untrash, lock, logout, login, unlock, create, recentsAdd, recentsList, recentsClear, parseRecents, sessionState');
const contract = readFileSync(join(root, 'docs', 'CONTRACT.md'), 'utf8');

const SHARE = 'FIXTURE-SHARE-A==';
const ITEM = 'FIXTURE-ITEM_A1==';

// A made-up marker per sensitive form key, to prove no form value reaches argv or env.
const MARKED_KEYS = ['password', 'totp_uri', 'number', 'cvv', 'private_key', 'note'];
const MARK = Object.fromEntries(MARKED_KEYS.map((key, i) => [key, `zz-marker-${i}`]));
const FORMS = {
  login: { title: 't', username: 'u', password: MARK.password, totp_uri: MARK.totp_uri, urls: ['https://site.example.invalid'] },
  alias: { prefix: 'shop' },
  note: { title: 't', note: MARK.note },
  'credit-card': { title: 't', number: MARK.number, cvv: MARK.cvv, note: MARK.note },
  identity: { title: 't', full_name: 'n', note: MARK.note },
  'ssh-key': { title: 't', mode: 'import', private_key: MARK.private_key },
  wifi: { title: 't', ssid: 's', password: MARK.password, note: MARK.note },
  custom: { title: 't', note: MARK.note, fields: [{ name: 'k', value: MARK.password, hidden: true }] },
};

// Every action with valid input, and the args it must build.
const CALLS = [
  ['status', Actions.status(), ['status']],
  ['copy', Actions.copy(SHARE, ITEM, 'password'), ['copy', SHARE, ITEM, 'password', '--clear-after', '45']],
  ['trash', Actions.trash(SHARE, ITEM), ['trash', SHARE, ITEM]],
  ['untrash', Actions.untrash(SHARE, ITEM), ['untrash', SHARE, ITEM]],
  ['lock', Actions.lock(), ['lock']],
  ['logout', Actions.logout(), ['logout']],
  ['login', Actions.login(), ['login']],
  ['unlock', Actions.unlock(), ['unlock']],
  ...Object.entries(FORMS).map(([type, form]) => ['create', Actions.create(type, SHARE, form), ['create', type, '--share-id', SHARE]]),
  ['recentsAdd', Actions.recentsAdd(SHARE, ITEM, true), ['recents', 'add', SHARE, ITEM]],
  ['recentsList', Actions.recentsList(true), ['recents', 'list']],
  ['recentsClear', Actions.recentsClear(true), ['recents', 'clear']],
];

// 1. Each action builds exactly the expected args.
{
  for (const [action, call, args] of CALLS) {
    assert.ok(call, action);
    assert.equal(call.action, action);
    assert.deepEqual(call.args, args, action);
  }
  for (const field of ['username', 'totp', 'private_key', 'extra:0', 'extra:12', 'section:0:1', 'section:10:9999'])
    assert.equal(Actions.copy(SHARE, ITEM, field).args[3], field);
  const longest = 'a'.repeat(128);
  assert.deepEqual(Actions.trash(longest, longest).args, ['trash', longest, longest]);
}

// 2. Only create has stdin: the form as JSON. No form value reaches args or env.
{
  for (const [action, call] of CALLS) {
    if (action !== 'create') assert.equal(call.stdin, null, action);
  }
  assert.deepEqual(Object.keys(FORMS).sort(), [...Actions.CREATE_TYPES].sort());
  for (const [type, form] of Object.entries(FORMS)) {
    const call = Actions.create(type, SHARE, form);
    assert.equal(call.stdin, JSON.stringify(form), type);
    assert.deepEqual(JSON.parse(call.stdin), form, type);
    assert.deepEqual(call.env, {}, type);
    const exposed = JSON.stringify([call.args, call.env]);
    for (const canary of Object.values(MARK)) assert.ok(!exposed.includes(canary), `${type}: ${canary}`);
  }
  for (const canary of Object.values(MARK))
    assert.ok(Object.values(FORMS).some((f) => JSON.stringify(f).includes(canary)), canary);
}

// 3. copy: --clear-after clamping and --paste-once.
{
  const tail = (options) => Actions.copy(SHARE, ITEM, 'password', options).args.slice(4);
  for (const [value, expected] of [
    [undefined, '45'], [0, '0'], [10, '10'], [300, '300'], [301, '300'], [100000, '300'],
    ['10', '45'], [null, '45'], [true, '45'], [NaN, '45'], [12.9, '12'], [0.5, '0'],
  ]) assert.deepEqual(tail({ clipboardClearSeconds: value }), ['--clear-after', expected], String(value));
  for (const options of [undefined, null, {}]) assert.deepEqual(tail(options), ['--clear-after', '45']);
  assert.deepEqual(tail({ pasteOnce: true }), ['--clear-after', '45', '--paste-once']);
  for (const pasteOnce of [false, 'true', 1, null, undefined])
    assert.deepEqual(tail({ pasteOnce }), ['--clear-after', '45'], String(pasteOnce));
}

// 4. Input the helper would refuse builds nothing.
{
  for (const bad of ['', 'a b', 'a/b', 'a'.repeat(129), 7, null, undefined, [SHARE]]) {
    const calls = [
      Actions.copy(bad, ITEM, 'password'), Actions.copy(SHARE, bad, 'password'),
      Actions.trash(bad, ITEM), Actions.trash(SHARE, bad),
      Actions.untrash(bad, ITEM), Actions.untrash(SHARE, bad),
      Actions.create('login', bad, FORMS.login),
      Actions.recentsAdd(bad, ITEM, true), Actions.recentsAdd(SHARE, bad, true),
    ];
    assert.deepEqual(calls, calls.map(() => null), String(bad));
  }
  for (const field of ['extra:01', 'a b', '--x', 'section:1', 'section:1:01', 'extra:', 'extra:10000', 'Password', '', 0, null])
    assert.equal(Actions.copy(SHARE, ITEM, field), null, String(field));
  for (const type of ['passkey', 'Login', '', '--help', null, undefined])
    assert.equal(Actions.create(type, SHARE, { title: 't' }), null, String(type));
  for (const form of [null, undefined, 'x', '{"title":"t"}', 7, true, [], [{ title: 't' }]])
    assert.equal(Actions.create('login', SHARE, form), null, String(form));

  // The size limit counts UTF-8 bytes, not characters.
  assert.equal(Actions.MAX_FORM_BYTES, 65536);
  const overhead = Buffer.byteLength(JSON.stringify({ note: '' }));
  for (const char of ['é', '€', '\u{1f511}']) {
    const width = Buffer.byteLength(char);
    const room = Actions.MAX_FORM_BYTES - overhead;
    const exact = { note: char.repeat(Math.floor(room / width)) + 'a'.repeat(room % width) };
    assert.equal(Buffer.byteLength(JSON.stringify(exact)), Actions.MAX_FORM_BYTES);
    assert.ok(Actions.create('note', SHARE, exact), `${width}-byte at the limit`);
    const over = { note: `${exact.note}a` };
    assert.ok(JSON.stringify(over).length < Actions.MAX_FORM_BYTES);
    assert.equal(Actions.create('note', SHARE, over), null, `${width}-byte over the limit`);
  }
}

// 5. ID_RE and CREATE_TYPES match the contract and Model.js.
{
  const rule = contract.match(/^8\. Identifiers taken as arguments[^`]*`share_id`, `item_id`\) must match\s+`([^`]+)`/m);
  assert.ok(rule, 'contract rule 8');
  assert.equal(Actions.ID_RE.source, rule[1]);
  assert.deepEqual([...Actions.CREATE_TYPES].sort(), [...Model.TYPES].sort());
}

// 6. recents: the showRecents setting travels as OMAPASS_SHOW_RECENTS.
{
  for (const [show, value] of [[true, '1'], [false, '0'], [undefined, '1']]) {
    for (const call of [Actions.recentsAdd(SHARE, ITEM, show), Actions.recentsList(show), Actions.recentsClear(show)])
      assert.deepEqual(call.env, { OMAPASS_SHOW_RECENTS: value }, `${call.action} ${show}`);
  }
}

// 7. parseRecents.
{
  const entry = { share_id: SHARE, id: ITEM, time: '2026-01-01T00:00:00Z' };
  const parse = (recents) => Actions.parseRecents(JSON.stringify({ ok: true, recents }));
  assert.deepEqual(parse([entry, { ...entry, id: 'second' }]), [entry, { ...entry, id: 'second' }]);
  assert.deepEqual(parse([]), []);
  assert.deepEqual(parse([{ ...entry, title: 'extra' }]), [entry]);
  assert.deepEqual(parse([{ share_id: SHARE, id: ITEM }]), [{ share_id: SHARE, id: ITEM, time: '' }]);
  assert.deepEqual(parse([null, 'x', {}, { id: ITEM }, { share_id: SHARE }, { ...entry, id: 'a b' }, { ...entry, share_id: 'a/b' }, entry]), [entry]);
  for (const output of [
    JSON.stringify({ ok: false, error: 'failed', recents: [entry] }),
    '{"ok":true}', '{"ok":true,"recents":null}', '{"ok":true,"recents":{}}',
    'null', '', 'not json', '{"ok":true,"recents":[',
  ]) assert.equal(Actions.parseRecents(output), null, output);
}

// 8. sessionState: only the states without a usable session.
{
  for (const state of ['signed_out', 'locked', 'too_old', 'plan_required', 'missing_cli'])
    assert.equal(Actions.sessionState(state), state);
  for (const state of ['agent_session', 'failed', 'ready', 'empty', null])
    assert.equal(Actions.sessionState(state), null, String(state));
}

// 9. lock and logout empty the cache; results still in flight are dropped.
for (const state of ['locked', 'signed_out']) {
  const vault = { share_id: SHARE, vault_id: 'vid', name: 'vname' };
  const vaults = Model.parseList(JSON.stringify({ ok: true, vaults: [vault] }));
  const list = Model.parseList(JSON.stringify({
    ok: true, notice: null, vaults: [{ ...vault, ok: true, count: 1 }],
    items: [{ share_id: SHARE, id: ITEM, type: 'login', title: 't' }],
  }));
  const c = Cache.create();
  Cache.request(c, 'open', 1000, 120);
  Cache.finish(c, Cache.take(c)[0], vaults, 1000);
  Cache.finish(c, Cache.take(c)[0], list, 1000);
  assert.equal(Cache.snapshot(c).items.length, 1);
  Cache.request(c, 'manual', 2000, 120);
  Cache.finish(c, Cache.take(c)[0], vaults, 2000);
  const late = Cache.take(c);
  assert.equal(late.length, 1);

  Cache.clear(c, state);
  const cleared = Cache.snapshot(c);
  assert.equal(cleared.state, state);
  assert.deepEqual(cleared.items, []);
  assert.equal(Cache.finish(c, late[0], list, 3000), false);
  assert.deepEqual(Cache.snapshot(c), cleared);
  assert.deepEqual(Cache.take(c), []);
}

// 10. too_old on startup, end to end: the real helper against the mock pass-cli.
{
  const mocks = join(here, 'mocks');
  // Not executable would make PATH fall through to a real pass-cli.
  accessSync(join(mocks, 'pass-cli'), constants.X_OK);
  const sandbox = mkdtempSync(join(tmpdir(), 'omapass-actions-'));
  try {
    const dir = (name) => {
      const path = join(sandbox, name);
      mkdirSync(path, { recursive: true, mode: 0o700 });
      return path;
    };
    const fixtures = dir('fixtures');
    cpSync(join(here, 'fixtures', 'pass-cli'), join(fixtures, 'pass-cli'), { recursive: true });
    cpSync(join(here, 'fixtures', 'scenarios', 'too_old', 'pass-cli'), join(fixtures, 'pass-cli'), { recursive: true });
    const call = Actions.status();
    const log = join(sandbox, 'mock.log');
    // Built from scratch: nothing but PATH comes from the real environment.
    const env = {
      PATH: `${mocks}${delimiter}${process.env.PATH}`,
      HOME: dir('home'),
      XDG_RUNTIME_DIR: dir('run'),
      XDG_CONFIG_HOME: dir('config'),
      XDG_CACHE_HOME: dir('cache'),
      XDG_DATA_HOME: dir('data'),
      XDG_STATE_HOME: dir('state'),
      OMAPASS_FIXTURES: fixtures,
      OMAPASS_MOCK_LOG: log,
      OMAPASS_MOCK_STDIN_DIR: dir('pass-cli-stdin'),
      ...call.env,
    };
    const run = spawnSync(join(root, 'bin', 'omapass-helper'), call.args, { env, input: '', encoding: 'utf8', timeout: 30000 });
    assert.equal(run.error, undefined);
    assert.equal(readFileSync(log, 'utf8'), 'pass-cli --version\n', 'the mock pass-cli was used');
    assert.equal(run.stderr, '');
    const status = Model.parseStatus(run.stdout);
    assert.equal(status.state, 'too_old');
    assert.equal(Actions.sessionState(status.state), 'too_old');
  } finally {
    rmSync(sandbox, { recursive: true, force: true });
  }
}

console.log('actions tests passed');

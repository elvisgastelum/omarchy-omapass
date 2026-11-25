#!/usr/bin/env node
// Contract test: checks docs/CONTRACT.md against the fixtures. Plain node >= 20, no deps.
// Run from any directory: node tests/contract.test.mjs
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const fixtures = join(here, 'fixtures');
const pcDir = join(fixtures, 'pass-cli');
const helperDir = join(fixtures, 'helper');

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));

export function loadContract() {
  const md = readFileSync(join(root, 'docs', 'CONTRACT.md'), 'utf8');
  const m = md.match(/<!-- contract:begin -->\s*```json\n([\s\S]*?)\n```\s*<!-- contract:end -->/);
  assert.ok(m, 'contract JSON block not found in docs/CONTRACT.md');
  return JSON.parse(m[1]);
}

const C = loadContract();
const sorted = (a) => [...a].sort();
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isEmpty = (v) => v === null || v === undefined || v === '';
const typeByVariant = Object.fromEntries(Object.entries(C.types).map(([t, d]) => [d.variant, t]));

function getPath(obj, path) {
  let cur = obj;
  for (const k of path) {
    if (!isObj(cur) || !(k in cur)) return { found: false };
    cur = cur[k];
  }
  return { found: true, value: cur };
}

const variantOf = (item) => Object.keys(item.content.content)[0];

// The contract mapping: one --show-secrets item (or a title-only item) to a ListItem.
export function toListItem(item, vaultName, titleOnly = false) {
  const out = {};
  const base = { share_id: item.share_id, id: item.id, vault_id: item.vault_id, vault: vaultName };
  if (titleOnly) {
    const type = typeByVariant[item.item_type];
    return {
      ...base, type, title: item.title, username: null, email: null, urls: [],
      create_time: item.create_time, modify_time: item.modify_time, last_use_time: item.last_use_time,
      has_totp: false, secret_fields: [], fields: [],
    };
  }
  const variant = variantOf(item);
  const type = typeByVariant[variant];
  const def = C.types[type];
  const val = (p) => getPath(item, p).value;
  const display = { username: null, email: null, urls: [] };
  const lg = item.content.content.Login;
  if (def.display.username) display.username = isEmpty(lg[def.display.username]) ? null : lg[def.display.username];
  if (def.display.email) {
    const src = type === 'alias' ? item[def.display.email] : lg[def.display.email];
    display.email = isEmpty(src) ? null : src;
  }
  if (def.display.urls) display.urls = lg[def.display.urls];
  const secret = [];
  let hasTotp = false;
  for (const [name, c] of Object.entries(def.copy)) {
    if (!isEmpty(val(c.path))) {
      secret.push(name);
      if (c.totp) hasTotp = true;
    }
  }
  const dyn = [];
  const addField = (id, f) => {
    const kindKey = Object.keys(f.content)[0];
    const kind = C.extra_field_kinds[kindKey];
    if (isEmpty(f.content[kindKey])) return;
    dyn.push({ field: id, name: f.name, kind });
    if (kind === 'totp') hasTotp = true;
  };
  item.content.extra_fields.forEach((f, i) => addField(`extra:${i}`, f));
  if (C.sections_variants.includes(variant)) {
    item.content.content[variant].sections.forEach((s, si) =>
      s.section_fields.forEach((f, fi) => addField(`section:${si}:${fi}`, f)));
  }
  Object.assign(out, base, {
    type, title: item.content.title, ...display,
    create_time: item.create_time, modify_time: item.modify_time, last_use_time: item.last_use_time,
    has_totp: hasTotp, secret_fields: [...secret, ...dyn.map((d) => d.field)], fields: dyn,
  });
  return out;
}

export function buildList(titleOnly) {
  const vaults = readJson(join(pcDir, 'vault__list__--output__json.json')).vaults;
  const res = { ok: true, notice: titleOnly ? 'agent_session' : null, vaults: [], items: [] };
  for (const v of vaults) {
    const file = `item__list__--share-id__${v.share_id}__--filter-state__active__--output__json${titleOnly ? '' : '__--show-secrets'}.json`;
    const items = readJson(join(pcDir, file)).items.filter((i) => i.state.toLowerCase() !== 'trashed');
    res.vaults.push({ share_id: v.share_id, vault_id: v.vault_id, name: v.name, ok: true, count: items.length });
    for (const i of items) res.items.push(toListItem(i, v.name, titleOnly));
  }
  return res;
}

const showSecretsFiles = readdirSync(pcDir).filter((f) => /^item__list__.*--show-secrets\.json$/.test(f));
const titleOnlyFiles = readdirSync(pcDir).filter((f) => /^item__list__.*\.json$/.test(f) && !f.endsWith('--show-secrets.json'));

function run() {
  // (a) envelope tables
  assert.ok(C.errors.every((e) => e in C.exit_codes), 'errors must be in exit_codes');
  const codes = Object.values(C.exit_codes);
  assert.equal(new Set(codes).size, codes.length, 'exit codes must be unique');

  // (b) vault list
  const vl = readJson(join(pcDir, 'vault__list__--output__json.json'));
  assert.ok(vl.vaults.length > 0);
  for (const v of vl.vaults) assert.deepEqual(sorted(Object.keys(v)), sorted(C.vault_keys));

  // (c) show-secrets fixtures
  assert.ok(showSecretsFiles.length >= 2, 'expected show-secrets fixtures');
  const extraKinds = Object.keys(C.extra_field_kinds);
  const checkExtra = (f, where) => {
    assert.deepEqual(sorted(Object.keys(f)), ['content', 'name'], where);
    assert.equal(typeof f.name, 'string', where);
    const ks = Object.keys(f.content);
    assert.equal(ks.length, 1, `${where}: one content key`);
    assert.ok(extraKinds.includes(ks[0]), `${where}: kind ${ks[0]}`);
    if (ks[0] === 'Timestamp') assert.equal(typeof f.content.Timestamp, 'number', where);
    else assert.equal(typeof f.content[ks[0]], 'string', where);
  };
  const seenTypes = new Set();
  let sawTrashed = false;
  for (const file of showSecretsFiles) {
    const doc = readJson(join(pcDir, file));
    assert.deepEqual(sorted(Object.keys(doc)), ['folders', 'items'], file);
    assert.ok(Array.isArray(doc.folders) && Array.isArray(doc.items), file);
    for (const item of doc.items) {
      const where = `${file}:${item.id}`;
      const variant = variantOf(item);
      assert.equal(Object.keys(item.content.content).length, 1, `${where}: one variant`);
      const type = typeByVariant[variant];
      assert.ok(type, `${where}: unknown variant ${variant}`);
      seenTypes.add(type);
      const want = [...C.item_keys, ...(type === 'alias' ? ['alias_email'] : [])];
      assert.deepEqual(sorted(Object.keys(item)), sorted(want), where);
      for (const k of ['id', 'share_id', 'vault_id', 'state', 'create_time', 'modify_time']) assert.equal(typeof item[k], 'string', `${where}.${k}`);
      assert.ok(item.last_use_time === null || typeof item.last_use_time === 'string', where);
      assert.ok(Array.isArray(item.flags) && item.flags.every((x) => typeof x === 'string'), where);
      if (item.state === 'Trashed') sawTrashed = true;
      const c = item.content;
      assert.deepEqual(sorted(Object.keys(c)),
        sorted(['title', 'note', 'item_uuid', 'content', 'extra_fields', 'custom_icon', 'platform_specific']), where);
      assert.equal(typeof c.title, 'string', where);
      assert.equal(typeof c.note, 'string', where);
      assert.equal(c.custom_icon, null, where);
      c.extra_fields.forEach((f, i) => checkExtra(f, `${where}.extra_fields[${i}]`));
      if (c.platform_specific !== null) {
        for (const a of c.platform_specific.android.allowed_apps) {
          assert.deepEqual(sorted(Object.keys(a)), ['app_name', 'hashes', 'package_name'], where);
        }
      }
      const body = c.content[variant];
      if (variant === 'Alias' || variant === 'Note') assert.equal(body, null, where);
      else assert.ok(isObj(body), where);
      if (variant === 'Login') {
        // Copy-field keys come from the contract; the rest are the verified display/metadata keys.
        const loginCopyKeys = Object.values(C.types.login.copy).map((f) => f.path.at(-1));
        assert.deepEqual(sorted(Object.keys(body)),
          sorted([...loginCopyKeys, 'urls', 'autofill_urls', 'passkeys']), where);
        assert.ok(body.urls.every((u) => typeof u === 'string'), where);
        for (const a of body.autofill_urls) assert.deepEqual(sorted(Object.keys(a)), ['mode', 'url'], where);
        for (const p of body.passkeys) {
          assert.deepEqual(sorted(Object.keys(p)), sorted(['content', 'create_time', 'creation_data', 'credential_id', 'domain',
            'key_id', 'note', 'rp_id', 'rp_name', 'user_display_name', 'user_handle', 'user_id', 'user_name']), where);
          assert.deepEqual(sorted(Object.keys(p.creation_data)), ['app_version', 'device_name', 'os_name', 'os_version'], where);
          assert.equal(typeof p.create_time, 'number', where);
        }
      }
      if (variant === 'Identity') {
        assert.equal(Object.keys(body).length, 32 + 5, where);
        for (const k of ['extra_address_details', 'extra_contact_details', 'extra_personal_details', 'extra_work_details', 'extra_sections']) {
          assert.ok(Array.isArray(body[k]), `${where}.${k}`);
        }
        for (const k of Object.keys(body)) {
          if (Array.isArray(body[k])) { if (k !== 'extra_sections') body[k].forEach((f, i) => checkExtra(f, `${where}.${k}[${i}]`)); }
          else assert.equal(typeof body[k], 'string', `${where}.${k}`);
        }
      }
      if (variant === 'SshKey') assert.deepEqual(sorted(Object.keys(body)), ['private_key', 'public_key', 'sections'], where);
      if (variant === 'Wifi') {
        const wifiCopyKeys = Object.values(C.types.wifi.copy).map((f) => f.path.at(-1));
        assert.deepEqual(sorted(Object.keys(body)), sorted([...wifiCopyKeys, 'sections', 'security']), where);
      }
      if (variant === 'Custom') assert.deepEqual(Object.keys(body), ['sections'], where);
      if (variant === 'CreditCard') {
        assert.deepEqual(sorted(Object.keys(body)),
          sorted(['cardholder_name', 'card_type', 'number', 'verification_number', 'expiration_date', 'pin']), where);
      }
      if (C.sections_variants.includes(variant)) {
        assert.ok(Array.isArray(body.sections), where);
        body.sections.forEach((s, si) => {
          assert.deepEqual(sorted(Object.keys(s)), ['section_fields', 'section_name'], where);
          assert.equal(typeof s.section_name, 'string', where);
          s.section_fields.forEach((f, fi) => checkExtra(f, `${where}.sections[${si}].section_fields[${fi}]`));
        });
      }
      for (const [name, cf] of Object.entries(C.types[type].copy)) {
        assert.ok(getPath(item, cf.path).found, `${where}: copy path ${name} does not resolve`);
      }
    }
  }
  assert.deepEqual(sorted(seenTypes), sorted(Object.keys(C.types)), 'every contract type needs a fixture item');
  assert.ok(sawTrashed, 'a trashed fixture item is required');

  // (d) title-only fixtures
  assert.equal(titleOnlyFiles.length, showSecretsFiles.length);
  for (const file of titleOnlyFiles) {
    const doc = readJson(join(pcDir, file));
    assert.deepEqual(sorted(Object.keys(doc)), ['folders', 'items'], file);
    for (const item of doc.items) {
      assert.deepEqual(sorted(Object.keys(item)), sorted(C.title_only_item_keys), `${file}:${item.id}`);
      assert.ok(typeByVariant[item.item_type], `${file}: item_type ${item.item_type}`);
    }
  }

  // (e) templates
  for (const [type, def] of Object.entries(C.types)) {
    if (def.template === null) continue;
    const tf = join(pcDir, `item__create__${def.template}__--get-template.json`);
    assert.ok(existsSync(tf), `missing template fixture for ${type}`);
    const tpl = readJson(tf);
    for (const [name, cf] of Object.entries(def.copy)) {
      if (cf.template !== null) assert.ok(cf.template in tpl, `${type}.${name}: template key ${cf.template}`);
    }
  }

  // (f) canary discipline
  const exempt = [
    /^(id|share_id|vault_id|state|create_time|modify_time|last_use_time|alias_email)$/,
    /^flags\[\*\]$/,
    /^content\.(title|item_uuid)$/,
    /^content\.content\.Login\.(username|email)$/,
    /^content\.content\.Login\.urls\[\*\]$/,
    /^content\.content\.Login\.autofill_urls\[\*\]\.(url|mode)$/,
    /^content\.extra_fields\[\*\]\.name$/,
    /^content\.content\.Identity\.extra_\w+\[\*\]\.name$/,
    /^content\.content\.\w+\.sections\[\*\]\.section_name$/,
    /^content\.content\.\w+\.sections\[\*\]\.section_fields\[\*\]\.name$/,
    /^content\.content\.Wifi\.security$/,
    /^content\.content\.CreditCard\.card_type$/,
    /^content\.content\.Login\.passkeys\[\*\]\.(domain|rp_id|rp_name)$/,
    /^content\.content\.Login\.passkeys\[\*\]\.creation_data\.\w+$/,
  ];
  const canary = C.canary;
  const checkLeaf = (s, path, where) => {
    const ex = exempt.some((re) => re.test(path));
    if (ex) assert.ok(!/canary/i.test(s), `${where}: exempt ${path} contains canary`);
    else if (s !== '') assert.ok(s.includes(canary), `${where}: ${path} lacks ${canary}`);
    if (s.includes('@')) assert.ok(s.endsWith('@example.invalid'), `${where}: ${path} has a non-synthetic @ value`);
  };
  const walk = (v, path, where) => {
    if (typeof v === 'string') checkLeaf(v, path, where);
    else if (Array.isArray(v)) v.forEach((x) => walk(x, `${path}[*]`, where));
    else if (isObj(v)) for (const [k, x] of Object.entries(v)) walk(x, path ? `${path}.${k}` : k, where);
  };
  const idsOf = (item) => [item.id, item.share_id, item.vault_id, item.content?.item_uuid].filter((x) => x !== undefined);
  for (const file of showSecretsFiles) {
    for (const item of readJson(join(pcDir, file)).items) {
      walk(item, '', `${file}:${item.id}`);
      for (const id of idsOf(item)) assert.ok(id.startsWith(C.fixture_id_prefix), `${file}: id ${id}`);
    }
  }
  for (const file of titleOnlyFiles) {
    const text = readFileSync(join(pcDir, file), 'utf8');
    assert.ok(!/canary/i.test(text), `${file}: title-only fixture holds a canary`);
    for (const item of readJson(join(pcDir, file)).items) {
      for (const id of idsOf(item)) assert.ok(id.startsWith(C.fixture_id_prefix), `${file}: id ${id}`);
    }
  }

  // (g) derived goldens
  const keyOrder = (g) => g.items.forEach((i) => assert.deepEqual(Object.keys(i), C.list_item_keys));
  for (const [file, titleOnly] of [['list.json', false], ['list.agent_session.json', true]]) {
    const text = readFileSync(join(helperDir, file), 'utf8');
    assert.ok(!text.includes(canary), `${file} leaks ${canary}`);
    const golden = JSON.parse(text);
    assert.deepEqual(golden, buildList(titleOnly), `${file} differs from the contract mapping`);
    keyOrder(golden);
    assert.ok(!golden.items.some((i) => i.title === 'Fixture Trashed'), `${file} lists a trashed item`);
  }

  // (h) golden envelopes
  for (const f of readdirSync(helperDir).filter((n) => n.endsWith('.json'))) {
    const g = readJson(join(helperDir, f));
    assert.equal(typeof g.ok, 'boolean', f);
    if (g.ok === false) {
      assert.ok(C.errors.includes(g.error), `${f}: error ${g.error}`);
      if ('reason' in g) assert.ok(C.reasons.includes(g.reason), f);
    }
  }
  assert.equal(readJson(join(helperDir, 'error.json')).ok, false);

  // (i) scenarios
  const sc = join(fixtures, 'scenarios');
  let scenarios = 0;
  if (existsSync(sc)) {
    for (const d of readdirSync(sc)) {
      const p = join(sc, d, 'expect.json');
      if (!statSync(join(sc, d)).isDirectory() || !existsSync(p)) continue;
      const e = readJson(p);
      assert.ok(e.subcommand in C.subcommands, `${d}: subcommand ${e.subcommand}`);
      if (e.ok !== true) assert.ok(C.errors.includes(e.error), `${d}: error ${e.error}`);
      if ('reason' in e) assert.ok(C.reasons.includes(e.reason), `${d}: reason ${e.reason}`);
      scenarios++;
    }
  }
  return scenarios;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    const n = run();
    console.log(`contract.test.mjs: ok (${showSecretsFiles.length} list fixtures, ${n} scenarios)`);
  } catch (err) {
    console.error(`contract.test.mjs: FAIL: ${err.message}`);
    process.exit(1);
  }
}

// node tests/i18n.test.mjs
import { readFileSync, readdirSync } from "node:fs"
import { join, relative } from "node:path"
import { fileURLToPath } from "node:url"

const root = fileURLToPath(new URL("..", import.meta.url))
const CLDR = ["zero", "one", "two", "few", "many", "other"]
const SKIP = new Set([".git", ".plans", "node_modules"])
const REQUIRED = ["state.", "detail.", "field.login.", "field.note.", "field.creditCard.", "field.identity.",
  "field.sshKey.", "field.wifi.", "field.alias.", "field.custom.", "trash.", "undo.", "create.login.",
  "create.note.", "create.creditCard.", "create.identity.", "create.sshKey.", "create.wifi.", "create.alias.",
  "create.custom.", "create.generator.", "setup.banner.", "session.", "vault.", "settings."]
// Load-bearing keys the planned UI relies on. Keys built at runtime (strings.t("field." + type))
// escape the QML scan below, so list them here when a story adds one.
const REQUIRED_KEYS = [
  "field.login.username", "field.login.email", "field.login.password", "field.login.totp", "field.note.body",
  "field.creditCard.number", "field.creditCard.cvv", "field.creditCard.expiry", "field.creditCard.holder",
  "field.identity.name", "field.identity.email", "field.identity.phone", "field.identity.address",
  "field.sshKey.privateKey", "field.sshKey.publicKey", "field.wifi.ssid", "field.wifi.password",
  "field.alias.address", "field.custom.field",
  "trash.title", "trash.confirm", "trash.cancel", "undo.trashed", "undo.action", "undo.openTrash",
  "create.generator.random", "create.generator.passphrase", "create.generator.length",
  "create.generator.symbols", "create.generator.words", "create.creditCard.expiryInvalid",
  "create.identity.nameRequired", "create.sshKey.generate", "create.sshKey.import",
  "create.alias.prefix", "create.alias.suffix", "create.alias.mailbox",
  "create.custom.addField", "create.custom.removeField",
  "setup.banner.title", "setup.banner.keybind", "setup.banner.menu", "setup.banner.pin", "setup.banner.confirm",
  "state.signIn", "state.unlock", "session.lock", "session.logout",
  "vault.hide", "vault.unhide", "vault.showHidden",
]

const errors = []
const fail = (msg) => errors.push(msg)
const readJson = (p) => JSON.parse(readFileSync(join(root, p), "utf8"))
const isPlural = (v) => typeof v === "object" && v !== null && !Array.isArray(v)
const holders = (s) => (s.match(/%\d+/g) || []).sort().join(",")
const forms = (v) => (isPlural(v) ? Object.values(v) : [v])
const union = (v) => [...new Set(forms(v).flatMap((s) => holders(s).split(",").filter(Boolean)))].sort().join(",")

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (SKIP.has(e.name)) return []
    const p = join(dir, e.name)
    return e.isDirectory() ? walk(p) : [p]
  })
}

function checkShape(file, cat) {
  if (!isPlural(cat)) return fail(`${file}: not a flat object`)
  const str = (key, s, what) => {
    if (typeof s !== "string" || s === "") fail(`${file}: ${key}: ${what} must be a non-empty string`)
    else if (s !== s.trim()) fail(`${file}: ${key}: ${what} has leading/trailing whitespace`)
  }
  for (const [key, v] of Object.entries(cat)) {
    if (!isPlural(v)) { str(key, v, "value"); continue }
    const bad = Object.keys(v).filter((k) => !CLDR.includes(k))
    if (bad.length) fail(`${file}: ${key}: invalid plural categories ${bad.join(", ")}`)
    if (!("other" in v)) fail(`${file}: ${key}: plural lacks "other"`)
    for (const [k, s] of Object.entries(v)) str(key, s, `form ${k}`)
  }
}

function compare(file, en, cat) {
  const missing = Object.keys(en).filter((k) => !(k in cat))
  const extra = Object.keys(cat).filter((k) => !(k in en))
  if (missing.length) fail(`${file}: missing keys: ${missing.join(", ")}`)
  if (extra.length) fail(`${file}: extra keys: ${extra.join(", ")}`)
  for (const key of Object.keys(en).filter((k) => k in cat)) {
    const a = en[key], b = cat[key]
    if (isPlural(a) !== isPlural(b)) { fail(`${file}: ${key}: kind differs from en (string vs plural)`); continue }
    if (union(a) !== union(b)) fail(`${file}: ${key}: placeholders [${union(b)}] differ from en [${union(a)}]`)
    if (isPlural(b) && typeof a.other === "string") {
      for (const [k, s] of Object.entries(b)) {
        if (typeof s === "string" && holders(s) !== holders(a.other))
          fail(`${file}: ${key}.${k}: placeholders differ from en other`)
      }
    }
  }
}

function checkQmlKeys(en) {
  const re = /strings\.(tn?)\(\s*["']([^"']+)["']/g
  for (const path of walk(root).filter((p) => p.endsWith(".qml"))) {
    const lines = readFileSync(path, "utf8").split("\n")
    lines.forEach((line, i) => {
      for (const [, fn, key] of line.matchAll(re)) {
        const where = `${relative(root, path)}:${i + 1}`
        if (!(key in en)) fail(`${where}: unknown key "${key}"`)
        else if (fn === "tn" && !isPlural(en[key])) fail(`${where}: "${key}" used with tn but is not plural in en`)
      }
    })
  }
}

function checkCoverage(en) {
  for (const p of REQUIRED) {
    if (!Object.keys(en).some((k) => k.startsWith(p))) fail(`en.json: no key with prefix ${p}`)
  }
  for (const k of REQUIRED_KEYS) if (!(k in en)) fail(`en.json: missing required key ${k}`)
  for (const { key } of readJson("manifest.json").barWidget.schema) {
    for (const k of [`settings.${key}`, `settings.${key}.description`]) {
      if (!(k in en)) fail(`en.json: missing ${k} for manifest setting ${key}`)
    }
  }
}

const en = readJson("i18n/en.json")
for (const f of readdirSync(join(root, "i18n")).filter((f) => f.endsWith(".json")).sort()) {
  const cat = readJson(`i18n/${f}`)
  checkShape(`i18n/${f}`, cat)
  if (f !== "en.json" && isPlural(cat)) compare(`i18n/${f}`, en, cat)
}
checkQmlKeys(en)
checkCoverage(en)

if (errors.length) {
  console.error(`i18n tests failed (${errors.length}):\n  ` + errors.join("\n  "))
  process.exit(1)
}
console.log("i18n tests passed")

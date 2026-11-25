.pragma library
// Parses helper output per docs/CONTRACT.md into allowlisted view models.
// Pure functions, no I/O, no secrets: unknown keys are never copied through.

var STATES = ["loading", "ready", "empty", "signed_out", "locked", "too_old", "plan_required", "agent_session", "missing_cli", "failed"]
var ERROR_CODES = ["signed_out", "locked", "too_old", "plan_required", "agent_session", "network", "timeout", "not_found", "failed"]
var LIST_ITEM_KEYS = ["share_id", "id", "vault_id", "vault", "type", "title", "username", "email", "urls", "create_time", "modify_time", "last_use_time", "has_totp", "secret_fields", "fields"]
var TYPES = ["login", "alias", "note", "credit-card", "identity", "ssh-key", "wifi", "custom"]

var REASONS = ["usage", "unknown_subcommand", "missing_pass_cli", "bad_version", "bad_output", "bad_input", "bad_lib"]
var FIELD_KINDS = ["text", "hidden", "timestamp", "totp"]
var CODE_RE = /^[a-z_]{1,32}$/
// Field selectors such as "password", "extra:0" or "section:0:1".
var SELECTOR_RE = /^[a-z_]{1,32}(:[0-9]{1,4}){0,2}$/

function isObj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v)
}

function isStr(v) {
    return typeof v === "string"
}

function has(list, v) {
    return list.indexOf(v) >= 0
}

function strOr(v, d) {
    return isStr(v) ? v : d
}

function strOrNull(v) {
    return isStr(v) && v !== "" ? v : null
}

function stateFor(error, reason) {
    if (reason === "missing_pass_cli")
        return "missing_cli"
    if (isStr(error) && has(["signed_out", "locked", "too_old", "plan_required", "agent_session"], error))
        return error
    return "failed"
}

function stateKey(state) {
    switch (state) {
    case "loading": return "state.loading"
    case "ready": return ""
    case "empty": return "state.empty"
    case "signed_out": return "state.signedOut"
    case "locked": return "state.locked"
    case "too_old": return "state.tooOld"
    case "plan_required": return "state.planRequired"
    case "agent_session": return "state.agentSession"
    case "missing_cli": return "state.missingCli"
    default: return "state.failed"
    }
}

function typeKey(type) {
    switch (type) {
    case "login": return "type.login"
    case "alias": return "type.alias"
    case "note": return "type.note"
    case "credit-card": return "type.creditCard"
    case "identity": return "type.identity"
    case "ssh-key": return "type.sshKey"
    case "wifi": return "type.wifi"
    default: return "type.custom"
    }
}

function badEnvelope() {
    return { ok: false, error: "failed", code: null, reason: "bad_output", data: null }
}

// Private: carries the raw object for the parsers; never exposed publicly.
function _envelope(input) {
    var obj = input
    if (isStr(input)) {
        try {
            obj = JSON.parse(input)
        } catch (e) {
            return badEnvelope()
        }
    }
    if (!isObj(obj) || typeof obj.ok !== "boolean")
        return badEnvelope()
    if (obj.ok)
        return { ok: true, error: null, code: null, reason: null, data: obj }
    var raw = obj.error
    var code = isStr(raw) && CODE_RE.test(raw) ? raw : null
    return {
        ok: false,
        error: isStr(raw) && has(ERROR_CODES, raw) ? raw : "failed",
        code: code,
        reason: isStr(obj.reason) && has(REASONS, obj.reason) ? obj.reason : null,
        data: null
    }
}

function parseEnvelope(input) {
    var env = _envelope(input)
    return { ok: env.ok, error: env.error, code: env.code, reason: env.reason }
}

function sanitizeField(raw) {
    if (!isObj(raw) || !isStr(raw.field) || !SELECTOR_RE.test(raw.field))
        return null
    return {
        field: raw.field,
        name: strOr(raw.name, ""),
        kind: has(FIELD_KINDS, raw.kind) ? raw.kind : "text"
    }
}

function sanitizeItem(raw) {
    if (!isObj(raw) || !isStr(raw.id) || raw.id === "" || !isStr(raw.share_id) || raw.share_id === "")
        return null
    var urls = []
    var secrets = []
    var fields = []
    var i
    if (Array.isArray(raw.urls))
        for (i = 0; i < raw.urls.length; i++)
            if (isStr(raw.urls[i]))
                urls.push(raw.urls[i])
    if (Array.isArray(raw.secret_fields))
        for (i = 0; i < raw.secret_fields.length; i++)
            if (isStr(raw.secret_fields[i]) && SELECTOR_RE.test(raw.secret_fields[i]))
                secrets.push(raw.secret_fields[i])
    if (Array.isArray(raw.fields))
        for (i = 0; i < raw.fields.length; i++) {
            var f = sanitizeField(raw.fields[i])
            if (f)
                fields.push(f)
        }
    return {
        share_id: raw.share_id,
        id: raw.id,
        vault_id: strOr(raw.vault_id, ""),
        vault: strOr(raw.vault, ""),
        type: has(TYPES, raw.type) ? raw.type : "custom",
        title: strOr(raw.title, ""),
        username: strOrNull(raw.username),
        email: strOrNull(raw.email),
        urls: urls,
        create_time: strOr(raw.create_time, ""),
        modify_time: strOr(raw.modify_time, ""),
        last_use_time: strOrNull(raw.last_use_time),
        has_totp: raw.has_totp === true,
        secret_fields: secrets,
        fields: fields
    }
}

function count(v) {
    return typeof v === "number" && isFinite(v) && v >= 0 && Math.floor(v) === v ? v : 0
}

function sanitizeVault(raw) {
    if (!isObj(raw) || !isStr(raw.share_id) || raw.share_id === "")
        return null
    var ok = raw.ok !== false
    return {
        share_id: raw.share_id,
        vault_id: strOr(raw.vault_id, ""),
        name: strOr(raw.name, ""),
        ok: ok,
        count: count(raw.count),
        error: ok ? null : (isStr(raw.error) && has(ERROR_CODES, raw.error) ? raw.error : "failed")
    }
}

function parseList(input) {
    var env = _envelope(input)
    if (!env.ok)
        return { state: stateFor(env.error, env.reason), error: env.error, code: env.code, reason: env.reason, notice: null, vaults: [], failedVaults: [], items: [] }
    var data = env.data
    var items = []
    var vaults = []
    var failed = []
    var seen = {}
    var i
    var rawItems = Array.isArray(data.items) ? data.items : []
    var rawVaults = Array.isArray(data.vaults) ? data.vaults : []
    for (i = 0; i < rawItems.length; i++) {
        var it = sanitizeItem(rawItems[i])
        if (!it)
            continue
        var key = it.share_id + "/" + it.id
        if (Object.prototype.hasOwnProperty.call(seen, key))
            continue
        seen[key] = true
        items.push(it)
    }
    for (i = 0; i < rawVaults.length; i++) {
        var v = sanitizeVault(rawVaults[i])
        if (!v)
            continue
        vaults.push(v)
        if (!v.ok)
            failed.push(v)
    }
    var notice = data.notice === "agent_session" ? "agent_session" : null
    return {
        state: notice ? "agent_session" : (items.length === 0 ? "empty" : "ready"),
        error: null, code: null, reason: null,
        notice: notice, vaults: vaults, failedVaults: failed, items: items
    }
}

function parseStatus(input) {
    var env = _envelope(input)
    if (!env.ok)
        return { state: stateFor(env.error, env.reason), error: env.error, code: env.code, reason: env.reason, pass_cli: null, min_pass_cli: null, vaults: 0 }
    var d = env.data
    return {
        state: d.state === "ready" ? "ready" : "failed",
        error: null, code: null, reason: null,
        pass_cli: strOrNull(d.pass_cli),
        min_pass_cli: strOrNull(d.min_pass_cli),
        vaults: count(d.vaults)
    }
}

function parseVersion(input) {
    var env = _envelope(input)
    if (!env.ok)
        return { ok: false, state: stateFor(env.error, env.reason), error: env.error, code: env.code, reason: env.reason, pass_cli: null, min_pass_cli: null }
    return {
        ok: true, state: "ready",
        error: null, code: null, reason: null,
        pass_cli: strOrNull(env.data.pass_cli),
        min_pass_cli: strOrNull(env.data.min_pass_cli)
    }
}

function filterByType(items, type) {
    var out = []
    for (var i = 0; i < items.length; i++)
        if (!type || type === "all" || items[i].type === type)
            out.push(items[i])
    return out
}

// Score one token against one text: higher is better, -1 means no match.
function tokenScore(token, text) {
    var t = text.toLowerCase()
    var at = t.indexOf(token)
    if (at === 0)
        return 1000
    if (at > 0)
        return /[a-z0-9]/.test(t.charAt(at - 1)) ? 500 : 750
    var pos = 0
    var first = -1
    var last = -1
    var run = 0
    var bonus = 0
    for (var i = 0; i < token.length; i++) {
        var found = t.indexOf(token.charAt(i), pos)
        if (found < 0)
            return -1
        if (first < 0)
            first = found
        run = found === last + 1 && i > 0 ? run + 1 : 0
        bonus += run * 10
        last = found
        pos = found + 1
    }
    var gaps = last - first + 1 - token.length
    // Stay strictly below the lowest substring tier (500).
    return Math.min(499, Math.max(1, 100 + bonus - gaps * 5))
}

function fuzzyScore(query, item) {
    var q = String(query === undefined || query === null ? "" : query).replace(/^\s+|\s+$/g, "").toLowerCase()
    if (q === "")
        return 0
    var tokens = q.split(/\s+/)
    var hay = []
    var i
    var j
    hay.push({ text: strOr(item.title, ""), weight: 1 })
    hay.push({ text: strOr(item.username, ""), weight: 0.7 })
    hay.push({ text: strOr(item.email, ""), weight: 0.7 })
    var urls = Array.isArray(item.urls) ? item.urls : []
    for (i = 0; i < urls.length; i++)
        hay.push({ text: strOr(urls[i], ""), weight: 0.4 })
    var total = 0
    var subCount = 0
    for (i = 0; i < tokens.length; i++) {
        var best = -1
        for (j = 0; j < hay.length; j++) {
            var s = tokenScore(tokens[i], hay[j].text)
            if (s < 0)
                continue
            // Tier-first: substring (s >= 500) adds 1000, so it beats any subsequence field (<= 499);
            // weight only orders fields within a tier.
            var fs = (s >= 500 ? 1000 : 0) + Math.max(1, Math.round(s * hay[j].weight))
            if (fs > best)
                best = fs
        }
        if (best < 0)
            return -1
        if (best >= 1000)
            subCount++
        total += best // multi-token: sum of each token's best field score
    }
    // More substring-matched tokens always ranks first; per-token sums stay far below 1e6.
    return subCount * 1000000 + total
}

function search(items, query, type) {
    var base = filterByType(items, type)
    var q = String(query === undefined || query === null ? "" : query).replace(/^\s+|\s+$/g, "")
    if (q === "")
        return base
    var scored = []
    for (var i = 0; i < base.length; i++) {
        var s = fuzzyScore(q, base[i])
        if (s >= 0)
            scored.push({ item: base[i], score: s, title: strOr(base[i].title, "").toLowerCase(), index: i })
    }
    scored.sort(function (a, b) {
        if (a.score !== b.score)
            return b.score - a.score
        if (a.title !== b.title)
            return a.title < b.title ? -1 : 1
        return a.index - b.index
    })
    return scored.map(function (e) { return e.item })
}

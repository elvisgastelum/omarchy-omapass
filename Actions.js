.pragma library
// Builds the helper call for each user action (docs/CONTRACT.md) as {action, args, stdin, env}.
// Pure functions. Only validated ids, field selectors, type names and numbers reach `args`; form
// values, which may be secret, are only ever in `stdin`. A builder returns null for input the
// helper would refuse, so nothing is run.

var ID_RE = /^[A-Za-z0-9_=-]{1,128}$/
// A copy field name, or a dynamic field: extra:<i> or section:<s>:<f>.
var FIELD_RE = /^([a-z_]{1,32}|extra:(0|[1-9][0-9]{0,3})|section:(0|[1-9][0-9]{0,3}):(0|[1-9][0-9]{0,3}))$/
var CREATE_TYPES = ["login", "alias", "note", "credit-card", "identity", "ssh-key", "wifi", "custom"]
var MAX_FORM_BYTES = 65536
var DEFAULT_CLEAR_SECONDS = 45
var MAX_CLEAR_SECONDS = 300
// States in which there is no usable session. Not agent_session: its title-only list is valid.
var SESSION_STATES = ["signed_out", "locked", "too_old", "plan_required", "missing_cli"]

function _id(v) {
    return typeof v === "string" && ID_RE.test(v)
}

function _call(action, args, stdin, env) {
    return { action: action, args: args, stdin: stdin === undefined ? null : stdin, env: env || {} }
}

function status() {
    return _call("status", ["status"])
}

// options: {clipboardClearSeconds, pasteOnce}, as Cache.settings returns them.
function copy(shareId, itemId, field, options) {
    if (!_id(shareId) || !_id(itemId) || typeof field !== "string" || !FIELD_RE.test(field))
        return null
    var o = options || {}
    var seconds = o.clipboardClearSeconds
    seconds = typeof seconds === "number" && isFinite(seconds) && seconds >= 0
        ? Math.min(MAX_CLEAR_SECONDS, Math.floor(seconds)) : DEFAULT_CLEAR_SECONDS
    var args = ["copy", shareId, itemId, field, "--clear-after", String(seconds)]
    if (o.pasteOnce === true)
        args.push("--paste-once")
    return _call("copy", args)
}

function _item(action, shareId, itemId) {
    return _id(shareId) && _id(itemId) ? _call(action, [action, shareId, itemId]) : null
}

function trash(shareId, itemId) {
    return _item("trash", shareId, itemId)
}

function untrash(shareId, itemId) {
    return _item("untrash", shareId, itemId)
}

function lock() {
    return _call("lock", ["lock"])
}

function logout() {
    return _call("logout", ["logout"])
}

function login() {
    return _call("login", ["login"])
}

function unlock() {
    return _call("unlock", ["unlock"])
}

function create(type, shareId, form) {
    if (CREATE_TYPES.indexOf(type) < 0 || !_id(shareId))
        return null
    if (form === null || typeof form !== "object" || typeof form.length === "number")
        return null
    var json
    var bytes
    try {
        json = JSON.stringify(form)
        // One character per UTF-8 byte; throws on a lone surrogate.
        bytes = encodeURIComponent(json).replace(/%[0-9A-F]{2}/g, "x").length
    } catch (e) {
        return null
    }
    return bytes <= MAX_FORM_BYTES ? _call("create", ["create", type, "--share-id", shareId], json) : null
}

function _recents(action, args, show) {
    return _call(action, ["recents"].concat(args), null, { OMAPASS_SHOW_RECENTS: show === false ? "0" : "1" })
}

function recentsAdd(shareId, itemId, show) {
    return _id(shareId) && _id(itemId) ? _recents("recentsAdd", ["add", shareId, itemId], show) : null
}

function recentsList(show) {
    return _recents("recentsList", ["list"], show)
}

function recentsClear(show) {
    return _recents("recentsClear", ["clear"], show)
}

// The recents of any successful `recents` call, or null when the output is not one.
function parseRecents(output) {
    var data
    try {
        data = JSON.parse(output)
    } catch (e) {
        return null
    }
    if (!data || data.ok !== true || !data.recents || typeof data.recents.length !== "number")
        return null
    var out = []
    for (var i = 0; i < data.recents.length; i++) {
        var r = data.recents[i]
        if (r && _id(r.share_id) && _id(r.id))
            out.push({ share_id: r.share_id, id: r.id, time: typeof r.time === "string" ? r.time : "" })
    }
    return out
}

// state: a Model.stateFor value. Returns it when it means there is no usable session, else null.
function sessionState(state) {
    return SESSION_STATES.indexOf(state) >= 0 ? state : null
}

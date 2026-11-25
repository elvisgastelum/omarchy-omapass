.pragma library
// In-memory metadata cache and refresh rules. Pure state machine: no I/O, no timers, nothing
// written to disk. Service.qml runs the jobs from take() and reports each one back to finish()
// with the Model.parseList result of the helper's output.
//
// Every refresh and every clear() starts a new generation; a job of an older generation only frees
// its slot, its result is dropped. `running` counts jobs of all generations, so the limit holds
// while stale helper processes are still alive.

var MAX_CALLS = 4
var DEFAULT_MAX_AGE_SECONDS = 120

function create() {
    return {
        generation: 0,
        running: 0,
        queue: [],
        outstanding: 0,     // unfinished jobs of the current generation
        inFlight: false,
        failed: false,      // some job of the current generation failed
        vaults: [],         // {share_id, vault_id, name, items, error, notice}
        hidden: [],
        updatedAt: 0,       // ms of the last refresh in which every call succeeded
        dirty: true,        // the next open must refresh whatever the age
        settled: false,     // some refresh has finished since the last clear
        sessionState: null, // locked, signed_out, too_old, ... while there is no usable session
        error: null         // error of the last `vaults` call
    }
}

function _isList(v) {
    return v !== null && typeof v === "object" && typeof v.length === "number"
}

function _indexOfVault(vaults, shareId) {
    for (var i = 0; i < vaults.length; i++)
        if (vaults[i].share_id === shareId)
            return i
    return -1
}

// share_ids from an array, or from a string holding a JSON array.
function _idList(v) {
    if (typeof v === "string") {
        try {
            v = JSON.parse(v)
        } catch (e) {
            return []
        }
    }
    var out = []
    if (!_isList(v))
        return out
    for (var i = 0; i < v.length; i++)
        if (typeof v[i] === "string" && v[i] !== "" && out.indexOf(v[i]) < 0)
            out.push(v[i])
    return out
}

function _seconds(v) {
    return typeof v === "number" && isFinite(v) && v >= 0 ? v : null
}

function _barEntry(barConfig, pluginId) {
    var layout = barConfig && barConfig.layout
    if (!layout || typeof layout !== "object")
        return null
    for (var section in layout) {
        var entries = layout[section]
        if (!_isList(entries))
            continue
        for (var i = 0; i < entries.length; i++)
            if (entries[i] && entries[i].id === pluginId)
                return entries[i]
    }
    return null
}

// Widget settings are keys of the plugin's bar layout entry; the manifest holds the defaults.
function settings(barConfig, pluginId, defaults) {
    var d = defaults || {}
    var entry = _barEntry(barConfig, pluginId) || {}
    var age = _seconds(entry.refreshMaxAgeSeconds)
    if (age === null)
        age = _seconds(d.refreshMaxAgeSeconds)
    return {
        hidden: _idList(entry.hiddenVaults !== undefined ? entry.hiddenVaults : d.hiddenVaults),
        maxAge: age === null ? DEFAULT_MAX_AGE_SECONDS : age
    }
}

function _begin(c) {
    c.generation += 1
    c.queue = [{ kind: "vaults", shareId: null, generation: c.generation }]
    c.outstanding = 1
    c.inFlight = true
    c.failed = false
    c.error = null
}

// reason "open" refreshes only a dirty or old cache with no refresh in flight. Every other reason
// ("manual", "create", "trash", "untrash") always starts over, so that a result fetched before the
// change is never kept. Returns true when a refresh started.
function request(c, reason, now, maxAgeSeconds) {
    if (reason === "open") {
        if (c.inFlight)
            return false
        if (!c.dirty && now - c.updatedAt < maxAgeSeconds * 1000)
            return false
    } else {
        c.dirty = true
    }
    _begin(c)
    return true
}

// The jobs to start now; each one must end in exactly one finish() call.
function take(c) {
    var jobs = []
    while (c.running < MAX_CALLS && c.queue.length > 0) {
        jobs.push(c.queue.shift())
        c.running += 1
    }
    return jobs
}

function args(job) {
    return job.kind === "list" ? ["list", "--share-id", job.shareId] : ["vaults"]
}

// Empties the cache and drops whatever is still in flight. Call it on lock and logout.
function clear(c, sessionState) {
    c.generation += 1
    c.queue = []
    c.outstanding = 0
    c.inFlight = false
    c.failed = false
    c.vaults = []
    c.updatedAt = 0
    c.dirty = true
    c.settled = false
    c.sessionState = sessionState || null
    c.error = null
}

// Returns true when the caller should refresh now: a vault was unhidden after a load, or the set
// changed under a refresh in flight. Newly hidden vaults are dropped at once.
function setHidden(c, hidden) {
    var next = _idList(hidden)
    var unhid = c.hidden.some(function(id) { return next.indexOf(id) < 0 })
    var hid = next.some(function(id) { return c.hidden.indexOf(id) < 0 })
    if (!unhid && !hid)
        return false
    c.hidden = next
    c.vaults = c.vaults.filter(function(v) { return next.indexOf(v.share_id) < 0 })
    if (unhid)
        c.dirty = true
    return c.inFlight || (unhid && c.settled)
}

function _finishVaults(c, result) {
    if (result.error) {
        c.failed = true
        c.error = result.error
        return
    }
    var next = []
    for (var i = 0; i < result.vaults.length; i++) {
        var v = result.vaults[i]
        if (c.hidden.indexOf(v.share_id) >= 0 || _indexOfVault(next, v.share_id) >= 0)
            continue
        var at = _indexOfVault(c.vaults, v.share_id)
        var old = at < 0 ? null : c.vaults[at]
        next.push({
            share_id: v.share_id,
            vault_id: v.vault_id,
            name: v.name,
            items: old ? old.items : [],
            error: old ? old.error : null,
            notice: old ? old.notice : false
        })
        // One call per visible vault: a bare `list` would also fetch the hidden ones.
        c.queue.push({ kind: "list", shareId: v.share_id, generation: c.generation })
        c.outstanding += 1
    }
    c.vaults = next
    c.sessionState = null
}

function _finishList(c, shareId, result) {
    var at = _indexOfVault(c.vaults, shareId)
    if (at < 0)
        return
    var vault = c.vaults[at]
    var error = result.error
    if (!error) {
        var reported = _indexOfVault(result.vaults, shareId)
        if (reported >= 0 && !result.vaults[reported].ok)
            error = result.vaults[reported].error
    }
    if (error === "not_found") {
        c.vaults.splice(at, 1)
        return
    }
    if (error) {
        // The old items stay.
        vault.error = error
        c.failed = true
        return
    }
    vault.items = result.items.filter(function(it) { return it.share_id === shareId })
    vault.error = null
    vault.notice = result.notice === "agent_session"
}

// result: a Model.parseList value, or {error: "timeout", state: "failed"}. Returns false when the
// job belonged to an older generation and its result was dropped.
function finish(c, job, result, now) {
    c.running = Math.max(0, c.running - 1)
    if (job.generation !== c.generation)
        return false
    // An error that maps to its own state means the session is unusable: keep no items.
    if (result.error && result.state !== "failed") {
        clear(c, result.state)
        return true
    }
    c.outstanding -= 1
    if (job.kind === "vaults")
        _finishVaults(c, result)
    else
        _finishList(c, job.shareId, result)
    if (c.outstanding === 0) {
        c.inFlight = false
        c.settled = true
        if (!c.failed) {
            c.updatedAt = now
            c.dirty = false
        }
    }
    return true
}

function _state(c, count, notice) {
    if (c.sessionState)
        return c.sessionState
    if (count > 0)
        return notice ? "agent_session" : "ready"
    if (c.inFlight)
        return "loading"
    if (c.error || (c.vaults.length > 0 && c.vaults.every(function(v) { return v.error !== null })))
        return "failed"
    return c.settled ? "empty" : "loading"
}

// A fresh copy of what the UI shows.
function snapshot(c) {
    var items = []
    var vaults = []
    var failed = []
    var notice = null
    for (var i = 0; i < c.vaults.length; i++) {
        var v = c.vaults[i]
        var out = { share_id: v.share_id, vault_id: v.vault_id, name: v.name, ok: v.error === null, count: v.items.length, error: v.error }
        vaults.push(out)
        if (!out.ok)
            failed.push(out)
        if (v.notice)
            notice = "agent_session"
        items = items.concat(v.items)
    }
    return {
        state: _state(c, items.length, notice),
        items: items,
        vaults: vaults,
        failedVaults: failed,
        notice: notice,
        error: c.error,
        refreshing: c.inFlight,
        updatedAt: c.updatedAt
    }
}

// Counts only, safe to print: no titles, names, ids or field values.
function info(c, now) {
    var s = snapshot(c)
    return {
        state: s.state,
        items: s.items.length,
        vaults: s.vaults.length,
        failedVaults: s.failedVaults.length,
        error: s.error,
        refreshing: s.refreshing,
        calls: c.running,
        ageSeconds: c.updatedAt > 0 ? Math.floor((now - c.updatedAt) / 1000) : null
    }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Actions.js" as Actions
import "Cache.js" as Cache
import "Model.js" as Model

Item {
  id: root

  // Injected by the shell after createObject; never read at construction.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "elvisgastelum.omapass"
  readonly property string skeletonValue: "service ok"

  readonly property string helperPath: decodeURIComponent(
    Qt.resolvedUrl("bin/omapass-helper").toString().replace(/^file:\/\//, ""))
  // Backstop for a hung helper: it already times out each pass-cli call, and one list run makes
  // up to four of them.
  readonly property int callTimeoutMs: 120000

  // Metadata only, held in memory. publish() copies it out of the cache after every change.
  readonly property var cache: Cache.create()
  property var items: []
  property var vaults: []
  property var failedVaults: []
  property string cacheState: "loading"
  property string notice: ""
  property string refreshError: ""
  property bool refreshing: false
  property real updatedAt: 0
  property int maxAgeSeconds: Cache.DEFAULT_MAX_AGE_SECONDS
  // `bar` of the user's shell.json; null until read, or when there is none.
  property var userBar: null

  // Ids and times only.
  property var recents: []
  property int lastRequestId: 0
  // "lock" or "logout" from the request until the helper returns.
  property string sessionPending: ""
  property bool sessionStarted: false
  property int sessionRequestId: 0
  property int copiesPending: 0

  // result: a Model.parseEnvelope value. Every non-zero request id gets exactly one of these.
  signal actionFinished(int requestId, string action, var result)

  Component.onCompleted: root.checkStatus()

  function toggleOverlay() {
    if (root.shell && typeof root.shell.toggle === "function")
      root.shell.toggle(root.pluginId, "")
  }

  function openOverlay() {
    if (root.shell && typeof root.shell.summon === "function")
      root.shell.summon(root.pluginId, "")
  }

  function closeOverlay() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  // The overlay shows the cached properties at once; this only decides whether to fetch.
  function overlayOpened() {
    root.refresh("open")
  }

  // reason: "open", "manual", "create", "trash" or "untrash".
  function refresh(reason) {
    // A lock or logout in progress must not be followed by a fetch.
    if (root.sessionPending !== "")
      return
    var restart = root.applySettings()
    Cache.request(root.cache, restart ? "manual" : (reason || "manual"), Date.now(), root.maxAgeSeconds)
    root.pump()
    root.publish()
  }

  // For lock and logout: empties the cache and drops whatever is still in flight.
  function clearCache(sessionState) {
    Cache.clear(root.cache, sessionState)
    root.publish()
  }

  function readSettings() {
    var defaults = root.manifest && root.manifest.barWidget ? root.manifest.barWidget.defaults : null
    var bar = root.userBar || (root.shell ? root.shell.barConfig : null)
    return Cache.settings(bar, root.pluginId, defaults)
  }

  function applySettings() {
    var s = root.readSettings()
    root.maxAgeSeconds = s.maxAge
    return Cache.setHidden(root.cache, s.hidden)
  }

  function settingsChanged() {
    var restart = root.applySettings()
    if (restart && root.sessionPending === "") {
      Cache.request(root.cache, "manual", Date.now(), root.maxAgeSeconds)
      root.pump()
    }
    root.publish()
  }

  // Runs the helper once; handler(stdout, timedOut) is called exactly once.
  function run(args, input, env, handler) {
    var call = helperCall.createObject(root, {
      argv: [root.helperPath].concat(args),
      input: input,
      extraEnv: env || ({}),
      handler: handler
    })
    if (!call)
      handler("", false)
  }

  function pump() {
    if (root.sessionPending !== "")
      return
    Cache.take(root.cache).forEach(root.startJob)
  }

  function startJob(job) {
    root.run(Cache.args(job), null, null, function(output, timedOut) {
      root.callFinished(job, output, timedOut)
    })
  }

  function callFinished(job, output, timedOut) {
    var result = timedOut ? { state: "failed", error: "timeout" } : Model.parseList(output)
    Cache.finish(root.cache, job, result, Date.now())
    root.pump()
    root.publish()
  }

  // Actions. Each returns a request id for actionFinished, or 0 when nothing was done because
  // the arguments are invalid.

  function copyField(shareId, itemId, field) {
    var request = Actions.copy(shareId, itemId, field, root.readSettings())
    if (!request)
      return 0
    if (root.sessionBlocked())
      return root.reject(request.action)
    root.copiesPending += 1
    return root.perform(request, function(result) {
      root.copiesPending -= 1
      root.noteSessionError(result)
      root.startSessionCall()
    })
  }

  function trashItem(shareId, itemId) { return root.changeItem(Actions.trash(shareId, itemId)) }
  function untrashItem(shareId, itemId) { return root.changeItem(Actions.untrash(shareId, itemId)) }
  // form may hold secrets: it goes to the helper on stdin and is not kept.
  function createItem(type, shareId, form) { return root.changeItem(Actions.create(type, shareId, form)) }

  function lockSession() { return root.endSession("lock") }
  function logoutSession() { return root.endSession("logout") }
  // These only open a terminal. Call checkStatus() afterwards.
  function login() { return root.perform(Actions.login()) }
  function unlock() { return root.perform(Actions.unlock()) }

  function addRecent(shareId, itemId) {
    return root.recentsCall(Actions.recentsAdd(shareId, itemId, root.readSettings().showRecents))
  }
  function listRecents() { return root.recentsCall(Actions.recentsList(root.readSettings().showRecents)) }
  function clearRecents() { return root.recentsCall(Actions.recentsClear(root.readSettings().showRecents)) }

  // The startup check, also for after login or unlock. `status` checks the pass-cli version first.
  function checkStatus() {
    if (root.sessionPending !== "")
      return 0
    var generation = root.cache.generation
    return root.perform(Actions.status(), function(result, output) {
      // A refresh or a clear since then knows better.
      if (generation !== root.cache.generation || root.sessionPending !== "")
        return
      var state = Model.parseStatus(output).state
      if (Actions.sessionState(state)) {
        Cache.clear(root.cache, state)
        root.publish()
      } else if (state === "ready" && root.cache.sessionState) {
        Cache.clear(root.cache, null)
        root.refresh("manual")
      }
    })
  }

  function perform(request, done) {
    if (!request)
      return 0
    var id = ++root.lastRequestId
    var action = request.action
    var input = request.stdin
    request.stdin = null
    root.run(request.args, input, request.env, function(output, timedOut) {
      var result = root.resultOf(output, timedOut)
      if (done)
        done(result, output)
      root.actionFinished(id, action, result)
    })
    input = null
    return id
  }

  function resultOf(output, timedOut) {
    return timedOut ? { ok: false, error: "timeout", code: "timeout", reason: null }
      : Model.parseEnvelope(output)
  }

  // True while an item action must not run: ending the session, or no usable session.
  function sessionBlocked() {
    return root.sessionPending !== "" || Actions.sessionState(root.cache.sessionState) !== null
  }

  function reject(action) {
    var id = ++root.lastRequestId
    Qt.callLater(function() {
      root.actionFinished(id, action, { ok: false, error: "failed", code: null, reason: null })
    })
    return id
  }

  // Empties the cache when the result says the session is gone; returns true if it did.
  function noteSessionError(result) {
    var state = result.ok ? null : Actions.sessionState(Model.stateFor(result.error, result.reason))
    if (!state)
      return false
    root.clearCache(state)
    return true
  }

  function changeItem(request) {
    if (!request)
      return 0
    var action = request.action
    if (root.sessionBlocked())
      return root.reject(action)
    return root.perform(request, function(result) {
      // Even a failed or timed-out change may have happened. Not if the session ended meanwhile.
      if (!root.noteSessionError(result) && !root.sessionBlocked())
        root.refresh(action)
    })
  }

  function recentsCall(request) {
    return root.perform(request, function(result, output) {
      var list = Actions.parseRecents(output)
      if (list)
        root.recents = list
    })
  }

  // The cache is emptied at once; the helper also clears the clipboard.
  function endSession(kind) {
    if (root.sessionPending !== "")
      return 0
    root.sessionPending = kind
    root.sessionRequestId = ++root.lastRequestId
    root.clearCache(null)
    root.startSessionCall()
    return root.sessionRequestId
  }

  // Waits for pending copies: one finishing after the helper cleared the clipboard would leave
  // its secret there.
  function startSessionCall() {
    if (root.sessionPending === "" || root.sessionStarted || root.copiesPending > 0)
      return
    root.sessionStarted = true
    var kind = root.sessionPending
    var id = root.sessionRequestId
    var request = kind === "lock" ? Actions.lock() : Actions.logout()
    root.run(request.args, null, null, function(output, timedOut) {
      var result = root.resultOf(output, timedOut)
      root.sessionPending = ""
      root.sessionStarted = false
      var state = result.ok ? (kind === "lock" ? "locked" : "signed_out")
        : Actions.sessionState(Model.stateFor(result.error, result.reason))
      root.clearCache(state)
      // The session may well be alive (no lock configured, network): fetch again.
      if (!state)
        root.refresh("manual")
      root.actionFinished(id, kind, result)
    })
  }

  function publish() {
    var s = Cache.snapshot(root.cache)
    root.items = s.items
    root.vaults = s.vaults
    root.failedVaults = s.failedVaults
    root.cacheState = s.state
    root.notice = s.notice || ""
    root.refreshError = s.error || ""
    root.refreshing = s.refreshing
    root.updatedAt = s.updatedAt
  }

  // shell.barConfig reaches a third-party plugin one config change late (Omarchy 4.5), so the
  // settings are read from the file itself.
  FileView {
    id: userConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var bar = Cache.userBar(userConfig.text())
      // A half-written file keeps the last good settings.
      if (bar === undefined)
        return
      root.userBar = bar
      root.settingsChanged()
    }
    // No file: the shell runs on its defaults, which shell.barConfig holds.
    onLoadFailed: {
      root.userBar = null
      root.settingsChanged()
    }
  }

  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onBarConfigChanged() { root.settingsChanged() }
  }

  // One helper process. It reports back exactly once, then destroys itself.
  Component {
    id: helperCall

    Item {
      id: call

      property var argv: []
      // Written to stdin once and dropped; null leaves stdin closed.
      property var input: null
      property var extraEnv: ({})
      property var handler: null
      property bool reported: false
      property bool timedOut: false

      function report() {
        if (call.reported)
          return
        call.reported = true
        backstop.stop()
        killer.stop()
        call.handler(collector.text, call.timedOut)
        call.destroy()
      }

      Component.onCompleted: {
        backstop.start()
        process.stdinEnabled = call.input !== null
        process.running = true
      }

      Process {
        id: process
        command: call.argv
        environment: call.extraEnv
        onStarted: {
          if (call.input === null)
            return
          process.write(call.input)
          call.input = null
          // Closes stdin, which `create` reads to its end.
          process.stdinEnabled = false
        }
        stdout: StdioCollector { id: collector }
        onExited: call.report()
        // A command that cannot start never emits exited; callLater lets exited go first.
        onRunningChanged: if (!running) Qt.callLater(call.report)
      }

      // SIGTERM first, so the helper's own exit trap removes its temp files.
      Timer {
        id: backstop
        interval: root.callTimeoutMs
        onTriggered: {
          call.timedOut = true
          if (!process.running) {
            call.report()
            return
          }
          process.signal(15)
          killer.start()
        }
      }

      Timer {
        id: killer
        interval: 5000
        onTriggered: process.signal(9)
      }
    }
  }

  ShellIpc {
    target: "omapass"

    function toggle(): void { root.toggleOverlay() }
    function open(): void { root.openOverlay() }
    function close(): void { root.closeOverlay() }
    function refresh(): void { root.refresh("manual") }
    function cacheInfo(): string { return JSON.stringify(Cache.info(root.cache, Date.now())) }
    function lock(): void { root.lockSession() }
    function logout(): void { root.logoutSession() }
  }
}

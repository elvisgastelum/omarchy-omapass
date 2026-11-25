import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
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

  function applySettings() {
    var defaults = root.manifest && root.manifest.barWidget ? root.manifest.barWidget.defaults : null
    var bar = root.userBar || (root.shell ? root.shell.barConfig : null)
    var s = Cache.settings(bar, root.pluginId, defaults)
    root.maxAgeSeconds = s.maxAge
    return Cache.setHidden(root.cache, s.hidden)
  }

  function settingsChanged() {
    if (root.applySettings()) {
      Cache.request(root.cache, "manual", Date.now(), root.maxAgeSeconds)
      root.pump()
    }
    root.publish()
  }

  function pump() {
    var jobs = Cache.take(root.cache)
    for (var i = 0; i < jobs.length; i++) {
      var call = helperCall.createObject(root, {
        job: jobs[i],
        argv: [root.helperPath].concat(Cache.args(jobs[i]))
      })
      if (!call)
        Cache.finish(root.cache, jobs[i], Model.parseList(""), Date.now())
    }
  }

  function callFinished(job, output, timedOut) {
    var result = timedOut ? { state: "failed", error: "timeout" } : Model.parseList(output)
    Cache.finish(root.cache, job, result, Date.now())
    root.pump()
    root.publish()
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

      property var job: null
      property var argv: []
      property bool reported: false
      property bool timedOut: false

      function report() {
        if (call.reported)
          return
        call.reported = true
        backstop.stop()
        killer.stop()
        root.callFinished(call.job, collector.text, call.timedOut)
        call.destroy()
      }

      Component.onCompleted: {
        backstop.start()
        process.running = true
      }

      Process {
        id: process
        command: call.argv
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
  }
}

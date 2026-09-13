import QtQuick
import Quickshell
import Quickshell.Io
import "Spectra.js" as Spectra

// Finds every Spectra project directly under `projectsRoot` and keeps one
// Project per hit. Discovery is one `find`; nothing here polls.
Scope {
  id: root

  property string projectsRoot: "~/projects"
  // One or more folders, `:`-separated; an empty setting means the default.
  readonly property var roots: {
    var list = Spectra.splitRoots(projectsRoot, Quickshell.env("HOME"))
    return list.length > 0 ? list : Spectra.splitRoots("~/projects", Quickshell.env("HOME"))
  }

  // [{id, name}] in name order, from the last scan.
  property var records: []
  property bool scanned: false
  readonly property bool scanning: findProcess.running

  // Project objects in the same order as `records`.
  property var projects: []

  // A rescan asked for mid-scan runs again afterwards: the running `find`
  // was started with the roots of that moment.
  property bool rescanPending: false

  function rescan() {
    if (findProcess.running) { rescanPending = true; return }
    findProcess.running = true
  }

  // Rescan, then refresh every project's change list.
  function refreshAll() {
    refreshAfterScan = true
    rescan()
  }
  property bool refreshAfterScan: false

  Process {
    id: findProcess
    running: false
    // -L: a symlinked project directory counts like a real one. A root that
    // does not exist only earns a stderr line; the others still list.
    command: ["find", "-L"].concat(root.roots).concat(["-mindepth", "2", "-maxdepth", "2", "-name", ".spectra.yaml"])
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        root.applyScan(findProcess.stdout.text)
        if (root.rescanPending) { root.rescanPending = false; root.rescan() }
      })
    }
  }

  function applyScan(output) {
    var next = Spectra.labelProjects(Spectra.projectsFromFind(output))
    // Same paths, same objects: rebuilding the Instantiator would drop every
    // loaded change list just to recreate identical projects.
    if (JSON.stringify(next) !== JSON.stringify(records)) records = next
    scanned = true
    if (refreshAfterScan) {
      refreshAfterScan = false
      // Read the live objects: a rescan that dropped projects leaves stale
      // entries in `projects` until the Instantiator has settled.
      for (var i = 0; i < instantiator.count; i++) {
        var obj = instantiator.objectAt(i)
        if (obj && typeof obj.refresh === "function") obj.refresh()
      }
    }
  }

  Instantiator {
    id: instantiator
    model: root.records

    delegate: Project {
      required property var modelData
      path: modelData.id
    }

    // Add/remove arrive one object at a time; rebuild once the batch settles.
    onObjectAdded: Qt.callLater(root.syncProjects)
    onObjectRemoved: Qt.callLater(root.syncProjects)
  }

  function syncProjects() {
    var list = []
    for (var i = 0; i < instantiator.count; i++) {
      var obj = instantiator.objectAt(i)
      if (obj) list.push(obj)
    }
    projects = list
  }

  // Roots that are not directories, for the editor's hint line. One `sh`
  // per check; the paths ride in argv so no shell string sees them.
  property var missingRoots: []

  // A check requested while one runs is kept and run afterwards, so the
  // hint always reflects the last list asked about.
  property var pendingCheck: null

  function checkRoots(list) {
    if (checkProcess.running) { pendingCheck = list; return }
    checkProcess.command = ["sh", "-c", 'for d in "$@"; do [ -d "$d" ] || printf "%s\n" "$d"; done', "sh"].concat(list)
    checkProcess.running = true
  }

  Process {
    id: checkProcess
    running: false
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        root.missingRoots = String(checkProcess.stdout.text).split("\n").filter(function(l) { return l.trim() !== "" })
        if (root.pendingCheck !== null) { var next = root.pendingCheck; root.pendingCheck = null; root.checkRoots(next) }
      })
    }
  }

  // ---- folder browser ----------------------------------------------------
  //
  // One level at a time: the subfolders of `browseDir` and which of them hold
  // a `.spectra.yaml` one level down, from a single `sh` (paths ride in argv).

  property bool browsing: false
  property string browseDir: ""
  property var browseEntries: []
  property string browseError: ""
  property string browseQueued: ""

  function browseTo(dir) {
    var d = String(dir || "").replace(/\/+$/, "") || "/"
    browsing = true
    if (browseProcess.running) { browseQueued = d; return }
    browseDir = d
    browseError = ""
    browseProcess.command = ["sh", "-c",
      'find -L "$1" -mindepth 1 -maxdepth 1 -type d ! -name ".*" && echo -- && find -L "$1" -mindepth 2 -maxdepth 2 -name .spectra.yaml 2>/dev/null',
      "sh", d]
    browseProcess.running = true
  }

  function browseUp() { browseTo(Spectra.parentDir(browseDir)) }

  function closeBrowser() {
    browsing = false
    browseEntries = []
    browseError = ""
  }

  Process {
    id: browseProcess
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        if (exitCode === 0) {
          root.browseEntries = Spectra.parseBrowse(browseProcess.stdout.text)
          root.browseError = ""
        } else {
          root.browseEntries = []
          root.browseError = "無法讀取"
        }
        if (root.browseQueued !== "") { var next = root.browseQueued; root.browseQueued = ""; root.browseTo(next) }
      })
    }
  }

  // Chip label for a project path: its name, or `<root>/<name>` on a clash.
  function labelFor(path) {
    if (!path) return ""
    for (var i = 0; i < records.length; i++)
      if (records[i].id === path) return records[i].label
    return path.slice(path.lastIndexOf("/") + 1)
  }

  function projectAt(path) {
    for (var i = 0; i < projects.length; i++)
      if (projects[i].path === path) return projects[i]
    return null
  }
}

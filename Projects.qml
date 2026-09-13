import QtQuick
import Quickshell
import Quickshell.Io
import "Spectra.js" as Spectra

// Finds every Spectra project directly under `projectsRoot` and keeps one
// Project per hit. Discovery is one `find`; nothing here polls.
Scope {
  id: root

  property string projectsRoot: "~/projects"
  readonly property string rootPath: Spectra.expandHome(projectsRoot, Quickshell.env("HOME"))

  // [{id, name}] in name order, from the last scan.
  property var records: []
  property bool scanned: false
  readonly property bool scanning: findProcess.running

  // Project objects in the same order as `records`.
  property var projects: []

  function rescan() {
    if (findProcess.running) return
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
    command: ["find", root.rootPath, "-mindepth", "2", "-maxdepth", "2", "-name", ".spectra.yaml"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() { root.applyScan(findProcess.stdout.text) })
    }
  }

  function applyScan(output) {
    var next = Spectra.projectsFromFind(output)
    // Same paths, same objects: rebuilding the Instantiator would drop every
    // loaded change list just to recreate identical projects.
    if (JSON.stringify(next) !== JSON.stringify(records)) records = next
    scanned = true
    if (refreshAfterScan) {
      refreshAfterScan = false
      for (var i = 0; i < projects.length; i++) projects[i].refresh()
    }
  }

  Instantiator {
    id: instantiator
    model: root.records

    delegate: Project {
      required property var modelData
      path: modelData.id
    }

    onObjectAdded: root.syncProjects()
    onObjectRemoved: root.syncProjects()
  }

  function syncProjects() {
    var list = []
    for (var i = 0; i < instantiator.count; i++) list.push(instantiator.objectAt(i))
    projects = list
  }

  function projectAt(path) {
    for (var i = 0; i < projects.length; i++)
      if (projects[i].path === path) return projects[i]
    return null
  }
}

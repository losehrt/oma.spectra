import QtQuick
import Quickshell
import Quickshell.Io
import "Spectra.js" as Spectra

// One Spectra project: its `.spectra.yaml` (read, and rewritten one line at a
// time for the five editable settings), the change lists its CLI reports, the
// artifact status of whichever change the panel is looking at, and the
// `update` run. See Spectra.js for the CLI allowlist.
Scope {
  id: project

  required property string path
  readonly property string name: path.slice(path.lastIndexOf("/") + 1)

  property string cli: Spectra.DEFAULT_CLI
  property string specDir: path + "/" + Spectra.DEFAULT_SPEC_DIR
  property string configError: ""
  property bool configLoaded: false
  // Stays true after the first read so the settings section does not vanish
  // for the length of every refresh.
  property bool configEverLoaded: false

  // The rest of `.spectra.yaml`, as displayed in the settings section.
  property string locale: ""
  property bool tdd: false
  property bool audit: false
  property bool experience: false
  property var tools: []
  // Why the last setting write was refused or failed; "" after a success.
  property string settingError: ""
  property string settingErrorKey: ""

  // `list --json` result. `changes` is the CLI's own entries untouched;
  // `listError` is the one line shown instead of the list when it failed.
  property var changes: []
  property string listError: ""
  property bool listLoaded: false
  readonly property bool listing: listProcess.running

  // `status --change X --json` results keyed by change name.
  property var artifactsByChange: ({})

  readonly property string error: configError !== "" ? configError : listError

  FileView {
    id: configFile
    path: project.path + "/.spectra.yaml"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      // Start the write outside the load handler: a write started inside it
      // replaces the still-finishing read and its `saved` never arrives.
      if (project.pendingWrite) { var current = text(); Qt.callLater(function() { project.commitPendingWrite(current) }) }
      else project.applyConfig(text())
    }
    onLoadFailed: function(error) {
      if (project.pendingWrite) {
        project.pendingWrite = null
        project.writeQueue = []
        project.settingError = "無法讀取 .spectra.yaml (" + error + ")"
      }
      project.configError = "cannot read .spectra.yaml (" + error + ")"
      project.configLoaded = true
      if (project.refreshPending) project.runRefresh()
    }
    // Same rule for whatever follows a write: start it after the handler.
    onSaved: project.finishWrite()
    onSaveFailed: function(error) {
      project.settingError = "無法寫入 .spectra.yaml"
      project.writeQueue = []
      project.finishWrite()
    }
  }

  function applyConfig(text) {
    var config = Spectra.parseConfig(text)
    cli = config.cli
    specDir = path + "/" + config.specDir.replace(/\/+$/, "")
    locale = config.locale
    tdd = config.tdd
    audit = config.audit
    experience = config.experience
    tools = config.tools
    configError = Spectra.configError(config)
    configLoaded = true
    configEverLoaded = true
    if (refreshPending) runRefresh()
  }

  // ---- settings writes --------------------------------------------------
  //
  // A write re-reads the file first so a concurrent terminal edit is rewritten
  // rather than clobbered, then rewrites one line and lets `saved` trigger the
  // normal refresh. The screen only ever shows what the file says.

  // Writes queue up: two quick toggles become two rewrites in order, each
  // against the file as the previous one left it.
  property var pendingWrite: null
  property var writeQueue: []
  readonly property bool writing: pendingWrite !== null

  function saveSetting(key, value) {
    var reason = Spectra.validateSetting(key, value)
    settingErrorKey = key
    if (reason !== "") { settingError = reason; return reason }
    settingError = ""
    writeQueue = writeQueue.concat([{ key: key, value: String(value).trim() }])
    startNextWrite()
    return ""
  }

  function startNextWrite() {
    if (pendingWrite !== null || writeQueue.length === 0) return
    pendingWrite = writeQueue[0]
    writeQueue = writeQueue.slice(1)
    configFile.reload()
  }

  function commitPendingWrite(text) {
    configFile.setText(Spectra.setConfigKey(text, pendingWrite.key, pendingWrite.value))
  }

  function finishWrite() {
    pendingWrite = null
    if (writeQueue.length > 0) Qt.callLater(startNextWrite)
    else Qt.callLater(refresh)
  }

  property bool refreshPending: false

  // Every refresh re-reads `.spectra.yaml` first, so a fixed config (or a
  // changed spec_dir) takes effect on the next `r` rather than the next
  // shell restart; `applyConfig` continues into `runRefresh` when it lands.
  function refresh() {
    refreshPending = true
    configLoaded = false
    configFile.reload()
  }

  function runRefresh() {
    refreshPending = false
    if (configError !== "") { changes = []; listLoaded = true; return }
    loadSpecs()
    loadArchived()
    if (listProcess.running || parkedProcess.running) return
    activeResult = null
    parkedResult = null
    listProcess.exited = false
    parkedProcess.exited = false
    listProcess.running = true
    parkedProcess.running = true
  }

  // Each listing lands on its own; the list is rebuilt once both are in.
  property var activeResult: null
  property var parkedResult: null

  function mergeListings() {
    if (activeResult === null || parkedResult === null) return
    var failed = activeResult.error !== "" ? activeResult : (parkedResult.error !== "" ? parkedResult : null)
    if (failed) {
      listError = failed.error
      changes = []
    } else {
      listError = ""
      changes = activeResult.entries.map(function(e) { return Object.assign({ parked: false }, e) })
        .concat(parkedResult.entries.map(function(e) { return Object.assign({}, e, { parked: true, status: "parked" }) }))
    }
    listLoaded = true
  }

  function listingResult(exitCode, out, err) {
    return Spectra.listingOutcome(exitCode, out, err, cli)
  }

  Process {
    id: listProcess
    running: false
    command: Spectra.cliCommand(project.cli, ["list", "--json", "--no-color"], project.path)
    workingDirectory: project.path
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }

    // A binary that is not on PATH never reaches `exited`: `running` just
    // drops back to false. Whichever signal lands, the panel hears about it.
    property bool exited: false
    onStarted: exited = false
    onExited: function(exitCode, exitStatus) {
      exited = true
      // Collectors flush on their own schedule; read them after this turn.
      Qt.callLater(function() {
        project.activeResult = project.listingResult(exitCode, listProcess.stdout.text, listProcess.stderr.text)
        project.mergeListings()
      })
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (!listProcess.exited && !listProcess.running) { project.activeResult = project.startFailure(); project.mergeListings() }
    })
  }

  Process {
    id: parkedProcess
    running: false
    command: Spectra.cliCommand(project.cli, ["list", "--parked", "--json", "--no-color"], project.path)
    workingDirectory: project.path
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    property bool exited: false
    onStarted: exited = false
    onExited: function(exitCode, exitStatus) {
      exited = true
      Qt.callLater(function() {
        project.parkedResult = project.listingResult(exitCode, parkedProcess.stdout.text, parkedProcess.stderr.text)
        project.mergeListings()
      })
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (!parkedProcess.exited && !parkedProcess.running) { project.parkedResult = project.startFailure(); project.mergeListings() }
    })
  }

  function startFailure() {
    return { entries: [], error: Spectra.startFailureMessage(cli) }
  }

  // ---- instruction-file update -----------------------------------------
  //
  // `<cli> update` regenerates the tool instruction files (.claude/skills/...).
  // Measured on spxa 0.1.1: it rewrites the generated SKILL.md files even
  // without --force, so hand edits there do not survive it (see README).

  readonly property bool updating: updateProcess.running
  property string updateResult: ""

  function runUpdate() {
    if (configError !== "") { updateResult = configError; return configError }
    if (updateProcess.running) return "already running"
    updateResult = ""
    updateProcess.exited = false
    updateProcess.running = true
    return ""
  }

  Process {
    id: updateProcess
    running: false
    command: Spectra.cliCommand(project.cli, ["update", "--no-color"], project.path)
    workingDirectory: project.path
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    property bool exited: false
    onStarted: exited = false
    onExited: function(exitCode, exitStatus) {
      exited = true
      Qt.callLater(function() {
        var out = Spectra.firstLine(updateProcess.stdout.text)
        var err = Spectra.firstLine(updateProcess.stderr.text)
        project.updateResult = exitCode === 0
          ? (out || err || project.cli + " update finished")
          : Spectra.isCliNotFound(exitCode, updateProcess.stderr.text, project.cli) ? Spectra.startFailureMessage(project.cli)
          : (err || out || project.cli + " update exited with code " + exitCode)
      })
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (!updateProcess.exited && !updateProcess.running) project.updateResult = project.startFailure().error
    })
  }

  // ---- archived changes ---------------------------------------------------
  //
  // `spxa list` has no archived view; the archive is a directory listing.

  property var archived: []
  property bool archivedLoaded: false

  function loadArchived() {
    if (configError !== "" || archivedProcess.running) return
    archivedProcess.running = true
  }

  Process {
    id: archivedProcess
    running: false
    command: ["find", project.specDir + "/changes/archive", "-mindepth", "1", "-maxdepth", "1", "-type", "d"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        // A missing archive directory is an empty list, not an error.
        project.archived = exitCode === 0 ? Spectra.archivedFromFind(archivedProcess.stdout.text) : []
        project.archivedLoaded = true
      })
    }
  }

  // Where a change's files live. Archived changes are addressed by their
  // directory name (`YYYY-MM-DD-name`), which cannot collide with an active
  // change name of the same text.
  function changeDir(changeKey) {
    var entry = archivedEntry(changeKey)
    return entry ? entry.dir : specDir + "/changes/" + changeKey
  }

  function archivedEntry(changeKey) {
    for (var i = 0; i < archived.length; i++)
      if (archived[i].key === changeKey) return archived[i]
    return null
  }

  // Artifact status for an archived change comes from which files exist.
  property string filesChange: ""
  property string filesQueued: ""

  function loadArtifactFiles(entry) {
    if (!entry) return
    if (filesProcess.running) { filesQueued = entry.key; return }
    filesChange = entry.key
    filesProcess.command = ["find", entry.dir, "-maxdepth", "1", "-name", "*.md"]
    filesProcess.running = true
  }

  Process {
    id: filesProcess
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        var names = Spectra.basenamesFromFind(filesProcess.stdout.text)
        var next = Object.assign({}, project.artifactsByChange)
        next[project.filesChange] = { artifacts: Spectra.artifactsFromFiles(names) }
        project.artifactsByChange = next
        if (project.filesQueued !== "") {
          var queued = project.archivedEntry(project.filesQueued)
          project.filesQueued = ""
          project.loadArtifactFiles(queued)
        }
      })
    }
  }

  // ---- spec listings ----------------------------------------------------

  // Delta spec capability names keyed by change name, and the project's own
  // archived specs. Both come from one `find` each.
  property var deltaSpecsByChange: ({})
  property var specNames: []
  property bool specsLoaded: false

  function loadDeltaSpecs(changeName) {
    if (configError !== "" || !changeName) return
    if (deltaProcess.running) { deltaQueued = changeName; return }
    deltaChange = changeName
    deltaProcess.running = true
  }
  property string deltaChange: ""
  property string deltaQueued: ""

  Process {
    id: deltaProcess
    running: false
    command: ["find", project.changeDir(project.deltaChange) + "/specs", "-mindepth", "2", "-maxdepth", "2", "-name", "spec.md"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        var next = Object.assign({}, project.deltaSpecsByChange)
        next[project.deltaChange] = Spectra.capabilitiesFromFind(deltaProcess.stdout.text)
        project.deltaSpecsByChange = next
        if (project.deltaQueued !== "") {
          var queued = project.deltaQueued
          project.deltaQueued = ""
          project.loadDeltaSpecs(queued)
        }
      })
    }
  }

  function loadSpecs() {
    if (configError !== "" || specsProcess.running) return
    specsProcess.running = true
  }

  Process {
    id: specsProcess
    running: false
    command: ["find", project.specDir + "/specs", "-mindepth", "2", "-maxdepth", "2", "-name", "spec.md"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        project.specNames = Spectra.capabilitiesFromFind(specsProcess.stdout.text)
        project.specsLoaded = true
      })
    }
  }

  // ---- artifact status --------------------------------------------------

  property string statusChange: ""

  function loadStatus(changeName) {
    if (configError !== "" || !changeName) return
    var archivedOne = archivedEntry(changeName)
    if (archivedOne) { loadArtifactFiles(archivedOne); return }
    if (statusProcess.running) { statusQueued = changeName; return }
    statusChange = changeName
    statusProcess.running = true
  }
  property string statusQueued: ""

  Process {
    id: statusProcess
    running: false
    command: Spectra.cliCommand(project.cli, ["status", "--change", project.statusChange, "--json", "--no-color"], project.path)
    workingDirectory: project.path
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        var artifacts = exitCode === 0 ? Spectra.parseStatus(statusProcess.stdout.text) : null
        var next = Object.assign({}, project.artifactsByChange)
        next[project.statusChange] = artifacts === null
          ? { error: Spectra.isCliNotFound(exitCode, statusProcess.stderr.text, project.cli) ? Spectra.startFailureMessage(project.cli)
                     : (Spectra.firstLine(statusProcess.stderr.text) || (project.cli + " status exited with code " + exitCode)) }
          : { artifacts: artifacts }
        project.artifactsByChange = next
        if (project.statusQueued !== "") {
          var queued = project.statusQueued
          project.statusQueued = ""
          project.loadStatus(queued)
        }
      })
    }
  }
}

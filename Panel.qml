import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Spectra.js" as Spectra

// Spectra: a window onto the Spectra changes and specs of every project under
// one folder. The bar owns the icon; the popup owns the rest. The only writes
// are the project's own `.spectra.yaml` settings and `<cli> update`; change
// and spec content stays read-only.
Panel {
  id: root
  moduleName: "oma.spectra"
  ipcTarget: "oma.spectra"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var projectList: projects.projects
  // Selection follows the project path, not its slot: a rescan that reorders
  // the chips must not swap out what is being read.
  property string selectedProjectPath: ""
  readonly property int projectIndex: {
    for (var i = 0; i < projectList.length; i++)
      if (projectList[i].path === selectedProjectPath) return i
    return 0
  }
  readonly property var project: projectList.length > 0 ? projectList[projectIndex] : null

  property bool cursorActive: false

  // ---- keyboard cursor --------------------------------------------------
  //
  // One cursor over one actionable item. Rows follow the visual order and are
  // recomputed from what is on screen; the cursor is a (row, col) pair that is
  // clamped whenever the rows change, so it never points at something gone.
  readonly property var settingKeys: ["locale", "tdd", "audit", "experience", "cli_command"]
  readonly property var cursorRows: {
    var rows = []
    var p = project
    if (projectList.length > 1) rows.push({ kind: "project", items: projectList.map(function(q) { return projects.labelFor(q.path) }) })
    var artifactRows = []
    if (selectedChange && contentExpanded) {
      artifactRows.push({ kind: "tab", items: artifactTabs })
      if (selectedSpec === "" && selectedTab === "specs" && deltaSpecs.length > 0) artifactRows.push({ kind: "delta", items: deltaSpecs })
    }
    if (p && p.error === "") {
      for (var i = 0; i < p.changes.length; i++) rows.push({ kind: "change", items: [p.changes[i].name] })
      if (selectedChange && !selectedChange.archived) rows = rows.concat(artifactRows)
      if (p.archived.length > 0) {
        rows.push({ kind: "archived-header", items: ["archived"] })
        if (archivedExpanded) for (var a = 0; a < p.archived.length; a++) rows.push({ kind: "archived", items: [p.archived[a].key] })
        if (selectedChange && selectedChange.archived) rows = rows.concat(artifactRows)
      }
    }
    if (p && p.error === "") {
      rows.push({ kind: "specs-header", items: ["specs"] })
      // One row per spec now that they are listed vertically.
      if (specsExpanded) for (var n = 0; n < p.specNames.length; n++) rows.push({ kind: "spec", items: [p.specNames[n]] })
    }
    if (p && p.configEverLoaded) {
      rows.push({ kind: "settings-header", items: ["settings"] })
      if (settingsExpanded) {
        for (var k = 0; k < settingKeys.length; k++) rows.push({ kind: "setting", items: [settingKeys[k]] })
        rows.push({ kind: "update", items: ["update"] })
      }
    }
    return rows
  }
  property int cursorRow: 0
  property int cursorCol: 0
  readonly property var cursorItem: cursorRows.length > 0 ? cursorRows[clamp(cursorRow, 0, cursorRows.length - 1)] : null
  readonly property string cursorKind: cursorItem ? cursorItem.kind : ""
  readonly property string cursorLabel: cursorItem ? String(cursorItem.items[clamp(cursorCol, 0, cursorItem.items.length - 1)]) : ""

  // Rows come and go (a delta row appears, a change gets parked): keep the
  // cursor on the same item when it still exists, and only then clamp.
  onCursorRowsChanged: {
    // Lists land after the panel opens; until the first project or change row
    // exists, keep re-applying the opening placement instead of re-anchoring.
    if (cursorPlacementPending) { placeCursorOnOpen(); return }
    if (!setCursor(cursorKind, cursorLabel, true)) clampCursor()
  }
  property bool cursorPlacementPending: false

  function clampCursor() {
    if (cursorRows.length === 0) { cursorRow = 0; cursorCol = 0; return }
    cursorRow = clamp(cursorRow, 0, cursorRows.length - 1)
    cursorCol = clamp(cursorCol, 0, cursorRows[cursorRow].items.length - 1)
  }

  function cursorAt(kind, item) {
    return cursorActive && cursorKind === kind && cursorLabel === String(item)
  }

  function setCursor(kind, item, keepActive) {
    for (var r = 0; r < cursorRows.length; r++) {
      if (cursorRows[r].kind !== kind) continue
      var c = cursorRows[r].items.indexOf(item)
      if (c >= 0) { if (!keepActive) cursorActive = true; cursorRow = r; cursorCol = c; return true }
    }
    return false
  }

  function moveCursor(dx, dy) {
    if (cursorRows.length === 0) return
    cursorActive = true
    if (dy !== 0) {
      cursorRow = clamp(cursorRow + dy, 0, cursorRows.length - 1)
      // Landing on the project row puts the cursor on the active project, so
      // the next h/l switches rather than merely catching up.
      cursorCol = cursorRows[cursorRow].kind === "project"
        ? projectIndex
        : clamp(cursorCol, 0, cursorRows[cursorRow].items.length - 1)
    }
    if (dx !== 0) {
      cursorCol = clamp(cursorCol + dx, 0, cursorRows[cursorRow].items.length - 1)
      // The project row keeps the old h/l feel: moving along it switches too.
      if (cursorRows[cursorRow].kind === "project") selectProject(cursorCol)
    }
    scrollToCursor()
  }

  function activateCursor() {
    var item = cursorItem
    if (!item) return
    cursorActive = true
    var label = cursorLabel
    switch (item.kind) {
    case "project": selectProject(cursorCol); break
    case "change": case "archived":
      // Re-activating the selected row folds it — unless a spec is showing,
      // in which case it brings the change's own content back.
      if (label === selectedChangeName && selectedSpec === "") contentExpanded = !contentExpanded
      else selectChange(label)
      break
    case "archived-header": archivedExpanded = !archivedExpanded; break
    case "tab": selectTab(artifactTabs.indexOf(label)); break
    case "delta": selectedSpec = ""; selectedDeltaSpec = label; break
    case "spec":
      if (label === selectedSpec) contentExpanded = !contentExpanded
      else selectSpec(label)
      break
    case "specs-header": specsExpanded = !specsExpanded; break
    case "settings-header": settingsExpanded = !settingsExpanded; break
    case "setting":
      if (!project) break
      if (label === "locale") localeDropdown.open()
      else if (label === "cli_command") cliDropdown.open()
      else project.saveSetting(label, project[label] === true ? "false" : "true")
      break
    case "update": if (project && project.configError === "" && !project.updating) project.runUpdate(); break
    }
  }

  // Cursor targets register themselves so the panel can scroll to them.
  property var cursorTargets: ({})
  function registerCursorTarget(kind, item, target) {
    var next = Object.assign({}, cursorTargets); next[kind + "/" + item] = target; cursorTargets = next
  }
  // A rebuilt delegate registers before the old one is destroyed, so only the
  // owner of an entry may remove it.
  function unregisterCursorTarget(kind, item, target) {
    var key = kind + "/" + item
    if (cursorTargets[key] !== target) return
    var next = Object.assign({}, cursorTargets); delete next[key]; cursorTargets = next
  }
  function scrollToCursor() {
    var target = cursorTargets[cursorKind + "/" + cursorLabel]
    if (!target || !panelFlick) return
    var top = target.mapToItem(column, 0, 0).y
    var bottom = top + target.height
    var pad = Style.space(12)
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    if (top - pad < panelFlick.contentY) panelFlick.contentY = clamp(top - pad, 0, maxY)
    else if (bottom + pad > panelFlick.contentY + panelFlick.height) panelFlick.contentY = clamp(bottom + pad - panelFlick.height, 0, maxY)
  }

  function pageScroll(direction) {
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = clamp(panelFlick.contentY + direction * panelFlick.height * 0.8, 0, maxY)
  }

  // Where the cursor lands when the panel opens: the active project chip, or
  // the first row when there is only one project.
  function placeCursorOnOpen() {
    cursorActive = true
    cursorRow = 0
    cursorCol = cursorRows.length > 0 && cursorRows[0].kind === "project" ? projectIndex : 0
    var settled = cursorRows.length > 0 && (cursorRows[0].kind === "project" || cursorRows[0].kind === "change")
    cursorPlacementPending = !settled
    if (!settled) cursorPlacementTimeout.restart()
  }
  Timer { id: cursorPlacementTimeout; interval: 1500; onTriggered: root.cursorPlacementPending = false }
  // Settings are an occasional thing: the section starts folded on every open.
  property bool settingsExpanded: false
  // So does the archive: it only grows, and it is rarely what you opened for.
  property bool archivedExpanded: false
  // And the project specs: a growing list you consult, not glance at.
  property bool specsExpanded: false
  // The selected change's artifact area; folds when its row is activated again.
  property bool contentExpanded: true

  // Expanding grows the panel below the fold, which is exactly where the eye
  // is not. Bring the section header to the top of the viewport instead.
  property bool settingsScrollPending: false
  onSettingsExpandedChanged: if (settingsExpanded) { settingsScrollPending = true; settingsScroll.restart() }

  function scrollToSettings() {
    if (!settingsSection.visible) return
    var y = settingsSection.mapToItem(column, 0, 0).y - Style.space(12)
    panelFlick.contentY = root.clamp(y, 0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
  }

  // The body and the window both grow over a few layout passes; follow each
  // height change while the scroll is pending, and stop after a beat.
  Connections {
    target: panelFlick
    function onContentHeightChanged() { if (root.settingsScrollPending) root.scrollToSettings() }
    function onHeightChanged() { if (root.settingsScrollPending) root.scrollToSettings() }
  }
  Timer {
    id: settingsScroll
    interval: 200
    onTriggered: { root.scrollToSettings(); root.settingsScrollPending = false }
  }

  // What is being read. A change plus one of its artifact tabs, or one of
  // the project's own specs; the content viewer follows `contentPath`.
  readonly property var artifactTabs: ["proposal", "design", "specs", "tasks"]
  property string selectedChangeName: ""
  property string selectedTab: "proposal"
  property string selectedDeltaSpec: ""
  property string selectedSpec: ""

  readonly property var selectedChange: {
    if (!project) return null
    for (var i = 0; i < project.changes.length; i++)
      if (project.changes[i].name === selectedChangeName) return project.changes[i]
    for (var j = 0; j < project.archived.length; j++)
      if (project.archived[j].key === selectedChangeName) return project.archived[j]
    return null
  }
  readonly property var statusEntry: project && selectedChangeName !== "" ? (project.artifactsByChange[selectedChangeName] || null) : null
  readonly property var artifacts: statusEntry && statusEntry.artifacts ? statusEntry.artifacts : []
  readonly property var deltaSpecs: project && selectedChangeName !== "" ? (project.deltaSpecsByChange[selectedChangeName] || []) : []

  function artifactStatus(id) {
    // An archived change has no `status --json`; its specs tab follows the
    // delta-spec listing that runs for every selection anyway.
    if (id === "specs" && selectedChange && selectedChange.archived)
      return { id: "specs", outputPath: "specs/**/*.md", status: deltaSpecs.length > 0 ? "done" : "missing" }
    for (var i = 0; i < artifacts.length; i++)
      if (artifacts[i].id === id) return artifacts[i]
    return null
  }

  // A change that left every list (archived, parked, project switched) takes
  // its selection with it; the content area must not point at its old path.
  onSelectedChangeChanged: if (!selectedChange && selectedChangeName !== "" && pendingSelect === "") {
    selectedChangeName = ""
    selectedDeltaSpec = ""
  }

  readonly property string contentPath: {
    if (!project) return ""
    if (selectedSpec !== "") return project.specDir + "/specs/" + selectedSpec + "/spec.md"
    if (selectedChangeName === "" || !selectedChange) return ""
    var base = project.changeDir(selectedChangeName)
    if (selectedTab === "specs")
      return selectedDeltaSpec !== "" ? base + "/specs/" + selectedDeltaSpec + "/spec.md" : ""
    var entry = artifactStatus(selectedTab)
    return base + "/" + (entry && entry.outputPath ? entry.outputPath : selectedTab + ".md")
  }
  property string contentText: ""
  property bool contentMissing: false

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectChange(name) {
    selectedSpec = ""
    selectedChangeName = name
    selectedDeltaSpec = ""
    contentExpanded = true
    if (project && name !== "") {
      project.loadStatus(name)
      project.loadDeltaSpecs(name)
    }
  }

  function selectTab(index) {
    var wrapped = ((index % artifactTabs.length) + artifactTabs.length) % artifactTabs.length
    selectedSpec = ""
    selectedTab = artifactTabs[wrapped]
  }

  function selectSpec(name) {
    specsExpanded = true
    contentExpanded = true
    selectedSpec = name
  }

  onProjectChanged: {
    selectedChangeName = ""
    selectedDeltaSpec = ""
    selectedSpec = ""
    applyPendingSelect()
  }

  // The first delta spec is the natural landing spot for the specs tab.
  onDeltaSpecsChanged: if (selectedDeltaSpec === "" && deltaSpecs.length > 0) selectedDeltaSpec = deltaSpecs[0]

  FileView {
    id: contentFile
    path: root.contentPath
    watchChanges: false
    printErrors: false
    onPathChanged: { root.contentText = ""; root.contentMissing = false }
    onLoaded: { root.contentText = text(); root.contentMissing = false }
    onLoadFailed: function(error) { root.contentText = ""; root.contentMissing = true }
  }

  function selectProject(index) {
    if (projectList.length === 0) return
    var wrapped = ((index % projectList.length) + projectList.length) % projectList.length
    selectedProjectPath = projectList[wrapped].path
    if (cursorKind === "project") cursorCol = wrapped
  }

  // Settings of this widget (not of a project) are persisted the way the
  // clock panel does it: apply locally, then hand the entry to the shell,
  // which writes shell.json and pushes the same values back to the widget.
  property string persistWarning: ""

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if ("hostWidget" in root && root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
      persistWarning = ""
    } else {
      persistWarning = "未寫入 shell.json（widget 不在 bar layout）"
    }
  }

  // "" on success, otherwise the reason shown under the field.
  function setRoots(value) {
    var v = String(value || "").trim()
    if (Spectra.splitRoots(v, Quickshell.env("HOME")).length === 0) return "至少要一個資料夾"
    persistSettings({ projectsRoot: v })
    projects.checkRoots(projects.roots)
    projects.refreshAll()
    return ""
  }

  function refreshNow() {
    projects.refreshAll()
    if (project && selectedChangeName !== "") {
      project.loadStatus(selectedChangeName)
      project.loadDeltaSpecs(selectedChangeName)
    }
    if (contentFile.path !== "") contentFile.reload()
  }

  // A scripted `select` can arrive before discovery has produced a project;
  // it waits here until the change list that names it lands.
  property string pendingSelect: ""

  function applyPendingSelect() {
    if (pendingSelect === "") return
    // Whichever project lists the change wins, the active one first.
    var order = project ? [project] : []
    for (var p = 0; p < projectList.length; p++)
      if (projectList[p] !== project) order.push(projectList[p])
    for (var o = 0; o < order.length; o++) {
      var candidate = order[o]
      var all = candidate.changes.concat(candidate.archived)
      for (var i = 0; i < all.length; i++) {
        // Active entries come first, so a name that is both active and
        // archived resolves to the active one; `key` addresses an archive.
        if (all[i].name === pendingSelect || all[i].key === pendingSelect) {
          pendingSelect = ""
          if (candidate !== project) selectedProjectPath = candidate.path
          if (all[i].archived) archivedExpanded = true
          selectChange(all[i].archived ? all[i].key : all[i].name)
          return
        }
      }
    }
  }

  // Lists land per project in any order; each arrival is a chance to apply.
  Connections {
    target: projects
    function onProjectsChanged() { root.applyPendingSelect() }
  }
  Instantiator {
    model: root.projectList
    delegate: Connections {
      required property var modelData
      target: modelData
      function onChangesChanged() { root.applyPendingSelect() }
      function onArchivedChanged() { root.applyPendingSelect() }
    }
  }

  // The one way out of the panel: a terminal in the selected project, where
  // the writing tools (Claude Code, the CLI) live. The path is a directory
  // name from disk, so it goes through execArgv rather than a shell string.
  function openTerminal() {
    if (!project) return
    Util.execArgv(["setsid", "uwsm-app", "--", "xdg-terminal-exec", "--dir=" + project.path])
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProjectIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    settingsExpanded = false
    archivedExpanded = false
    specsExpanded = false
    contentExpanded = true
    placeCursorOnOpen()
    if (panelFlick) panelFlick.contentY = 0
    refreshNow()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Projects {
    id: projects
    projectsRoot: root.setting("projectsRoot", "~/projects")
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProject(root.projectIndex + 1); return "ok" }
    // Scriptable selection, e.g. `omarchy-shell oma.spectra select my-change`.
    // Selecting runs `status` for that change, and nothing runs while the
    // panel is closed, so a scripted select opens the panel first.
    function select(changeName: string): string {
      root.pendingSelect = changeName
      root.open()
      root.applyPendingSelect()
      return root.pendingSelect === "" ? "ok" : "pending"
    }
    function tab(name: string): string {
      var index = root.artifactTabs.indexOf(name)
      if (index < 0) return "unknown tab: " + name
      root.selectTab(index)
      return "ok"
    }
    function spec(name: string): string { root.selectSpec(name); return "ok" }
    function content(action: string): string {
      if (action === "show") root.contentExpanded = true
      else if (action === "hide") root.contentExpanded = false
      else if (action === "toggle") root.contentExpanded = !root.contentExpanded
      else return "unknown action: " + action + " (show|hide|toggle)"
      return "ok"
    }
    function setRoots(value: string): string {
      var reason = root.setRoots(value)
      return reason === "" ? "ok" : reason
    }
    function specs(action: string): string {
      if (action === "show") root.specsExpanded = true
      else if (action === "hide") root.specsExpanded = false
      else if (action === "toggle") root.specsExpanded = !root.specsExpanded
      else return "unknown action: " + action + " (show|hide|toggle)"
      return "ok"
    }
    function terminal(): string { root.openTerminal(); return "ok" }
    // Settings of the active project: `setSetting tdd true`, `update`.
    function setSetting(key: string, value: string): string {
      if (!root.project) return "no project selected"
      var reason = root.project.saveSetting(key, value)
      return reason === "" ? "ok" : reason
    }
    function cursor(action: string): string {
      if (action === "down") root.moveCursor(0, 1)
      else if (action === "up") root.moveCursor(0, -1)
      else if (action === "right") root.moveCursor(1, 0)
      else if (action === "left") root.moveCursor(-1, 0)
      else if (action === "activate") root.activateCursor()
      else return "unknown action: " + action + " (down|up|left|right|activate)"
      return "ok"
    }
    function archived(action: string): string {
      if (action === "show") root.archivedExpanded = true
      else if (action === "hide") root.archivedExpanded = false
      else if (action === "toggle") root.archivedExpanded = !root.archivedExpanded
      else return "unknown action: " + action + " (show|hide|toggle)"
      return "ok"
    }
    function settings(action: string): string {
      if (action === "show") root.settingsExpanded = true
      else if (action === "hide") root.settingsExpanded = false
      else if (action === "toggle") root.settingsExpanded = !root.settingsExpanded
      else return "unknown action: " + action + " (show|hide|toggle)"
      return "ok"
    }
    function update(): string {
      if (!root.project) return "no project selected"
      var reason = root.project.runUpdate()
      return reason === "" ? "started" : reason
    }
    function state(): string {
      var p = root.project
      return JSON.stringify({ opened: root.opened, project: p ? projects.labelFor(p.path) : null,
        projects: root.projectList.map(function(q) { return projects.labelFor(q.path) }), roots: projects.roots, change: root.selectedChangeName,
        tab: root.selectedTab, pending: root.pendingSelect, settingsExpanded: root.settingsExpanded,
        changes: p ? p.changes.map(function(c) { return c.name + (c.parked ? " (parked)" : "") }) : [],
        archived: p ? p.archived.map(function(c) { return c.key }) : [], archivedExpanded: root.archivedExpanded,
        specsExpanded: root.specsExpanded, contentExpanded: root.contentExpanded, contentPath: root.contentPath,
        missingRoots: projects.missingRoots, persistWarning: root.persistWarning,
        cursor: { row: root.cursorRow, col: root.cursorCol, kind: root.cursorKind, label: root.cursorLabel },
        targets: Object.keys(root.cursorTargets).length,
        rows: root.cursorRows.map(function(r) { return r.kind + (r.items.length > 1 ? "(" + r.items.length + ")" : "") }),
        artifacts: root.artifacts.map(function(a) { return a.id + ":" + a.status }),
        settings: p ? { locale: p.locale, tdd: p.tdd, audit: p.audit, experience: p.experience,
          cli_command: p.cli, spec_dir: p.specDir, tools: p.tools } : null,
        listError: p ? p.listError : "", listLoaded: p ? p.listLoaded : false, settingError: p ? p.settingError : "", updateResult: p ? p.updateResult : "", updating: p ? p.updating : false })
    }
    function project(name: string): string {
      for (var i = 0; i < root.projectList.length; i++)
        if (projects.labelFor(root.projectList[i].path) === name) { root.selectProject(i); return "ok" }
      var matches = []
      for (var j = 0; j < root.projectList.length; j++)
        if (root.projectList[j].name === name) matches.push(j)
      if (matches.length === 1) { root.selectProject(matches[0]); return "ok" }
      if (matches.length > 1) return "ambiguous: " + matches.map(function(k) { return projects.labelFor(root.projectList[k].path) }).join(", ")
      return "unknown project: " + name
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The Spectra mark, tinted to whatever the bar paints its other icons in
    // so a theme switch recolours it like a glyph.
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Image {
          id: mark
          anchors.fill: parent
          source: Qt.resolvedUrl("assets/spectra.svg")
          sourceSize: Qt.size(width * 2, height * 2)
          fillMode: Image.PreserveAspectFit
          smooth: true
          visible: false
        }

        MultiEffect {
          anchors.fill: mark
          source: mark
          colorization: 1.0
          colorizationColor: button.active && button.useActiveColor ? button.activeColor : button.foreground
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openTerminal()
      else if (buttonCode === Qt.MiddleButton) root.selectProject(root.projectIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The locale field and the cli dropdown own the keys while active;
      // otherwise typing "tw" would switch project on the "w"... and "r".
      blocked: localeDropdown.popupOpen || cliDropdown.popupOpen

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      // PageUp / PageDown are not part of PanelKeyCatcher's vocabulary.
      Keys.onPressed: function(event) {
        if (blocked) return
        if (event.key === Qt.Key_PageDown) { root.pageScroll(1); event.accepted = true }
        else if (event.key === Qt.Key_PageUp) { root.pageScroll(-1); event.accepted = true }
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.selectedChangeName !== "") root.selectTab(root.artifactTabs.indexOf(root.selectedTab) + direction)
        else root.switchPanel(direction)
      }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: logo · Spectra · project ----------
          PanelHero {
            width: parent.width
            title: "Spectra"
            meta: root.project ? projects.labelFor(root.project.path) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Image {
                source: Qt.resolvedUrl("assets/spectra.png")
                width: Style.font.display
                height: Style.font.display
                sourceSize: Qt.size(width * 2, height * 2)
                fillMode: Image.PreserveAspectFit
                smooth: true
              }
            }
          }

          // ---------- Project switch ----------
          Row {
            id: projectSwitch
            visible: root.projectList.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.projectList.length > 0
              ? (width - spacing * (root.projectList.length - 1)) / root.projectList.length
              : 0

            Repeater {
              model: root.projectList

              Button {
                required property var modelData
                required property int index

                width: projectSwitch.cellWidth
                readonly property string label: projects.labelFor(modelData.path)
                text: label
                selected: index === root.projectIndex
                hasCursor: root.cursorAt("project", label)
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: { root.setCursor("project", label); root.selectProject(index) }
                onHovered: function(isHovered) { if (isHovered) root.setCursor("project", label) }
                Component.onCompleted: root.registerCursorTarget("project", label, this)
                Component.onDestruction: root.unregisterCursorTarget("project", label, this)
              }
            }
          }

          // ---------- Empty root ----------
          Text {
            visible: projects.scanned && root.projectList.length === 0
            textFormat: Text.PlainText
            width: parent.width
            text: "No Spectra projects under " + projects.roots.map(function(r) { return Spectra.abbreviateHome(r, Quickshell.env("HOME")) }).join(", ")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // ---------- Changes ----------
          Column {
            id: changesSection
            visible: !!root.project
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "CHANGES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // The project's CLI could not be run or answered with garbage: one
            // line says which, and the other projects are unaffected.
            BorderSurface {
              visible: !!root.project && root.project.error !== ""
              width: parent.width
              implicitHeight: errorText.implicitHeight + Style.spacing.xl * 2
              color: root.alpha(root.urgent, 0.10)
              borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
              radius: Style.cornerRadius

              Text {
                id: errorText
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                text: root.project ? root.project.error : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Text {
              visible: !!root.project && root.project.error === "" && root.project.listLoaded && root.project.changes.length === 0
              textFormat: Text.PlainText
              width: parent.width
              text: "No active changes"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.project && root.project.error === "" ? root.project.changes : []

              ChangeRow {
                required property var modelData
                width: changesSection.width
                entry: modelData
                selected: root.selectedChangeName === String(modelData.name || "")
                hasCursor: root.cursorAt("change", modelData.name)
                onClicked: {
                  root.setCursor("change", modelData.name)
                  if (selected && root.selectedSpec === "") root.contentExpanded = !root.contentExpanded
                  else root.selectChange(String(modelData.name || ""))
                }
                onHovered: root.setCursor("change", modelData.name)
                Component.onCompleted: root.registerCursorTarget("change", modelData.name, this)
                Component.onDestruction: root.unregisterCursorTarget("change", modelData.name, this)
              }
            }
          }

          // Artifacts of a selected active / parked change: right under the list.
          Loader {
            width: parent.width
            active: !!root.selectedChange && !root.selectedChange.archived && root.contentExpanded
            visible: active
            sourceComponent: Component { ArtifactSection {} }
          }

          // ---------- Archived changes ----------
          Column {
            id: archivedSection
            visible: !!root.project && root.project.error === "" && root.project.archived.length > 0
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(archivedHeader.implicitHeight, archivedMarker.implicitHeight)

              PanelSectionHeader {
                id: archivedHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "ARCHIVED (" + (root.project ? root.project.archived.length : 0) + ")"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                id: archivedMarker
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.archivedExpanded ? "⌄" : "›"
                color: archivedHeaderMouse.containsMouse || root.cursorAt("archived-header", "archived") ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: archivedHeaderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.setCursor("archived-header", "archived"); root.archivedExpanded = !root.archivedExpanded }
                onContainsMouseChanged: if (containsMouse) root.setCursor("archived-header", "archived")
              }
              Component.onCompleted: root.registerCursorTarget("archived-header", "archived", this)
            }

            Column {
              visible: root.archivedExpanded
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.project && root.archivedExpanded ? root.project.archived : []

                ListRow {
                  required property var modelData
                  width: archivedSection.width
                  text: (modelData.date ? modelData.date + "  " : "") + modelData.name
                  trailing: "archived"
                  selected: root.selectedChangeName === String(modelData.key || "")
                  hasCursor: root.cursorAt("archived", modelData.key)
                  onClicked: {
                    root.setCursor("archived", modelData.key)
                    if (selected && root.selectedSpec === "") root.contentExpanded = !root.contentExpanded
                    else root.selectChange(String(modelData.key || ""))
                  }
                  onHovered: root.setCursor("archived", modelData.key)
                  Component.onCompleted: root.registerCursorTarget("archived", modelData.key, this)
                  Component.onDestruction: root.unregisterCursorTarget("archived", modelData.key, this)
                }
              }
            }
          }

          // Artifacts of a selected archived change: right under the archive.
          Loader {
            width: parent.width
            active: !!root.selectedChange && root.selectedChange.archived === true && root.contentExpanded
            visible: active
            sourceComponent: Component { ArtifactSection {} }
          }

          // ---------- Project specs ----------
          PanelSeparator {
            visible: specsSection.visible
            foreground: root.foreground
          }

          Column {
            id: specsSection
            visible: !!root.project && root.project.error === ""
            width: parent.width
            spacing: Style.space(10)

            // Header doubles as the fold toggle, like ARCHIVED and SETTINGS.
            Item {
              width: parent.width
              implicitHeight: Math.max(specsHeader.implicitHeight, specsMarker.implicitHeight)

              PanelSectionHeader {
                id: specsHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "SPECS (" + (root.project ? root.project.specNames.length : 0) + ")"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                id: specsMarker
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.specsExpanded ? "⌄" : "›"
                color: specsHeaderMouse.containsMouse || root.cursorAt("specs-header", "specs") ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: specsHeaderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.setCursor("specs-header", "specs"); root.specsExpanded = !root.specsExpanded }
                onContainsMouseChanged: if (containsMouse) root.setCursor("specs-header", "specs")
              }
              Component.onCompleted: root.registerCursorTarget("specs-header", "specs", this)
            }

            Text {
              visible: root.specsExpanded && !!root.project && root.project.specsLoaded && root.project.specNames.length === 0
              textFormat: Text.PlainText
              width: parent.width
              text: "No specs yet"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Column {
              visible: root.specsExpanded
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.project && root.specsExpanded ? root.project.specNames : []

                ListRow {
                  required property var modelData
                  width: specsSection.width
                  text: modelData
                  trailing: "spec"
                  selected: root.selectedSpec === modelData
                  hasCursor: root.cursorAt("spec", modelData)
                  onClicked: {
                    root.setCursor("spec", modelData)
                    if (selected) root.contentExpanded = !root.contentExpanded
                    else root.selectSpec(modelData)
                  }
                  onHovered: root.setCursor("spec", modelData)
                  Component.onCompleted: root.registerCursorTarget("spec", modelData, this)
                  Component.onDestruction: root.unregisterCursorTarget("spec", modelData, this)
                }
              }
            }
          }

          // A project spec renders right under the SPECS rows.
          ContentView { visible: root.selectedSpec !== "" && root.contentPath !== "" && root.contentExpanded }

          // ---------- Settings (.spectra.yaml) ----------
          PanelSeparator {
            visible: settingsSection.visible
            foreground: root.foreground
          }

          Column {
            id: settingsSection
            visible: !!root.project && root.project.configEverLoaded
            width: parent.width
            spacing: Style.space(10)

            readonly property var p: root.project

            // Header doubles as the fold toggle: `SETTINGS ›` folded, `⌄` open.
            Item {
              width: parent.width
              implicitHeight: Math.max(settingsHeader.implicitHeight, settingsMarker.implicitHeight)

              PanelSectionHeader {
                id: settingsHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "SETTINGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                id: settingsMarker
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.settingsExpanded ? "⌄" : "›"
                color: settingsHeaderMouse.containsMouse || root.cursorAt("settings-header", "settings") ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: settingsHeaderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.setCursor("settings-header", "settings"); root.settingsExpanded = !root.settingsExpanded }
                onContainsMouseChanged: if (containsMouse) root.setCursor("settings-header", "settings")
              }
              Component.onCompleted: root.registerCursorTarget("settings-header", "settings", this)
            }

            Column {
              id: settingsBody
              visible: root.settingsExpanded
              width: parent.width
              spacing: Style.space(10)

            // locale — one of the three codes spxa understands.
            SettingRow {
              label: "locale"
              cursorKey: "locale"
              error: settingsSection.p && settingsSection.p.settingErrorKey === "locale" ? settingsSection.p.settingError : ""

              Dropdown {
                id: localeDropdown
                width: Style.space(140)
                showLabel: false
                fontFamily: root.fontFamily
                foreground: root.foreground
                hasCursor: root.cursorAt("setting", "locale")
                onHovered: function(h) { if (h) root.setCursor("setting", "locale") }
                // A file value outside the list still shows as the current
                // entry, so the user sees what is there before overwriting it.
                readonly property string current: settingsSection.p ? settingsSection.p.locale : ""
                options: {
                  var list = Spectra.LOCALES.map(function(code) { return { value: code, label: Spectra.LOCALE_LABELS[code] } })
                  if (current !== "" && Spectra.LOCALES.indexOf(current) < 0) list.push({ value: current, label: current + "（未支援）" })
                  return list
                }
                value: current
                // Dropdown assigns `value` when the user picks, which drops
                // the binding above; follow the file explicitly afterwards.
                onCurrentChanged: value = current
                onChanged: function(v) {
                  if (settingsSection.p && Spectra.LOCALES.indexOf(v) >= 0) settingsSection.p.saveSetting("locale", v)
                }
              }
            }

            Repeater {
              model: ["tdd", "audit", "experience"]

              SettingRow {
                id: toggleRow
                required property var modelData
                label: modelData
                cursorKey: modelData
                error: settingsSection.p && settingsSection.p.settingErrorKey === modelData ? settingsSection.p.settingError : ""

                ToggleSwitch {
                  checked: settingsSection.p ? settingsSection.p[toggleRow.modelData] === true : false
                  hasCursor: root.cursorAt("setting", toggleRow.modelData)
                  onHovered: function(h) { if (h) root.setCursor("setting", toggleRow.modelData) }
                  foreground: root.foreground
                  onToggled: if (settingsSection.p) settingsSection.p.saveSetting(toggleRow.modelData, checked ? "false" : "true")
                }
              }
            }

            SettingRow {
              label: "cli_command"
              cursorKey: "cli_command"
              error: settingsSection.p && settingsSection.p.settingErrorKey === "cli_command" ? settingsSection.p.settingError : ""

              Dropdown {
                id: cliDropdown
                hasCursor: root.cursorAt("setting", "cli_command")
                onHovered: function(h) { if (h) root.setCursor("setting", "cli_command") }
                width: Style.space(120)
                showLabel: false
                fontFamily: root.fontFamily
                foreground: root.foreground
                options: Spectra.ALLOWED_CLIS
                readonly property string current: settingsSection.p ? settingsSection.p.cli : ""
                value: current
                onCurrentChanged: value = current
                onChanged: function(v) { if (settingsSection.p) settingsSection.p.saveSetting("cli_command", v) }
              }
            }

            SettingRow {
              label: "spec_dir"
              Text {
                textFormat: Text.PlainText
                text: settingsSection.p ? settingsSection.p.specDir.slice(settingsSection.p.path.length + 1) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            SettingRow {
              label: "tools"
              Text {
                textFormat: Text.PlainText
                text: settingsSection.p && settingsSection.p.tools.length > 0 ? settingsSection.p.tools.join(", ") : "—"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            // Regenerate the instruction files (`<cli> update`, never --force).
            Column {
              width: parent.width
              spacing: Style.space(6)

              Button {
                hasCursor: root.cursorAt("update", "update")
                onHovered: function(h) { if (h) root.setCursor("update", "update") }
                Component.onCompleted: root.registerCursorTarget("update", "update", this)
                text: settingsSection.p && settingsSection.p.updating ? "更新中…" : "更新指令檔"
                iconText: ""
                iconSpinning: !!settingsSection.p && settingsSection.p.updating
                bordered: true
                enabled: !!settingsSection.p && !settingsSection.p.updating && settingsSection.p.configError === ""
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: if (enabled) settingsSection.p.runUpdate()
              }

              Text {
                visible: text !== ""
                textFormat: Text.PlainText
                width: parent.width
                text: settingsSection.p ? settingsSection.p.updateResult : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
            }
          }
        }
      }
    }
  }


  // The selected change's tab row, delta chips and content. It is loaded
  // right under whichever list the change came from, and only while the
  // content is unfolded; the spec viewer below SPECS reuses ContentView.
  component ArtifactSection: Column {
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(12)
    // ---------- Artifacts of the selected change ----------
    PanelSeparator {
      visible: artifactSection.visible
      foreground: root.foreground
    }

    Column {
      id: artifactSection
      visible: !!root.selectedChange
      width: parent.width
      spacing: Style.space(10)

      Row {
        id: tabRow
        width: parent.width
        spacing: Style.spacing.md

        readonly property real cellWidth: (width - spacing * (root.artifactTabs.length - 1)) / root.artifactTabs.length

        Repeater {
          model: root.artifactTabs

          Button {
            required property var modelData
            required property int index

            readonly property var status: root.artifactStatus(modelData)
            // A tab the CLI has not marked done is still there — the
            // file may be missing — but it steps back.
            readonly property bool ready: !!status && status.status === "done"

            width: tabRow.cellWidth
            text: modelData
            selected: root.selectedSpec === "" && root.selectedTab === modelData
            hasCursor: root.cursorAt("tab", modelData)
            opacity: ready ? 1.0 : 0.45
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.setCursor("tab", modelData); root.selectTab(index) }
            onHovered: function(h) { if (h) root.setCursor("tab", modelData) }
            Component.onCompleted: root.registerCursorTarget("tab", modelData, this)
            Component.onDestruction: root.unregisterCursorTarget("tab", modelData, this)
          }
        }
      }

      Text {
        visible: !!root.statusEntry && !!root.statusEntry.error
        textFormat: Text.PlainText
        width: parent.width
        text: root.statusEntry && root.statusEntry.error ? String(root.statusEntry.error) : ""
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // Delta specs of this change, one chip each.
      Flow {
        visible: root.selectedSpec === "" && root.selectedTab === "specs"
        width: parent.width
        spacing: Style.spacing.md

        Repeater {
          model: root.deltaSpecs

          Button {
            required property var modelData
            text: modelData
            selected: root.selectedDeltaSpec === modelData
            hasCursor: root.cursorAt("delta", modelData)
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            verticalPadding: Style.spacing.xs
            onClicked: { root.setCursor("delta", modelData); root.selectedDeltaSpec = modelData }
            onHovered: function(h) { if (h) root.setCursor("delta", modelData) }
            Component.onCompleted: root.registerCursorTarget("delta", modelData, this)
            Component.onDestruction: root.unregisterCursorTarget("delta", modelData, this)
          }
        }
      }

      Text {
        visible: root.selectedSpec === "" && root.selectedTab === "specs" && root.deltaSpecs.length === 0
        textFormat: Text.PlainText
        width: parent.width
        text: "No delta specs in this change"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    ContentView { visible: root.selectedSpec === "" && root.contentPath !== "" }
  }

  component ContentView: Column {
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(12)
    // ---------- Content ----------
    PanelSeparator {
      visible: contentSection.visible
      foreground: root.foreground
    }

    Column {
      id: contentSection
      visible: root.contentPath !== ""
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.contentPath.slice(root.project ? root.project.specDir.length + 1 : 0)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }

      Text {
        visible: root.contentMissing
        textFormat: Text.PlainText
        width: parent.width
        text: root.selectedSpec !== "" ? "Spec file missing" : "Not written for this change"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // The artifact itself. Qt's Markdown engine covers everything the
      // Spectra templates emit: headings, lists, fenced code, tables.
      TextEdit {
        visible: !root.contentMissing && root.contentText !== ""
        width: parent.width
        text: root.contentText
        textFormat: TextEdit.MarkdownText
        readOnly: true
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        color: root.foreground
        selectionColor: root.track
        selectedTextColor: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        // Links come from project files; only web links leave the panel,
        // and never through a shell string.
        onLinkActivated: function(link) {
          if (/^https?:\/\//.test(link)) Util.execArgv(["xdg-open", link])
        }
      }
    }
  }

  // One dimmed list row: text on the left, a trailing word on the right, a
  // fold marker when it is the selected item. ARCHIVED and SPECS both use it.
  component ListRow: Item {
    id: listRow
    property string text: ""
    property string trailing: ""
    property bool selected: false
    property bool hasCursor: false
    signal clicked()
    signal hovered()

    implicitHeight: rowText.implicitHeight + Style.space(4)

    Rectangle {
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      radius: Style.cornerRadius
      color: listRow.hasCursor ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: listRow.clicked()
      onContainsMouseChanged: if (containsMouse) listRow.hovered()
    }

    Text {
      id: rowText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: trailingText.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: listRow.text
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: listRow.selected
      elide: Text.ElideRight
    }

    Text {
      id: trailingText
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: listRow.trailing + (listRow.selected ? (root.contentExpanded ? "  ⌄" : "  ›") : "")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One setting: label on the left, its control on the right, and the reason
  // a write was refused underneath when there is one.
  component SettingRow: Column {
    id: settingRow
    property string label: ""
    property string error: ""
    // Which setting this row is in the cursor sequence; "" for display-only rows.
    property string cursorKey: ""
    readonly property bool hasCursor: cursorKey !== "" && root.cursorAt("setting", cursorKey)
    default property alias control: controlSlot.data

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(4)

    Component.onCompleted: if (cursorKey !== "") root.registerCursorTarget("setting", cursorKey, this)
    Component.onDestruction: if (cursorKey !== "") root.unregisterCursorTarget("setting", cursorKey, this)

    Item {
      width: parent.width
      implicitHeight: Math.max(labelText.implicitHeight, controlSlot.childrenRect.height)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onContainsMouseChanged: if (containsMouse && settingRow.cursorKey !== "") root.setCursor("setting", settingRow.cursorKey)
      }

      Text {
        id: labelText
        textFormat: Text.PlainText
        text: settingRow.label
        font.bold: settingRow.hasCursor
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Item {
        id: controlSlot
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: childrenRect.width
        height: childrenRect.height
      }
    }

    Text {
      visible: settingRow.error !== ""
      textFormat: Text.PlainText
      width: parent.width
      text: settingRow.error
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // One change: name and task counter, progress meter, status text. Click
  // to open its artifacts below.
  component ChangeRow: Column {
    id: changeRow
    property var entry: null
    property bool selected: false
    property bool hasCursor: false
    signal clicked()
    signal hovered()

    readonly property int total: entry ? Number(entry.totalTasks) || 0 : 0
    readonly property int done: entry ? Number(entry.completedTasks) || 0 : 0
    // A parked change is listed after the active ones and steps back visually.
    readonly property bool parked: !!entry && entry.parked === true

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(nameText.implicitHeight, counterText.implicitHeight)

      Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        radius: Style.cornerRadius
        color: changeRow.hasCursor ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: changeRow.clicked()
        onContainsMouseChanged: if (containsMouse) changeRow.hovered()
      }

      Text {
        id: nameText
        textFormat: Text.PlainText
        text: changeRow.entry ? String(changeRow.entry.name || "") : ""
        color: changeRow.parked ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: changeRow.selected
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: counterText.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: counterText
        textFormat: Text.PlainText
        text: changeRow.done + "/" + changeRow.total + (changeRow.selected ? (root.contentExpanded ? "  ⌄" : "  ›") : "")
        color: changeRow.parked ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: changeRow.total > 0 ? changeRow.done / changeRow.total : 0
      opacity: changeRow.parked ? 0.5 : 1.0
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: changeRow.entry ? String(changeRow.entry.status || "") : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Meter: Item {
    id: meter
    property real value: -1
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }
}

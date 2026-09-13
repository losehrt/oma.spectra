# Spectra

One bar icon and one panel for every [Spectra](https://spectra.5xcamp.us/)
project on the machine. The panel lists each project's changes (active and
parked) with their task progress, shows which artifacts a change has, renders
the proposal, design, delta specs, tasks and the project's own specs as
formatted Markdown, and lets you flip the project's `.spectra.yaml` settings
and regenerate its instruction files. Everything else stays read-only —
`new`, `apply`, `archive`, `park` and friends live in Claude Code and the
terminal.

## Bar

The icon is the Spectra mark from https://spectra.5xcamp.us/ (`assets/spectra.svg`,
a monochrome redraw of the site's `logo-06670f93.png`), tinted to the bar's
foreground so it follows the theme like every other icon. It sits in the
`right` section of `~/.config/omarchy/shell.json` directly before
`omarchy.agents`:

```json
{ "id": "oma.spectra" }
```

- **Left click** — open / close the panel.
- **Middle click** — switch to the next project.
- **Right click** — open a terminal in the selected project's root and close
  the panel.

## Panel

- **Hero** — the full-colour logo (`assets/spectra.png`), the word
  `Spectra`, and the active project's name.
- **Project chips** — one per discovered project, hidden when only one
  exists. Click, or `h` / `l`.
- **Changes** — one row per entry of `<cli> list --json`, then one per
  entry of `<cli> list --parked --json` (dimmed, status `parked`): name,
  `completed/total` tasks, a progress bar and the status text. Click a row
  to open its artifacts. `No active changes` when both lists are empty.
- **Archived** — `ARCHIVED (N) ›` below the changes, folded on every open;
  expand it for one dimmed row per directory under `changes/archive/`
  (`YYYY-MM-DD  name`, newest first, no progress bar). Selecting one opens
  its artifacts like any change; since `spxa status` does not know archived
  changes, a tab is dimmed when its file is missing from the archive
  directory.
- **Artifact tabs** — shown right under the list the selected change came
  from (below CHANGES for an active or parked change, below the ARCHIVED rows
  for an archived one). Click or `Enter` the selected row again to fold the
  tabs and content away (`›`), and again to unfold (`⌄`); selecting another
  change always unfolds. `proposal` · `design` · `specs` · `tasks`, dimmed when
  `<cli> status --change <name> --json` does not report the artifact as
  `done`. `specs` shows one chip per delta spec of the change.
- **Content** — the selected file rendered with Qt's Markdown engine; a
  project spec renders under the SPECS rows instead
  (headings, lists, fenced code, tables). `Not written for this change` when
  the file does not exist. Text is selectable; `http(s)` links open in the
  browser.
- **Specs** — `SPECS (N) ›`, folded on every open; expand it for one row
  per `specs/*/spec.md` (same row style as ARCHIVED, or `No specs yet`).
  Selecting a spec by click, keyboard or IPC expands the section and renders
  it under the rows; activating the selected row again folds the content.
- **Settings** — the project's `.spectra.yaml`, folded to a `SETTINGS ›`
  header every time the panel opens; click the header to expand (`⌄`) and
  again to fold. Editable: `locale` (dropdown:
  English / 繁體中文 / 日本語, written as `en` / `tw` / `ja` — the only codes
  spxa turns into a language name; any other value in the file shows as
  `<value>（未支援）` until you pick one), `tdd` / `audit` / `experience`
  (switches), `cli_command` (one of `spectra`, `specx`, `spxa`).
  Display-only: `spec_dir`, `tools`. A change rewrites just that one line of
  the file (an active `key:` line, else the commented `# key:` line, else a
  new line at the end); comments and order are kept, and the file is
  re-read afterwards so the panel always shows what is on disk. A rejected
  or failed write shows its reason under the row and leaves the file alone.
  The `更新指令檔` button runs `<cli> update` in the project and shows the
  first line of its output; note that `spxa update` rewrites the generated
  `.claude/skills/spectra-*/SKILL.md` files even without `--force`, so
  hand edits to those files do not survive it.

An error line replaces the change list when a project's CLI cannot be run or
does not answer with JSON; other projects are unaffected. When the selected
change leaves every list (archived or parked from a terminal, then `r`), the
selection and the content area are cleared.

### Keys

A keyboard cursor walks every clickable item in visual order: project chips,
change rows, the ARCHIVED header and its rows, the artifact tabs, delta spec
chips, the SPECS header and its rows, the SETTINGS header and its rows, the
update button. The panel scrolls to keep the cursor visible; hovering an item with
the mouse moves the cursor there too.

| Key | Action |
| --- | --- |
| `↓` / `j`, `↑` / `k` | next / previous row |
| `→` / `l`, `←` / `h` | next / previous item in the row (on the project row this also switches the project) |
| `Enter` / `Space` | activate: select, expand or fold a header, flip a switch, open a dropdown, run the update |
| `PageDown` / `PageUp` | scroll the panel by 80% of its height |
| `Tab` / `Shift+Tab` | next / previous artifact tab (wraps) |
| `r` | rescan projects, re-read each `.spectra.yaml`, reload every change list, the selected change's status and the open file |
| `Esc` | close |

Data loads when the panel opens and on `r`; nothing runs while it is closed.

## Setting

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `projectsRoot` | path | `~/projects` | Folder whose **direct** subfolders are scanned for `.spectra.yaml`. `~` is expanded. |

Set it inline in the bar layout entry (`{ "id": "oma.spectra", "projectsRoot": "~/code" }`)
or through the shell's widget settings.

Each project's `.spectra.yaml` supplies `cli_command` (one of `spectra`,
`specx`, `spxa`; default `spectra`) and `spec_dir` (default `openspec`).
Any other CLI name, or a `spec_dir` that is absolute or climbs out of the
project, is refused with an error line rather than executed. The CLI must be
on the login-session PATH the shell was started with.

## IPC

`omarchy-shell oma.spectra <fn>`: `show`, `hide`, `toggle`, `refresh`,
`next`, `project <name>`, `select <change>`, `tab <proposal|design|specs|tasks>`,
`spec <capability>`, `terminal`, `settings <show|hide|toggle>` (fold or
expand the settings section), `archived <show|hide|toggle>`, `specs <show|hide|toggle>`, `content <show|hide|toggle>`,
`cursor <down|up|left|right|activate>`, `setSetting <key> <value>` (answers `ok` or
the reason the value was refused), `update` (answers `started` or why not),
`state` (JSON of what is open and selected, the cursor position and row
sequence, the archived names, plus the active project's settings, list error
and update result).

`select` opens the panel, switches to whichever project lists that change,
and answers `pending` when the change lists are still loading (it applies as
soon as they land).

## Non-goals

- Writing anything to a project other than the five `.spectra.yaml` keys
  above and what `<cli> update` itself generates; no `new` / `apply` /
  `archive` / `park` / `task` from the panel.
- Editing `spec_dir` or `tools` (moving the spec directory or adding an AI
  tool stays a terminal job).
- Syntax highlighting inside code blocks and rendering of Mermaid diagrams
  (both show as plain monospace text).
- Watching files for live updates.
- Nested project discovery (only direct children of `projectsRoot`).
- Task progress for archived changes (they show no bar), and searching or
  filtering the archive.

## Files

```
manifest.json   plugin manifest and the projectsRoot setting
Panel.qml       bar button, popup, all rendering
Projects.qml    scans projectsRoot, one Project per hit
Project.qml     .spectra.yaml, list / status / spec listings for one project
Spectra.js      pure helpers (config parsing, JSON shapes, CLI allowlist)
assets/         spectra.png (hero), spectra.svg (bar)
```

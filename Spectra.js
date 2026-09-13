.pragma library

// Pure helpers shared by Projects.qml and Panel.qml. No QML types in here so
// the same code runs under node for a quick check:
//   node -e "eval(require('fs').readFileSync('Spectra.js','utf8').replace('.pragma library','')); console.log(parseConfig('cli_command: spxa'))"

// The only CLIs a project may name. `.spectra.yaml` is project data, and the
// panel runs whatever it names, so the name is checked against this list
// instead of handed to the shell as-is.
var ALLOWED_CLIS = ["spectra", "specx", "spxa"];
var DEFAULT_CLI = "spectra";
var DEFAULT_SPEC_DIR = "openspec";

function expandHome(path, home) {
  var p = String(path || "").trim();
  if (p === "~") return home;
  if (p.indexOf("~/") === 0) return home + p.slice(1);
  return p;
}

// Reads the scalar keys and the `tools` list out of `.spectra.yaml`. A full
// YAML parser is more than this file deserves; a commented line
// (`# cli_command:`) never matches because the key must start the line.
function parseConfig(text) {
  var config = {
    cli: DEFAULT_CLI, specDir: DEFAULT_SPEC_DIR,
    locale: "", tdd: false, audit: false, experience: false, tools: []
  };
  var lines = String(text || "").split("\n");
  var inTools = false;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    // `tools:` is the one list: its items are the `  - x` lines that follow.
    if (inTools) {
      var item = /^\s*-\s*(\S+)/.exec(line);
      if (item) { config.tools.push(stripQuotes(item[1])); continue; }
      if (/^\s*(#|$)/.test(line)) continue;
      inTools = false;
    }
    var m = /^\s*([a-z_]+):\s*(.*?)\s*$/.exec(line);
    if (!m) continue;
    var key = m[1], value = stripQuotes(m[2].replace(/\s+#.*$/, ""));
    if (key === "cli_command") config.cli = value;
    else if (key === "spec_dir") config.specDir = value;
    else if (key === "locale") config.locale = value;
    else if (key === "tdd" || key === "audit" || key === "experience") config[key] = value === "true";
    else if (key === "tools") inTools = true;
  }
  return config;
}

// The keys the panel may write, and nothing else.
var EDITABLE_KEYS = ["locale", "tdd", "audit", "experience", "cli_command"];
var TOGGLE_KEYS = ["tdd", "audit", "experience"];
// The locales spxa 0.1.1 turns into a language name; anything else it hands
// to the AI verbatim, so the panel only offers these.
var LOCALES = ["en", "tw", "ja"];
var LOCALE_LABELS = { en: "English", tw: "繁體中文", ja: "日本語" };

// "" when the value may be written; otherwise the reason shown to the user.
function validateSetting(key, value) {
  var v = String(value === undefined || value === null ? "" : value).trim();
  if (EDITABLE_KEYS.indexOf(key) < 0) return "'" + key + "' 不是面板可以修改的設定";
  if (TOGGLE_KEYS.indexOf(key) >= 0 && v !== "true" && v !== "false") return key + " 只能是 true 或 false";
  if (key === "cli_command" && ALLOWED_CLIS.indexOf(v) < 0) return "cli_command 只能是 " + ALLOWED_CLIS.join(" / ");
  if (key === "locale" && LOCALES.indexOf(v) < 0) return "locale 只能是 " + LOCALES.join(" / ");
  return "";
}

// Rewrite one key in `.spectra.yaml`, touching nothing else: the active
// `key:` line if there is one, else the first commented `# key:` line
// (uncommented), else a new line at the end. Comments and order survive.
function setConfigKey(text, key, value) {
  var src = String(text || "");
  var hadTrailingNewline = src.length === 0 || src[src.length - 1] === "\n";
  var lines = src.split("\n");
  if (hadTrailingNewline && lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  var replacement = key + ": " + String(value);
  var active = new RegExp("^\\s*" + key + ":");
  var commented = new RegExp("^\\s*#\\s*" + key + ":");
  for (var i = 0; i < lines.length; i++) {
    if (active.test(lines[i])) { lines[i] = replacement; return lines.join("\n") + "\n"; }
  }
  for (var j = 0; j < lines.length; j++) {
    if (commented.test(lines[j])) { lines[j] = replacement; return lines.join("\n") + "\n"; }
  }
  lines.push(replacement);
  return lines.join("\n") + "\n";
}

function stripQuotes(value) {
  var v = String(value);
  if (v.length >= 2 && ((v[0] === '"' && v[v.length - 1] === '"') || (v[0] === "'" && v[v.length - 1] === "'")))
    return v.slice(1, -1);
  return v;
}

// Why a project cannot be browsed, or "" when its config is usable.
function configError(config) {
  if (ALLOWED_CLIS.indexOf(config.cli) < 0)
    return "cli_command '" + config.cli + "' is not one of " + ALLOWED_CLIS.join("/");
  var d = String(config.specDir || "");
  if (d === "" || d[0] === "/" || d.split("/").indexOf("..") >= 0)
    return "spec_dir '" + d + "' must be a relative path inside the project";
  return "";
}

// Parent directories of every `.spectra.yaml` that `find` printed, sorted by
// basename so the chip row reads the same on every refresh.
function projectsFromFind(output) {
  var records = [];
  var lines = String(output || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (line === "") continue;
    var dir = line.replace(/\/\.spectra\.yaml$/, "");
    if (dir === line) continue;
    records.push({ id: dir, name: dir.slice(dir.lastIndexOf("/") + 1) });
  }
  records.sort(function(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; });
  return records;
}

function firstLine(text) {
  var lines = String(text || "").trim().split("\n");
  return lines.length > 0 ? lines[0].trim() : "";
}

// `<cli> list --json` → array of change entries, or null when the text is not
// the shape the CLI documents. `list --parked --json` answers with the same
// entries under `parked` instead of `changes`.
function parseChangeList(text) {
  try {
    var data = JSON.parse(String(text || ""));
    if (!data) return null;
    if (Array.isArray(data.changes)) return data.changes;
    if (Array.isArray(data.parked)) return data.parked;
    return null;
  } catch (e) {
    return null;
  }
}

// `<cli> status --change X --json` → array of {id, outputPath, status}, or null.
function parseStatus(text) {
  try {
    var data = JSON.parse(String(text || ""));
    if (!data || !Array.isArray(data.artifacts)) return null;
    return data.artifacts;
  } catch (e) {
    return null;
  }
}

// Capability directory names from a `find <dir> -name spec.md` listing.
function capabilitiesFromFind(output) {
  var names = [];
  var lines = String(output || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    var m = /\/([^\/]+)\/spec\.md$/.exec(line);
    if (m) names.push(m[1]);
  }
  names.sort();
  return names;
}

// Archived changes live as `changes/archive/<YYYY-MM-DD>-<name>/`. Newest
// first; a directory without the date prefix keeps its full name and sorts last.
function archivedFromFind(output) {
  var entries = [];
  var lines = String(output || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var dir = lines[i].trim();
    if (dir === "") continue;
    var base = dir.slice(dir.lastIndexOf("/") + 1);
    var m = /^(\d{4}-\d{2}-\d{2})-(.+)$/.exec(base);
    // `key` is what the panel selects by: the directory name stays unique
    // when the same change name is archived more than once.
    entries.push({
      key: base, name: m ? m[2] : base, date: m ? m[1] : "", dir: dir,
      archived: true, status: "archived", completedTasks: 0, totalTasks: 0
    });
  }
  entries.sort(function(a, b) {
    if (a.date !== b.date) return a.date < b.date ? 1 : -1;
    return a.name < b.name ? 1 : a.name > b.name ? -1 : 0;
  });
  return entries;
}

// The `status --json` shape, built from which files an archived change has.
// The `specs` entry is left out: the delta-spec listing the panel already
// runs for the selection answers that one.
var ARCHIVED_ARTIFACTS = [["proposal", "proposal.md"], ["design", "design.md"], ["tasks", "tasks.md"]];
function artifactsFromFiles(names) {
  var present = {};
  for (var i = 0; i < names.length; i++) present[String(names[i]).trim()] = true;
  return ARCHIVED_ARTIFACTS.map(function(pair) {
    return { id: pair[0], outputPath: pair[1], status: present[pair[1]] ? "done" : "missing" };
  });
}

// Basenames from a `find <dir> -maxdepth 1 -name '*.md'` listing.
function basenamesFromFind(output) {
  var names = [];
  var lines = String(output || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (line !== "") names.push(line.slice(line.lastIndexOf("/") + 1));
  }
  return names;
}

// `projectsRoot` holds one or more folders separated by `:` like PATH. Empty
// segments and repeats are dropped; each segment gets its `~` expanded.
function splitRoots(value, home) {
  var roots = [];
  var parts = String(value || "").split(":");
  for (var i = 0; i < parts.length; i++) {
    var p = expandHome(parts[i].trim(), home);
    if (p !== "" && roots.indexOf(p) < 0) roots.push(p);
  }
  return roots;
}

// Chip labels: the directory name, or `<root folder>/<name>` when two roots
// hold a project of the same name. Sorted by name, then by path.
function labelProjects(records) {
  // Start with the bare name; while any label is shared, give the sharers
  // one more path component each (`src/foo` → `work/src/foo`) until unique.
  var out = records.map(function(r) {
    return { id: r.id, name: r.name, label: r.name, parts: r.id.split("/").filter(function(x) { return x !== ""; }), depth: 1 };
  });
  for (var round = 0; round < 32; round++) {
    var counts = {};
    for (var i = 0; i < out.length; i++) counts[out[i].label] = (counts[out[i].label] || 0) + 1;
    var clash = false;
    for (var j = 0; j < out.length; j++) {
      if (counts[out[j].label] > 1 && out[j].depth < out[j].parts.length) {
        out[j].depth++;
        out[j].label = out[j].parts.slice(-out[j].depth).join("/");
        clash = true;
      }
    }
    if (!clash) break;
  }
  out = out.map(function(r) { return { id: r.id, name: r.name, label: r.label }; });
  out.sort(function(a, b) {
    if (a.name !== b.name) return a.name < b.name ? -1 : 1;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  return out;
}

function abbreviateHome(path, home) {
  var p = String(path || "");
  if (home && (p === home || p.indexOf(home + "/") === 0)) return "~" + p.slice(home.length);
  return p;
}

// ---- folder browser / root list helpers -----------------------------------

function parentDir(path) {
  var p = String(path || "/").replace(/\/+$/, "");
  if (p === "") return "/";
  var i = p.lastIndexOf("/");
  return i <= 0 ? "/" : p.slice(0, i);
}

// Two `find` listings separated by a `--` line: the subfolders of a folder,
// then the `.spectra.yaml` files two levels down. Sorted by name.
function parseBrowse(output) {
  var parts = String(output || "").split(/^--$/m);
  var dirs = String(parts[0] || "").split("\n");
  var spectra = {};
  var second = String(parts[1] || "").split("\n");
  for (var i = 0; i < second.length; i++) {
    var line = second[i].trim();
    if (line !== "") spectra[parentDir(line)] = true;
  }
  var entries = [];
  for (var j = 0; j < dirs.length; j++) {
    var d = dirs[j].trim();
    if (d === "") continue;
    entries.push({ path: d, name: d.slice(d.lastIndexOf("/") + 1), hasSpectra: !!spectra[d] });
  }
  entries.sort(function(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; });
  return entries;
}

function addRoot(roots, path) {
  var p = String(path || "").replace(/\/+$/, "") || "/";
  return roots.indexOf(p) >= 0 ? roots.slice() : roots.concat([p]);
}

// Never empties the list: the last root stays.
function removeRoot(roots, path) {
  if (roots.length <= 1) return roots.slice();
  return roots.filter(function(r) { return r !== path; });
}

// The stored form: `~`-abbreviated, `:`-joined.
function joinRoots(roots, home) {
  return roots.map(function(r) { return abbreviateHome(r, home); }).join(":");
}

// ---- CLI invocation ---------------------------------------------------------

// The shell is a GUI process with the login-session PATH, so a CLI installed
// by mise/nvm may be invisible to it. Run through the user's login shell the
// way Omarchy's own Util.execArgv does: `exec` replaces bash, and the command
// plus arguments ride in argv so nothing is re-parsed by the shell.
// `cwd` is pinned inside the shell string so a profile that does `cd`
// cannot move the command out of the project.
function cliCommand(cli, args, cwd) {
  return ["bash", "-lc", 'cd -- "$1" && shift && exec "$@"', "bash", cwd || ".", cli].concat(args || []);
}

// bash answers 127 when `exec` finds nothing; the same wording covers a bash
// that could not start at all.
function startFailureMessage(cli) {
  return cli + " could not be found, even through the login shell";
}

// True only for bash's own "not found" — a 127 from the CLI's interpreter
// (`env: 'node': No such file`) keeps its real stderr line instead.
function isCliNotFound(exitCode, stderr, cli) {
  return exitCode === 127 && new RegExp("exec: " + cli.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ": not found").test(String(stderr || ""));
}

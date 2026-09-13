// Regression checks for the pure helpers. Run: node Spectra.test.js
var fs = require("fs");
eval(fs.readFileSync(__dirname + "/Spectra.js", "utf8").replace(".pragma library", ""));

var failures = 0;
function check(name, actual, expected) {
  var a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) console.log("PASS", name);
  else { failures++; console.log("FAIL", name, "\n  expected", e, "\n  actual  ", a); }
}

// parseConfig / key resolution
check("config keys", parseConfig("cli_command: spxa\nspec_dir: docs/spectra\n"), { cli: "spxa", specDir: "docs/spectra", locale: "", tdd: false, audit: false, experience: false, tools: [] });
check("commented key ignored", parseConfig("# cli_command: spectra\nspec_dir: docs/spectra\n").cli, "spectra");
check("empty file defaults", [parseConfig("").cli, parseConfig("").specDir], ["spectra", "openspec"]);
check("tools list, any indent", parseConfig("tools:\n- claude\n  - cursor\n#   - x\nlocale: tw\n").tools, ["claude", "cursor"]);
check("trailing comment stripped", parseConfig("cli_command: spxa  # note\n").cli, "spxa");

// validateSetting
check("reject bad locale", validateSetting("locale", "zz-!!") !== "", true);
check("reject en-US (not a spxa locale)", validateSetting("locale", "en-US") !== "", true);
check("accept spxa locales", LOCALES.map(function(l) { return validateSetting("locale", l); }), ["", "", ""]);
check("reject unknown cli", validateSetting("cli_command", "not-a-real-cli") !== "", true);
check("reject toggle maybe", validateSetting("tdd", "maybe") !== "", true);
check("reject spec_dir", validateSetting("spec_dir", "x") !== "", true);

// setConfigKey rewrite table
check("active line", setConfigKey("locale: tw\n", "locale", "en"), "locale: en\n");
check("commented line", setConfigKey("# tdd: true\n", "tdd", "true"), "tdd: true\n");
check("append", setConfigKey("a: 1\n", "experience", "true"), "a: 1\nexperience: true\n");
check("audit off", setConfigKey("audit: true\n", "audit", "false"), "audit: false\n");

// configError
check("cli allowlist", configError({ cli: "not-a-real-cli", specDir: "x" }) !== "", true);
check("spec_dir escape", configError({ cli: "spxa", specDir: "../x" }) !== "", true);

// listings
check("projects sorted by name", projectsFromFind("/p/oma/.spectra.yaml\n/p/blog/.spectra.yaml\n").map(function(p) { return p.name; }), ["blog", "oma"]);
check("parked shape", parseChangeList('{"parked":[{"name":"x"}]}').length, 1);
check("capabilities sorted", capabilitiesFromFind("/c/specs/b/spec.md\n/c/specs/a/spec.md\n"), ["a", "b"]);

// archived
var arch = archivedFromFind("/x/changes/archive/2026-09-13-oma-spectra-panel\n/x/changes/archive/2026-09-13-panel-project-settings\n/x/changes/archive/legacy-change\n");
check("archived newest first, legacy last", arch.map(function(e) { return e.date + "|" + e.name; }), ["2026-09-13|panel-project-settings", "2026-09-13|oma-spectra-panel", "|legacy-change"]);
check("archived empty", archivedFromFind(""), []);
check("artifacts from files", artifactsFromFiles(["proposal.md", "tasks.md"]).map(function(a) { return a.id + ":" + a.status; }), ["proposal:done", "design:missing", "tasks:done"]);
check("archived key is the directory name", arch.map(function(e) { return e.key; }), ["2026-09-13-panel-project-settings", "2026-09-13-oma-spectra-panel", "legacy-change"]);
check("basenames", basenamesFromFind("/a/b/proposal.md\n/a/b/tasks.md\n"), ["proposal.md", "tasks.md"]);

console.log(failures === 0 ? "all passed" : failures + " failed");
process.exit(failures === 0 ? 0 : 1);

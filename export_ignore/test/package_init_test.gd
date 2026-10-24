@tool
extends EditorScript
## package_init's package cfg template and the unpackaged-dir completion scan.

const Discovery = preload("res://addons/package_exporter/src/class/export/package_discovery.gd")
const PluginInit = preload("res://addons/package_exporter/src/class/export/plugin_init.gd")
const Runner = preload("res://addons/package_exporter/src/class/release/release_runner.gd")
const ROOT = "user://pe_package_init_tests"
const FIXTURES = "res://addons/package_exporter/export_ignore/test/fixtures"
const GIT_CEILING = "GIT_CEILING_DIRECTORIES"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	_test_package_cfg()
	_test_unpackaged()
	# Fixtures sit inside package_exporter's own checkout; without a ceiling, git would find that
	# repo above them, as it doesn't in CI's test workspace.
	var ceiling = OS.get_environment(GIT_CEILING)
	DirAccess.make_dir_recursive_absolute(FIXTURES)
	OS.set_environment(GIT_CEILING, ProjectSettings.globalize_path(FIXTURES))
	_test_release_workflow()
	_test_test_workflow()
	_test_project_root_workflow()
	if ceiling == "":
		OS.unset_environment(GIT_CEILING)
	else:
		OS.set_environment(GIT_CEILING, ceiling)
	_test_godot_build_name()
	var output:Array[String] = ["package_init: %d passed, %d failed" % [_passed, _failures.size()]]
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


static func _test_package_cfg() -> void:
	var cfg = ConfigFile.new()
	_check("cfg parses", cfg.parse(PluginInit.package_cfg_text("res://addons/_lib/my_pkg/")), OK)
	_check("name is folder", cfg.get_value("plugin", "name"), "my_pkg")
	_check("path drops res://", cfg.get_value("plugin", "path"), "addons/_lib/my_pkg")
	_check("version", cfg.get_value("plugin", "version"), "0.1.0")
	_check("url", cfg.get_value("plugin", "url"), "")
	_check("require", cfg.get_value("plugin", "require"), [])
	_check("namespace path", cfg.get_value("namespace", "path"), "")


static func _test_unpackaged() -> void:
	Runner.remove_dir(ProjectSettings.globalize_path(ROOT))
	_mkdir("bare/deep/deeper")
	_mkdir("group/lib/src")
	_mkdir("group/new_lib")
	_write("addon_pkg/addon.cfg")
	_mkdir(".hidden/x")
	_mkdir("_export_ignore/x")
	_write("plugin/plugin.cfg")
	_mkdir("plugin/src")
	_write("group/lib/version.cfg")
	var dir = DirAccess.open(ROOT)
	_check("symlink fixture", dir.create_link(ProjectSettings.globalize_path(ROOT), "loop"), OK)
	_check("unpackaged default depth", Discovery.discover_unpackaged(ROOT).keys(),
		["bare", "bare/deep", "group", "group/new_lib"])
	_check("depth 1", Discovery.discover_unpackaged(ROOT, 1).keys(), ["bare", "group"])
	_write("group/new_lib/version.cfg")
	_check("initialized drops off", Discovery.discover_unpackaged(ROOT).keys(), ["bare", "bare/deep", "group"])
	_check("missing root", Discovery.discover_unpackaged(ROOT.path_join("missing")), {})
	DirAccess.remove_absolute(ROOT.path_join("loop"))
	Runner.remove_dir(ProjectSettings.globalize_path(ROOT))


## Opt-in only: written at the package root, never over an existing file, refused for non-packages.
static func _test_release_workflow() -> void:
	var dir = FIXTURES.path_join("_release_workflow_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var notes:Array[String] = []
	_check("not a package refused", PluginInit.write_release_workflow(dir, notes), "")
	_check("not a package says why", notes.size() == 1 and notes[0].begins_with("Not a package"), true)
	FileAccess.open(dir.path_join("version.cfg"), FileAccess.WRITE).store_string('[plugin]\nversion="0.1.0"\n')
	notes.clear()
	var path = PluginInit.write_release_workflow(dir, notes)
	_check("written at the package root", path, dir.path_join(".github/workflows/release.yml"))
	_check("warns without a .git dir", notes.size() == 1 and "no .git dir" in notes[0], true)
	var text = FileAccess.get_file_as_string(path)
	_check("calls the reusable workflow", "uses: brohd11/godot-package-exporter/.github/workflows/package-release.yml@%s" % PluginInit.RELEASE_WORKFLOW_REF in text, true)
	_check("runs on version tags", 'tags: ["v*", "[0-9]*"]' in text, true)
	_check("builds on the editor's Godot", 'godot-version: "%s"' % PluginInit.godot_build_name() in text, true)
	_check("manual runs are dry runs", ["workflow_dispatch:" in text, "publish: ${{ github.event_name == 'push' }}" in text], [true, true])
	_check("no package-dir at the package root", "package-dir:" in text, false)
	FileAccess.open(path, FileAccess.WRITE).store_string("edited")
	notes.clear()
	_check("existing not overwritten", [PluginInit.write_release_workflow(dir, notes), FileAccess.get_file_as_string(path)], ["", "edited"])
	_check("existing says why", notes.size() == 1 and notes[0].begins_with("Workflow already exists"), true)
	Runner.remove_dir(ProjectSettings.globalize_path(dir))


## Its own file beside the release workflow, every push, a JSON list of Godot builds.
static func _test_test_workflow() -> void:
	var dir = FIXTURES.path_join("_test_workflow_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	FileAccess.open(dir.path_join("version.cfg"), FileAccess.WRITE).store_string('[plugin]\nversion="0.1.0"\n')
	var notes:Array[String] = []
	var path = PluginInit.write_test_workflow(dir, notes)
	_check("test workflow path", path, dir.path_join(".github/workflows/test.yml"))
	var text = FileAccess.get_file_as_string(path)
	_check("test workflow parses as a caller", ["package-test.yml@%s" % PluginInit.RELEASE_WORKFLOW_REF in text, "branches: [\"**\"]" in text],
		[true, true])
	_check("test workflow lists the editor's Godot", "godot-versions: '[\"%s\"]'" % PluginInit.godot_build_name() in text, true)
	_check("test workflow has no package-dir at the package root", "package-dir:" in text, false)
	_check("release workflow still separate", PluginInit.write_release_workflow(dir, notes).ends_with("release.yml"), true)
	Runner.remove_dir(ProjectSettings.globalize_path(dir))


## A package below its repo's root (a whole-project repo) is refused unless allow_project_root,
## which writes at that root with package-dir pointing back at it. A package that is its own
## repo is unaffected by the flag.
static func _test_project_root_workflow() -> void:
	var project = FIXTURES.path_join("_project_workflow_%d" % Time.get_ticks_usec())
	var package = project.path_join("addons/_lib/x")
	_write_cfg(package)
	_check("project fixture is a repo", _git_init(project), 0)
	var notes:Array[String] = []
	_check("refused without the flag", [PluginInit.write_release_workflow(package, notes), PluginInit.write_test_workflow(package, notes)], ["", ""])
	_check("refusal names the flag and the pointer", notes.size() == 2 and notes.all(func(n):
		return "--allow-project-root" in n and "package-dir: addons/_lib/x" in n), true)
	_check("refusal writes nothing", [DirAccess.dir_exists_absolute(project.path_join(".github")),
		DirAccess.dir_exists_absolute(package.path_join(".github"))], [false, false])

	notes.clear()
	var path = PluginInit.write_release_workflow(package, notes, true)
	_check("written at the repo root", path, project.path_join(".github/workflows/release.yml"))
	_check("no .git warning inside a repo", notes.is_empty(), true)
	_check("points package-dir at the package", 'package-dir: "addons/_lib/x"' in FileAccess.get_file_as_string(path), true)
	var test_path = PluginInit.write_test_workflow(package, notes, true)
	_check("test workflow at the repo root", test_path, project.path_join(".github/workflows/test.yml"))
	_check("test workflow points package-dir at the package", 'package-dir: "addons/_lib/x"' in FileAccess.get_file_as_string(test_path), true)
	notes.clear()
	_check("existing at the repo root not overwritten", PluginInit.write_release_workflow(package, notes, true), "")
	_check("existing at the repo root says why", notes.size() == 1 and notes[0].begins_with("Workflow already exists"), true)

	var own = project.path_join("addons/own")
	_write_cfg(own)
	_check("own-repo fixture is a repo", _git_init(own), 0)
	notes.clear()
	var own_path = PluginInit.write_release_workflow(own, notes, true)
	_check("own repo written at its root despite the flag", own_path, own.path_join(".github/workflows/release.yml"))
	_check("own repo has no package-dir", "package-dir:" in FileAccess.get_file_as_string(own_path), false)
	Runner.remove_dir(ProjectSettings.globalize_path(project))


static func _write_cfg(package_dir:String) -> void:
	DirAccess.make_dir_recursive_absolute(package_dir)
	FileAccess.open(package_dir.path_join("version.cfg"), FileAccess.WRITE).store_string('[plugin]\nversion="0.1.0"\n')


static func _git_init(dir:String) -> int:
	return OS.execute("git", ["-C", ProjectSettings.globalize_path(dir), "init", "-q"])


## Names must match godot-builds releases exactly, since CI downloads by them.
static func _test_godot_build_name() -> void:
	_check("patch release", PluginInit.godot_build_name({"major": 4, "minor": 6, "patch": 3, "status": "stable"}), "4.6.3-stable")
	_check("x.y.0 drops the patch", PluginInit.godot_build_name({"major": 4, "minor": 7, "patch": 0, "status": "stable"}), "4.7-stable")
	_check("pre-release", PluginInit.godot_build_name({"major": 4, "minor": 8, "patch": 0, "status": "beta1"}), "4.8-beta1")
	_check("custom build", PluginInit.godot_build_name({"major": 4, "minor": 8, "patch": 0, "status": "custom_build"}), "")
	_check("running editor is official", PluginInit.godot_build_name() != "", true)


static func _mkdir(relative:String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(relative))


static func _write(relative:String) -> void:
	var path = ROOT.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("")


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
	else:
		_failures.append("%s (expected %s, got %s)" % [label, expected, got])

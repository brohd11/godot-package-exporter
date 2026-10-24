
const UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd")
const UtilsLocal = preload("res://addons/package_exporter/src/class/utils_local.gd")

const UFile = UtilsRemote.UFile
const Confirmation = UtilsRemote.Confirmation
const FilePicker = UtilsRemote.FilePicker

const ExportFileUtils = UtilsLocal.ExportFileUtils
const KeysConfig = ExportFileUtils.KeysConfig
const ExportIgnore = ExportFileUtils.ExportIgnore
const ExportPaths = ExportFileUtils.ExportPaths
const PackageCfg = ExportFileUtils.PackageCfg

static func new_plugin(plugin_dir_name, create_export:=true):
	var new_plugin_path = "res://addons/%s" % plugin_dir_name
	if DirAccess.dir_exists_absolute(new_plugin_path):
		print("Plugin already exists.")
		return
	
	DirAccess.make_dir_recursive_absolute(new_plugin_path)
	var plugin_cap_name = plugin_dir_name.capitalize()
	
	var plugin_gd_path = new_plugin_path.path_join("plugin.gd")
	var file_access = FileAccess.open(plugin_gd_path, FileAccess.WRITE)
	file_access.store_string(_NewPluginText.PLUGIN_GD_TEXT % plugin_cap_name)
	file_access.close()
	
	var plugin_cfg_path = new_plugin_path.path_join("plugin.cfg")
	
	var cfg_file_access = FileAccess.open(plugin_cfg_path, FileAccess.WRITE)
	cfg_file_access.store_string(_NewPluginText.PLUGIN_CFG_TEXT % plugin_cap_name)
	cfg_file_access.close()
	
	print("Created plugin: %s" % plugin_cap_name)
	
	if create_export:
		plugin_init(plugin_dir_name)
	
	EditorInterface.get_resource_filesystem().scan()

static func plugin_init(plugin_name:=""):
	var plugin_dir = ""
	if plugin_name != "":
		plugin_dir = ExportPaths.resolve_target(plugin_name)
		if plugin_dir == "":
			printerr("Invalid package target (expected a path inside this project): " + plugin_name)
			return
		if not DirAccess.dir_exists_absolute(plugin_dir):
			printerr("Plugin directory does not exist: %s" % plugin_dir)
			return
	else:
		var dialog = FilePicker.Editor.dir()
		dialog.dialog.title = "Pick plugin folder..."
		var resp = await dialog.get_response()
		if resp.cancelled:
			return
		var handled = resp.payload
		plugin_dir = ExportPaths.resolve_target(handled)
		if plugin_dir == "":
			printerr("Selected package must be inside this project: " + handled)
			return
	
	var export_dir:String = ProjectSettings.localize_path(plugin_dir)
	var export_ignore_dir = ExportIgnore.dir_or_default(export_dir) # keeps an existing folder's name
	if not DirAccess.dir_exists_absolute(export_ignore_dir):
		DirAccess.make_dir_recursive_absolute(export_ignore_dir)
	for sub in ExportIgnore.SUB_DIRS:
		DirAccess.make_dir_recursive_absolute(export_ignore_dir.path_join(sub))
	
	#var export_config_path = export_ignore_dir.path_join("plugin_export.json")
	var export_config_path = export_ignore_dir.path_join(ExportIgnore.CONFIG_NAMES[0])
	if FileAccess.file_exists(export_config_path):
		var conf = Confirmation.new("Overwrite: %s?" % export_config_path)
		var conf_handled = await conf.handled
		if not conf_handled:
			return

	var export_dir_name = export_dir.trim_suffix("/").get_file()
	var template_data = PluginExportJSON.get_body_data()
	template_data[KeysConfig.EXPORT_ROOT] = export_ignore_dir.path_join("exports")
	var plugin_folder = export_dir_name.capitalize().replace(" ", "")
	template_data[KeysConfig.PLUGIN_FOLDER] = "%s{{version=%s}}" % [plugin_folder, export_dir]
	
	var export = PluginExportJSON.get_export_obj_data()
	export[KeysConfig.Export.SOURCE] = export_dir
	export[KeysConfig.Export.REMOTE_DIR] = export_dir.path_join("src/remote")
	var export_dir_name_dash = export_dir_name.replace("_", "-")
	export[KeysConfig.Export.EXPORT_NAME] = "%s{{version=%s}}" % [export_dir_name_dash, export_dir]
	export[KeysConfig.Export.EXPORT_FOLDER] = export_dir.trim_prefix("res://").trim_suffix("/")
	
	var exclude = export.get(KeysConfig.Export.EXCLUDE)
	exclude[KeysConfig.Export.Exclude.DIRECTORIES] = [export_ignore_dir]
	
	template_data[KeysConfig.EXPORTS].append(export)

	#UFile.write_to_json(template_data, export_config_path)
	YAMLParser.dump_to_file(template_data, export_config_path)
	
	var gitignore_fa = FileAccess.open(export_ignore_dir.path_join(".gitignore"), FileAccess.WRITE)
	gitignore_fa.store_line("exports/")
	gitignore_fa.close()
	
	EditorInterface.get_resource_filesystem().scan()
	
	print("Plugin init complete: %s" % plugin_dir)
	return export_config_path


## Turns any folder into a library package: a package cfg (`cfg_name`, one of PackageCfg.NAMES),
## its own git repo, src/, then plugin_init.
static func package_init(target:String, cfg_name:String = "addon.cfg"):
	if not cfg_name in PackageCfg.NAMES:
		printerr("Invalid cfg name %s, expected one of: %s" % [cfg_name, ", ".join(PackageCfg.NAMES)])
		return
	var package_dir = ExportPaths.resolve_target(target)
	if package_dir == "":
		printerr("Invalid package target (expected a path inside this project): " + target)
		return
	DirAccess.make_dir_recursive_absolute(package_dir)
	var existing = PackageCfg.find(package_dir)
	if existing != "":
		printerr("Already a package, %s exists: %s" % [existing.get_file(), package_dir])
		return
	
	var cfg_f = FileAccess.open(package_dir.path_join(cfg_name), FileAccess.WRITE)
	cfg_f.store_string(package_cfg_text(package_dir))
	cfg_f.close()
	
	var global_dir = ProjectSettings.globalize_path(package_dir)
	var git_path = package_dir.path_join(".git")
	if not DirAccess.dir_exists_absolute(git_path) and not FileAccess.file_exists(git_path): # file form: worktree/submodule
		var output = []
		if OS.execute("git", ["-C", global_dir, "init"], output, true) != 0:
			push_warning("git init failed in %s: %s" % [package_dir, "\n".join(PackedStringArray(output)).strip_edges()])
	
	DirAccess.make_dir_recursive_absolute(package_dir.path_join("src"))
	print("Package init complete: %s" % package_dir)
	return await plugin_init(package_dir)

static func package_cfg_text(package_dir:String) -> String:
	var res_path = ProjectSettings.localize_path(package_dir).trim_suffix("/")
	return _NewPluginText.PACKAGE_CFG_TEXT % [res_path.get_file(), res_path.trim_prefix("res://")]


const RELEASE_WORKFLOW_PATH = ".github/workflows/release.yml"
const TEST_WORKFLOW_PATH = ".github/workflows/test.yml"
## Ref of PackageExporter's reusable workflows that callers pin. Not a version tag: the resolver reads
## every v* tag here as a package_exporter release, so a moving `v1` would outrank them all.
const RELEASE_WORKFLOW_REF = "main"

## Opts a package into CI releases: a workflow at its repo root calling PackageExporter's reusable
## one on version tags. Separate from package_init so publishing stays a choice; never overwrites.
## A package below its repo's root (a whole-project repo) is refused unless `allow_project_root`,
## which writes at that root with package-dir pointing at it. Returns the path written, or "".
static func add_release_workflow(target:String, allow_project_root:bool = false) -> String:
	return _report_workflow("Release", write_release_workflow, target, allow_project_root)


## Opts a package into test CI: on every push and pull request, its suites run against its requires
## at their tags. Never overwrites; `allow_project_root` as in add_release_workflow. Returns the
## path written, or "".
static func add_test_workflow(target:String, allow_project_root:bool = false) -> String:
	return _report_workflow("Test", write_test_workflow, target, allow_project_root)


## add_release_workflow without console output: a refusal ("" returned) or a warning about a
## written file goes into `notes`, so tests can assert on it.
static func write_release_workflow(target:String, notes:Array[String], allow_project_root:bool = false) -> String:
	return _write_workflow(target, RELEASE_WORKFLOW_PATH, _NewPluginText.RELEASE_WORKFLOW_TEXT, notes, allow_project_root)


static func write_test_workflow(target:String, notes:Array[String], allow_project_root:bool = false) -> String:
	return _write_workflow(target, TEST_WORKFLOW_PATH, _NewPluginText.TEST_WORKFLOW_TEXT, notes, allow_project_root)


static func _report_workflow(kind:String, write:Callable, target:String, allow_project_root:bool) -> String:
	var notes:Array[String] = []
	var path = write.call(target, notes, allow_project_root)
	for note in notes:
		if path == "":
			printerr(note)
		else:
			push_warning(note)
	if path != "":
		print("%s workflow added: %s" % [kind, path])
	return path


## `text` takes the ref, the Godot version (the editor's own unless it's a custom build) and the
## package-dir lines. A package below its repo's root goes there only with `allow_project_root`:
## a plain addon folder inside a dev project's repo looks the same, and shouldn't get one by accident.
static func _write_workflow(target:String, rel_path:String, text:String, notes:Array[String], allow_project_root:bool) -> String:
	var package_dir = ExportPaths.resolve_target(target)
	if package_dir == "" or PackageCfg.find(package_dir) == "":
		notes.append("Not a package (no %s): %s" % [" / ".join(PackageCfg.NAMES), target])
		return ""
	# The prefix (the package's path in its repo) rather than comparing dirs, which symlinks break.
	var repo = ExportFileUtils.run_git_exec(package_dir, ["rev-parse", "--show-toplevel", "--show-prefix"])
	var repo_lines = "".join(repo.output).split("\n") if repo.exit == 0 else PackedStringArray()
	var prefix = repo_lines[1].strip_edges().trim_suffix("/") if repo_lines.size() > 1 else ""
	var root_dir = package_dir
	var package_dir_lines = ""
	if prefix != "":
		var toplevel = repo_lines[0].strip_edges()
		if not allow_project_root:
			notes.append("%s is inside the repo at %s, not its root; pass --allow-project-root to write the workflow there with package-dir: %s" % [
				package_dir, toplevel, prefix])
			return ""
		root_dir = ProjectSettings.localize_path(toplevel)
		package_dir_lines = _NewPluginText.PACKAGE_DIR_TEXT % prefix
	var path = root_dir.path_join(rel_path)
	if FileAccess.file_exists(path):
		notes.append("Workflow already exists: " + path)
		return ""
	if repo.exit != 0:
		notes.append("%s has no .git dir; the workflow only runs from the package's own repo root" % package_dir)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		notes.append("Could not write " + path)
		return ""
	var godot = godot_build_name()
	if godot.is_empty():
		var info = Engine.get_version_info()
		godot = "%d.%d-stable" % [info.major, info.minor]
		notes.append("%s isn't an official Godot build; the workflow uses %s, edit godot-version to change it" % [info.string, godot])
	file.store_string(text % [RELEASE_WORKFLOW_REF, godot, package_dir_lines])
	file.close()
	return path


## The godot-builds release name of `info` (Engine.get_version_info()): "4.6.3-stable", "4.7-stable",
## "4.8-beta1". CI downloads exactly that build, so a custom build's status gives "".
static func godot_build_name(info:Dictionary = Engine.get_version_info()) -> String:
	var status = str(info.get("status", ""))
	var official = RegEx.create_from_string("^(stable|(alpha|beta|rc|dev)\\d+)$")
	if official.search(status) == null:
		return ""
	var version = "%d.%d" % [info.major, info.minor]
	if int(info.get("patch", 0)) > 0:
		version += ".%d" % info.patch
	return version + "-" + status


class _NewPluginText:
	const RELEASE_WORKFLOW_TEXT = \
'# Builds and publishes this package on version tags with PackageExporter. The tag must match
# version= in the package cfg; deps are fetched by tag, so they need pushing first.
# A manual run (Actions tab) builds the tag matching version= without publishing it.
name: release
on:
  push:
    tags: ["v*", "[0-9]*"]
  workflow_dispatch:
jobs:
  release:
    uses: brohd11/godot-package-exporter/.github/workflows/package-release.yml@%s
    with:
      # Builds and verifies on this Godot; it must run everything the package and its deps use.
      godot-version: "%s"
      publish: ${{ github.event_name == \'push\' }}
%s    permissions:
      contents: write
'

	const TEST_WORKFLOW_TEXT = \
'# Tests this package with PackageExporter: its suites, as pushed, against its requires at their
# tags - so a pass means the declared requires are enough. Add Godot builds to test on more.
name: test
on:
  push:
    branches: ["**"]
  pull_request:
  workflow_dispatch:
jobs:
  test:
    uses: brohd11/godot-package-exporter/.github/workflows/package-test.yml@%s
    with:
      godot-versions: \'["%s"]\'
%s'

	const PACKAGE_DIR_TEXT = \
'      # The package\'s folder in this repo, since the repo isn\'t the package itself.
      package-dir: "%s"
'

	const PLUGIN_GD_TEXT = \
'@tool' + \
'\nextends EditorPlugin' + \
'
func _get_plugin_name() -> String:
	return "%s"
func _get_plugin_icon() -> Texture2D:' + \
'\n\treturn EditorInterface.get_base_control().get_theme_icon("Node", &"EditorIcons")' + \
'\nfunc _has_main_screen() -> bool:
	return true

func _make_visible(visible:bool) -> void:
	pass

func _enable_plugin() -> void:
	pass

func _disable_plugin() -> void:
	pass

func _enter_tree() -> void:
	pass

func _exit_tree() -> void:
	pass'

	const PLUGIN_CFG_TEXT = \
'[plugin]

name="%s"
description=""
author=""
version="0.1.0"
script="plugin.gd"'

	const PACKAGE_CFG_TEXT = \
'[plugin]
name="%s"
path="%s"
version="0.1.0"
url=""
require=[]

[namespace]
path=""
'


class PluginExportJSON:
	static func _optimizer_defaults() -> Dictionary:
		var settings:Dictionary = UtilsRemote.GDScriptOptimizer.Config.DEFAULTS.duplicate(true)
		settings.enabled = true
		return settings

	static func get_body_data():
		return {
			KeysConfig.EXPORT_ROOT: "",
			KeysConfig.PLUGIN_FOLDER: "",
			KeysConfig.PRE_SCRIPT: "",
			KeysConfig.POST_SCRIPT: "",
			# build_require / test_require default to the cfg's require, compile_require and
			# exported_require to [] (DepResolver, ExportData), so new configs leave them out.
			KeysConfig.OPTIONS: {
				KeysConfig.Options.OVERWRITE: true,
				KeysConfig.Options.INCLUDE_UID: true,
				KeysConfig.Options.INCLUDE_IMPORT: true,
				KeysConfig.Options.IGNORE_SRC: true,
				KeysConfig.Options.USE_TAG_IN_CFG: true,
				KeysConfig.Options.INCLUDE_MIN_VERSION: true,
				KeysConfig.Options.MOVE_GLOBAL_FILES: true,
				KeysConfig.Options.INCLUDE_DOCS: true,
				KeysConfig.Options.INCLUDE_PROJECT_LICENSE: false,
				KeysConfig.Options.PARSER_SETTINGS:{
					"use_relative_paths":false,
					"backport_target": 100,
					"parse_cs":{
						"namespace_rename":{}
						},
					"parse_gd":{
						"replace_editor_interface":false,
						"optimizer": _optimizer_defaults(),
						"class_rename_ignore":[],
						"backport_string_renames":{},
						},
					"parse_tscn":{},
					"parse_tres":{},
				}
			},
			"exports": [],
		}
	
	static func get_export_obj_data():
		return {
			KeysConfig.Export.SOURCE: "",
			KeysConfig.Export.EXPORT_NAME: "",
			KeysConfig.Export.EXPORT_FOLDER: "",
			KeysConfig.Export.EXCLUDE: {
				KeysConfig.Export.Exclude.DIRECTORIES: [],
				KeysConfig.Export.Exclude.FILE_EXTENSIONS: [],
				KeysConfig.Export.Exclude.FILES: [],
				},
			KeysConfig.Export.OTHER_TRANSFERS:[],
			KeysConfig.Options.PARSER_OVERIDE_SETTINGS:{
				"parse_cs":{},
				"parse_gd":{},
				"parse_tscn":{},
				"parse_tres":{},
			}
		}

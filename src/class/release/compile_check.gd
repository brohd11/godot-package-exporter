@tool
extends RefCounted
## Proves a release export stands alone: installs it into an empty project (plus runtime deps),
## loads every script and resource there, and collects parse/compile errors from the output.
## load() hands back a non-null GDScript even when compilation fails, so output is the real signal.
## Files whose extends line carries RUNTIME_EXTEND_TAG are not loaded: that line is a placeholder
## swapped at runtime (Singletons.RuntimeExtend), so it can never compile as written.

const ReleaseRunner = preload("res://addons/package_exporter/src/class/release/release_runner.gd")

const PROBE_DIR = "pe_compile_probe"
const LOAD_FAIL_PREFIX = "PE_LOAD_FAIL "
const LOAD_EXTENSIONS = ["gd", "tscn", "tres"]
const RUNTIME_EXTEND_TAG = "#! pe-runtime-extend"

const _PROBE = """@tool
extends EditorPlugin
# Written by PackageExporter's release compile check: loads every file of one plugin, then quits.

var _started := false
var _done := false

func _enter_tree() -> void:
	set_process(true)
	_run.call_deferred()

# Same guard as the export autorun: a script error must not leave the parent waiting forever.
# Quitting without the result line is reported by the parent as an unfinished probe.
func _process(_delta:float) -> void:
	if _started and not _done:
		_done = true
		get_tree().quit(3)

func _run() -> void:
	var fs = EditorInterface.get_resource_filesystem()
	await get_tree().process_frame
	while fs.is_scanning():
		await get_tree().process_frame
	_started = true
	var skip = %s
	for path in _walk("%s"):
		if path.get_extension() in %s and not path in skip:
			if ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) == null:
				print("%s" + path)
	_done = true
	print("%s{}")
	get_tree().quit()

func _walk(dir:String) -> Array:
	var out = []
	for f in DirAccess.get_files_at(dir):
		out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_walk(dir.path_join(d)))
	return out
"""


## Preload/ext_resource targets that point inside the plugin but don't exist. Cheap, so it runs
## before a Godot process is spent. Same walk as export_fixture_test's every-reference check.
static func broken_references(plugin_dir:String, install_path:String) -> Array[String]:
	plugin_dir = plugin_dir.trim_suffix("/")
	var preload_regex = RegEx.new()
	preload_regex.compile(r'(?:preload|load)\(\s*"([^"]+)"\s*\)')
	var ext_resource_regex = RegEx.new()
	ext_resource_regex.compile(r'\[ext_resource[^\]]*\bpath="([^"]+)"')

	var broken:Array[String] = []
	for file in _walk(plugin_dir):
		var ext = file.get_extension()
		if not ext in LOAD_EXTENSIONS:
			continue
		var regex = preload_regex if ext == "gd" else ext_resource_regex
		for m in regex.search_all(FileAccess.get_file_as_string(file)):
			var target = m.get_string(1)
			var resolved = _resolve(target, file, plugin_dir, install_path)
			if resolved != "" and not FileAccess.file_exists(resolved):
				broken.append("%s -> %s" % [file.trim_prefix(plugin_dir + "/"), target])
	return broken


## .gd files under plugin_dir, relative to it, whose extends line carries RUNTIME_EXTEND_TAG.
static func runtime_extended(plugin_dir:String) -> Array[String]:
	plugin_dir = plugin_dir.trim_suffix("/")
	var found:Array[String] = []
	for file in _walk(plugin_dir):
		if file.get_extension() != "gd":
			continue
		var access = FileAccess.open(file, FileAccess.READ)
		if access == null:
			continue
		# extends sits in the header; a few lines covers @tool and doc comments above it
		for i in 10:
			if access.eof_reached():
				break
			var line = access.get_line()
			if line.begins_with("extends"):
				if RUNTIME_EXTEND_TAG in line:
					found.append(file.trim_prefix(plugin_dir + "/"))
				break
	return found


## Errors from loading the export, installed at install_path in a clean project at work_dir; []
## means it compiled. `extra_installs` maps res:// install paths to source dirs, for runtime deps.
static func compile_errors(plugin_dir:String, install_path:String, work_dir:String, extra_installs:Dictionary = {}) -> Array[String]:
	plugin_dir = plugin_dir.trim_suffix("/")
	install_path = install_path.trim_suffix("/")
	var errors:Array[String] = []

	if DirAccess.dir_exists_absolute(work_dir):
		ReleaseRunner.remove_dir(work_dir)
	if not ReleaseRunner.copy_dir(plugin_dir, work_dir.path_join(install_path.trim_prefix("res://"))):
		errors.append("could not install %s into %s" % [plugin_dir, work_dir])
		return errors
	for extra in extra_installs:
		ReleaseRunner.copy_dir(extra_installs[extra], work_dir.path_join(extra.trim_prefix("res://")))

	var skip:Array[String] = []
	for rel in runtime_extended(plugin_dir):
		skip.append(install_path.path_join(rel))
	var probe = _PROBE % [str(skip), install_path, str(LOAD_EXTENSIONS), LOAD_FAIL_PREFIX, ReleaseRunner.RESULT_PREFIX]
	ReleaseRunner.write_plugin(work_dir, PROBE_DIR, probe)
	var project = ReleaseRunner.project_godot("PE Compile Check", ["res://addons/%s/plugin.cfg" % PROBE_DIR])
	var file = FileAccess.open(work_dir.path_join("project.godot"), FileAccess.WRITE)
	file.store_string(project)
	file.close()

	var imported = ReleaseRunner.godot(work_dir, ["--import"])
	var run = ReleaseRunner.godot(work_dir, ["--editor"])
	var output = imported.output + run.output

	if not ReleaseRunner.RESULT_PREFIX in run.output:
		errors.append("compile probe never finished (exit %d)" % run.exit)
	for line in output.split("\n"):
		if line.begins_with(LOAD_FAIL_PREFIX):
			errors.append("failed to load " + line.trim_prefix(LOAD_FAIL_PREFIX))
	for err in ReleaseRunner.script_errors(output):
		if "res://addons/%s/" % PROBE_DIR in err:
			continue
		# Normally under .gdignore and never parsed, but an import that does reach one is no failure.
		if skip.any(func(path): return path in err):
			continue
		errors.append(err)
	return errors


## A reference as written, mapped back onto disk. The install path means the export dir once
## installed; other plugins and non-addon paths aren't this check's business.
static func _resolve(target:String, from_file:String, plugin_dir:String, install_path:String) -> String:
	if target.begins_with("uid://"):
		return ""
	var prefix = install_path.trim_suffix("/") + "/"
	if target.begins_with(prefix):
		return plugin_dir.path_join(target.trim_prefix(prefix))
	if target.begins_with("./") or target.begins_with("../"):
		return from_file.get_base_dir().path_join(target).simplify_path()
	return ""


static func _walk(dir:String) -> Array[String]:
	var out:Array[String] = []
	for f in DirAccess.get_files_at(dir):
		out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_walk(dir.path_join(d)))
	return out

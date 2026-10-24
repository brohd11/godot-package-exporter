
const UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd")
const UtilsLocal = preload("res://addons/package_exporter/src/class/utils_local.gd")

const ExportData = UtilsLocal.ExportData
const FileParser = UtilsLocal.FileParser

const UFile = UtilsRemote.UFile
const UString = UtilsRemote.UString
const UEditor = UtilsRemote.UEditor
const UClassDetail = UtilsRemote.UClassDetail
const ScanGD = UtilsRemote.DepScanner.ScanGD
const DependencyTags = UtilsLocal.DependencyTags
const Reporter = UtilsLocal.Reporter

const Confirmation = UtilsRemote.Confirmation
const ExportIgnore = preload("res://addons/package_exporter/src/class/export/export_ignore.gd")
const ExportPaths = preload("res://addons/package_exporter/src/class/export/export_paths.gd")
const PackageCfg = preload("res://addons/package_exporter/src/class/export/package_cfg.gd")

const VALID_FILE_NAMES = ExportIgnore.CONFIG_NAMES

static var _global_class_regex:RegEx
static var _lookback_regex:RegEx

static var string_maps = {}

## The plugin's export config in _export_ignore/ or export_ignore/, preferring the former. With
## none, where one would go - so "not found" messages point at a sensible path.
static func get_export_config_path(addon_name:String, reporter = null):
	var plugin_dir = ExportPaths.resolve_target(addon_name)
	if plugin_dir == "":
		Reporter.or_default(reporter).error("Invalid package target (expected a path inside this project): " + addon_name)
		return ""
	return ExportIgnore.config_path(plugin_dir)

static func get_export_data(export_config_path:String, reporter = null):
	reporter = Reporter.or_default(reporter)
	if not FileAccess.file_exists(export_config_path):
		reporter.error("Export file path does not exist: " + export_config_path)
		return
	var export_file = FileAccess.open(export_config_path, FileAccess.READ)
	if export_file == null:
		reporter.error("Error opening export configuration file: " + export_config_path)
		return
	
	var config_string = export_file.get_as_text()
	if export_config_path.get_extension() == "json":
		var json = JSON.new()
		var parse_result = json.parse(config_string)
		if parse_result != OK:
			reporter.error("Package Exporter - Error parsing JSON: " + json.get_error_message() + " at line " + str(json.get_error_line()))
			return
		return json.data
	elif export_config_path.get_extension() in ["yml", "yaml"]:
		var parser = YAMLParser.new()
		var err = parser.parse(config_string)
		if err != OK:
			reporter.error("Package Exporter - Error parsing YAML: %s %s" % [err, parser.errors])
			return
		return parser.data

static func get_file_export_path(file_path:String, export_config_path:String, desired_export:int=-1, export_data:ExportData=null):
	if not FileAccess.file_exists(file_path):
		Reporter.or_default(export_data.reporter if export_data else null).error("Package Exporter - File doesn't exist: %s" % file_path)
		return
	if export_data == null:
		export_data = ExportData.new(export_config_path)
	var reporter = export_data.reporter
	if not export_data.data_valid:
		reporter.error("Issue with export data.")
		return
	
	var exports = export_data.exports
	if exports.size() > 1 and desired_export == -1:
		reporter.warn("Multiple exports, defaulting to first.")
	if desired_export == -1:
		desired_export = 0
	if desired_export > exports.size() - 1:
		reporter.error("Desired export index greater than exports in file.")
		return
	
	var export = exports[desired_export] as ExportData.Export
	var local_path = ProjectSettings.localize_path(file_path)
	if local_path not in export.valid_files_for_transfer.keys():
		reporter.warn("File path not a valid export: %s" % file_path)
		return
	else:
		var export_file_data = export.valid_files_for_transfer.get(local_path)
		var export_path = export_file_data.get(KeysData.TO)
		return export_path


static func get_version(folder, export_config_file, reporter = null):
	reporter = Reporter.or_default(reporter)
	var target_folder = ExportPaths.resolve_target(folder)
	var config_dir = export_config_file.get_base_dir()
	var plugin_cfg_path = ""
	for dir in [target_folder, config_dir, config_dir.get_base_dir()]:
		plugin_cfg_path = PackageCfg.find(dir)
		if plugin_cfg_path != "":
			break
	
	if plugin_cfg_path == "":
		reporter.error("No package cfg (%s) in %s, Aborting." % ["/".join(PackageCfg.NAMES), target_folder], true)
		return
	
	var plugin_data = UFile.load_config_file(plugin_cfg_path)
	if not plugin_data:
		reporter.error("Issue getting plugin data. Aborting.", true)
		return 
	return PackageCfg.get_value(plugin_data, "version", "No version")


static func replace_version(input_text: String, export_config_file, reporter = null) -> String:
	var regex = RegEx.new()
	var pattern = r"\{\{version=([^}]*)\}\}"
	regex.compile(pattern)
	# Targets can contain slashes, so resolve explicit tokens before walking output segments.
	var matches = regex.search_all(input_text)
	matches.reverse()
	for found in matches:
		var version = get_version(found.get_string(1), export_config_file, reporter)
		if not version:
			return ""
		input_text = input_text.substr(0, found.get_start()) + "-" + str(version) + input_text.substr(found.get_end())
	var output_text = ""
	var slice_count = input_text.get_slice_count("/")
	for i in range(slice_count):
		var slice = input_text.get_slice("/", i)
		var edited_slice
		if slice.find("{{version}}") > -1:
			var version_target = slice.replace("{{version}}", "")
			var version = get_version(version_target, export_config_file, reporter)
			if version:
				version = "-" + version
				edited_slice = slice.replace("{{version}}", version)
			else:
				edited_slice = slice.replace("{{version}}", "{{version error}}")
				return ""
		else:
			edited_slice = slice
		if edited_slice != "":
			output_text += edited_slice + "/"
	
	return output_text


static func get_full_export_path(export_root, plugin_folder, export_config_path, reporter = null):
	export_root = ProjectSettings.globalize_path(export_root)
	var full_export_path = export_root.path_join(plugin_folder)
	full_export_path = replace_version(full_export_path, export_config_path, reporter)
	if full_export_path == "":
		return ""
	if not full_export_path.ends_with("/"):
		full_export_path = full_export_path + "/"
	
	var os_name = OS.get_name()
	if os_name == "Linux" or os_name == "macOS": # not sure about mac
		if not full_export_path.begins_with("/"):
			full_export_path = "/" + full_export_path
	
	return full_export_path


## An export's package folder under the full export path - the unit that gets zipped. Defaults to
## plugin_folder's last segment. Version resolved, trailing "/".
static func get_export_name(export_entry:Dictionary, plugin_folder:String, export_config_path, reporter = null) -> String:
	var export_name = String(export_entry.get(KeysConfig.Export.EXPORT_NAME, ""))
	if export_name == "":
		export_name = plugin_folder.trim_suffix("/").get_file()
	return replace_version(export_name, export_config_path, reporter)

## Where an export installs relative to res:// (e.g. "addons/my_plugin/" or "lib/my_lib/"),
## recreated as-is inside the package so it extracts straight into a project. Defaults to the
## source dir; "" when export_folder_error() rejects it.
static func get_export_folder(export_entry:Dictionary, _export_config_path = null) -> String:
	var folder = String(export_entry.get(KeysConfig.Export.EXPORT_FOLDER, ""))
	if ExportPaths.export_folder_error(folder) != "":
		return ""
	if folder == "":
		folder = String(export_entry.get(KeysConfig.Export.SOURCE, ""))
	folder = folder.strip_edges().trim_prefix("res://").trim_prefix("/").trim_suffix("/")
	return folder + "/" if folder != "" else ""


static func run_export_script(script_path, func_name, export_data):
	if not check_export_script_valid(script_path, func_name, export_data.reporter):
		return
	_run_export_script(script_path, func_name, export_data)

static func check_export_script_valid(script_path, func_name, reporter = null):
	reporter = Reporter.or_default(reporter)
	if not FileAccess.file_exists(script_path):
		reporter.error("%s script file not found." % func_name, true)
		return false
	var loaded_script = load(script_path)
	var script_ins = loaded_script.new()
	var script_valid = script_ins.has_method(func_name)
	script_ins.queue_free()
	if not script_valid:
		reporter.error("Export script does not have method: %s." % func_name, true)
		return false
	return true

static func _run_export_script(script_path, func_name, export_data):
	var script = load(script_path)
	var script_ins = script.new()
	EditorInterface.get_base_control().add_child(script_ins)
	if script_ins.has_method("_configure"): # duck-typed: plain Node scripts predate ExportScript
		script_ins._configure(export_data)
	await script_ins.call(func_name)
	script_ins.queue_free()


static func check_ignore(local_path, export_obj:ExportData.Export):
	if ExportIgnore.is_inside(local_path, export_obj.source):
		return true # the plugin's dev-only folder never ships, whatever the exclude list still names
	for d in export_obj.exclude_directories:
		if local_path.find(d) > -1:
			return true
	var file_ext = local_path.get_extension()
	for ext in export_obj.exclude_file_extensions:
		if ext == file_ext:
			return true
	for f in export_obj.exclude_files:
		if f == local_path:
			return true
	
	return false


## Expands other_transfers into one {FROM, TO, ...flags} entry per file, TO in source space.
## A directory source keeps its subpaths under `to`. Any error invalidates the export and returns [].
static func get_other_transfer_data(export_obj:ExportData.Export) -> Array:
	var export_source_path = export_obj.source

	var transfers = []
	var seen = {} # destination -> source, so two files can never land on one path
	for other in export_obj.other_transfers:
		var to:String = other.get(KeysData.TO)
		if not to.begins_with(export_source_path):
			to = export_source_path.path_join(to)

		# Copied onto every file the row expands to, so a new flag needs no plumbing here.
		var flags = {}
		for key in [KeysData.CUSTOM_TREE_MESSAGE, KeysData.IGNORE_DEPS]:
			if other.has(key):
				flags[key] = other[key]

		var from_files = other.get(KeysData.FROM)
		if from_files == null and to.get_file() == ".gdignore":
			from_files = KeysData.VIRTUAL_GDIGNORE
			flags[KeysData.CUSTOM_TREE_MESSAGE] = " (virtual file)"

		var pairs = [] # [from, to]
		if from_files is String:
			if FileAccess.file_exists(from_files) or from_files.begins_with(KeysData.VIRTUAL):
				pairs.append([from_files, to])
			elif DirAccess.dir_exists_absolute(from_files):
				var dir = from_files.trim_suffix("/") + "/"
				var files = UtilsRemote.GetFiles.scan(dir) if other.get(KeysData.RECURSIVE, false) \
						else DirAccess.get_files_at(dir)
				for f:String in files:
					if f.get_extension() in ["uid", "import"]:
						continue
					var path = dir.path_join(f) if f.is_relative_path() else f
					pairs.append([path, to.path_join(path.trim_prefix(dir))])
			else:
				export_obj.reporter.error("Path not file or dir: %s" % from_files)
				export_obj.invalidate()
				return []
		elif from_files is Array:
			for file in from_files:
				if not FileAccess.file_exists(file):
					export_obj.reporter.error("File doesn't exist, aborting: %s" % file)
					export_obj.invalidate()
					return []
				pairs.append([file, to.path_join(file.get_file())])
		else:
			export_obj.reporter.error("Issues with other transfers, destination: %s" % to)
			export_obj.invalidate()
			return []

		for pair in pairs:
			if seen.has(pair[1]):
				export_obj.reporter.error("Error with other transfers, %s and %s both export to: %s" % [seen[pair[1]], pair[0], pair[1]])
				export_obj.invalidate()
				return []
			seen[pair[1]] = pair[0]
			var entry = flags.duplicate()
			entry[KeysData.FROM] = pair[0]
			entry[KeysData.TO] = pair[1]
			transfers.append(entry)

	return transfers



static func write_zip_file(path:String, files):
	var zip = ZIPPacker.new()
	var err = zip.open(path)
	if err != OK:
		return err
	var base_dir = path.get_basename()
	for f in files:
		var f_path:String = f.replace(base_dir, "")
		if f_path.begins_with("/"):
			f_path = f_path.trim_prefix("/") # what is this for??
		zip.start_file(f_path)
		var f_content = FileAccess.get_file_as_bytes(f)
		zip.write_file(f_content)
		zip.close_file()
	
	zip.close()
	return OK

static func write_new_uid(uid_path):
	var id = ResourceUID.create_id()
	var uid = ResourceUID.id_to_text(id)
	var f = FileAccess.open(uid_path, FileAccess.WRITE)
	f.store_string(uid)

static func is_remote_file(file_path:String):
	var file_access = FileAccess.open(file_path, FileAccess.READ)
	var count = 0
	while not file_access.eof_reached() and count < 10:
		var line = file_access.get_line()
		if line.begins_with("#! remote"):
			return true
		count += 1

	return false


## The path a `#! remote` file extends, resolved absolute, or "" if it does not extend one.
## Such a file is a stub standing in for the real script, which is what gets copied in its place.
static func get_remote_extends_path(file_path:String, export_obj:ExportData.Export) -> String:
	var text = ScanGD.mask_ignored_lines(FileAccess.get_file_as_string(file_path),
		[DependencyTags.IGNORE_REMOTE])
	for line:String in text.split("\n"):
		var extend_idx = line.find("extends ") # ""
		var class_idx = line.find("class ") # ""
		var comment_idx = line.find("#")
		if comment_idx > -1 and comment_idx < extend_idx:
			continue

		if extend_idx > -1 and line.count('"') == 2 and (class_idx == -1 or class_idx > extend_idx):
			var remote_file_path = line.get_slice('"', 1)
			remote_file_path = remote_file_path.get_slice('"', 0)
			if not remote_file_path.is_absolute_path():
				var absolute = export_obj.ensure_absolute_path(remote_file_path, file_path)
				export_obj.reporter.info("Not absolute path: %s -> %s" % [remote_file_path, absolute])
				remote_file_path = absolute

			if FileAccess.file_exists(remote_file_path):
				return remote_file_path
			export_obj.reporter.error("Extended file could not be found: %s" % remote_file_path)
			return ""

	return ""



static func get_global_classes_in_file(file_path:String, global_class_dict:Dictionary, reporter = null):
	var class_data = _get_global_classes_in_file(file_path, global_class_dict, reporter)
	class_data.erase("global_class_definition")
	return class_data.keys()

## The names a chunk of source uses, for callers holding text rather than a path - the export
## rewrites a file in memory before it is written back, and what it used before the rewrite is
## not what it uses after.
static func get_global_classes_in_file_text(text:String, global_class_dict:Dictionary) -> Array:
	var class_data = _get_global_classes_in_text(text, global_class_dict)
	class_data.erase("global_class_definition")
	return class_data.keys()

static func _get_global_classes_in_file(file_path:String, global_class_dict:Dictionary, reporter = null):
	var file_access = FileAccess.open(file_path, FileAccess.READ)
	if not file_access:
		Reporter.or_default(reporter).error("Could not open file: %s" % file_path)
		return {}
	return _get_global_classes_in_text(file_access.get_as_text(), global_class_dict)

static func _get_global_classes_in_text(file_as_string:String, global_class_dict:Dictionary):
	if not is_instance_valid(_global_class_regex):
		_global_class_regex = RegEx.new()
		_global_class_regex.compile("\\b[a-zA-Z_]\\w*\\b")

	var string_map = get_string_map(file_as_string)
	var dependency_text = ScanGD.mask_ignored_lines(file_as_string, [DependencyTags.IGNORE_REMOTE])
	var found_classes = {}
	
	var matches = _global_class_regex.search_all(file_as_string)
	for m in matches:
		var start_index = m.get_start()
		var word = m.get_string()
		if not global_class_dict.has(word):
			continue
		if string_map.index_in_string_or_comment(start_index):
			continue
		#if string_map.comment_mask[start_index] == 1:
			#continue
		#if string_map.string_mask[start_index] == 1:
			#continue
		if is_member_access(file_as_string, start_index):
			continue
		if is_class_definition(file_as_string, start_index):
			found_classes["global_class_definition"] = word
			continue
		if dependency_text.substr(start_index, word.length()) != word:
			continue
		
		found_classes[word] = true
	
	return found_classes

static func get_string_map(text:String):
	if not is_instance_valid(string_maps):
		string_maps = {}
	if string_maps.has(text):
		return string_maps[text]
	var string_map = UString.get_string_map(text, UString.StringMap.Mode.STRING)
	string_maps[text] = string_map
	return string_map

## True when the token is the tail of a dotted expression - the "UFile" of
## "ALibRuntime.Utils.UFile". Only the head of a chain is a use of the class; a tail that happens
## to share a name with a global class is a member of something else entirely, and treating it as
## a use gets it a bogus injected preload and a \bName\b rename through the middle of the chain.
static func is_member_access(text: String, current_index: int) -> bool:
	if current_index < 1:
		return false
	return text[current_index - 1] == "."

static func is_class_definition(text: String, current_index: int) -> bool:
	if not is_instance_valid(_lookback_regex):
		_lookback_regex = RegEx.new()
		_lookback_regex.compile("\\bclass_name\\s*$")
	
	if current_index < 10:
		return false
	var lookback_amount = 20
	var start = max(0, current_index - lookback_amount)
	var length = current_index - start
	var preceding_text = text.substr(start, length)
	# Check if that chunk ends with "class_name" + whitespace
	return _lookback_regex.search(preceding_text) != null

static func get_scripts_in_ser_file(file_path:String):
	var file_access = FileAccess.open(file_path, FileAccess.READ)
	var scripts = {}
	
	while not file_access.eof_reached():
		var line = file_access.get_line()
		if line.begins_with('[ext_resource'):
			var path = line.get_slice('path="', 1)
			path = path.get_slice('"', 0)
			if path.get_extension() == "gd":
				scripts[path] = true
	
	return scripts.keys()

static func get_global_singleton_module_scripts():
	var global_classes = UClassDetail.get_all_global_class_paths()
	var valid = []
	for path in global_classes.values():
		if is_singleton_module_script(path):
			valid.append(path)
	return valid

static func is_singleton_module_script(file_path:String, reporter = null):
	if not file_path.get_extension() == "gd": return false
	var singleton_scripts = ["singleton_base.gd", "singleton_ref_count.gd"]
	if file_path.get_file() in singleton_scripts:
		return false
	if not FileAccess.file_exists(file_path):
		Reporter.or_default(reporter).error("Could not find file: %s" % file_path)
		return false
	var script = load(file_path) as GDScript
	var base_type = script.get_base_script()
	if base_type == null: return false
	return base_type.resource_path.get_file() in singleton_scripts

#! keys exit:int output:Array
static func run_git_exec(dir:String, args:Array):
	var final_args = [
		"-C",
		ProjectSettings.globalize_path(dir),
	]
	final_args.append_array(args)
	var output = []
	var exit_code = OS.execute("git", final_args, output)
	return {
		&"exit":exit_code,
		&"output": output
	}

#! keys i-run_git_exec;
static func run_git_describe(dir:String) -> Dictionary:
	return run_git_exec(dir, ["describe", "--tags", "--always", "--dirty" ])


class KeysData:
	const TO = "to"
	const FROM = "from"
	const RECURSIVE = "recursive"
	## Copied (and path-rewritten) but never scanned for dependencies or global classes.
	const IGNORE_DEPS = "ignore_deps"

	const PATH = "path"
	const REPLACE_WITH = "replace_with"
	const DEPENDENT = "dependent"
	const DEPENDENCY_DIR = "dependency_dir"
	const DEPENDENCY_SOURCE = "dependency_source"
	
	const CUSTOM_TREE_MESSAGE = "custom_tree_message"
	
	const VIRTUAL = "PE_VIRTUAL"
	const VIRTUAL_GDIGNORE = VIRTUAL + "_GDIGNORE"

class KeysConfig:
	
	const EXPORT_ROOT = "export_root"
	const PLUGIN_FOLDER = "plugin_folder"
	const PRE_SCRIPT = "pre_script"
	const POST_SCRIPT = "post_script"
	
	const BUILD_REQUIRE = "build_require"
	const TEST_REQUIRE = "test_require"
	const EXPORTED_REQUIRE = "exported_require"
	const COMPILE_REQUIRE = "compile_require"
	
	const EXPORTS = "exports"
	class Export:
		const SOURCE = "source"
		const REMOTE_DIR = "remote_dir"
		const EXPORT_NAME = "export_name"
		const EXPORT_FOLDER = "export_folder"
		const OTHER_TRANSFERS = "other_transfers"
		const EXCLUDE = "exclude"
		class Exclude:
			const DIRECTORIES = "directories"
			const FILE_EXTENSIONS = "file_extensions"
			const FILES = "files"
	
	
	const OPTIONS = "options"
	class Options:
		const INCLUDE_IMPORT = "include_import"
		const INCLUDE_UID = "include_uid"
		const USE_TAG_IN_CFG = "use_tag_in_cfg"
		const EXPORTED_DEPS = "exported_deps" # renamed to KeysConfig.EXPORTED_REQUIRE; still read
		const INCLUDE_MIN_VERSION = "include_min_version"
		const OVERWRITE = "overwrite"
		const IGNORE_DEPENDENCIES = "ignore_dependencies"
		const IGNORE_SRC = "ignore_src"
		const MOVE_GLOBAL_FILES = "move_global_files"
		const INCLUDE_DOCS = "include_docs"
		const INCLUDE_PROJECT_LICENSE = "include_project_license"

		const PARSER_SETTINGS = "parser_settings"
		# the per-parser keys inside these (class_rename_ignore, use_relative_paths,
		# reduce_access_paths, backport_target, ...) are still read as string literals
		const PARSER_OVERIDE_SETTINGS = "parser_overide_settings"

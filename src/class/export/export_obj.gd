const PLUGIN_EXPORTED = false

## Dot-prefixed so Godot never imports the docs and they stay out of a consumer's game export,
## while editor code can still read them. DocViewer looks for this name.
const DOC_DIR_NAME = ".doc"

## Base dir of a project-root LICENSE, as get_base_dir() reports it.
const PROJECT_LICENSE_DIR = "res://"

const _UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd")
const _UEditor = _UtilsRemote.UEditor
const _UtilsLocal = preload("res://addons/package_exporter/src/class/utils_local.gd")
const _ExportFileUtils = _UtilsLocal.ExportFileUtils
const _KeysConfig = _ExportFileUtils.KeysConfig
const _KeysData = _ExportFileUtils.KeysData
const _ExportData = _UtilsLocal.ExportData
const _FileParser = _UtilsLocal.FileParser
const _UClassDetail = _UtilsRemote.UClassDetail
const _UFile = _UtilsRemote.UFile
const _GetFiles = _UtilsRemote.GetFiles
const _PackageCfg = preload("res://addons/package_exporter/src/class/export/package_cfg.gd")
const _VersionScanner = preload("res://addons/package_exporter/src/editor_plugins/console_command/min_version/version_scanner.gd")

var export_data: _ExportData
var source:String
var remote_dir:String
## Package folder under the full export path; zipped as a whole.
var export_name:String
## Install path relative to res:// ("addons/..."), recreated inside the package.
var export_folder:String
var export_dir_path:String
var exclude_directories:Array
var exclude_file_extensions:Array
var exclude_files:Array
var source_files:Array
var other_transfers:Array
var valid_files_for_transfer:Dictionary = {}

var virtual_files:Dictionary = {}

var ignore_dependencies:= false

var rename_plugin := false
var plugin_name := ""
var new_plugin_name := ""

var use_relative_paths := false

var parser_overide_settings:Dictionary = {}
var file_parser:_FileParser

var files_to_copy:Dictionary = {}
## Seed set for the dependency crawl, used as a set - only its keys are ever read.
var files_to_scan_for_deps:Dictionary = {}

var replace_with_files:Dictionary = {}
## Set of doc files gathered by gather_docs, used as a set - only its keys are ever read.
var doc_files:Dictionary = {}

var file_dependencies:Dictionary = {}

var adjusted_remote_paths:Dictionary = {}
## Source-space placements stay separate from renamed paths used by exported code.
var _local_copy_paths:Dictionary = {}
var _dependency_placements:Dictionary = {}
var global_classes_used:Dictionary = {}

var class_rename_ignore:Array = []
var class_renames:Dictionary = {}

## Rewrite dotted access paths into direct preloads on export, so a file using
## "ALibRuntime.Utils.UFile" depends on u_file.gd instead of the namespace hub that would drag
## every one of its siblings in. Opt-in per export.
var reduce_access_paths:bool = false
## {file_path: {expression: {name, parent, path, tail}}} - what each file's dotted paths reduce
## to. Filled during the dependency crawl, applied on export.
var access_reductions:Dictionary = {}
## {expression: const_name} for the whole export. Names are decided once here rather than per
## file: a base script and everything deriving from it must bind an expression to the same name,
## because GDScript rejects redeclaring an inherited constant and the injection can only skip
## what an ancestor already declares if the two agree.
var access_bindings:Dictionary = {}

var unique_files:Array = []

var shared_data:Dictionary = {}

var export_file_data:Dictionary = {}

var export_valid:bool = true

func get_backport_files(backport_target):
	var required_backport_files = _UtilsLocal.Backport.get_required_files(backport_target)
	
	for file in required_backport_files:
		if file in source_files:
			continue
		unique_files.append(file)
		var export_path = get_remote_file_local_path(file)
		other_transfers.append({
			_KeysData.FROM: file,
			_KeysData.TO: export_path,
			_KeysData.CUSTOM_TREE_MESSAGE:" <- (Backport Dependency)"
		})


func get_valid_files_for_transfer():
	for file in source_files:
		if file.get_extension() == "uid" or file.get_extension() == "import":
			continue
		
		var l_path = ProjectSettings.localize_path(file)
		if _ExportFileUtils.check_ignore(l_path, self):
			continue
		
		var export_path = get_export_path(l_path)
		
		if FileAccess.file_exists(export_path) and not export_data.overwrite:
			_UEditor.push_toast("File exists, aborting: " + export_path, 2 as _UEditor.ToastSeverity)
			invalidate()
			return

		if FileAccess.file_exists(l_path):
			valid_files_for_transfer[l_path] = {_KeysData.TO:export_path}
			if rename_plugin:
				adjusted_remote_paths[l_path] = get_renamed_path(l_path)

	for entry:Dictionary in _ExportFileUtils.get_other_transfer_data(self):
		var from:String = entry[_KeysData.FROM]
		var to_path:String = entry[_KeysData.TO]
		var row = entry.duplicate()
		row.erase(_KeysData.FROM)
		row[_KeysData.TO] = get_export_path(to_path)
		if from.begins_with(_KeysData.VIRTUAL):
			if not virtual_files.has(from):
				virtual_files[from] = {}
			virtual_files[from][to_path] = row
			continue

		if FileAccess.file_exists(row[_KeysData.TO]) and not export_data.overwrite:
			_UEditor.push_toast("File exists, aborting: " + row[_KeysData.TO], 2 as _UEditor.ToastSeverity)
			invalidate()
			return

		valid_files_for_transfer[from] = row
		adjusted_remote_paths[from] = get_renamed_path(to_path)


func sort_valid_files():
	for file:String in valid_files_for_transfer.keys():
		files_to_copy[file] = valid_files_for_transfer.get(file)
		if file_deps_ignored(file):
			continue

		if not file_parser.check_file_valid(file):
			continue

		files_to_scan_for_deps[file] = true
		var file_ext = file.get_extension()
		if file_ext == "tres" or file_ext == "tscn":
			continue

		if file_ext == "gd":
			var global_name = _UClassDetail.get_global_class_name(file)
			if global_name != "" and not global_classes_used.has(global_name):
				global_classes_used[global_name] = {
					#_KeysData.DEPENDENT: file,
					_KeysData.PATH: file
					}
		
		if file_ext != "gd" or not _ExportFileUtils.is_remote_file(file):
			continue

		var remote_file_path = _ExportFileUtils.get_remote_extends_path(file, self)
		if remote_file_path == "":
			continue

		files_to_copy[file][_KeysData.REPLACE_WITH] = remote_file_path
		replace_with_files[remote_file_path] = file


func get_global_classes_used_in_valid_files():
	if ignore_dependencies:
		return
		
	# sort_valid_files seeded exactly the valid, non-ignored files; keys() snapshots it, so the
	# classes added below are not rescanned here.
	for file:String in files_to_scan_for_deps.keys():
		var file_ext = file.get_extension()
		var classes_used
		if file_ext == "gd":
			classes_used = _ExportFileUtils.get_global_classes_in_file(file, export_data.class_list)
		elif file_ext == "tres" or file_ext == "tscn":
			var classes = {}
			var scripts = _ExportFileUtils.get_scripts_in_ser_file(file)
			for path in scripts:
				var class_nm = export_data.class_path_lookup.get(path)
				if class_nm != null:
					classes[class_nm] = true
			
			classes_used = classes.keys()
			if classes_used.is_empty():
				continue
		
		if classes_used == null:
			continue
		
		var gd_parser = file_parser.default_parsers.get("gd") if file_ext == "gd" else null
		for class_nm in classes_used:
			# only a pass-through here: reduction rewrites every mention of it away, so seeding
			# the crawl at it would pull in its whole preload tree for nothing
			if gd_parser != null and gd_parser.class_reduced_away(file, class_nm):
				continue
			var remote_path = export_data.class_list.get(class_nm)
			if global_classes_used.has(class_nm):
				continue
			global_classes_used[class_nm] = {
				_KeysData.DEPENDENT: file,
				_KeysData.PATH: remote_path
				}
			files_to_scan_for_deps[remote_path] = true


func get_file_dependencies():
	if ignore_dependencies:
		return

	_seed_access_reduction_targets()

	var scanned_files = {}
	for file_path in files_to_scan_for_deps.keys():
		file_parser.get_dependencies(file_path, file_dependencies, scanned_files)
	
	for remote_path:String in file_dependencies.keys():
		if replace_with_files.has(remote_path):
			var replace_path = replace_with_files.get(remote_path)
			adjusted_remote_paths[remote_path] = get_renamed_path(replace_path)
			continue
		
		var data = file_dependencies.get(remote_path, {})
		var dependent:String = data.get(_KeysData.DEPENDENT, "")
		var dependency_dir = data.get(_KeysData.DEPENDENCY_DIR)
		if _UtilsRemote.UFile.is_file_in_directory(remote_path, source):
			continue
		
		if dependent != "":
			var dep_data = files_to_copy.get(dependent, {})
			var replace_dep_with = dep_data.get(_KeysData.REPLACE_WITH)
			if replace_dep_with != null:
				if replace_dep_with == remote_path:
					continue # stop remote classes from creating extra copy in remote
		
		
		if dependency_dir != null and dependency_dir != "":
			_dependency_placements[remote_path] = data
			continue
		_register_copy(remote_path, get_remote_file_local_path(remote_path), dependent)


## Run after global relocation so relative destinations follow the final declaring file.
func resolve_dependency_placements() -> void:
	var resolved:Dictionary = {}
	for path:String in _dependency_placements:
		_resolve_dependency_placement(path, resolved, [])


func _resolve_dependency_placement(path:String, resolved:Dictionary, visiting:Array) -> String:
	if resolved.has(path):
		return resolved[path]
	if path in visiting:
		_dependency_placement_error(path, "cyclic destination chain: " + " -> ".join(visiting + [path]))
		return ""
	visiting.append(path)
	var data:Dictionary = _dependency_placements[path]
	var dir:String = data[_KeysData.DEPENDENCY_DIR]
	var declaring_file:String = data[_KeysData.DEPENDENCY_SOURCE]
	var declaring_dest = ""
	var relative_dir = dir.replace("\\", "/")
	if relative_dir.is_relative_path() and relative_dir != "<package>" and not relative_dir.begins_with("<package>/"):
		declaring_dest = _dependency_declaring_destination(declaring_file, resolved, visiting)
		if declaring_dest == "":
			_dependency_placement_error(path, "declaring file has no valid export destination")
			resolved[path] = ""
			visiting.pop_back()
			return ""
	var destination = _ExportFileUtils.ExportPaths.dependency_destination(dir, source, declaring_dest, path.get_file())
	visiting.pop_back()
	resolved[path] = destination
	if destination == "":
		_dependency_placement_error(path, "destination must name a file inside " + source)
	else:
		_register_copy(path, destination, data.get(_KeysData.DEPENDENT))
	return destination


func _dependency_declaring_destination(path:String, resolved:Dictionary, visiting:Array) -> String:
	# A remote base travels at its replacement stub's location.
	path = replace_with_files.get(path, path)
	if _dependency_placements.has(path):
		return _resolve_dependency_placement(path, resolved, visiting)
	if _local_copy_paths.has(path):
		return _local_copy_paths[path]
	var destination:String = files_to_copy.get(path, {}).get(_KeysData.TO, "")
	var export_root = export_dir_path.trim_suffix("/") + "/"
	if destination.begins_with(export_root):
		return source.path_join(destination.trim_prefix(export_root))
	return ""


func _dependency_placement_error(path:String, reason:String) -> void:
	var data:Dictionary = _dependency_placements[path]
	var message = 'Dependency destination "%s" for %s declared in %s: %s' % [
		data[_KeysData.DEPENDENCY_DIR], path, data[_KeysData.DEPENDENCY_SOURCE], reason]
	printerr("Package Exporter - " + message)
	_UEditor.push_toast(message, 2)
	files_to_copy.erase(path)
	adjusted_remote_paths.erase(path)
	_local_copy_paths.erase(path)
	invalidate()


## Seed targets already found by the global-class pass, including their transitive dependencies.
func _seed_access_reduction_targets() -> void:
	if not reduce_access_paths:
		return
	for file_path:String in access_reductions:
		for expression:String in access_reductions[file_path]:
			var path:String = access_reductions[file_path][expression].get(_KeysData.PATH, "")
			if path == "" or files_to_scan_for_deps.has(path):
				continue
			if _UtilsRemote.UFile.is_file_in_directory(path, source):
				continue # already travelling as part of the plugin itself
			if not file_dependencies.has(path):
				file_dependencies[path] = {_KeysData.DEPENDENT: file_path}
			files_to_scan_for_deps[path] = true # so its own dependencies come too


## Registers a file for copying. `local_dest` is where it lands inside the plugin: that is what
## other files' preloads are rewritten to, and mapping it out of res:// gives the write path.
##
## `dependent` is left untyped because the two callers disagree - one passes a path string, the
## other passes null for a file that is copied regardless of who asked for it - and the GUI reads
## the difference back as the same "no dependent".
func _register_copy(source_path:String, local_dest:String, dependent = null) -> void:
	_local_copy_paths[source_path] = local_dest
	adjusted_remote_paths[source_path] = get_renamed_path(local_dest)
	files_to_copy[source_path] = {
		_KeysData.TO: get_export_path(local_dest),
		_KeysData.DEPENDENT: dependent,
		}


## Decides the const name every reduced expression binds to, once for the whole export.
##
## Two expressions landing on the same file share a name - they are the same preload. Two
## landing on different files cannot, so the loser takes the segment above it ("Utils_UFile")
## and then an index. A reduction whose target will not be in the export is dropped outright:
## rewriting it would leave a preload of a file that was never copied.
func build_access_bindings():
	if not reduce_access_paths:
		return

	var expressions:Array = []
	for file:String in access_reductions:
		for expression:String in access_reductions[file]:
			if not expression in expressions:
				expressions.append(expression)
	expressions.sort() # deterministic, so the same export twice binds the same names

	var by_name:Dictionary = {} # name -> the path it is already bound to
	for expression:String in expressions:
		var entry:Dictionary = _find_reduction(expression)
		if entry.is_empty() or not _will_be_exported(entry.path):
			continue
		var name:String = _free_binding_name(entry, by_name)
		by_name[name] = entry.path
		access_bindings[expression] = name


func _find_reduction(expression:String) -> Dictionary:
	for file:String in access_reductions:
		var plan:Dictionary = access_reductions[file]
		if plan.has(expression):
			return plan[expression]
	return {}


# A file inside the plugin is copied wholesale; anything else has to have been pulled in as a
# dependency for the preload to resolve after export.
func _will_be_exported(path:String) -> bool:
	if files_to_copy.has(path):
		return true
	return _UtilsRemote.UFile.is_file_in_directory(path, source)


## Transfers marked ignore_deps are copied verbatim: never crawled, never seed global classes.
func file_deps_ignored(path:String) -> bool:
	return valid_files_for_transfer.get(path, {}).get(_KeysData.IGNORE_DEPS, false)


func _free_binding_name(entry:Dictionary, by_name:Dictionary) -> String:
	var candidates:Array = [entry.name]
	if entry.parent != "":
		candidates.append("%s_%s" % [entry.parent, entry.name])
	for i in range(2, 10):
		candidates.append("%s_%d" % [entry.name, i])

	for candidate:String in candidates:
		var bound = by_name.get(candidate)
		if bound == null or bound == entry.path:
			return candidate
	return "%s_%s" % [entry.name, _UtilsRemote.UFile.hash_string(entry.path).substr(0, 4)]


func get_global_class_export_paths():
	for name in global_classes_used.keys():
		# class_renames holds every global class not listed in class_rename_ignore
		var renameable = class_renames.has(name)
		var data = global_classes_used.get(name)
		var remote_path = data.get(_KeysData.PATH)
		var dependent = data.get(_KeysData.DEPENDENT)
		var remote_dir_path = get_remote_file_local_path(remote_path)

		if _UtilsRemote.UFile.is_file_in_directory(remote_path, source):
			remote_dir_path = remote_path # if in plugin, do not move to remote
			dependent = null # if in plugin, no dependent, will be transferred regardless
		elif renameable and dependent == remote_path:
			dependent = null # if global class was found in self, no dependent

		if not renameable and export_data.should_move_global(): # non renamed ones will be moved to "global", allowing src to be hidden
			#remote_dir_path = source.path_join("global").path_join(remote_dir_path.trim_prefix(remote_dir))

			# this places the file in global directly, meaning name clashes are possible, above doesn't
			# work with code completions for example
			remote_dir_path = source.path_join("global").path_join(remote_dir_path.get_file())

		if renameable: # fills in the path; get_class_renames() seeded every name with ""
			class_renames[name] = remote_path

		_register_copy(remote_path, remote_dir_path, dependent)

func check_all_files_have_valid_path():
	for file_path in files_to_copy.keys():
		var file_data = files_to_copy.get(file_path)
		var export_path = file_data.get(_KeysData.TO)
		var replace_with = file_data.get(_KeysData.REPLACE_WITH)
		var source_path = file_path
		if replace_with != null:
			source_path = replace_with
		
		check_file_has_valid_path(source_path, export_path)

func get_singleton_modules():
	var all_data = []
	for file_path:String in files_to_copy.keys():
		if not _ExportFileUtils.is_singleton_module_script(file_path):
			continue
		if not file_parser.check_file_valid(file_path):
			continue
		var file_access = FileAccess.open(file_path, FileAccess.READ)
		var count = 0
		var _class_name = ""
		var version = ""
		while not file_access.eof_reached() and count < 10:
			var line = file_access.get_line()
			if line.find("class_name") == -1:
				continue
			if line.find("#! singleton-module") > -1: #^ this should be removable at this point, the whole singleton tag system
				version = line.get_slice("#! singleton-module", 1).strip_edges()
			break
		
		var script = load(file_path)
		_class_name = script.get_singleton_name()
		
		if version == "":
			version = "0.0.0"
			var base_dir = file_path.get_base_dir()
			while base_dir != "res://":
				if not _PackageCfg.has_cfg(base_dir):
					base_dir = base_dir.get_base_dir()
				else:
					version = _PackageCfg.dir_value(base_dir, "version", "0.0.0")
					break
		
		
		var adjusted_path = adjusted_remote_paths.get(file_path, file_path)
		var singleton_data = {
			"name":_class_name,
			"version": str(version),
			"path": adjusted_path
		}
		all_data.append(singleton_data)
	
	if not all_data.is_empty():
		export_file_data["singleton_modules"] = all_data

func write_export_data_file():
	if export_file_data.is_empty():
		return
	var all_data_path = export_dir_path.path_join(".export_data")
	_UtilsRemote.UFile.write_to_json(export_file_data, all_data_path)

func update_plugin_cfg():
	var plugin_cfg_path = _PackageCfg.find(export_dir_path)
	if plugin_cfg_path == "":
		return
	
	_update_deps(plugin_cfg_path)
	
	var use_tag = export_data.options.get(_KeysConfig.Options.USE_TAG_IN_CFG, false)
	var include_min = export_data.options.get(_KeysConfig.Options.INCLUDE_MIN_VERSION, true)
	if not (use_tag or include_min):
		return
	
	var as_string = FileAccess.get_file_as_string(plugin_cfg_path)
	var lines = as_string.split("\n")
	var section = _PackageCfg.key_section(as_string, "version") # minimum_version sits beside version
	if use_tag:
		var rev_parse_result = _ExportFileUtils.run_git_exec(source, ["rev-parse", "--show-toplevel"])
		if rev_parse_result.exit == 0:
			var os_repo_dir = rev_parse_result.output[0].strip_edges()
			var describe = _ExportFileUtils.run_git_describe(os_repo_dir)
			if describe.exit == 0:
				for i in _section_lines(lines, section):
					var line = lines[i]
					if not line.begins_with("version="):
						continue
					var current = _UtilsRemote.UString.unquote(line.get_slice("version=", 1))
					var new_string = ""
					var describe_str = describe.output[0].strip_edges()
					
					var v_regex = RegEx.new()
					v_regex.compile("^v(?=\\d)") 
					var no_tag_regex = RegEx.new()
					no_tag_regex.compile("^[0-9a-f]{7,}(?:-dirty)?$")
					
					if v_regex.search(describe_str):
						new_string = describe_str.substr(1)
					elif no_tag_regex.search(describe_str):
						new_string = current + "-" + describe_str
					else:
						new_string = describe_str
					
					if new_string != "":
						lines[i] = 'version="%s"' % new_string
					break
	
	if include_min:
		var scanner = _VersionScanner.new()
		if scanner.api.has_index():
			# Scans only this export's files, so variants can differ.
			var min_version = scanner.scan_files(files_to_copy.keys())["min_version"]
			var min_msg = 'minimum_version="%s"' % min_version
			var section_lines = _section_lines(lines, section)
			if section_lines.is_empty():
				section_lines = range(lines.size())
			for i in range(section_lines.size() - 1, -1, -1):
				if lines[section_lines[i]].strip_edges() != "":
					lines.insert(section_lines[i] + 1, min_msg)
					break
		else:
			printerr("No min_version API index found, minimum_version not written: %s" % plugin_cfg_path)
	
	
	var file_access = FileAccess.open(plugin_cfg_path, FileAccess.WRITE)
	file_access.store_string("\n".join(lines))

## Bundled deps ship inside the package, so the released cfg lists only what an installer must add.
func _update_deps(plugin_cfg_path:String):
	var text = FileAccess.get_file_as_string(plugin_cfg_path)
	var updated = _PackageCfg.set_require(text, export_data.exported_require)
	if updated == text:
		return
	var file = FileAccess.open(plugin_cfg_path, FileAccess.WRITE)
	if file == null:
		printerr("Could not write config: ", plugin_cfg_path)
		return
	file.store_string(updated)

## Line indexes inside cfg `section`, header excluded; empty when the section is missing.
static func _section_lines(lines:PackedStringArray, section:String) -> Array:
	var out = []
	var inside = false
	for i in lines.size():
		var stripped = lines[i].strip_edges()
		if stripped.begins_with("["):
			inside = stripped == "[%s]" % section
		elif inside:
			out.append(i)
	return out

## Set of licenses that own at least one of file_paths, each file going to the closest license dir
## above it. Domains are walked deepest-first so the first containing one is the nearest ancestor -
## matching in scan order let a shallower license claim files a nested one owned.
static func resolve_license_owners(license_map:Dictionary, file_paths:Array) -> Dictionary:
	var domains = license_map.keys()
	domains.sort_custom(func(a, b):
		return a.trim_suffix("/").count("/") > b.trim_suffix("/").count("/"))

	var used = {}
	for file in file_paths:
		for d in domains:
			if _UFile.is_file_in_directory(file, d):
				used[license_map[d]] = true
				break
	return used


func gather_licenses():
	var license_map = {}
	var all_files = _GetFiles.scan("res://")
	for file in all_files:
		if file.get_file().get_basename().to_lower() == "license":
			license_map[file.get_base_dir()] = file

	# res:// contains everything, so as the shallowest domain it sweeps up every file no other
	# license covers. Held out of the matching and only added back on request.
	var project_license = license_map.get(PROJECT_LICENSE_DIR, "")
	license_map.erase(PROJECT_LICENSE_DIR)

	var used_licenses = resolve_license_owners(license_map, files_to_copy.keys())

	# A plugin shipping its own LICENSE already covers itself - the root one would just duplicate it.
	if export_data.include_project_license and project_license != "" \
			and not license_map.has(source.trim_suffix("/")):
		used_licenses[project_license] = true

	var seen_license_paths = {}
	for file in used_licenses.keys():
		if files_to_copy.has(file):
			continue # keeps already found licenses where they would be ie. plugin root
		var license_name = file.get_file()
		var local_path
		if file == project_license:
			local_path = source.path_join(license_name) # inherited as the plugin's own
		else:
			var dir_name = file.get_base_dir().trim_prefix("res://").trim_prefix("addons/").replace("/", "_")
			local_path = source.path_join("licenses").path_join(dir_name).path_join(license_name)
		if seen_license_paths.has(local_path):
			printerr("Potential LICENSE clash: ", local_path)
		seen_license_paths[local_path] = true
		# Mapped out of res:// from the in-plugin path like every other copy; renaming first would
		# strip the source prefix get_export_path matches on, writing the file into the live project.
		var export_path = get_export_path(local_path)
		files_to_copy[file] = {_KeysData.TO:export_path}


## Copies the plugin's doc folder in wholesale, no dependency crawl - docs are data, not source.
func gather_docs(doc_dir:String):
	for file in _GetFiles.scan(doc_dir):
		# Sidecars of the project's own import of a doc image, meaningless once it ships.
		if file.get_extension() in ["import", "uid"]:
			continue
		var rel = file.trim_prefix(doc_dir).trim_prefix("/")
		var local_path = source.path_join(DOC_DIR_NAME).path_join(rel)
		# Mapped out of res:// from the in-plugin path for the same reason gather_licenses is,
		# see the comment there.
		files_to_copy[file] = {_KeysData.TO:get_export_path(local_path)}
		doc_files[file] = true


func check_file_has_valid_path(source_path:String, export_path:String) -> void:
	var globalized_source = ProjectSettings.globalize_path(source_path)
	var globalized_export = ProjectSettings.globalize_path(export_path)
	
	if globalized_export.is_relative_path():
		print("Issue with file export, export path is relative path: %s" % globalized_export)
		export_valid = false
	if globalized_source == globalized_export:
		print("Issue with file export, export path == source path: %s" % globalized_source)
		export_valid = false


func export_files():
	var include_uid = export_data.include_uid
	var include_import = export_data.include_import
	var file_dep_keys = file_dependencies.keys()
	var global_paths = []
	for nm in global_classes_used.keys():
		var data = global_classes_used.get(nm, {})
		global_paths.append(data.get(_KeysData.PATH, ""))
	file_dep_keys.append_array(global_paths)
	
	for file_path in files_to_copy.keys():
		file_parser.current_file_path_parsing = file_path
		file_parser.current_adjusted_file_path = adjusted_remote_paths.get(file_path, file_path)
		
		var file_data = files_to_copy.get(file_path)
		var export_path = file_data.get(_KeysData.TO)
		var replace_with = file_data.get(_KeysData.REPLACE_WITH)
		
		var file_uid = include_uid
		var file_import = include_import
		# A doc's .import points at this project's .godot cache and means nothing in a hidden dir.
		if doc_files.has(file_path):
			file_uid = false
			file_import = false
		if replace_with == null:
			var is_dep = false
			# dependencies need a new uid to avoid clashes
			if file_path in file_dep_keys or file_path in unique_files:
				is_dep = true
				file_uid = false
				file_import = false # should this be?
			
			_simple_export(file_path, export_path, file_uid, file_import)
			
			if is_dep and FileAccess.file_exists(file_path + ".uid"):
				_ExportFileUtils.write_new_uid(export_path + ".uid")
			
		else:
			_simple_export(replace_with, export_path, false, false)
			if FileAccess.file_exists(replace_with + ".uid"):
				_ExportFileUtils.write_new_uid(export_path + ".uid")
		
		file_parser.post_export_edit_file(export_path)
		if not export_valid:
			return
	##
	
	for virtual_file_type in virtual_files.keys():
		var virtual_file_type_data = virtual_files[virtual_file_type]
		for local_file_path in virtual_file_type_data.keys():
			var export_data_for_file = virtual_file_type_data.get(local_file_path)
			var export_path = export_data_for_file.get(_KeysData.TO)
			
			_write_virtual_file(virtual_file_type, export_path)
	

##

func get_class_renames():
	for _class_name in export_data.class_list_array:
		if _class_name not in class_rename_ignore:
			class_renames[_class_name] = ""

func get_remote_file_local_path(file_path:String) -> String:
	var stripped_path = file_path.trim_prefix("res://")
	
	var remote_count = stripped_path.count("/remote/") ## This will remove duplicate files from exported plugins
	if remote_count > 0:
		stripped_path = stripped_path.get_slice("/remote/", remote_count)
	
	var remote_dir_path = remote_dir.path_join(stripped_path)
	
	return remote_dir_path

func get_renamed_path(file_path:String) -> String:
	if not rename_plugin:
		return file_path
	if file_path.begins_with(plugin_name):
		file_path = new_plugin_name.path_join(file_path.trim_prefix(plugin_name))
	return file_path

func get_export_path(file_path:String) -> String:
	file_path = file_path.replace(source, export_dir_path)
	return file_path

func get_relative_path(file_path:String) -> String:
	var current_file = file_parser.current_file_path_parsing
	var current_file_export = adjusted_remote_paths.get(current_file, current_file)
	var new_path = _UtilsRemote.UFile.get_relative_path(current_file_export, file_path)
	return new_path

func ensure_absolute_path(file_path:String, current_file_path:String):
	var absolute_path:String
	if file_path.begins_with("uid:"):
		absolute_path = _UtilsRemote.UFile.uid_to_path(file_path)
	else:
		absolute_path = _UtilsRemote.UFile.path_from_relative(file_path, current_file_path)
	if absolute_path == "":
		return ""
	#if not file_path.is_absolute_path() and not PLUGIN_EXPORTED:
		#print("Rel to Abs: %s -> %s" % [file_path, absolute_path])
	return absolute_path.simplify_path()

func get_rel_or_absolute_path(path:String) -> String:
	if use_relative_paths:
		var rel = get_relative_path(path)
		if not rel.begins_with("."):
			rel = "./" + rel
		return rel
	else:
		return ensure_absolute_path(path, file_parser.current_file_path_parsing)


## Aborts the export. ExportData._init checks export_valid once the stages have all run, so this
## is how a stage that has to give up makes that stick - returning early only leaves the stage.
func invalidate():
	export_valid = false

##

func _simple_export(from, export_path, export_uid_file, export_import_file):
	if FileAccess.file_exists(export_path): ## this message prints when a duplicate is replaced with get_remote_file_local_path ^^
		var raw_path = export_data.full_export_path
		var msg = "Overwriting duplicate file: %s with %s" % [export_path.replace(raw_path, "").trim_prefix("/"), from]
		_UtilsRemote.UEditor.print_warn(msg)
	
	var export_path_dir = export_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(export_path_dir):
		DirAccess.make_dir_recursive_absolute(export_path_dir)
	DirAccess.copy_absolute(from, export_path)
	
	var from_uid = from + ".uid"
	var export_path_uid = export_path + ".uid"
	if FileAccess.file_exists(from_uid) and export_uid_file:
		DirAccess.copy_absolute(from_uid, export_path_uid)
	var from_import = from + ".import"
	var export_path_import = export_path + ".import"
	if FileAccess.file_exists(from_import) and export_uid_file:
		DirAccess.copy_absolute(from_import, export_path_import)


func _write_virtual_file(virtual_file_type:String, export_path:String):
	var export_path_dir = export_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(export_path_dir):
		DirAccess.make_dir_recursive_absolute(export_path_dir)
	
	if virtual_file_type == _KeysData.VIRTUAL_GDIGNORE:
		var fa = FileAccess.open(export_path, FileAccess.WRITE)
		fa.close()

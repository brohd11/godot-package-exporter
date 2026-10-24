extends RefCounted

const UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd") #>remote
const UtilsLocal = preload("res://addons/package_exporter/src/class/utils_local.gd")

const PluginInit = UtilsLocal.PluginInit
const ExportFileUtils = UtilsLocal.ExportFileUtils
const KeysConfig = ExportFileUtils.KeysConfig
const UFile = UtilsRemote.UFile

const ExportData = UtilsLocal.ExportData
const FileParser = UtilsLocal.FileParser
const Reporter = UtilsLocal.Reporter

static func get_export_config_by_name(plugin_dir_name:String) -> String:
	return UtilsLocal.ExportFileUtils.get_export_config_path(plugin_dir_name)

static func get_export_data_by_name(plugin_dir_name:String) -> ExportData:
	var export_config_path = UtilsLocal.ExportFileUtils.get_export_config_path(plugin_dir_name)
	if not FileAccess.file_exists(export_config_path):
		return null
	var export_data = ExportData.new(export_config_path)
	return export_data

static func export_by_gui(export_config_path:String, include_uid_overide=null, include_import_overide=null):
	var reporter = Reporter.new()
	var success = export_plugin(export_config_path, include_uid_overide, include_import_overide, reporter)
	
	_print_result(success, export_config_path, reporter)


static func export_by_name(plugin_dir_name, reporter = null):
	reporter = Reporter.or_default(reporter)
	var export_config_path = UtilsLocal.ExportFileUtils.get_export_config_path(plugin_dir_name, reporter)
	if not FileAccess.file_exists(export_config_path):
		reporter.error("Plugin Export config not found at: %s" % plugin_dir_name)
		return false
	var success = export_plugin(export_config_path, null, null, reporter)

	_print_result(success, export_config_path, reporter)
	return success


static func _print_result(success:bool, export_config_path:String, reporter):
	var plugin_name = _plugin_label(export_config_path, reporter)
	var accent_color = EditorInterface.get_editor_theme().get_color("accent_color", &"Editor").to_html()
	var details = []
	if success and reporter.stats.has("files"):
		details.append("%d files (%d external)" % [reporter.stats.files, reporter.stats.external])
	var warnings = reporter.count(Reporter.Level.WARN)
	var errors = reporter.count(Reporter.Level.ERROR)
	if warnings:
		details.append("%d warning%s" % [warnings, "" if warnings == 1 else "s"])
	if errors:
		details.append("%d error%s" % [errors, "" if errors == 1 else "s"])
	var suffix = (": " + ", ".join(details)) if not details.is_empty() else ""
	if success:
		reporter.note("'[color=%s]%s[/color]' [color=25c225]exported[/color]%s" % [accent_color, plugin_name, suffix])
	else:
		reporter.note("'[color=%s]%s[/color]' [color=b20f0f]export failed[/color]%s" % [accent_color, plugin_name, suffix])


static func _plugin_label(export_config_path:String, reporter) -> String:
	var plugin_dir = export_config_path.get_base_dir().get_base_dir()
	var plugin_version = ExportFileUtils.get_version(plugin_dir, export_config_path, reporter)
	return "%s - %s" % [plugin_dir.get_file().capitalize(), plugin_version]


static func export_plugin(export_config_path:String, include_uid_overide=null, include_import_overide=null, reporter = null):
	reporter = Reporter.or_default(reporter)
	reporter.note("Exporting: %s" % _plugin_label(export_config_path, reporter))
	
	var export_data = ExportData.new(export_config_path, reporter)
	if not export_data.data_valid:
		return false
	
	if export_data.pre_script != "":
		if not ExportFileUtils.check_export_script_valid(export_data.pre_script, "pre_export", reporter):
			return false
		ExportFileUtils.run_export_script(export_data.pre_script, "pre_export", export_data)
	
	var full_export_path = export_data.full_export_path
	
	#var options = export_data.get(KeysConfig.OPTIONS) # actuallt not a key, but worked via get
	var options = export_data.options
	var overwrite = options.get(KeysConfig.Options.OVERWRITE, false)
	if overwrite:
		var cleared = _clear_export_dir(full_export_path, reporter)
		if not cleared:
			return false
	
	update_git_submodule_details(export_config_path, export_data)
	
	var include_uid = export_data.include_uid
	var include_import = export_data.include_import
	
	if include_uid_overide != null:
		if include_uid != include_uid_overide:
			reporter.info("Overiding 'Include UID': %s -> %s" % [include_uid_overide, not include_uid_overide])
		include_uid = include_uid_overide
	if include_import_overide != null:
		if include_import != include_import_overide:
			reporter.info("Overiding 'Include Import': %s -> %s" % [include_import_overide, not include_import_overide])
		include_import = include_import_overide
	
	export_data.include_uid = include_uid
	export_data.include_import = include_import
	
	var count = 0
	var files = 0
	var external = 0
	for export:ExportData.Export in export_data.exports:
		reporter.info("Exporting: export %s" % count)
		export.file_parser.set_export_obj(export)
		export.file_parser.pre_export()
		if not export.export_valid:
			return false
		
		export.export_files()
		if not export.export_valid:
			return false
		export.write_export_data_file()
		export.update_plugin_cfg()
		count += 1
		files += export.files_to_copy.size()
		for path:String in export.files_to_copy:
			if not UFile.is_file_in_directory(path, export.source):
				external += 1
	reporter.stats = {"files": files, "external": external}
	
	if export_data.post_script != "":
		ExportFileUtils.run_export_script(export_data.post_script, "post_export", export_data)
	
	var exported_dirs = DirAccess.get_directories_at(full_export_path)
	for dir in exported_dirs:
		var dir_path = full_export_path.path_join(dir)
		var search = UtilsRemote.GetFiles.open(dir_path)
		search.show_hidden = true
		search.enter_gdignore = true
		var search_files = search.get_files() # need to double check before switch
		ExportFileUtils.write_zip_file(dir_path + ".zip", search_files)
	
	if UtilsRemote.UFile.is_dir_in_or_equal_to_dir(export_data.export_root, "res://"):
		var gdignore_path = export_data.export_root.path_join(".gdignore")
		if not FileAccess.file_exists(gdignore_path):
			var file = FileAccess.open(gdignore_path, FileAccess.WRITE)
			file.close()
			reporter.info("Created .gdignore for in-resource file system export.")
	
	
	# moved to the export ignore folder, just ignoring all exports now
	#var gitignore_path = export_data.export_root.path_join(".gitignore")
	#if not FileAccess.file_exists(gitignore_path):
		##var gitignore_path = full_export_path.path_join(".gitignore")
		#var file = FileAccess.open(gitignore_path, FileAccess.WRITE)
		#file.store_string("**")
		#file.close()
	
	return true
	


static func _clear_export_dir(full_export_path, reporter = null):
	var forbidden_paths = ["res://", "res://addons"]
	for dir in forbidden_paths:
		if full_export_path == dir:
			Reporter.or_default(reporter).error(("Could not clear export dir: %s, so project files are not deleted. "
				+ "Recommended location: res://addons/my_plugin/_export_ignore/exports") % full_export_path)
			return false
	
	if not DirAccess.dir_exists_absolute(full_export_path):
		return true
	
	var dir_array_2d:Array = UFile.scan_for_dirs(full_export_path, true)
	for dir_array:Array in dir_array_2d:
		dir_array.reverse()
		for dir in dir_array:
			var dir_access = DirAccess.open(dir)
			dir_access.include_hidden = true
			var files = dir_access.get_files()
			for file in files:
				var path = dir.path_join(file)
				DirAccess.remove_absolute(path)
			
			DirAccess.remove_absolute(dir)
	
	var dir_access = DirAccess.open(full_export_path)
	dir_access.include_hidden = true
	var files = dir_access.get_files()
	for f in files:
		var path = full_export_path.path_join(f)
		DirAccess.remove_absolute(path)
	
	return true


static func update_git_submodule_details(export_config_path, export_data:ExportData=null):
	#var check_exit = OS.execute("git", ["--version"])
	if OS.execute("git", ["--version"]) != 0:
		Reporter.or_default(export_data.reporter if export_data else null).info("Error accessing git. Skipping git export details file.")
		return
	
	if export_data == null:
		export_data = ExportData.new(export_config_path)
	var reporter = export_data.reporter
	var git_details_file_lines = []
	var main_repo_path = "res://.git"
	if DirAccess.dir_exists_absolute(main_repo_path):
		var main_repo_lines = _get_git_data("res://", git_details_file_lines, "Main Repo", reporter)
		if main_repo_lines:
			var i = 0
			for line in main_repo_lines:
				line = line.trim_prefix("\t")
				main_repo_lines[i] = line
				i += 1
			git_details_file_lines.append_array(main_repo_lines)
	else:
		git_details_file_lines.append("No main repo found.\n")
	for export:ExportData.Export in export_data.exports:
		var single_export_git_file_lines = []
		git_details_file_lines.append("\nExport: " + export.export_name.path_join(export.export_folder))
		var source_git_path = export.source.path_join(".git")
		if FileAccess.file_exists(source_git_path):
			var lines = _get_git_data(export.source, single_export_git_file_lines, "Submodule", reporter)
			if lines:
				single_export_git_file_lines.append_array(lines)
		elif DirAccess.dir_exists_absolute(source_git_path):
			var lines = _get_git_data(export.source, single_export_git_file_lines, "Submodule", reporter)
			if lines:
				single_export_git_file_lines.append_array(lines)
		else:
			single_export_git_file_lines.append("Source is not a git repo")
		
		
		for file in export.file_dependencies.keys():
			var dir = file.get_base_dir()
			while dir != "res://":
				var git_path = dir.path_join(".git")
				if FileAccess.file_exists(git_path):
					var lines = _get_git_data(dir, single_export_git_file_lines, "Submodule", reporter)
					if lines:
						single_export_git_file_lines.append_array(lines)
					break
				elif DirAccess.dir_exists_absolute(git_path):
					var lines = _get_git_data(dir, single_export_git_file_lines, "Submodule", reporter)
					if lines:
						single_export_git_file_lines.append_array(lines)
					break
				else:
					dir = dir.get_base_dir()
		
		git_details_file_lines.append_array(single_export_git_file_lines)
		if single_export_git_file_lines.size() == 0:
			git_details_file_lines.append("\tNo git modules.")
	
	for export in export_data.exports:
		#var first_export = export_data.exports[0] as ExportData.Export
		var file_path = export.export_dir_path.path_join(".export_git_details")
		if not DirAccess.dir_exists_absolute(file_path.get_base_dir()):
			DirAccess.make_dir_recursive_absolute(file_path.get_base_dir())
		
		var file = FileAccess.open(file_path, FileAccess.WRITE)
		for line in git_details_file_lines:
			file.store_line(line)
		file.close()
		

static func _get_git_data(dir, git_file_lines, repo_type="Submodule", reporter = null):
	reporter = Reporter.or_default(reporter)
	var global_dir = ProjectSettings.globalize_path(dir)
	global_dir = global_dir.trim_suffix("/")
	var repo_line = "\t%s: %s" % [repo_type, global_dir.get_file()]
	if repo_line in git_file_lines:
		return []
	
	var rev_parse = ExportFileUtils.run_git_exec(dir, ["rev-parse", "HEAD"])
	if rev_parse.exit == -1:
		reporter.error("Error getting commit: %s" % dir)
		return
	var commit = rev_parse.output[0].strip_edges()
	if commit == "":
		reporter.error("Error getting commit: %s" % dir)
		return []
	
	var describe = ExportFileUtils.run_git_describe(dir)
	var describe_str = describe.output[0] if describe.exit == 0 else ""
	
	var plugin_version
	var plugin_cfg = ExportFileUtils.PackageCfg.find(dir)
	if plugin_cfg != "":
		var plugin_data = UFile.load_config_file(plugin_cfg)
		if plugin_data:
			plugin_version = ExportFileUtils.PackageCfg.get_value(plugin_data, "version", "Could not get version")
	
	var lines = [
		repo_line,
		"\t\tDir: %s" % dir,
	]
	if plugin_version:
		lines.append("\t\tPlugin Version: %s" % plugin_version)
	lines.append("\t\tCommit: %s" % commit) # maybe can be removed in favor of describe
	if describe_str:
		lines.append("\t\tDescribe: %s" % describe_str.strip_edges())
	#var git_status = _get_git_status(dir)
	#if git_status == true:
		#lines.append("\t\t*has uncommited changes")
	return lines

static func _get_git_status(dir):
	var res = ExportFileUtils.run_git_exec(dir, ["diff", "--quiet", "--exit-code"])
	if res.exit == -1 or res.exit == 0:
		printerr("Error getting git status: %s" % dir)
		return false
	elif res.exit == 1: #dirty
		return true


static func new_plugin(plugin_dir_name, create_export:=true):
	PluginInit.new_plugin(plugin_dir_name, create_export)

static func open_export_dir(export_config_path):
	var export_data = ExportFileUtils.get_export_data(export_config_path)
	if export_data == null:
		return
	var export_root = export_data.get(KeysConfig.EXPORT_ROOT, "")
	if export_root != "":
		var global_path = ProjectSettings.globalize_path(export_root)
		if not DirAccess.dir_exists_absolute(global_path):
			printerr("Export dir does not exist: %s" % global_path)
			return
		
		OS.shell_open(global_path)

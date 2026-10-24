extends RefCounted

const UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd")
const UtilsLocal = preload("res://addons/package_exporter/src/class/utils_local.gd")

const KeysData = UtilsLocal.ExportFileUtils.KeysData

const TEXT_FILE_TYPES = ["gd", "tscn", "cs", "tres"]

const PARSE_FOLDER_PATH = "./parse" #! ignore-remote

var custom_text_types:Array = []

var custom_parse_data:Dictionary = {}

var default_parsers:Dictionary = {}
var optimization
var export_obj


var current_file_path_parsing:String
var current_adjusted_file_path:String

func _init() -> void:
	optimization = load("res://addons/package_exporter/src/class/export/optimization.gd").new()
	var file_parser_path = self.get_script().resource_path
	var parse_folder_path = file_parser_path.get_base_dir().path_join("parse")
	
	var default_parse_files = DirAccess.get_files_at(parse_folder_path)
	for f in default_parse_files:
		if f == "parse_base.gd" or f == "template.gd":
			continue
		if f.get_extension() == "uid":
			continue
		var full_path = parse_folder_path.path_join(f)
		var script = load(full_path)
		if not script is Script:
			printerr("Error loading parse script, resource is not script: %s" % full_path)
			continue
		var parse_ext = f.trim_prefix("parse_").trim_suffix(".gd")
		var instance = script.new()
		if parse_ext in default_parsers.keys():
			printerr("Parse already loaded, may be duplicate parsers: %s" % full_path)
			continue
		
		default_parsers[parse_ext] = instance
	
	
	var parse_dirs = DirAccess.get_directories_at(parse_folder_path)
	custom_text_types = parse_dirs
	for dir in parse_dirs:
		var dir_path = parse_folder_path.path_join(dir)
		var files = DirAccess.get_files_at(dir_path)
		var parse_ins_array = []
		for file in files:
			# The compatibility adapter is invoked centrally before packaging rewrites.
			if dir == "gd" and file == "struct.gd":
				continue
			if file.get_extension() == "uid":
				continue
			var full_path = dir_path.path_join(file)
			var script = load(full_path)
			if script is Script:
				var instance = script.new()
				parse_ins_array.append(instance)
			else:
				printerr("Issue getting parse script: %s" % full_path)
		
		custom_parse_data[dir] = parse_ins_array

func set_parser_settings(parser_settings):
	optimization.set_parse_settings(parser_settings.get("parse_gd", {}))
	for parser_ext in default_parsers.keys():
		var parse_ins = default_parsers.get(parser_ext)
		var settings = parser_settings.get("parse_%s" % parser_ext, {})
		parse_ins.set_parse_settings(settings)
	
	for parser_ext in custom_parse_data.keys():
		var parse_ins_array = custom_parse_data.get(parser_ext, [])
		var settings = parser_settings.get("parse_%s" % parser_ext, {})
		for parse_ins in parse_ins_array:
			parse_ins.set_parse_settings(settings)

func set_export_obj(_export_obj):
	export_obj = _export_obj
	optimization.export_obj = export_obj
	for parser_ext in default_parsers.keys():
		var parse_ins = default_parsers.get(parser_ext)
		parse_ins.export_obj = export_obj
	
	for parser_ext in custom_parse_data.keys():
		var parse_ins_array = custom_parse_data.get(parser_ext, [])
		for parse_ins in parse_ins_array:
			parse_ins.export_obj = export_obj




func get_dependencies(file_path:String, all_dependencies:Dictionary, scanned_files:Dictionary):
	var files_to_scan = [file_path]
	while not files_to_scan.is_empty():
		var current_file_path = files_to_scan.pop_front()
		
		if scanned_files.has(current_file_path):
			continue
		scanned_files[current_file_path] = true
		if export_obj.file_deps_ignored(current_file_path):
			continue

		var file_deps = {}
		var ext = current_file_path.get_extension()
		if ext in TEXT_FILE_TYPES:
			var parse_ins = default_parsers.get(ext)
			file_deps = parse_ins.get_direct_dependencies(current_file_path)
	
		if ext in custom_text_types:
			var parse_ins_array = custom_parse_data.get(ext)
			for parse_ins in parse_ins_array:
				var deps = parse_ins.get_direct_dependencies(current_file_path)
				file_deps.merge(deps, true)
				#file_deps.merge(deps)
		
		
		for path in file_deps.keys():
			var data = file_deps.get(path)
			var existing = all_dependencies.get(path, {})
			var entry = {KeysData.DEPENDENT:current_file_path}
			# a "#! dependency <destination>" placement has to survive a later plain reference to the
			# same file, whichever order the two are crawled in
			var dep_dir = data.get(KeysData.DEPENDENCY_DIR, existing.get(KeysData.DEPENDENCY_DIR))
			if dep_dir != null:
				entry[KeysData.DEPENDENCY_DIR] = dep_dir
				var placement = data if data.has(KeysData.DEPENDENCY_DIR) else existing
				entry[KeysData.DEPENDENCY_SOURCE] = placement.get(KeysData.DEPENDENCY_SOURCE, current_file_path)
			all_dependencies[path] = entry
			if not scanned_files.has(path):
				files_to_scan.push_back(path)

func pre_export():
	optimization.pre_export()
	if not optimization.export_obj.export_valid:
		return
	for ext in default_parsers:
		var parse_ins = default_parsers.get(ext)
		parse_ins.pre_export()
	
	for ext in custom_parse_data.keys():
		var parse_ins_array = custom_parse_data.get(ext)
		for parse_ins in parse_ins_array:
			parse_ins.pre_export()


func post_export_edit_file(file_path:String):
	if not check_file_valid(file_path):
		return
	var ext = file_path.get_extension()
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		export_obj.reporter.error("Could not open file: %s" % file_path)
		return
	var file_lines = []
	while not file.eof_reached():
		file_lines.append(file.get_line())
	
	file.close()
	
	var valid_parsers = []
	if ext in TEXT_FILE_TYPES:
		valid_parsers.append(default_parsers.get(ext))
	if ext in custom_text_types:
		var parse_ins_array = custom_parse_data.get(ext, [])
		valid_parsers.append_array(parse_ins_array)
	
	var file_lines_edited
	if ext == "gd" and optimization.replacements.has(current_file_path_parsing):
		file_lines_edited = optimization.replacements[current_file_path_parsing].duplicate()
	
	for parse_ins in valid_parsers:
		file_lines_edited = parse_ins.post_export_edit_file(file_path, file_lines_edited)
		if not parse_ins.export_obj.export_valid:
			return
	
	if file_lines_edited != null:
		file_lines = file_lines_edited
	
	var final_file_lines = []
	for line in file_lines:
		for parse_ins in valid_parsers:
			line = parse_ins.post_export_edit_line(line)
		
		final_file_lines.append(line)
	
	
	var write_file_access = FileAccess.open(file_path, FileAccess.WRITE)
	for line in final_file_lines:
		write_file_access.store_line(line)
	
	write_file_access.close()

func check_file_valid(file_path:String) -> bool:
	var ext = file_path.get_extension() 
	if ext in TEXT_FILE_TYPES or ext in custom_text_types:
		return true
	return false

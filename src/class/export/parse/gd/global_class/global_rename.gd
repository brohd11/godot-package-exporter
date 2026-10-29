extends "res://addons/package_exporter/src/class/export/parse/parse_base.gd"

## [RegEx, replace_name] per renamed class. Applied over the whole file, not per line, because a
## string literal can span lines and only a full-text StringMap sees where it closes.
var renames:Array = []

func set_parse_settings(settings):
	pass

func get_direct_dependencies(file_path:String) -> Dictionary:
	var dependencies = {} 
	return dependencies

func pre_export() -> void:
	renames.clear()
	var plugin_name = export_obj.plugin_name
	if export_obj.rename_plugin:
		plugin_name = export_obj.new_plugin_name
	
	var suffix_hash = UFile.hash_string(plugin_name).substr(0,3)
	var global_classes_used = export_obj.global_classes_used.keys()
	for _class_name in export_obj.class_renames:
		if not _class_name in global_classes_used:
			continue
		var regex = RegEx.new()
		regex.compile("\\b%s\\b" % _class_name)
		renames.append([regex, "%s_%s" % [_class_name, suffix_hash]])


func post_export_edit_file(file_path:String, file_lines:Variant=null) -> Variant:
	if renames.is_empty():
		return file_lines
	if file_lines == null:
		var file = FileAccess.open(file_path, FileAccess.READ)
		if not file:
			return null
		file_lines = []
		while not file.eof_reached():
			file_lines.append(file.get_line())
	
	var text = rename_in_text("\n".join(file_lines), renames)
	return Array(text.split("\n"))

func post_export_edit_line(line:String) -> String:
	return line


## Matches inside strings and comments are left alone. Distinct \b names can't overlap, so every
## splice is made against the original offsets, last first.
static func rename_in_text(text:String, _renames:Array) -> String:
	var map = UString.get_string_map(text, UString.StringMap.Mode.STRING)
	var edits = []
	for pair in _renames:
		var regex:RegEx = pair[0]
		for m in regex.search_all(text):
			if map.index_in_string_or_comment(m.get_start()):
				continue
			edits.append([m.get_start(), m.get_end(), pair[1]])
	
	edits.sort_custom(func(a, b): return a[0] > b[0])
	for edit in edits:
		text = text.left(edit[0]) + edit[2] + text.substr(edit[1])
	return text

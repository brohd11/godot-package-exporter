extends "res://addons/package_exporter/src/class/export/parse/parse_base.gd"

var backport_target:= 100

var _misc_string_replacement_regex:= RegEx.new()
const MISC_STRING_REPLACEMENTS = {
	"type_string": {
		"replace":"MiscBackport.type_string_compat",
		"min_ver":2
	},
}

var combined_string_replacements := {}

var no_strings:= false

func _compile_misc_strings():
	_string_regex = URegex.get_strings()
	
	combined_string_replacements.merge(MISC_STRING_REPLACEMENTS)
	
	var escaped_strings = []
	for string in combined_string_replacements.keys():
		var replace_data = combined_string_replacements.get(string)
		var min_ver = replace_data.get("min_ver", 0)
		if min_ver < backport_target:
			continue
		escaped_strings.append(URegex.escape_regex_meta_characters(string))
	
	if escaped_strings.is_empty():
		no_strings = true
		return
	
	var misc_list = "|".join(escaped_strings)
	#misc_list.trim_prefix("|").trim_suffix("|")
	var misc_string_pattern = "(?<![\\w.])(" + misc_list + ")\\b(\\s*\\((?:(?:[^()]|\\([^)]*\\))*)\\))?"
	_misc_string_replacement_regex.compile(misc_string_pattern)

func set_parse_settings(settings):
	backport_target = settings.get("backport_target", 100)
	# Copied: _compile_misc_strings() merges the built-ins into this, and it belongs to the caller.
	combined_string_replacements = settings.get("backport_string_renames", {}).duplicate()
	_compile_misc_strings()

func get_direct_dependencies(file_path:String) -> Dictionary:
	var dependencies = {} 
	return dependencies

func pre_export() -> void:
	pass

func post_export_edit_file(file_path:String, file_lines:Variant=null) -> Variant:
	return file_lines

func post_export_edit_line(line:String) -> String:
	line = replace_misc_methods(line)
	return line


func replace_misc_methods(line:String) -> String:
	return URegex.string_safe_regex_sub(line, _replace_misc_methods, _string_regex)

func _replace_misc_methods(line:String) -> String:
	if no_strings:
		return line
	if not _misc_string_replacement_regex.is_valid():
		return line
	
	var matches = _misc_string_replacement_regex.search_all(line)
	for i in range(matches.size() - 1, -1, -1):
		var _match: RegExMatch = matches[i]
		var _match_string = _match.get_string(1)
		var replace_data = combined_string_replacements.get(_match_string, {})
		var replacement = _match_string
		if replace_data.is_empty():
			export_obj.reporter.warn("Could not replace string: %s" % _match_string)
		else:
			replacement = replace_data.get("replace")
		
		var args = _match.get_string(2)
		
		var new_call = replacement + args
		
		line = line.substr(0, _match.get_start(0)) \
			+ new_call \
			+ line.substr(_match.get_end(0))
	
	return line

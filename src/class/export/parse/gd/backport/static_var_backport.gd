extends "res://addons/package_exporter/src/class/export/parse/parse_base.gd"

const Backport = preload("res://addons/package_exporter/src/class/export/parse/gd/backport.gd")

const BACKPORT_STATIC_PATH = "res://addons/package_exporter/src/class/export/backport/sv_backport.gd"
const BACKPORT_STATIC = "_BackportStaticVar"

const STATIC_VAR_MIN_VER = 1
var backport_target:= -1

var all_static_vars_map = {}

var global_static_vars_map = {}
var preloaded_static_vars_map = {}
var preload_alias_map = {}

var external_regexs = []

var _class_name_regex:= RegEx.new()
var _static_var_regex:= RegEx.new()
var _preload_regex := RegEx.new()
var _name_and_value_regex := RegEx.new()


func _init() -> void:
	_class_name_regex.compile("^\\s*class_name\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
	_static_var_regex.compile("^\\s*static\\s+var\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
	_preload_regex.compile("const\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*preload\\(\"(.*)\"\\)")
	_name_and_value_regex.compile("^\\s*static\\s+var\\s+([a-zA-Z_][a-zA-Z0-9_]*)(?:.*?)?(?:\\s*(?::=|=)\\s*(.*))?")
	
	
	#test_new_getter()


func set_parse_settings(settings):
	backport_target = settings.get("backport_target", 100)


func get_direct_dependencies(file_path:String) -> Dictionary:
	var dependencies = {} 
	return dependencies

func pre_export():
	if backport_target > STATIC_VAR_MIN_VER:
		return
	
	var file_lines_array = []
	for file_path:String in export_obj.files_to_copy.keys():
		if not file_path.get_extension() == "gd":
			continue
		
		var file = FileAccess.open(file_path, FileAccess.READ)
		if not file:
			export_obj.reporter.error("Could not read file: %s" % file_path)
			continue
		
		var content = file.get_as_text()
		file.close()
		var lines = content.split("\n", false)
		file_lines_array.append(lines)
		
		var class_name_match = _class_name_regex.search(content)
		var local_path = ProjectSettings.localize_path(file_path)
		var script_identifier
		var desired_map
		if not class_name_match:
			script_identifier = local_path
			desired_map = preloaded_static_vars_map
		else:
			script_identifier = class_name_match.get_string(1)
			desired_map = global_static_vars_map
		
		
		var found_static_vars = []
		
		for line in lines:
			var static_var_matches = _static_var_regex.search_all(line)
			for _match in static_var_matches:
				var var_nm = _match.get_string(1)
				found_static_vars.append(var_nm)
		
		if not found_static_vars.is_empty():
			all_static_vars_map[local_path] = found_static_vars
			desired_map[script_identifier] = found_static_vars
	
	
	for lines in file_lines_array:
		for line in lines:
			var preload_matches = _preload_regex.search_all(line)
			for _match in preload_matches:
				var const_name = _match.get_string(1)
				var path = _match.get_string(2)
				
				if preloaded_static_vars_map.has(path):
					if preload_alias_map.has(path):
						var nm = preload_alias_map.get(path)
						if nm != const_name:
							export_obj.reporter.error("Preload name clash for static var backport: %s, aliases: %s, %s" % [path, nm, const_name])
							continue
					
					preload_alias_map[path] = const_name
	
	for class_nm in global_static_vars_map.keys():
		var s_var_nms = global_static_vars_map.get(class_nm)
		for var_nm in s_var_nms:
			external_regexs.append(_build_external_setter_rule(class_nm, var_nm))
			external_regexs.append(_build_external_getter_rule(class_nm, var_nm))
	
	for path in preloaded_static_vars_map.keys():
		var s_var_nms = preloaded_static_vars_map.get(path, [])
		if s_var_nms.is_empty():
			continue
		var const_name = preload_alias_map.get(path)
		if const_name == null: # never preloaded anywhere, so nothing external can reach the var
			#print("Could not find path in static var preload alias map: %s" % path) 
			continue
		for var_nm in s_var_nms:
			external_regexs.append(_build_external_setter_rule(const_name, var_nm))
			external_regexs.append(_build_external_getter_rule(const_name, var_nm))
	
	
	#for file_path:String in export_obj.files_to_copy.keys():
		#if not file_path.get_extension() == "gd":
			#continue
	
	## compile regexs?


func post_export_edit_file(file_path:String, file_lines:Variant=null) -> Variant:
	if backport_target > STATIC_VAR_MIN_VER:
		return file_lines
	
	var global_class_names = export_obj.export_data.class_list.keys()
	var current_original_path = export_obj.file_parser.current_file_path_parsing
	var internal_vars = all_static_vars_map.get(current_original_path, [])
	
	var static_var_data = {}
	for i in range(file_lines.size()):
		var line = file_lines[i]
		
		if line.strip_edges().begins_with("static var "):
			var code = line
			var comment_idx = line.find("#")
			if comment_idx > -1:
				code = line.get_slice("#", 0)
			
			var _match = _name_and_value_regex.search(code)
			if _match:
				var var_nm = _match.get_string(1)
				var var_val = _match.get_string(2)
				if not var_val:
					var_val = "null"
				static_var_data[var_nm] = {
						"name":var_nm,
						"default":var_val
						}
				
				
			line = "#%s<- Backport Static Var" % line
			file_lines[i] = line
	
	#if static_var_data.keys().is_empty():
		#return file_lines # can this be done?
	
	var internal_setter_regex_array = []
	var internal_getter_regex_array = []
	
	for var_nm in internal_vars:
		internal_setter_regex_array.append(_build_setter_regex(var_nm))
		internal_getter_regex_array.append(_build_getter_regex(var_nm))
	
	
	for i in range(file_lines.size()):
		var line:String = file_lines[i]
		var code_part = line
		var comment_part = ""
		var hash_pos = line.find("#")
		if hash_pos != -1:
			code_part = line.substr(0, hash_pos)
			comment_part = line.substr(hash_pos)
		
		var processed_line = code_part
		for regex in internal_setter_regex_array:
			while true:
				var _match = regex.search(processed_line)
				if not _match:
					break

				var full_match_text = _match.get_string(0)
				var var_name = _match.get_string(1)
				var operator = _match.get_string(2).strip_edges()
				var value = _match.get_string(3).strip_edges()

				var replacement_text = ""
				if operator == "=":
					replacement_text = "set_{var}({val})".format({
						"var": var_name,
						"val": value
					})
				else:
					# "x += 1" has to read through the getter before it can write back
					var compound_op = operator.substr(0, operator.length() - 1)
					replacement_text = "set_{var}(get_{var}() {op} {val})".format({
						"var": var_name,
						"op": compound_op,
						"val": value
					})

				processed_line = processed_line.replace(full_match_text, replacement_text)
		
		for regex in internal_getter_regex_array:
			processed_line = regex.sub(processed_line, "get_$1()", true)
		#for reg
		processed_line = process_line_for_external(processed_line, external_regexs)
		
		processed_line = processed_line + comment_part
		
		file_lines[i] = processed_line
	
	
	file_lines.append("# PACKAGE EXPORTER STATIC VAR BACKPORT")
	var adjusted_path = export_obj.adjusted_remote_paths.get(export_obj.file_parser.current_file_path_parsing)
	if not adjusted_path:
		adjusted_path = export_obj.file_parser.current_file_path_parsing
	var _BPSV_CONST_NAME = "_BPSV_PATH_" + adjusted_path.get_file().trim_suffix(".gd")
	file_lines.append('const %s = "%s"' % [_BPSV_CONST_NAME, adjusted_path]) # "" '' <- parser
	for sv_data in static_var_data.values():
		file_lines.append("")
		sv_data.const_nm = _BPSV_CONST_NAME
		file_lines.append_array(_get_static_getter_lines(sv_data))
		file_lines.append_array(_get_static_setter_lines(sv_data))
	
	#file_lines.append("### PACKAGE EXPORTER STATIC VAR BACKPORT")
	var extends_class = file_extends_class(file_lines, backport_target)
	if not extends_class:
		file_lines.append(Backport.get_backport_file_path(self, BACKPORT_STATIC, BACKPORT_STATIC_PATH, export_obj))
	
	file_lines.append("")
	
	return file_lines

func post_export_edit_line(line:String) -> String:
	return line


func _build_setter_regex(var_nm):
	var setter_regex = RegEx.new()
	var escaped_nm = URegex.escape_regex_meta_characters(var_nm)
	var pattern_setter = "\\b(" + escaped_nm + ")\\b\\s*([+\\-*/%]?=)(?!=)\\s*(.*)"
	setter_regex.compile(pattern_setter)
	return setter_regex

func _build_getter_regex(var_nm):
	var getter_regex = RegEx.new()
	var escaped_nm = URegex.escape_regex_meta_characters(var_nm)
	var pattern_getter = "\\b(" + escaped_nm + ")\\b"
	getter_regex.compile(pattern_getter)
	return getter_regex

func _build_external_setter_rule(_class_name: String, var_name: String) -> Dictionary:
	var regex = RegEx.new()
	var prefix_pattern = "(?:[a-zA-Z_][a-zA-Z0-9_]*\\.)*?"
	var escp_cl = URegex.escape_regex_meta_characters(_class_name)
	var escp_vr = URegex.escape_regex_meta_characters(var_name)
	var pattern = "\\b((" + prefix_pattern + escp_cl + ")\\.(" + escp_vr + ")(?!\\w))\\s*([+\\-*/%]?=)(?!=)\\s*(.*)"
	regex.compile(pattern)

	# No "replacement" key - a compound assignment needs the object chain twice, which a
	# sub() template cannot express; process_line_for_external builds it by hand instead.
	return {
		"type": "setter_external",
		"regex": regex
	}


func _build_external_getter_rule(_class_name: String, var_name: String) -> Dictionary:
	var regex = RegEx.new()

	var prefix_pattern = "(?:[a-zA-Z_][a-zA-Z0-9_]*\\.)*?"
	var escp_cl = URegex.escape_regex_meta_characters(_class_name)
	var escp_vr = URegex.escape_regex_meta_characters(var_name)
	# Captures: 1=whole match, 2=object chain, 3=var name
	var pattern = "\\b((" + prefix_pattern + escp_cl + ")\\.(" + escp_vr + ")(?!\\w))"
	regex.compile(pattern)

	return {
		"type": "getter_external",
		"regex": regex,
		"replacement": "$2.get_$3()"
	}


## Setters run before getters: the getter pattern also matches the left side of an assignment,
## so running it first would rewrite "A.x = 1" into "A.get_x() = 1" before the setter ever sees it.
func process_line_for_external(line: String, rules: Array) -> String:
	var processed_line = line

	var setter_rules = rules.filter(func(r): return r.type == "setter_external")
	for rule in setter_rules:
		while true:
			var _match = rule.regex.search(processed_line)
			if not _match: break

			var full_match_text = _match.get_string(1)
			var object_chain = _match.get_string(2)
			var var_name = _match.get_string(3)
			var operator = _match.get_string(4).strip_edges()
			var value = _match.get_string(5).strip_edges()

			var replacement_text = ""
			if operator == "=":
				replacement_text = "{obj}.set_{var}({val})".format({"obj": object_chain, "var": var_name, "val": value})
			else:
				var compound_op = operator.substr(0, operator.length() - 1)
				replacement_text = "{obj}.set_{var}({obj}.get_{var}() {op} {val})".format({
					"obj": object_chain, 
					"var": var_name, 
					"op": compound_op, 
					"val": value
				})
			
			processed_line = processed_line.replace(full_match_text, replacement_text)
	
	var getter_rules = rules.filter(func(r): return r.type == "getter_external")
	for rule in getter_rules:
		# Re-search rather than sub() so multiple getters on one line all get rewritten
		while true:
			var _match = rule.regex.search(processed_line)
			if not _match:
				break

			var full_match_text = _match.get_string(1)
			var object_chain = _match.get_string(2)
			var var_name = _match.get_string(3)
			#print(var_name)
			var replacement_text = "{obj}.get_{var}()".format({
				"obj": object_chain,
				"var": var_name
			})

			processed_line = processed_line.replace(full_match_text, replacement_text)
		
	return processed_line



static func _get_static_getter_lines(data):
	return [
		"static func get_%s():" % data.name,
		"\treturn %s.get_ins().get_var(%s, '%s', %s)" % [BACKPORT_STATIC, data.const_nm, data.name, data.default]
	]

static func _get_static_setter_lines(data):
	return [
		"static func set_%s(value):" % data.name,
		"\treturn %s.get_ins().set_var(%s, '%s', value)" % [BACKPORT_STATIC, data.const_nm, data.name]
	]


func test_new_getter():
	var getter_rule = _build_external_getter_rule("Plugin", "instance")
	var regex = getter_rule.regex

	var line1 = "if not is_instance_valid(Plugin.instance):"
	var line2 = "var dock_manager = Plugin.instance.new_gui_instance()"
	var line3 = "var player = AnotherPlugin.instance_variable # Should not match"

	print("--- Testing Getter for '", line1, "' ---")
	var match1 = regex.search(line1)
	if match1:
		print("  Match found!")
		print("  Full match ($1): ", match1.get_string(1))
		print("  Object Chain ($2): ", match1.get_string(2))
		print("  Var Name ($3): ", match1.get_string(3))
		var replacement = "{obj}.get_{var}()".format({"obj": match1.get_string(2), "var": match1.get_string(3)})
		print("  Replaced Line: ", line1.replace(match1.get_string(1), replacement))
	else:
		print("  No match found. (ERROR)")

	print("\n--- Testing Getter for '", line2, "' ---")
	var match2 = regex.search(line2)
	if match2:
		print("  Match found!")
		var replacement = "{obj}.get_{var}()".format({"obj": match2.get_string(2), "var": match2.get_string(3)})
		print("  Replaced Line: ", line2.replace(match2.get_string(1), replacement))
	else:
		print("  No match found. (ERROR)")
		
	print("\n--- Testing Getter for '", line3, "' ---")
	var match3 = regex.search(line3)
	if not match3:
		print("  No match found. (CORRECT)")
	else:
		print("  False positive match found. (ERROR)")

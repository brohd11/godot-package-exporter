extends "res://addons/package_exporter/src/class/export/parse/parse_base.gd"

const PLUGIN_EXPORTED_STRING = "const PLUGIN_EXPORTED = false"
const PLUGIN_EXPORTED_REPLACE = "const PLUGIN_EXPORTED = true"

const OUT_OF_PLUGIN_MSG = \
"Out of plugin file path updated (if needed) but file not copied, if it should be, tag with \"#! dependency\" or ignore warning with \"#! ignore-remote\".
 File: \"%s\", in \"%s\""

var path_regex:RegEx
var const_name_regex:RegEx

func _init() -> void:
	super()
	
	path_regex = RegEx.new()
	var all_string_paths_pattern = "[\"'](.*?)[\"']"
	path_regex.compile(all_string_paths_pattern)
	
	const_name_regex = UtilsRemote.URegex.get_const_name()

func set_parse_settings(settings):
	pass

func get_direct_dependencies(file_path:String) -> Dictionary:
	var direct_dependencies = {}
	var global_classes_in_files = get_global_classes_in_file(file_path)
	reductions_for(file_path)
	for _class_name in global_classes_in_files:
		# a class this file only walks through is about to disappear from it, and pulling it in
		# would drag everything it preloads along with it
		if class_reduced_away(file_path, _class_name):
			continue
		var path = export_obj.export_data.class_list.get(_class_name)
		if not export_obj.global_classes_used.has(_class_name):
			export_obj.global_classes_used[_class_name] = {
				KeysData.DEPENDENT: file_path,
				KeysData.PATH: path
			}
		direct_dependencies[path] = {}

	return edges_to_dependencies(scan_direct_edges(file_path), direct_dependencies)


func post_export_edit_file(file_path:String, file_lines:Variant=null):
	var class_renames = export_obj.class_renames
	var classes_preloaded = []
	var classes_used = []
	
	if file_lines == null:
		file_lines = Array(FileAccess.get_file_as_string(file_path).split("\n"))
	var global_classes_in_file = ExportFileUtils._get_global_classes_in_text("\n".join(file_lines), export_obj.export_data.class_list)
	var class_declaration = global_classes_in_file.get("global_class_definition", "")
	global_classes_in_file.erase("global_class_definition")
	
	classes_used.append_array(global_classes_in_file.keys())

	var reductions = _file_reductions()
	var declared_bindings = {}

	var extended_class_string = ""
	var ignored_lines = DepScanner.ScanGD.ignored_line_numbers(
		"\n".join(file_lines), [DependencyTags.IGNORE_REMOTE])
	
	var adjusted_file_lines = []
	for line_index in file_lines.size():
		var line:String = file_lines[line_index]
		var comment_stripped = _strip_comment(line)
		
		if comment_stripped.begins_with("class_name "):
			if _check_text_valid(line, "class_name "):
				if class_renames.has(class_declaration):
					if comment_stripped.find(" extends ") > -1:
						line = "extends " + comment_stripped.get_slice(" extends ", 1) + line.substr(comment_stripped.length())
					else:
						line = ""
		if ignored_lines.has(line_index):
			# An ignored preload can still declare a binding used on another line.
			if comment_stripped.strip_edges().begins_with("const "):
				var binding = const_name_regex.search(comment_stripped)
				if binding != null:
					classes_preloaded.append(binding.get_string(1))
			adjusted_file_lines.append(line)
			continue
		
		if comment_stripped.find("extends ") > -1 and comment_stripped.count('"') == 2: # make this if so it will scan class nm too?
			#if not _check_for_comment(line, ["extends", "class"]):
			#if _check_text_valid(line, "extends "): #^c these 2 are mostly for checking preloaded in the current script,
				#if comment_stripped.find("class ") == -1: #^c hence no inner?
			if _is_extends_valid(line): #^c class check is handled in this func ^^
				var extend_file_path = comment_stripped.get_slice('"', 1)
				extend_file_path = extend_file_path.get_slice('"', 0)
				extend_file_path = export_obj.ensure_absolute_path(extend_file_path, file_path)
				if not FileAccess.file_exists(extend_file_path):
					printerr("Could not find extended file in line: %s" % line)
				
				var inherited_used_classes = _recursive_get_globals(extend_file_path)
				classes_preloaded.append_array(inherited_used_classes)
		
		elif comment_stripped.find("extends ") > -1:
			#if _check_text_valid(line, "extends "): #^ use line as arg so it just reuses string map
				#if comment_stripped.find("class ") == -1: #^c i think this could work for both class types
			if _is_extends_valid(line): #^c class check is handled in this func ^^
				var global_class = comment_stripped.get_slice("extends ", 1) # ""
				global_class = global_class.strip_edges()
				if global_class.find(" ") > -1: #^c what is this for?
					printerr("GETTING SPACE GLOBAL CLASS")
					global_class = global_class.get_slice(" ", 0)
				if export_obj.export_data.class_list.has(global_class):
					var path = export_obj.export_data.class_list.get(global_class)
					var inherited_used_classes = _recursive_get_globals(path)
					classes_preloaded.append_array(inherited_used_classes)
					if class_renames.has(global_class):
						line = line.replace(global_class, '"%s"' % path)
				else:
					
					var current_script = load(export_obj.file_parser.current_file_path_parsing)
					var constants = UClassDetail.script_get_all_constants(current_script,UClassDetail.IncludeInheritance.NONE)
					if constants.has(global_class):
						extended_class_string = global_class
						var extended_script = constants.get(extended_class_string)
						classes_preloaded.append_array(_recursive_get_globals(extended_script.resource_path))
						line = 'extends "%s"' % extended_script.resource_path
					elif global_class.find(".") > -1:
						var extended_script_path = UClassDetail.resolve_script_access_path(current_script, global_class)
						if extended_script_path.ends_with(".gd"):
							line = 'extends "%s"' % extended_script_path
						else:
							var path = extended_script_path.get_slice(".gd.", 0)
							var suffix = extended_script_path.get_slice(".gd.", 1)
							extended_script_path = path + ".gd"
							line = 'extends "%s".%s' % [extended_script_path, suffix]
						classes_preloaded.append_array(_recursive_get_globals(extended_script_path))
		
		elif comment_stripped.find("const") > -1:
			if _check_text_valid(line, "const"):
				var result = const_name_regex.search(line)
				if result:
					var const_name = result.get_string(1)
					if const_name == extended_class_string:
						line = ""
					elif class_renames.has(const_name):
						if not const_name in classes_preloaded:
							classes_preloaded.append(const_name)
		
		var existing_binding = _matching_preload_binding(line, comment_stripped, reductions)
		if existing_binding != "":
			declared_bindings[existing_binding] = true

		var declaration = _reduce_const_declaration(line, comment_stripped, reductions)
		if declaration.is_empty():
			line = _apply_reductions(line, comment_stripped, reductions)
		else:
			line = declaration.line
			if declaration.declares != "":
				declared_bindings[declaration.declares] = true

		line = _update_paths(line)

		adjusted_file_lines.append(line)

	#if not classes_used.is_empty(): #debug prints
		#print(file_path)
		#print(classes_used)
		#print(classes_preloaded)
	
	# `classes_used` is stale after the rewrites above: re-reading it keeps a reduced-away class
	# from getting its preload injected back. Guarded so exports without reduction stay unchanged.
	if not reductions.is_empty():
		classes_used = ExportFileUtils.get_global_classes_in_file_text(
			"\n".join(adjusted_file_lines), export_obj.export_data.class_list)

	var rename_lines = []
	for name in export_obj.export_data.class_list_array:
		if name in classes_preloaded:
			continue
		if not class_renames.has(name):
		#if not name in class_renames_keys:
			continue
		if not name in classes_used:
			continue
		var remote_path = class_renames[name]
		# Defaulted rather than null: a preload built from null throws mid-loop, silently
		# abandoning every rewrite this pass made, since the caller only takes the returned lines.
		var adjusted_path = export_obj.adjusted_remote_paths.get(remote_path, "")
		if adjusted_path == "":
			# An ignore_deps file may name classes from plugins it only optionally integrates with.
			if export_obj.file_deps_ignored(export_obj.file_parser.current_file_path_parsing):
				continue
			printerr('Class "%s" is used in %s but was not copied into the export - cannot inject its preload.'
				% [name, file_path])
			continue
		#if use_relative_paths:
			#adjusted_path = export_obj.get_relative_path(adjusted_path)
		adjusted_path = export_obj.get_rel_or_absolute_path(adjusted_path)
		var line = 'const %s' % name 
		line = line + ' = preload("%s")' % adjusted_path
		rename_lines.append(line)
		
	
	rename_lines.append_array(_reduction_preload_lines(reductions, declared_bindings))

	if not rename_lines.is_empty():
		adjusted_file_lines.append("")
		adjusted_file_lines.append("")
		adjusted_file_lines.append("### Package Exporter Global Classes")
		adjusted_file_lines.append_array(rename_lines)
		#adjusted_file_lines.append("### Package Exporter Global Classes")
		adjusted_file_lines.append("")


	return adjusted_file_lines


## The reductions that apply to the file currently being written, as
## {expression: {name, tail, path, inject}}.
##
## `inject` is false when an ancestor already declares the same binding: GDScript rejects
## redeclaring an inherited constant, so the derived script lets the const come down the chain.
## Names agree because build_access_bindings() decides them once for the whole export.
func _file_reductions() -> Dictionary:
	if not export_obj.reduce_access_paths:
		return {}
	var source_path:String = export_obj.file_parser.current_file_path_parsing
	var plan:Dictionary = export_obj.access_reductions.get(source_path, {})
	if plan.is_empty():
		return {}

	var inherited = _inherited_expressions(source_path)
	var out = {}
	for expression:String in plan:
		var name = export_obj.access_bindings.get(expression)
		if name == null: # dropped: its target is not in the export
			continue
		var entry:Dictionary = plan[expression]
		out[expression] = {
			"name": name,
			"tail": entry.tail,
			"path": entry.path,
			"inject": not inherited.has(expression),
		}
	return out


## Expressions any ancestor of `source_path` also reduces. The path list starts with the script
## itself, which has to be skipped - otherwise every file reads its own bindings as inherited and
## never declares them.
func _inherited_expressions(source_path:String) -> Dictionary:
	var out = {}
	var script = load(source_path) as GDScript
	if script == null:
		return out
	for path in UClassDetail.script_get_inherited_script_paths(script):
		if path == source_path:
			continue
		for expression in export_obj.access_reductions.get(path, {}):
			out[expression] = true
	return out


## `const UFile = ALibRuntime.Utils.UFile` is the shape this feature exists for, and the general
## rewrite would turn it into `const UFile = UFile`. The declaration IS the binding, so it
## becomes the preload itself. Returns {} when the line is not that shape, otherwise
## {line, declares} where `declares` names a binding no longer needing separate injection.
func _reduce_const_declaration(line:String, comment_stripped:String, reductions:Dictionary) -> Dictionary:
	if reductions.is_empty() or not comment_stripped.strip_edges().begins_with("const "):
		return {}
	if not _check_text_valid(line, "const "):
		return {}
	var result = const_name_regex.search(line)
	if result == null:
		return {}

	var value = comment_stripped.get_slice("=", 1).strip_edges()
	var entry = reductions.get(value)
	if entry == null:
		return {}

	var const_name = result.get_string(1)
	var preload_str = 'preload("%s")' % get_adjusted_path_or_old_renamed(entry.path)
	if not entry.tail.is_empty():
		preload_str += "." + ".".join(entry.tail)

	var indent = line.substr(0, line.length() - line.strip_edges(true, false).length())
	var comment = line.substr(comment_stripped.length())
	var declares := ""
	# only a class-scope declaration can stand in for the injected const; one inside an inner
	# class is scoped to it, so the outer binding may still be needed
	if indent == "" and const_name == entry.name:
		declares = const_name
	return {
		"line": "%sconst %s = %s%s" % [indent, const_name, preload_str, comment],
		"declares": declares,
	}


func _matching_preload_binding(line:String, comment_stripped:String,
		reductions:Dictionary) -> String:
	if reductions.is_empty() or not comment_stripped.strip_edges().begins_with("const "):
		return ""
	if line.length() != line.strip_edges(true, false).length():
		return "" # inner-class constants cannot supply an outer binding

	var const_match = const_name_regex.search(line)
	var path_match = preload_regex.search(comment_stripped)
	if const_match == null or path_match == null:
		return ""

	var const_name = const_match.get_string(1)
	var declared_path = export_obj.ensure_absolute_path(
		path_match.get_string(2), export_obj.file_parser.current_file_path_parsing)
	for expression:String in reductions:
		var entry:Dictionary = reductions[expression]
		if entry.name == const_name and entry.path.simplify_path() == declared_path:
			return const_name
	return ""


## An `extends` line is left alone - it is rewritten to a quoted path further up, and a class
## body constant cannot be used there anyway. Longest expression first, so "A.B.C" is consumed
## before "A.B" can eat its prefix.
func _apply_reductions(line:String, comment_stripped:String, reductions:Dictionary) -> String:
	if reductions.is_empty() or line.strip_edges() == "":
		return line
	var stripped = comment_stripped.strip_edges()
	if stripped.begins_with("extends ") or stripped.begins_with("class_name "):
		return line

	var expressions = reductions.keys()
	expressions.sort_custom(func(a, b): return a.length() > b.length())
	for expression:String in expressions:
		if line.find(expression) == -1:
			continue
		var entry:Dictionary = reductions[expression]
		var replacement = reduction_replacement(entry.name, entry.tail)
		var regex = get_reduction_regex(expression)
		line = _string_safe_regex_sub(line, func(text:String) -> String:
			return regex.sub(text, replacement, true))
	return line


func _reduction_preload_lines(reductions:Dictionary, declared_bindings:Dictionary) -> Array:
	var by_name = {}
	for expression:String in reductions:
		var entry:Dictionary = reductions[expression]
		if entry.inject and not declared_bindings.has(entry.name):
			by_name[entry.name] = entry.path

	# sorted so re-exporting the same plugin produces the same file
	var names = by_name.keys()
	names.sort()
	var lines = []
	for name:String in names:
		lines.append('const %s = preload("%s")' % [name, get_adjusted_path_or_old_renamed(by_name[name])])
	return lines


func _update_paths(line:String):
	if not DepScanner.ScanGD.ignored_line_numbers(line, [DependencyTags.IGNORE_REMOTE]).is_empty():
		return line
	var current_parse_file = export_obj.file_parser.current_file_path_parsing
	var comment_index = line.find("#")
	var matches = path_regex.search_all(line)
	for i in range(matches.size() - 1, -1, -1):
		var _match:RegExMatch = matches[i]
		var start = _match.get_start(1)
		var end = _match.get_end(1)
		if comment_index > -1 and comment_index < start:
			return line
		
		var old_path = _match.get_string(1)
		if old_path.begins_with(UFile._UID):
			if old_path == UFile._UID or old_path == UFile._UID_INVALID:
				continue
			old_path = UFile.uid_to_path(old_path)
		if old_path.count("/") == 0:
			if not old_path.is_valid_filename():
				continue
		else:
			if not old_path.get_file().is_valid_filename():
				continue
		
		
		var was_relative = old_path.is_relative_path()
		old_path = export_obj.ensure_absolute_path(old_path, current_parse_file)
		if was_relative:
			if not FileAccess.file_exists(old_path):
				continue
		
		var new_path = export_obj.adjusted_remote_paths.get(old_path)
		if new_path == null:
			if not UFile.is_file_in_directory(old_path, export_obj.source): #TODO #^ this needs some work, would be nice to allow renaming out of plugin
				#if not has_ignore_tag: # redundant
					#print(has_ignore_tag)
				#UtilsRemote.UEditor.print_warn(OUT_OF_PLUGIN_MSG % [line, current_parse_file])
				continue
			if export_obj.rename_plugin: # if new path was null, the old path was not processed. If rename, update to be accurate to new name
				if old_path.find(export_obj.plugin_name) > -1:
					new_path = export_obj.get_renamed_path(old_path)
		
		if new_path == null:
			new_path = old_path
		
		new_path = export_obj.get_rel_or_absolute_path(new_path)
		line = line.substr(0, start) + new_path + line.substr(end)
	
	return line

func get_global_class_in_file_data(file_path:String):
	return ExportFileUtils._get_global_classes_in_file(file_path, export_obj.export_data.class_list)

func get_global_classes_in_file(file_path:String) -> Array:
	var global_classes_in_files = ExportFileUtils._get_global_classes_in_file(file_path, export_obj.export_data.class_list)
	global_classes_in_files.erase("global_class_definition")
	return global_classes_in_files.keys()

func _recursive_get_globals(file_path:String) -> Array:
	var _classes = {}
	var script = load(file_path) as GDScript
	var inherited_scripts = UClassDetail.script_get_inherited_script_paths(script)
	for path in inherited_scripts:
		var global_classes = get_global_classes_in_file(path)
		for cl in global_classes:
			_classes[cl] = true
	return _classes.keys()

func post_export_edit_line(line:String):
	line = _update_file_export_flags(line)
	return line

func _update_file_export_flags(line:String):
	if line.find(PLUGIN_EXPORTED_STRING) > -1:
		line = line.replace(PLUGIN_EXPORTED_STRING, PLUGIN_EXPORTED_REPLACE)
	return line


func _is_extends_valid(line:String):
	var valid_text = _check_text_valid(line, "extends")
	if not valid_text:
		return false
	if line.begins_with("extends ") or line.begins_with("class_name "):
		return true
	
	return false

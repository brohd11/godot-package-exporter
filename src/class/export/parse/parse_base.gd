extends RefCounted


const UtilsLocal = preload("res://addons/package_exporter/src/class/utils_local.gd")
const UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd") #>remote
const UFile = UtilsRemote.UFile
const UString = UtilsRemote.UString
const URegex = UtilsRemote.URegex
const UClassDetail = UtilsRemote.UClassDetail
const ExportFileUtils = UtilsLocal.ExportFileUtils
const KeysData = ExportFileUtils.KeysData
const CompatData = UtilsLocal.CompatData
const DependencyTags = UtilsLocal.DependencyTags

const DepScanner = UtilsRemote.DepScanner
const DepEdge = DepScanner.DepEdge
const DepKind = DepEdge.Kind

## Edge kinds that mean "copy this file". LOAD is deliberately absent - a load() target
## compiles without the file, so it is only pulled in when tagged "#! dependency".
const DEP_KINDS = [DepKind.PRELOAD, DepKind.EXTENDS_PATH, DepKind.EXT_RESOURCE, DepKind.TAG]

const RES_LINE_TEMPLATE = '[ext_resource type="%s" path="%s" id="%s"]'

static var preload_regex:RegEx
static var _reduction_regexes:Dictionary = {}
static var _class_token_regexes:Dictionary = {}

var _string_regex:RegEx

var _dep_scanner
var _dep_scanner_export
var _edge_cache:Dictionary = {}

var export_obj: UtilsLocal.ExportData.Export

func _init() -> void:
	preload_regex = UtilsRemote.URegex.get_preload_path()
	

## Settings arrive keyed by extension: "parse_<ext>": {"my_setting": value}.
func set_parse_settings(settings) -> void:
	pass

## The returned dict acts as a set - dependencies[my_dep_path] = {}; the value is unused.
func get_direct_dependencies(file_path:String) -> Dictionary:
	var direct_dependencies = {}
	return direct_dependencies

## Direct references out of `file_path`, as DepEdges. Strings and comments are masked, uid and
## relative paths resolved, "#!" tags dispatched to their handler - so parsers no longer count
## quotes. Only one hop: file_parser.get_dependencies() drives the recursion.
func scan_direct_edges(file_path:String) -> Array:
	if _edge_cache.has(file_path):
		return _edge_cache[file_path]
	var scanner = _get_dep_scanner()
	scanner.roots = [file_path]
	var graph = scanner.get_graph()
	for edge in graph.unresolved:
		export_obj.reporter.error('Unresolved reference "%s" in %s:%s' % [edge.raw, edge.from, edge.line_no])
	var edges = graph.get_out_edges(file_path)
	_edge_cache[file_path] = edges
	return edges


## The file's reduction plan, scanned once per export. Both the global-class pass and the
## dependency crawl ask for this, and the crawl runs second.
func reductions_for(file_path:String) -> Dictionary:
	if not export_obj.reduce_access_paths:
		return {}
	if export_obj.access_reductions.has(file_path):
		return export_obj.access_reductions[file_path]
	var plan = edges_to_reductions(scan_direct_edges(file_path), {})
	export_obj.access_reductions[file_path] = plan
	return plan


## True when `cls` is only ever a pass-through in `file_path` - every mention of it is the head
## of a chain that reduction rewrites away, so the export needs neither the class nor its tree.
func class_reduced_away(file_path:String, cls:String) -> bool:
	if not export_obj.reduce_access_paths:
		return false
	var plan = reductions_for(file_path)
	var expressions = expressions_headed_by(plan, cls)
	if expressions.is_empty():
		return false
	var text = DepScanner.ScanGD.mask_ignored_lines(
		FileAccess.get_file_as_string(file_path), [DependencyTags.IGNORE_REMOTE])
	return class_fully_reduced(text, cls, expressions)

# One scanner per Export, reused across files by reassigning roots.
func _get_dep_scanner():
	if _dep_scanner == null or _dep_scanner_export != export_obj:
		var class_map = {}
		if export_obj != null and export_obj.reduce_access_paths:
			class_map = export_obj.export_data.class_list
		_dep_scanner = build_dep_scanner(class_map)
		_dep_scanner_export = export_obj
		_edge_cache.clear()
	return _dep_scanner

## `class_map` non-empty turns on access-path resolution: the scan then reports where a dotted
## path like "ALibRuntime.Utils.UFile" actually lands, which is what reduce_access_paths needs.
## Left empty, the scan does no global-class work at all - parse_gd's own pass owns that.
static func build_dep_scanner(class_map:Dictionary = {}):
	var scanner = DepScanner.new()
	# depth of 1, called per file, so only need direct dependencies for each
	scanner.max_depth = 1
	scanner.include_missing = false # a file that is not on disk must never reach files_to_copy
	scanner.use_project_classes = false # the export's own class list is the authority
	scanner.class_map = class_map
	scanner.resolve_access_paths = not class_map.is_empty()
	scanner.ignore_line_tags = [DependencyTags.IGNORE_REMOTE]
	scanner.add_tag_handler(DependencyTags.TAG, DependencyTags.dependency_dir())
	return scanner

## Folds scanned edges into the legacy {path: {"dependency_dir"?: dir}} shape.
static func edges_to_dependencies(edges:Array, out:Dictionary) -> Dictionary:
	for edge in edges:
		if edge.to == "":
			continue
		# An access-path edge (META_RESOLVED_FROM) names a file the export must copy in its own
		# right - the hub it resolves to may not survive reduction. Bare ones stay parse_gd's business.
		if not DEP_KINDS.has(edge.kind) and not edge.meta.has(DepEdge.META_RESOLVED_FROM):
			continue
		var entry = out.get(edge.to)
		if entry == null:
			entry = {}
			out[edge.to] = entry
		# 'preload("x") #! dependency current' emits a PRELOAD and a TAG edge for the same
		# file, so the directory is only ever written - never cleared by whichever lands last.
		var dependency_dir = edge.meta.get(DependencyTags.DIR_KEY, "")
		if dependency_dir != "":
			entry[KeysData.DEPENDENCY_DIR] = dependency_dir
			entry[KeysData.DEPENDENCY_SOURCE] = edge.meta.get(DependencyTags.DECLARING_FILE_KEY, edge.from)
	return out

## What each dotted access path in a file reduces to: {expression: {name, path, tail}}.
## Two kinds of expression are deliberately left alone: one whose head is already the deepest
## file it names (a genuine use of that class, not a pass-through), and one that walks a file's
## own const preloads rather than a global class - those paths are already rewritten on export.
static func edges_to_reductions(edges:Array, out:Dictionary) -> Dictionary:
	for edge in edges:
		var expression:String = edge.meta.get(DepEdge.META_RESOLVED_FROM, "")
		if expression == "" or edge.to == "" or out.has(expression):
			continue
		if not edge.meta.get(DepEdge.META_HEAD_FROM_CLASS_MAP, false):
			continue
		var consumed:int = edge.meta.get(DepEdge.META_CONSUMED, 0)
		if consumed < 2:
			continue
		var parts = expression.split(".", false)
		if consumed > parts.size():
			continue
		out[expression] = {
			"name": parts[consumed - 1],
			# the segment above it, the first fallback when two reductions want the same name
			"parent": parts[consumed - 2] if consumed >= 2 else "",
			"path": edge.to,
			"tail": Array(parts.slice(consumed)),
		}
	return out


## Matches an expression as a whole dotted token. The lookbehind keeps it off a longer chain
## that merely ends with it ("Other.ALibRuntime.Utils"), and the trailing boundary keeps
## "A.B.UFile" from matching inside "A.B.UFileWatcher".
static func get_reduction_regex(expression:String) -> RegEx:
	var regex = _reduction_regexes.get(expression)
	if regex == null:
		regex = RegEx.new()
		regex.compile("(?<![.\\w])%s\\b" % expression.replace(".", "\\."))
		_reduction_regexes[expression] = regex
	return regex


## The text a reduced expression becomes: the bound name, plus whatever the walk could not
## follow. "Hub.Utils.UProfile.TimeFunction" -> "UProfile.TimeFunction".
static func reduction_replacement(name:String, tail:Array) -> String:
	if tail.is_empty():
		return name
	return name + "." + ".".join(tail)


## The planned expressions that `cls` heads.
static func expressions_headed_by(plan:Dictionary, cls:String) -> Array:
	var out:Array = []
	for expression:String in plan:
		if expression.get_slice(".", 0) == cls:
			out.append(expression)
	return out


## True when every mention of `cls` in `text` is the head of an expression that reduction will
## rewrite away - the class is pure pass-through here, so the file needs neither a preload of it
## nor, in turn, the whole tree that file preloads.
static func class_fully_reduced(text:String, cls:String, expressions:Array) -> bool:
	if expressions.is_empty():
		return false

	var reduced_at = {}
	for expression:String in expressions:
		for m in get_reduction_regex(expression).search_all(text):
			reduced_at[m.get_start()] = true

	var map = ExportFileUtils.get_string_map(text)
	for m in get_class_token_regex(cls).search_all(text):
		var index = m.get_start()
		if map.index_in_string_or_comment(index):
			continue
		if ExportFileUtils.is_member_access(text, index):
			continue # a tail segment elsewhere, not a use of this class
		if not reduced_at.has(index):
			return false
	return true


static func get_class_token_regex(cls:String) -> RegEx:
	var regex = _class_token_regexes.get(cls)
	if regex == null:
		regex = RegEx.new()
		regex.compile("\\b%s\\b" % cls)
		_class_token_regexes[cls] = regex
	return regex

## Rewrites a serialized file's references: every ext_resource path is remapped to where the
## export puts it, and the file's own uid is regenerated if it is a copied dependency, so two
## plugins vendoring the same scene do not collide. `header` is the leading tag holding that uid -
## "[gd_scene" for a scene, "[gd_resource" for a resource.
func _rewrite_ser_file(file_path:String, header:String) -> Variant:
	var file_access = FileAccess.open(file_path, FileAccess.READ)
	if not file_access:
		export_obj.reporter.error("%s - Issue reading file: %s" % [get_script().resource_path.get_file(), file_path])
		return null

	var file_dependencies_keys = export_obj.file_dependencies.keys()
	var adjusted_file_lines = []
	while not file_access.eof_reached():
		var line = file_access.get_line()

		if line.find(header) > -1:
			var uid = line.get_slice(' uid="', 1)
			uid = uid.get_slice('"', 0)
			if UFile.uid_to_path(uid) in file_dependencies_keys:
				var new_uid = ResourceUID.id_to_text(ResourceUID.create_id())
				line = line.replace('uid="%s"' % uid, 'uid="%s"' % new_uid)
		elif line.find('[ext_resource') > -1:
			var type = line.get_slice(' type="', 1)
			type = type.get_slice('"', 0)
			var path = line.get_slice('path="', 1)
			path = path.get_slice('"', 0)
			var id = line.get_slice(' id="', 1)
			id = id.get_slice('"', 0)

			line = RES_LINE_TEMPLATE % [type, get_adjusted_path_or_old_renamed(path), id]

		adjusted_file_lines.append(line)

	return adjusted_file_lines


## Hook for extension-specific files; runs right before the export writes files.
func pre_export() -> void:
	return

## Second post-export pass; sees whatever post_export_edit_file returned.
func post_export_edit_line(line:String) -> String:
	return line

## First post-export pass. `file_lines` is null for extensions the base does not handle;
## process and return the lines, or return null to fall back to the file on disk.
func post_export_edit_file(file_path:String, file_lines:Variant=null) -> Variant:
	return file_lines

func _update_file_export_flags(line:String) -> String:
	return line

func get_adjusted_path_or_old_renamed(file_path:String) -> String:
	var new_path = export_obj.adjusted_remote_paths.get(file_path, file_path)
	new_path = export_obj.get_rel_or_absolute_path(new_path)
	if not export_obj.use_relative_paths:
		new_path = export_obj.get_renamed_path(new_path)
	return new_path

func _string_safe_regex_sub(line: String, processor: Callable) -> String:
	if not is_instance_valid(_string_regex):
		_string_regex = URegex.get_strings()
	line = URegex.string_safe_regex_sub(line, processor, _string_regex)
	return line


func file_extends_class(file_lines:Array, backport_target:=100) -> bool:
	var global_class_names = export_obj.export_data.class_list.keys()
	var extends_class = false
	for i in range(file_lines.size()):
		var line = file_lines[i]
		
		var _class = get_extended_class(line)
		if _class:
			if _class.find('"') > -1:
				extends_class = true
			else:
				if _class in global_class_names:
					extends_class = true
				elif _class not in ClassDB.get_class_list():
					extends_class = true
				if backport_target < 4:
					if _class in CompatData.COMPAT_CLASSES:
						extends_class = true
				
				break
	return extends_class

static func _check_for_comment(line, check_array) -> bool:
	if check_array is String:
		check_array = [check_array]
	var comment_index = line.find("#")
	if comment_index == -1:
		return false
	for text in check_array:
		var index = line.find(text)
		if index == -1:
			continue
		if comment_index < index:
			return true
	
	return false


static func _check_text_valid(line:String, to_check:String) -> bool:
	if line.begins_with("#"):
		return false
	var string_map = ExportFileUtils.get_string_map(line) as UString.StringMap
	var idx = line.find(to_check)
	if idx == -1:
		return false
	if string_map.string_mask[idx] == 1:
		return false
	var com_idx = string_map.get_comment_index(0)
	#var com_idx = string_map.comment_mask.find(1)
	if com_idx > -1 and com_idx < idx:
		return false
	return true


static func _strip_comment(line:String):
	var string_map = ExportFileUtils.get_string_map(line) as UString.StringMap
	#var com_idx = string_map.comment_mask.find(1)
	var com_idx = string_map.get_comment_index(0)
	if com_idx == -1:
		return line
	return line.substr(0, com_idx)


static func get_preload_path(line):
	if not is_instance_valid(preload_regex):
		preload_regex = UtilsRemote.URegex.get_preload_path()
	
	if not _check_text_valid(line, "preload("):
		return
	
	var _match = preload_regex.search(line)
	if _match:
		var file_path = _match.get_string(2)
		return file_path

static func _construct_pre(class_nm:String, path:String):
	var c = "const"
	var p = 'preload("%s")' % path
	var constructed = "%s %s = %s" % [c, class_nm, p]
	return constructed

static func get_extended_class(line:String):
	if not _check_text_valid(line, "extends"):
		return
	var _class = line.get_slice("extends ", 1).strip_edges()
	return _class

static func line_has_tag(line:String, tag:String, prefix:="#!") -> bool:
	var pre_idx = line.find(prefix)
	if pre_idx == -1:
		return false
	var tags = line.substr(pre_idx)
	return tags.find(tag) > -1

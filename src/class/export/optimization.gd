extends "res://addons/package_exporter/src/class/export/parse/parse_base.gd"
## Render before packaging changes source identities, then let packaging relocate new references.

const Optimizer = UtilsRemote.GDScriptOptimizer

var replacements:Dictionary = {}
var stats:Dictionary = {}
var errors:Array = []
var warnings:Array = []
var _settings:Variant = {}


static func defaults() -> Dictionary:
	var settings:Dictionary = Optimizer.Config.DEFAULTS.duplicate(true)
	settings.enabled = true
	return settings


static func configuration(settings:Variant) -> Dictionary:
	if not settings is Dictionary:
		return {"options": {}, "errors": ["optimizer must be a mapping."]}
	var enabled:Variant = settings.get("enabled", true)
	if not enabled is bool:
		return {"options": {}, "errors": ["optimizer.enabled must be a boolean."]}
	if not enabled:
		return {"options": {"enabled": false}, "errors": []}
	var options:Dictionary = settings.duplicate(true)
	options.erase("enabled")
	var result:Dictionary = Optimizer.Config.from_dictionary(options)
	if result.errors.is_empty():
		result.options.enabled = true
	return result


static func _policy(options:Dictionary) -> Dictionary:
	var policy := options.duplicate()
	policy.erase("enabled")
	return policy


func set_parse_settings(settings) -> void:
	_settings = settings.get("optimizer", {})
	if _settings is Dictionary:
		_settings = _settings.duplicate(true)


func pre_export() -> void:
	replacements.clear()
	stats.clear()
	errors.clear()
	warnings.clear()
	var config := configuration(_settings)
	errors.append_array(config.errors)
	if not errors.is_empty():
		_report()
		return
	var options:Dictionary = config.options
	if not options.enabled:
		return
	var context = Optimizer.Context.new()
	context.set_global_classes(export_obj.export_data.class_list)
	context.removed_globals = export_obj.class_renames
	context.scan_references = _references
	context.injection_header = "### Package Exporter Structs"
	context.configure(_policy(options))
	var sources:Dictionary = {}
	for key:String in export_obj.files_to_copy:
		var source:String = export_obj.files_to_copy[key].get(KeysData.REPLACE_WITH, key)
		if source.get_extension() == "gd":
			sources[key] = source
	context.map_path = func(key:String): return sources.get(key, key)
	var passes:Array = []
	if options.struct_mode != "off":
		passes.append(Optimizer.StructPass)
	if options.inline_mode != "off":
		passes.append(Optimizer.InlinePass)
	var optimizer = Optimizer.new()
	var prepared:Dictionary = optimizer.prepare(sources, context, passes)
	stats = optimizer.stats.duplicate()
	errors.append_array(prepared.errors)
	warnings.append_array(prepared.warnings)
	var pending:Dictionary = {}
	if errors.is_empty():
		for key:String in optimizer.planned_files():
			var original := FileAccess.get_file_as_string(sources[key])
			var result:Dictionary = optimizer.apply(key, Array(original.split("\n")))
			errors.append_array(result.errors)
			warnings.append_array(result.get("warnings", []))
			for name:String in result.get("stats", {}):
				stats[name] = stats.get(name, 0) + result.stats[name]
			if "\n".join(result.lines) != original:
				_check_dependencies(key, original, "\n".join(result.lines), sources)
				pending[key] = result.lines
	if errors.is_empty():
		replacements = pending
		export_obj.reporter.info("Package Exporter - optimizer stats=" + JSON.stringify(stats))
	_report()


func _check_dependencies(key:String, original:String, rendered:String, sources:Dictionary) -> void:
	var preloads := RegEx.create_from_string('(?m)^\\s*const\\s+\\w+\\s*=\\s*preload\\("([^"\\n]+)"\\)')
	var existing:Dictionary = {}
	for found in preloads.search_all(original):
		existing[found.get_string(1)] = true
	for found in preloads.search_all(rendered):
		var path:String = found.get_string(1)
		if existing.has(path) or export_obj.files_to_copy.has(path) or sources.values().has(path):
			continue
		errors.append("%s: optimizer introduced an unpackaged dependency: %s" % [key, path])


func _references(path:String) -> Array:
	var paths:Array = []
	for edge in scan_direct_edges(path):
		if edge.to != "":
			paths.append(edge.to)
	var classes:Dictionary = export_obj.export_data.class_list
	var globals:Dictionary = ExportFileUtils._get_global_classes_in_file(path, classes, export_obj.reporter)
	globals.erase("global_class_definition")
	for name in globals:
		if classes.has(name):
			paths.append(classes[name])
	return paths


func _report() -> void:
	for warning in warnings:
		export_obj.reporter.warn("Optimizer - " + warning)
	for error in errors:
		export_obj.reporter.error("Package Exporter - optimizer - " + error)
	if not errors.is_empty():
		export_obj.invalidate()

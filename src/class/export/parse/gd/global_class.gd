extends "res://addons/package_exporter/src/class/export/parse/parse_base.gd"

const StripTypeCast = preload("res://addons/package_exporter/src/class/export/parse/gd/global_class/strip_type_cast.gd")
var strip_type_cast:StripTypeCast

const GlobalRename = preload("res://addons/package_exporter/src/class/export/parse/gd/global_class/global_rename.gd")
var global_rename:GlobalRename

const RemoveNamespace = preload("res://addons/package_exporter/src/class/export/parse/gd/global_class/remove_namespace.gd")
var remove_namespace: RemoveNamespace

func _init() -> void:
	strip_type_cast = StripTypeCast.new()
	global_rename = GlobalRename.new()
	remove_namespace = RemoveNamespace.new()

func set_parse_settings(settings):
	
	strip_type_cast.export_obj = export_obj
	global_rename.export_obj = export_obj
	remove_namespace.export_obj = export_obj
	
	strip_type_cast.set_parse_settings(settings)

func get_direct_dependencies(file_path:String) -> Dictionary:
	var dependencies = {} 
	return dependencies

func pre_export() -> void:
	global_rename.pre_export()


func post_export_edit_file(file_path:String, file_lines:Variant=null) -> Variant:
	file_lines = strip_type_cast.post_export_edit_file(file_path, file_lines)
	file_lines = global_rename.post_export_edit_file(file_path, file_lines)
	return file_lines

func post_export_edit_line(line:String) -> String:
	line = remove_namespace.post_export_edit_line(line)
	return line

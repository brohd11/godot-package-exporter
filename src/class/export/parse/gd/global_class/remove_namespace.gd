extends "res://addons/package_exporter/src/class/export/parse/parse_base.gd"

func set_parse_settings(settings):
	pass

func get_direct_dependencies(file_path:String) -> Dictionary:
	var dependencies = {} 
	return dependencies

func pre_export() -> void:
	return


func post_export_edit_file(file_path:String, file_lines:Variant=null) -> Variant:
	return file_lines

func post_export_edit_line(line:String) -> String:
	if line.begins_with("#! namespace"):
		line = ""
	if line.begins_with("# This file is auto-generated. Do not edit."):
		line = ""
	return line

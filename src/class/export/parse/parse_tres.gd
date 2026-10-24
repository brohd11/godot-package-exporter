extends "res://addons/package_exporter/src/class/export/parse/parse_base.gd"

func set_parse_settings(settings):
	pass

func get_direct_dependencies(file_path:String) -> Dictionary:
	_read_script_class(file_path)
	return edges_to_dependencies(scan_direct_edges(file_path), {})

# The scanner is run without a class map, so the [gd_resource] header is read here. It is
# always the first line.
func _read_script_class(file_path:String) -> void:
	var file_access = FileAccess.open(file_path, FileAccess.READ)
	if not file_access:
		export_obj.reporter.error("Could not open file: %s" % file_path)
		return
	var line = file_access.get_line()
	if line.find("[gd_resource") == -1 or line.find(' script_class="') == -1:
		return
	var script_class = line.get_slice(' script_class="', 1)
	script_class = script_class.get_slice('"', 0)
	if not export_obj.global_classes_used.has(script_class):
		export_obj.global_classes_used[script_class] = {
			#KeysData.DEPENDENT: file_path,
			KeysData.PATH: file_path
		}
	# erase from renames, keeps resource class global
	export_obj.class_renames.erase(script_class)

func post_export_edit_line(line:String) -> String:
	return line

func post_export_edit_file(file_path:String, file_lines:Variant=null) -> Variant:
	return _rewrite_ser_file(file_path, '[gd_resource')

func _update_file_export_flags(line:String) -> String:
	return line

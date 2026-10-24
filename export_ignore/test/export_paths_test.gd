@tool
extends EditorScript

## Tests for export config path rules: export_folder is an install path anywhere under res://, and
## the old "<package>/<folder>" form is caught by its {{...}} template instead of installing wrong.
##
##     load("res://addons/package_exporter/export_ignore/test/export_paths_test.gd").run_tests()

const ExportPaths = preload("res://addons/package_exporter/src/class/export/export_paths.gd")

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_export_folder_error()
	_test_targets()
	_test_dependency_destinations()

	var output:Array[String] = []
	output.append("export_paths: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_export_folder_error() -> void:
	for valid in ["", "addons/x", "addons/_lib/x/", "lib/x", "res://lib/x"]:
		_check("valid: '%s'" % valid, ExportPaths.export_folder_error(valid), "")
	_check("absolute", ExportPaths.export_folder_error("/abs/x"), "is an absolute path")
	_check("drive letter", ExportPaths.export_folder_error("C:/x"), "is an absolute path")
	_check("leaves the project", ExportPaths.export_folder_error("addons/../../x"), "leaves the project")
	_check("old form points at export_name",
		"export_name" in ExportPaths.export_folder_error("brohd{{version=brohd}}/_lib/brohd"), true)


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])


static func _test_targets() -> void:
	var expected = "res://addons/_lib/brohd"
	for target in ["_lib/brohd", "./_lib/brohd/", "res://addons/_lib/brohd/",
			ProjectSettings.globalize_path(expected), "_lib/other/../brohd"]:
		_check("target: " + target, ExportPaths.resolve_target(target), expected)
	_check("outside addons", ExportPaths.resolve_target("res://lib/pkg"), "res://lib/pkg")
	_check("relative parent", ExportPaths.resolve_target("../lib/pkg"), "res://lib/pkg")
	_check("project root", ExportPaths.resolve_target("res://"), "res://")
	for invalid in ["", "  ", "user://pkg", "uid://abc", "https://host/pkg", "../../outside",
			"res://../outside", ProjectSettings.globalize_path("res://").trim_suffix("/") + "-other/pkg"]:
		_check("invalid: " + invalid, ExportPaths.resolve_target(invalid), "")
	_check("workspace aliases", ExportPaths.workspace_key(expected), ExportPaths.workspace_key("_lib/brohd"))
	_check("workspace stays flat", "/" in ExportPaths.workspace_key(expected), false)
	_check("workspace basename collision", ExportPaths.workspace_key("lib/pkg") == ExportPaths.workspace_key("res://lib/pkg"), false)


static func _test_dependency_destinations() -> void:
	var source = "res://addons/example/"
	var declaring = source + "remote/ui/console.gd"
	var cases = {
		"licenses/font/LICENSE": "remote/ui/licenses/font/LICENSE",
		"./licenses/./font/LICENSE": "remote/ui/licenses/font/LICENSE",
		"../licenses/font/LICENSE": "remote/licenses/font/LICENSE",
		"LICENSE": "remote/ui/LICENSE",
		"current": "remote/ui/LICENSE.txt",
		".": "remote/ui/LICENSE.txt",
		"<package>/licenses/font/LICENSE": "licenses/font/LICENSE",
		"<package>/licenses/../font/LICENSE": "font/LICENSE",
		"<package>/LICENSE": "LICENSE",
		source + "LICENSE": "LICENSE",
		source + "licenses/font/LICENSE": "licenses/font/LICENSE",
		ProjectSettings.globalize_path(source + "licenses/font/LICENSE"): "licenses/font/LICENSE",
	}
	for raw:String in cases:
		_check("destination: " + raw, ExportPaths.dependency_destination(raw, source, declaring, "LICENSE.txt"), source + cases[raw])
	for raw in ["../../../outside", "<package>/../outside", "res://addons/example-other/licenses",
			"res://addons/another/licenses", "user://licenses", "/tmp/licenses", "res://addons/example/../outside",
			"", "<package>", "<package>/", "licenses/", "licenses/..", "licenses/.", source]:
		_check("invalid destination: " + raw, ExportPaths.dependency_destination(raw, source, declaring, "LICENSE.txt"), "")
	_check("relative needs declaring placement", ExportPaths.dependency_destination("licenses", source, "", "LICENSE.txt"), "")
	_check("package independent of declaration", ExportPaths.dependency_destination("<package>/licenses/LICENSE", source, "", "LICENSE.txt"), source + "licenses/LICENSE")

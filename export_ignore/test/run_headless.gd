extends SceneTree
## Clean-compile headless entry for the package_exporter suites, exiting with a CI code.
##     godot --headless --path . --script res://addons/package_exporter/export_ignore/test/run_headless.gd

const SUITES:PackedStringArray = [
	"res://addons/package_exporter/export_ignore/test/optimizer_config_test.gd",
	"res://addons/package_exporter/export_ignore/test/dependency_tags_test.gd",
	"res://addons/package_exporter/export_ignore/test/access_reduction_test.gd",
	"res://addons/package_exporter/export_ignore/test/license_resolution_test.gd",
	"res://addons/package_exporter/export_ignore/test/dep_resolver_test.gd",
	"res://addons/package_exporter/export_ignore/test/require_update_test.gd",
	"res://addons/package_exporter/export_ignore/test/require_check_test.gd",
	"res://addons/package_exporter/export_ignore/test/repo_cache_test.gd",
	"res://addons/package_exporter/export_ignore/test/toolchain_test.gd",
	"res://addons/package_exporter/export_ignore/test/package_layout_test.gd",
	"res://addons/package_exporter/export_ignore/test/release_cache_test.gd",
	"res://addons/package_exporter/export_ignore/test/export_ignore_test.gd",
	"res://addons/package_exporter/export_ignore/test/export_paths_test.gd",
	"res://addons/package_exporter/export_ignore/test/global_rename_test.gd",
	"res://addons/package_exporter/export_ignore/test/reporter_test.gd",
	"res://addons/package_exporter/export_ignore/test/package_discovery_test.gd",
	"res://addons/package_exporter/export_ignore/test/package_init_test.gd",
	"res://addons/package_exporter/export_ignore/test/package_cfg_test.gd",
	"res://addons/package_exporter/export_ignore/test/package_targets_test.gd",
	"res://addons/package_exporter/export_ignore/test/release_runner_test.gd",
	"res://addons/package_exporter/export_ignore/test/release_engine_test.gd",
	"res://addons/package_exporter/export_ignore/test/doc_viewer/markdown_parser_test.gd",
	"res://addons/package_exporter/export_ignore/test/doc_viewer/doc_index_test.gd",
]

func _init() -> void:
	var success = true
	var output:Array[String] = []

	for path in SUITES:
		var res:Dictionary = load(path).run_tests()
		success = success and res.result == 0
		output.append_array(res.output)

	print("\n".join(output))
	quit(0 if success else 1)

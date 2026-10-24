class_name PackageExporter

const MiscBackport = preload("res://addons/package_exporter/src/class/export/backport/misc_backport_class.gd")

const Plugin = preload("res://addons/package_exporter/plugin.gd")
const UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd")
const UtilsLocal = preload("res://addons/package_exporter/src/class/utils_local.gd")
const PluginExporterStatic = UtilsLocal.PluginExporterStatic
const PluginInit = UtilsLocal.PluginInit
const PackageDiscovery = preload("res://addons/package_exporter/src/class/export/package_discovery.gd")
const ExportScript = preload("res://addons/package_exporter/src/class/export/export_script.gd")

enum TargetAddons {
	ALL,
	VALID,
	NOT_VALID,
}

## `reporter` (UtilsLocal.Reporter) collects what the export says, e.g. for a console sink.
static func export(plugin_name:String, reporter = null):
	return PluginExporterStatic.export_by_name(plugin_name, reporter)

## Pinned export: deps resolved to tags, exported from a workspace of those tags, then compile
## checked. `refresh` re-checks cached tags against their remotes; `local` fetches from this
## project's checkouts instead, so tags needn't be pushed.
static func export_release(plugin_name:String, refresh:=false, local:=false, reporter = null) -> bool:
	return load("res://addons/package_exporter/src/class/release/release_export.gd").export_release(plugin_name, refresh, local, reporter)

static func new_plugin(plugin_name:String):
	PluginExporterStatic.new_plugin(plugin_name)

static func plugin_init(plugin_name:String):
	PluginInit.plugin_init(plugin_name)

static func package_init(target:String, cfg_name:String = "addon.cfg"):
	PluginInit.package_init(target, cfg_name)

static func add_release_workflow(target:String) -> String:
	return PluginInit.add_release_workflow(target)

static func add_test_workflow(target:String) -> String:
	return PluginInit.add_test_workflow(target)

## Test CI locally: the package's suites against its requires at their tags, in a workspace.
static func test_package(target:String, refresh:bool = false, local:bool = false, reporter = null) -> bool:
	return load("res://addons/package_exporter/src/class/release/test_ci.gd").test_package(target, refresh, local, "", reporter)

static func gui_open(plugin_name:String):
	var export_file_path = UtilsLocal.ExportFileUtils.get_export_config_path(plugin_name)
	if not FileAccess.file_exists(export_file_path):
		printerr("File does not exist: %s" % export_file_path)
		return
	if not is_instance_valid(Plugin.instance):
		printerr("PackageExporter instance not found. Make sure plugin is enabled.")
		return
	
	var dock_manager = Plugin.instance.new_gui_instance()
	var gui_instance = dock_manager.get_plugin_control()
	
	var read_file = true
	gui_instance.load_export_file(export_file_path, read_file)

static func open_export_folder(plugin_name:String):
	var export_config_path = UtilsLocal.ExportFileUtils.get_export_config_path(plugin_name)
	if not FileAccess.file_exists(export_config_path):
		printerr("Could not find file: %s" % export_config_path)
		return
	PluginExporterStatic.open_export_dir(export_config_path)


static func get_addons_dirs(limit_to:=TargetAddons.VALID) -> Dictionary:
	return PackageDiscovery.discover("res://addons", limit_to)

static func get_unpackaged_dirs() -> Dictionary:
	return PackageDiscovery.discover_unpackaged("res://addons")

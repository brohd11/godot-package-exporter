extends RefCounted

const PluginExporterStatic = preload("res://addons/package_exporter/src/class/export/plugin_exporter_static.gd")
const PluginInit = preload("res://addons/package_exporter/src/class/export/plugin_init.gd")
const ExportData = preload("res://addons/package_exporter/src/class/export/export_data.gd")
const ExportObj = preload("res://addons/package_exporter/src/class/export/export_obj.gd")
const FileParser = preload("res://addons/package_exporter/src/class/export/file_parser.gd")
const ExportFileUtils = preload("res://addons/package_exporter/src/class/export/plugin_exporter_file_utils.gd")
const DependencyTags = preload("res://addons/package_exporter/src/class/export/dependency_tags.gd")
const TagRegistry = preload("res://addons/package_exporter/src/class/export/tag_registry.gd")
const Reporter = preload("res://addons/package_exporter/src/class/export/reporter.gd")

const ParseBase = preload("res://addons/package_exporter/src/class/export/parse/parse_base.gd")
const ParseGD = preload("res://addons/package_exporter/src/class/export/parse/parse_gd.gd")
const ParseTSCN = preload("res://addons/package_exporter/src/class/export/parse/parse_tscn.gd")
const ParseCS = preload("res://addons/package_exporter/src/class/export/parse/parse_cs.gd")
const ParseTres = preload("res://addons/package_exporter/src/class/export/parse/parse_tres.gd")

const ExportIgnore = preload("res://addons/package_exporter/src/class/export/export_ignore.gd")

const Backport = preload("res://addons/package_exporter/src/class/export/parse/gd/backport.gd")
const CompatData = preload("res://addons/package_exporter/src/class/export/backport/compat_data.gd")

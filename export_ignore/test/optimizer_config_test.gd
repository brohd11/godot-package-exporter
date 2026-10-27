extends RefCounted

const Optimization = preload("res://addons/package_exporter/src/class/export/optimization.gd")
const Init = preload("res://addons/package_exporter/src/class/export/plugin_init.gd")

static func run_tests() -> Dictionary:
	var failures:Array = []
	var expected := Optimization.defaults()
	expected.enabled = false
	var template:Dictionary = Init.PluginExportJSON.get_body_data()
	var seeded:Dictionary = template.options.parser_settings.parse_gd.optimizer
	if seeded != expected:
		failures.append("plugin_init did not seed optimizer defaults")
	var yaml := YAMLParser.new()
	if yaml.parse(YAMLParser.dump(template)) != OK or yaml.data.options.parser_settings.parse_gd.optimizer != expected:
		failures.append("seeded defaults did not survive YAML serialization")
	seeded.enabled = true
	if Init.PluginExportJSON.get_body_data().options.parser_settings.parse_gd.optimizer.enabled:
		failures.append("template defaults leaked between initializations")
	var defaults := Optimization.configuration({})
	if not defaults.errors.is_empty() or not defaults.options.enabled or defaults.options.inline_mode != "tagged" or defaults.options.struct_mode != "tagged":
		failures.append("missing optimizer block did not enable shared defaults")
	var partial := Optimization.configuration({"inline_mode": "off"})
	if not partial.errors.is_empty() or partial.options.inline_mode != "off" or partial.options.struct_mode != "tagged":
		failures.append("partial optimizer settings lost defaults")
	var disabled := Optimization.configuration({"enabled": false, "unknown": true, "struct_mode": "unknown"})
	if not disabled.errors.is_empty() or disabled.options != {"enabled": false}:
		failures.append("disabled optimizer validated inactive settings")
	for value in [false, null, [], {"enabled": "false"}, {"enabled": 0}, {"unknown": true}]:
		if Optimization.configuration(value).errors.is_empty():
			failures.append("invalid optimizer configuration accepted: " + str(value))
	return {"result": failures.size(), "output": ["optimizer config: %d failures" % failures.size()] + failures}

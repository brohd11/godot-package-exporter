extends GDSh.CommandBase

const PluginExporter = preload("res://addons/package_exporter/src/class/plugin_exporter.gd")
const PECommandUtils = preload("res://addons/package_exporter/src/editor_plugins/console_command/command_utils.gd")

const _HELP = \
"Export the selected plugin
Usage: package_exporter export [--verbose] [--release [--local] [--refresh]] <plugin_name>"

var release_flag := false
var refresh_flag := false
var local_flag := false
var verbose_flag := false

static func get_command_name() -> String:
	return "export"

static func get_self_command_data() -> Dictionary:
	return _command_data({
		&"help": _HELP + PECommandUtils.TARGET_HELP,
		&"positional_count": 1
	})

func _get_completions(ctx:Completion):
	return PECommandUtils.plugin_name_completion(self, ctx, PECommandUtils.TargetAddons.VALID)

func _get_flags() -> Dictionary:
	var options = Options.new()
	options.add_option("--verbose", {
		&"help": "Also show progress lines; warnings, errors and the result always show."
	})
	options.add_option("--release", {
		&"help": "Export from the tags in plugin.cfg deps/require instead of the dev tree, then compile check."
	})
	options.add_option("--refresh", {
		&"help": "With --release: re-check cached tags against their remotes, failing if one moved."
	})
	options.add_option("--local", {
		&"help": "With --release: fetch tags from this project's checkouts instead of remotes (no push needed)."
	})
	return options.get_options()

func _process_flag(flag:String):
	if flag == "--release":
		release_flag = true
	elif flag == "--refresh":
		refresh_flag = true
	elif flag == "--local":
		local_flag = true
	elif flag == "--verbose":
		verbose_flag = true

func _execute(ctx:Context):
	var plugin_name = positional_args[0]
	var reporter = PECommandUtils.console_reporter(ctx, verbose_flag)
	var success
	if release_flag:
		success = PluginExporter.export_release(plugin_name, refresh_flag, local_flag, reporter)
	else:
		success = PluginExporter.export(plugin_name, reporter)
	return ExitCode.OK if success else ExitCode.FAIL

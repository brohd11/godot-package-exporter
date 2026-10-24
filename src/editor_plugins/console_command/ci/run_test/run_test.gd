extends GDSh.CommandBase

const PluginExporter = preload("res://addons/package_exporter/src/class/plugin_exporter.gd")
const PECommandUtils = preload("res://addons/package_exporter/src/editor_plugins/console_command/command_utils.gd")

const _HELP = \
"Run a package's tests as test CI does: its tree against its requires at their tags, in a
workspace without the rest of this project - so a pass means its declared requires are enough.
Usage: package_exporter ci run_test [--verbose] [--local] [--refresh] <plugin_name>"

var refresh_flag := false
var local_flag := false
var verbose_flag := false

static func get_command_name() -> String:
	return "run_test"

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
		&"help": "Also show progress and passing suites; failures, skips and the result always show."
	})
	options.add_option("--refresh", {
		&"help": "Re-check cached tags against their remotes, failing if one moved."
	})
	options.add_option("--local", {
		&"help": "Fetch tags from this project's checkouts instead of remotes (no push needed)."
	})
	return options.get_options()

func _process_flag(flag:String):
	if flag == "--refresh":
		refresh_flag = true
	elif flag == "--local":
		local_flag = true
	elif flag == "--verbose":
		verbose_flag = true

func _execute(ctx:Context):
	var reporter = PECommandUtils.console_reporter(ctx, verbose_flag)
	return ExitCode.OK if PluginExporter.test_package(positional_args[0], refresh_flag, local_flag, reporter) else ExitCode.FAIL

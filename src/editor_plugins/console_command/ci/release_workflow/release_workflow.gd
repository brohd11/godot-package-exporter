extends GDSh.CommandBase

const PluginExporter = preload("res://addons/package_exporter/src/class/plugin_exporter.gd")
const PECommandUtils = preload("res://addons/package_exporter/src/editor_plugins/console_command/command_utils.gd")

const _HELP = \
"Opt a package into CI releases: writes .github/workflows/release.yml at its repo root, calling
PackageExporter's reusable workflow on version tags. Never overwrites an existing file.
A package below its repo's root (a whole-project repo) is refused unless --allow-project-root.
Usage: package_exporter ci release_workflow [--allow-project-root] <plugin_name>"

var allow_project_root_flag := false

static func get_command_name() -> String:
	return "release_workflow"

static func get_self_command_data() -> Dictionary:
	return _command_data({
		&"help": _HELP + PECommandUtils.TARGET_HELP,
		&"positional_count": 1
	})

func _get_completions(ctx:Completion):
	return PECommandUtils.plugin_name_completion(self, ctx, PECommandUtils.TargetAddons.VALID)

func _get_flags() -> Dictionary:
	var options = Options.new()
	options.add_option("--allow-project-root", {
		&"help": "Write at the repo root above the package, with package-dir pointing at it."
	})
	return options.get_options()

func _process_flag(flag:String):
	if flag == "--allow-project-root":
		allow_project_root_flag = true

func _execute(ctx:Context):
	var path = PluginExporter.add_release_workflow(positional_args[0], allow_project_root_flag)
	if path == "":
		ctx.append_error("No workflow written; see Output.")
		return ExitCode.FAIL
	return ExitCode.OK

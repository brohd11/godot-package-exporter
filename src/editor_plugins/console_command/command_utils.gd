
const CommandBase = GDSh.CommandBase
const Completion = CommandBase.Completion

const PluginExporter = preload("res://addons/package_exporter/src/class/plugin_exporter.gd")
const Reporter = preload("res://addons/package_exporter/src/class/export/reporter.gd")
const TargetAddons = PluginExporter.TargetAddons
const TARGET_HELP = "\nTargets are relative to res://addons/ (e.g. _lib/util_r), or absolute res:// / filesystem paths inside this project."

## A Reporter that streams into the console: warnings and errors to stderr, the rest to stdout.
static func console_reporter(ctx, verbose := false) -> Reporter:
	var reporter = Reporter.new()
	reporter.verbose = verbose
	reporter.sink = func(text:String, level:int):
		if level >= Reporter.Level.WARN:
			ctx.append_error(text)
		else:
			ctx.append_output(text)
	return reporter

static func plugin_name_completion(cmd:CommandBase, ctx:Completion,target_addons:=TargetAddons.VALID, target_position:int=0):
	if not _completing_target(cmd, ctx, target_position):
		return {}
	return dir_completion(cmd, ctx, PluginExporter.get_addons_dirs(target_addons), target_position)

static func dir_completion(cmd:CommandBase, ctx:Completion, dirs:Dictionary, target_position:int=0):
	if not _completing_target(cmd, ctx, target_position):
		return {}
	var options = CommandBase.Options.new()
	for d in dirs.keys():
		options.add_option(d)
	return options.get_options()

static func _completing_target(cmd:CommandBase, ctx:Completion, target_position:int) -> bool:
	if not cmd.positional_arg_index in [target_position, target_position - 1]:
		return false
	return not (cmd.positional_arg_index == target_position - 1 and not ctx.char_before_cursor == " ")

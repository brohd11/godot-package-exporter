@tool
extends EditorScript

## Routing rules of the export Reporter and the console sink. Only sinkless calls print to Output,
## so the run prints one "reporter_test:" line - a fixture, not a failure.
##
##     load("res://addons/package_exporter/export_ignore/test/reporter_test.gd").run_tests()

const Reporter = preload("res://addons/package_exporter/src/class/utils_local.gd").Reporter
const Level = Reporter.Level
const PECommandUtils = preload("res://addons/package_exporter/src/editor_plugins/console_command/command_utils.gd")

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_sink_routing()
	_test_verbose()
	_test_dedupe()
	_test_or_default()
	_test_console_sink()

	var output:Array = ["reporter: %d passed, %d failed" % [_passed, _failures.size()]]
	output.append_array(_failures)
	return {"result": _failures.size(), "output": output}


func _run() -> void:
	print("\n".join(run_tests().output))


static func _capture(reporter) -> Array:
	var sent = []
	reporter.sink = func(text:String, level:int): sent.append([level, text])
	return sent


static func _test_sink_routing() -> void:
	var reporter = Reporter.new()
	var sent = _capture(reporter)
	reporter.info("reporter_test: info")
	reporter.note("reporter_test: note")
	reporter.warn("reporter_test: warn")
	reporter.error("reporter_test: error")
	_check("all levels kept", reporter.entries.size(), 4)
	_check("info held back by default", sent.size(), 3)
	_check("note reaches sink", sent[0], [Level.NOTE, "reporter_test: note"])
	_check("warn reaches sink", sent[1], [Level.WARN, "reporter_test: warn"])
	_check("error reaches sink", sent[2], [Level.ERROR, "reporter_test: error"])
	_check("count", [reporter.count(Level.INFO), reporter.count(Level.WARN), reporter.count(Level.ERROR)], [1, 1, 1])
	# No sink: still recorded, nothing to call.
	var bare = Reporter.new()
	bare.error("reporter_test: no sink")
	_check("no sink still records", bare.count(Level.ERROR), 1)


static func _test_verbose() -> void:
	var reporter = Reporter.new()
	reporter.verbose = true
	var sent = _capture(reporter)
	reporter.info("reporter_test: verbose info")
	_check("verbose forwards info", sent, [[Level.INFO, "reporter_test: verbose info"]])


static func _test_dedupe() -> void:
	var reporter = Reporter.new()
	var sent = _capture(reporter)
	for i in 3:
		reporter.warn("reporter_test: repeated")
	reporter.error("reporter_test: repeated")
	reporter.note("reporter_test: note twice")
	reporter.note("reporter_test: note twice")
	_check("repeats all counted", reporter.count(Level.WARN), 3)
	# Dedup is by text across warn/error; notes are never deduped.
	_check("repeat sent once", sent.size(), 3)


static func _test_or_default() -> void:
	var made = Reporter.or_default(null)
	_check("or_default makes one", made != null, true)
	_check("or_default keeps given", Reporter.or_default(made), made)


## Stands in for a gdsh Context: only the two calls the console sink makes.
class FakeContext:
	var stdout:Array = []
	var stderr:Array = []
	func append_output(line:String) -> void: stdout.append(line)
	func append_error(line:String) -> void: stderr.append(line)


static func _test_console_sink() -> void:
	var ctx = FakeContext.new()
	var reporter = PECommandUtils.console_reporter(ctx)
	reporter.info("reporter_test: console info")
	reporter.note("reporter_test: console note")
	reporter.warn("reporter_test: console warn")
	reporter.error("reporter_test: console error")
	_check("console: note to stdout, info held back", ctx.stdout, ["reporter_test: console note"])
	_check("console: warn styled, error plain", ctx.stderr, [
		"[color=#fedd66]Warning: reporter_test: console warn[/color]", "reporter_test: console error"])


static func _check(label:String, actual, expected) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failures.append("FAIL %s: expected %s, got %s" % [label, expected, actual])

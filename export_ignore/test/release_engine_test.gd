@tool
extends EditorScript
## Release exports refuse an engine older than the sources need, before the import can drop classes.

const ReleaseExport = preload("res://addons/package_exporter/src/class/release/release_export.gd")
const TestCI = preload("res://addons/package_exporter/src/class/release/test_ci.gd")
const Reporter = ReleaseExport.Reporter
const MISSING = "res://addons/__pe_missing_package"

const ENGINE_46 = {"major": 4, "minor": 6, "patch": 3, "string": "4.6.3.stable.mono.official"}
const FINDINGS = [
	{"feature": "Node.old_api", "version": "4.5", "location": "addons/lib/a.gd:3"},
	{"feature": "Foo.new_api", "version": "4.7", "location": "addons/lib/b.gd:9"},
]


static func run_tests() -> Dictionary:
	var failures:Array[String] = []
	_expect(failures, "same minor", ReleaseExport.engine_check("4.6", FINDINGS, ENGINE_46) == "")
	_expect(failures, "older minor", ReleaseExport.engine_check("4.5", FINDINGS, ENGINE_46) == "")
	_expect(failures, "unparseable", ReleaseExport.engine_check("", FINDINGS, ENGINE_46) == "")
	var err = ReleaseExport.engine_check("4.7", FINDINGS, ENGINE_46)
	_expect(failures, "newer minor errors: " + err, err.contains("need Godot 4.7") and err.contains("Foo.new_api at addons/lib/b.gd:9") and err.contains("4.6.3"))
	var major = ReleaseExport.engine_check("5.0", [], ENGINE_46)
	_expect(failures, "newer major errors: " + major, major.contains("need Godot 5.0"))
	_expect(failures, "4.10 above 4.9", ReleaseExport.engine_check("4.10", [], {"major": 4, "minor": 9}) != "")
	_test_reporting(failures)

	var output:Array[String] = ["release_engine: %d failed" % failures.size()]
	output.append_array(failures)
	return {"result": failures.size(), "output": output}


## Both fail before any fetch on a missing package, so this runs offline. The caller's reporter gets
## the failure live and the result line after it.
static func _test_reporting(failures:Array[String]) -> void:
	var cases = {
		"release": func(r): return ReleaseExport.export_release(MISSING, false, false, r),
		"test ci": func(r): return TestCI.test_package(MISSING, false, false, "", r),
	}
	for label in cases:
		var reporter = Reporter.new()
		var sent = []
		reporter.sink = func(text:String, level:int): sent.append(level)
		var ok = cases[label].call(reporter)
		_expect(failures, label + " fails", ok == false)
		_expect(failures, label + " error reported", reporter.count(Reporter.Level.ERROR) == 1)
		_expect(failures, label + " sink gets error then result", sent == [Reporter.Level.ERROR, Reporter.Level.NOTE])


static func _expect(failures:Array[String], label:String, ok:bool) -> void:
	if not ok:
		failures.append("FAIL " + label)

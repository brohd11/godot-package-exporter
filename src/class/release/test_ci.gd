@tool
extends RefCounted
## Test CI: a package as it is on disk, uncommitted changes included, tested against its requires at
## their tags in a throwaway workspace like a release export's. Passing means the declared requires
## are enough for its tests, which this project, with every package checked out, can't tell you.

const ReleaseExport = preload("res://addons/package_exporter/src/class/release/release_export.gd")
const DepResolver = ReleaseExport.DepResolver
const RepoCache = ReleaseExport.RepoCache
const ReleaseWorkspace = ReleaseExport.ReleaseWorkspace
const ReleaseRunner = ReleaseExport.ReleaseRunner
const Toolchain = ReleaseExport.Toolchain
const ReleaseCache = ReleaseExport.ReleaseCache
const PackageFetcher = ReleaseExport.PackageFetcher
const ExportFileUtils = ReleaseExport.ExportFileUtils
const ExportPaths = ReleaseExport.ExportPaths
const ExportIgnore = ExportFileUtils.ExportIgnore
const Reporter = ReleaseExport.Reporter

const TEST_DIR = "test"
const SKIP_PREFIX = "SKIP:"

## The running test_package call's reporter; null between calls, see ReleaseExport.reporter.
static var reporter: Reporter
## TestRunner's report from the last run that got as far as the suites, else {}.
static var report:Dictionary = {}


## `local` fetches deps checked out in this project from those checkouts, still by tag. `tree_dir`
## is the checkout to test when it isn't at the package's install path, as when CI tests
## package_exporter with a released one already installed there.
static func test_package(plugin_name:String, refresh:bool = false, local:bool = false, tree_dir:String = "", _reporter = null) -> bool:
	reporter = Reporter.or_default(_reporter)
	report = {}
	var started = Time.get_ticks_msec()
	var ok = _test_package(plugin_name, refresh, local, tree_dir)
	var seconds = (Time.get_ticks_msec() - started) / 1000.0
	var suites = ""
	if not report.get("suites", []).is_empty():
		suites = ", %d/%d suites passed" % [report.suites.size() - report.failed, report.suites.size()]
	if ok:
		reporter.note("'%s' [color=25c225]tests passed against its requires[/color] (%.1fs%s)" % [plugin_name, seconds, suites])
	else:
		reporter.note("'%s' [color=b20f0f]test CI failed[/color] (%.1fs%s)" % [plugin_name, seconds, suites])
	reporter = null
	return ok


static func _test_package(plugin_name:String, refresh:bool, local:bool, tree_dir:String) -> bool:
	var dev_dir = ExportPaths.resolve_target(plugin_name) # the install path
	if dev_dir == "":
		return _fail("Invalid package target (expected a path inside this project): " + plugin_name)
	var tree = tree_dir if tree_dir != "" else dev_dir
	if ExportIgnore.dir_in(tree) == "" or not DirAccess.dir_exists_absolute(ExportIgnore.dir_in(tree).path_join(TEST_DIR)):
		return _fail("%s has no %s" % [tree, " or ".join(ExportIgnore.NAMES.map(func(n): return n.path_join(TEST_DIR)))])
	var url = DepResolver.origin_url(tree)
	if url == "":
		return _fail("%s has no origin remote; it names the package, so deps requiring it resolve to it" % tree)

	reporter.info("Test CI: resolving %s's requires" % plugin_name)
	var cache = RepoCache.new("", refresh)
	var fetcher = PackageFetcher.new(cache, ReleaseCache.new(cache.root, refresh))
	var dev_repos = DepResolver.scan_dev_repos()
	dev_repos[DepResolver.repo_id_from_url(url)] = tree
	var overrides = {}
	if local:
		for id in dev_repos:
			var local_url = "file://" + ProjectSettings.globalize_path(dev_repos[id])
			overrides[id] = local_url
			cache.local_urls[local_url] = true
	var resolver = DepResolver.new(fetcher, dev_repos, overrides)
	var lock = resolver.resolve_tree(url, tree, dev_dir)
	if lock.is_empty():
		for e in resolver.errors:
			_note("  " + e)
		return false
	ReleaseExport._print_lock(lock, reporter)

	var options = {}
	var config_path = ExportIgnore.config_path(tree)
	if FileAccess.file_exists(config_path):
		var config = ExportFileUtils.get_export_data(config_path, reporter)
		if config is Dictionary:
			options = config.get("options", {})
	var toolchain = ""
	if lock.target.path != ReleaseWorkspace.TOOLCHAIN_PATH:
		var tc = Toolchain.new()
		var info = tc.resolve(options, cache.root, local, refresh, ReleaseExport._local_toolchain_dir() if local else "")
		if info.is_empty():
			for e in tc.errors:
				_note("  " + e)
			return false
		toolchain = info.dir
		lock.toolchain = {"version": info.version, "source": info.source, "id": info.id}
		reporter.info("  toolchain %s %s (%s)" % [Toolchain.NAME, info.version, info.source])
	lock.godot = Engine.get_version_info().string

	var workspace = ReleaseWorkspace.new(fetcher)
	var debug_section = ReleaseRunner.project_section(FileAccess.get_file_as_string("res://project.godot"), "debug")
	var ws = workspace.build_tests(lock, dev_dir, toolchain, tree, debug_section)
	if ws == "":
		for e in workspace.errors:
			_note("  " + e)
		return false
	var engine_err = ReleaseExport.engine_error(ws, reporter)
	if engine_err != "":
		return _fail(engine_err)

	var target_dir = ws.path_join(String(lock.target.path).trim_prefix("res://"))
	var test_dir = ExportIgnore.dir_in(target_dir).path_join(TEST_DIR)
	var test_res = "res://" + test_dir.trim_prefix(ws.trim_suffix("/") + "/")
	reporter.info("Test CI: running %s in %s" % [test_res, ws])
	var run = ReleaseRunner.run_tests(ws, test_res)
	var script_errors = runtime_errors(run.output)
	if run.result.is_empty() or not run.result.has("report"):
		var errs = ReleaseRunner.script_errors(run.output)
		if errs.is_empty() and script_errors.is_empty():
			_note(run.output.right(4000))
		for e in (errs + script_errors).slice(0, 12):
			_note("  " + e)
		return _fail("tests did not run to the end (exit %d): %s" % [run.exit, run.result.get("error", "see output above")])

	report = run.result.report
	var ok = _print_report(report, test_dir)
	# A runtime error ends only the function it hits, so a suite can still report a pass after one.
	if not script_errors.is_empty():
		for e in script_errors.slice(0, 12):
			_note("  " + e)
		return _fail("%d script error(s) while testing" % script_errors.size())
	if not ok:
		# no suites already said why
		return false if report.suites.is_empty() else _fail("%d suite(s) failed" % report.failed)
	return true


## PASS/FAIL per suite, full output only for failures. A pass still shows its "SKIP:" lines, so a
## suite that skipped part of itself (a missing optional backend) doesn't read as fully run.
## Passes are INFO; failures, skips and invalid suites always show.
static func _print_report(rep:Dictionary, test_dir:String) -> bool:
	for suite in rep.suites:
		var label = String(suite.path).trim_prefix("res://")
		var lines = []
		for line in suite.output:
			var text = str(line).strip_edges()
			if not suite.passed or text.begins_with(SKIP_PREFIX):
				lines.append("      " + (text if suite.passed else str(line)))
		var header = "  [%s] %s" % ["PASS" if suite.passed else "FAIL", label]
		if suite.passed and lines.is_empty():
			reporter.info(header)
			continue
		reporter.note(_escape(header))
		for line in lines:
			reporter.note(_escape(line))
	for path in rep.invalid:
		reporter.note(_escape("  [----] %s (no run/run_test/run_tests)" % String(path).trim_prefix("res://")))
	if rep.suites.is_empty():
		_note("  no *_test.gd suites in " + test_dir)
		return false
	return rep.failed == 0


## Suite output is arbitrary text and notes are BBCode: "[PASS]" or a "[b]" in a report must print as-is.
static func _escape(text:String) -> String:
	return text.replace("[", "[lb]")


## Runtime "SCRIPT ERROR" lines, each with its "at:" line. Parse errors are ReleaseRunner.script_errors.
static func runtime_errors(output:String) -> Array[String]:
	var lines = output.split("\n")
	var out:Array[String] = []
	for i in lines.size():
		var line = lines[i].strip_edges()
		if not line.begins_with("SCRIPT ERROR:") or "Parse Error" in line or "Compile Error" in line:
			continue
		if i + 1 < lines.size() and lines[i + 1].strip_edges().begins_with("at:"):
			line += "  " + lines[i + 1].strip_edges()
		if not line in out:
			out.append(line)
	return out


static func _fail(message:String) -> bool:
	_note("Test CI: " + message)
	return false


static func _note(line:String) -> void:
	reporter.error(line)

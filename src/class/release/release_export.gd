@tool
extends RefCounted
## Release export: resolves the target's deps to pinned tags, exports from a workspace built out of
## those tags instead of the dev tree, then proves the output compiles on its own. The workspace
## export (PluginExporterStatic.export_by_name) is untouched - this is the build with go.work off.

const UtilsLocal = preload("res://addons/package_exporter/src/class/utils_local.gd")
const UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd")
const ExportFileUtils = UtilsLocal.ExportFileUtils
const ExportPaths = ExportFileUtils.ExportPaths
const Reporter = UtilsLocal.Reporter

const DepResolver = preload("res://addons/package_exporter/src/class/release/dep_resolver.gd")
const RepoCache = preload("res://addons/package_exporter/src/class/release/repo_cache.gd")
const ReleaseWorkspace = preload("res://addons/package_exporter/src/class/release/release_workspace.gd")
const ReleaseRunner = preload("res://addons/package_exporter/src/class/release/release_runner.gd")
const CompileCheck = preload("res://addons/package_exporter/src/class/release/compile_check.gd")
const Toolchain = preload("res://addons/package_exporter/src/class/release/toolchain.gd")
const ReleaseCache = preload("res://addons/package_exporter/src/class/release/release_cache.gd")
const PackageFetcher = preload("res://addons/package_exporter/src/class/release/package_fetcher.gd")
const VersionScanner = preload("res://addons/package_exporter/src/editor_plugins/console_command/min_version/version_scanner.gd")
const VersionApi = VersionScanner.VersionApi

const LOCK_FILE = ".export_lock.json"
const GIT_DETAILS_FILE = ".export_git_details"
const UNVERIFIED_SUFFIX = "-unverified"
const TOOLCHAIN_SCRIPTS = "res://addons/package_exporter/src/class/"

## The running export_release call's reporter (the caller's, so a console can sink it live). Null
## between calls: kept past one, its sink would live until static teardown and crash the exit.
static var reporter: Reporter
## Zips the last successful export_release produced, for callers that publish them (release_cli.gd).
static var zips:Array[String] = []


## `local` fetches every repo checked out in this project from that checkout rather than its
## remote - still by tag, so nothing uncommitted gets in, but nothing has to be pushed either.
## `tree_dir` is the checkout to read cfg, config and origin from when it isn't at the install path,
## as when CI releases package_exporter with a released one installed there.
static func export_release(plugin_name:String, refresh:bool = false, local:bool = false, _reporter = null, tree_dir:String = "") -> bool:
	reporter = Reporter.or_default(_reporter)
	zips.clear()
	var started = Time.get_ticks_msec()
	var ok = _export_release(plugin_name, refresh, local, tree_dir)
	var seconds = (Time.get_ticks_msec() - started) / 1000.0
	if ok:
		reporter.note("'%s' [color=25c225]release exported and verified[/color] (%.1fs)" % [plugin_name, seconds])
	else:
		reporter.note("'%s' [color=b20f0f]release export failed[/color] (%.1fs)" % [plugin_name, seconds])
	reporter = null
	return ok


static func _export_release(plugin_name:String, refresh:bool, local:bool, tree_dir:String) -> bool:
	var dev_dir = ExportPaths.resolve_target(plugin_name) # the install path
	if dev_dir == "":
		return _fail("Invalid package target (expected a path inside this project): " + plugin_name)
	var tree = tree_dir if tree_dir != "" else dev_dir
	var config_path = ExportFileUtils.get_export_config_path(plugin_name, reporter) if tree_dir == "" \
		else ExportFileUtils.ExportIgnore.config_path(tree)
	if not FileAccess.file_exists(config_path):
		return _fail("no export config at " + config_path)
	var version = _cfg_version(tree)
	if version == "":
		return _fail("no version= in %s package cfg" % tree)
	var url = DepResolver.origin_url(tree)
	if url == "":
		return _fail("%s has no origin remote; release exports fetch the target by tag from it" % tree)

	reporter.info("Release export: resolving %s %s" % [plugin_name, version])
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
	var lock = resolver.resolve(url, version, dev_dir)
	if lock.is_empty():
		for e in resolver.errors:
			_note("  " + e)
		return false
	if local:
		lock.local = true
		_warn_unpushed(lock, dev_repos)

	var config = ExportFileUtils.get_export_data(config_path, reporter)
	if not config is Dictionary:
		return false
	var options = config.get("options", {})
	_print_lock(lock, reporter)
	_warn_unexported_peers(config)

	# Recorded in the lock before the workspace is keyed on it, so a new toolchain gets a new one.
	var toolchain = ""
	if lock.target.path != ReleaseWorkspace.TOOLCHAIN_PATH:
		var tc = Toolchain.new()
		var info = tc.resolve(options, cache.root, local, refresh, _local_toolchain_dir() if local else "")
		if info.is_empty():
			for e in tc.errors:
				_note("  " + e)
			return false
		toolchain = info.dir
		lock.toolchain = {"version": info.version, "source": info.source, "id": info.id}
		reporter.info("  toolchain %s %s (%s)" % [Toolchain.NAME, info.version, info.source])
	# Also keys the workspace: its .godot import cache belongs to one engine.
	lock.godot = Engine.get_version_info().string

	var workspace = ReleaseWorkspace.new(fetcher)
	var debug_section = ReleaseRunner.project_section(FileAccess.get_file_as_string("res://project.godot"), "debug")
	var export_root = ProjectSettings.globalize_path(config.get("export_root", ""))
	var ws = workspace.build(lock, dev_dir, toolchain, export_root, debug_section)
	if ws == "":
		for e in workspace.errors:
			_note("  " + e)
		return false
	var engine_err = engine_error(ws, reporter)
	if engine_err != "":
		return _fail(engine_err)

	reporter.info("Release export: exporting in " + ws)
	var target_dir = ws.path_join(String(lock.target.path).trim_prefix("res://"))
	var workspace_config = ExportFileUtils.ExportIgnore.config_path(target_dir)
	var config_resource = "res://" + workspace_config.trim_prefix(ws.trim_suffix("/") + "/")
	var run = ReleaseRunner.run_export(ws, config_resource)
	if lock.has("toolchain"):
		var broken = ReleaseRunner.script_errors(run.output).filter(func(e): return TOOLCHAIN_SCRIPTS in e)
		if not broken.is_empty():
			for e in broken.slice(0, 8):
				_note("  " + e)
			return _fail("toolchain %s %s (%s) export scripts don't compile" % [
				Toolchain.NAME, lock.toolchain.version, lock.toolchain.source])
	if run.result.is_empty() or not run.result.get("ok", false):
		var errs = ReleaseRunner.script_errors(run.output)
		if errs.is_empty():
			_note(run.output.right(4000))
		for e in errs.slice(0, 12):
			_note("  " + e)
		return _fail("export in workspace failed (exit %d): %s" % [run.exit, run.result.get("error", "see output above")])

	var full_export_path:String = run.result.full_export_path
	for e in run.result.exports:
		_finalize_export_dir(e.dir, lock)
	var written = _rezip(full_export_path)

	reporter.info("Release export: verifying")
	# compile_require deps (and what they need) sit beside the export, as they would when installed.
	var verify_installs = {}
	for entry in lock.deps:
		if entry.get("verify", false):
			verify_installs[entry.path] = ws.path_join(entry.path.trim_prefix("res://"))
	var failures:Array[String] = []
	for exported in run.result.exports:
		var plugin_dir = String(exported.dir).trim_suffix("/")
		var label = plugin_dir.trim_prefix(full_export_path.trim_suffix("/") + "/")
		for b in CompileCheck.broken_references(plugin_dir, exported.install_path):
			failures.append("%s: missing reference %s" % [label, b])
		var parse_skipped = CompileCheck.parse_skipped(plugin_dir)
		if not parse_skipped.is_empty():
			reporter.info("  %s: compile check skips %d pe-skip-parse file(s): %s" % [label, parse_skipped.size(), ", ".join(parse_skipped)])
		var work_dir = cache.root.path_join("verify").path_join(label.replace("/", "_"))
		var errs = CompileCheck.compile_errors(plugin_dir, exported.install_path, work_dir, verify_installs)
		for e in errs:
			failures.append("%s: %s" % [label, e])
		if errs.is_empty():
			ReleaseRunner.remove_dir(work_dir)
		else:
			_note("  compile check project kept at " + work_dir)

	if not failures.is_empty():
		for f in failures:
			_note("  " + f)
		_mark_unverified(full_export_path)
		return _fail("output does not compile on its own; moved to *%s" % UNVERIFIED_SUFFIX)
	zips = written
	return true


## Scans the workspace's sources (target and deps, not the toolchain) against the API index before
## its Godot run: an older engine fails to parse newer syntax on import and drops those classes
## quietly. Returns why this engine can't, or "".
static func engine_error(ws:String, _reporter = null) -> String:
	var out = Reporter.or_default(_reporter)
	var scanner = VersionScanner.new()
	scanner.load_scripts = false
	if not scanner.api.has_index():
		out.warn("no min_version API index; skipping the engine check")
		return ""
	var search = UtilsRemote.GetFiles.open(ws)
	search.file_extensions = ["gd", "tscn", "tres"]
	search.ignore_dir_paths = [ws.path_join(ReleaseWorkspace.TOOLCHAIN_PATH.trim_prefix("res://"))]
	search.ignore_dir_names = ExportFileUtils.ExportIgnore.NAMES
	var scan = scanner.scan_files(search.get_files())
	for f in scan.findings:
		f.location = String(f.location).trim_prefix(ws.trim_suffix("/") + "/")
	var err = engine_check(scan.min_version, scan.findings, Engine.get_version_info())
	if err == "":
		out.info("  sources need Godot %s" % scan.min_version)
	return err


## "" when `engine` (Engine.get_version_info()) runs code needing `min_version`, else why not, citing
## the first finding at that version. An unparseable min_version passes - the index can't judge it.
static func engine_check(min_version:String, findings:Array, engine:Dictionary) -> String:
	var need = VersionApi.version_code(min_version)
	if need < 0 or need <= int(engine.major) * 1000 + int(engine.minor):
		return ""
	var where = ""
	for f in findings:
		if f.version == min_version:
			where = " (%s at %s)" % [f.feature, f.location]
			break
	return "sources need Godot %s%s, but this export runs on %s; set godot-version in .github/workflows/release.yml, or export from a newer editor" % [
		min_version, where, engine.get("string", "%d.%d" % [engine.major, engine.minor])]


## Where this project exports package_exporter, for --local toolchains. Computed with the export
## pipeline (it resolves {{version}} templates), so it stays here rather than in Toolchain.
static func _local_toolchain_dir() -> String:
	var config_path = ExportFileUtils.get_export_config_path(Toolchain.NAME, reporter)
	if not FileAccess.file_exists(config_path):
		return ""
	var data = ExportFileUtils.get_export_data(config_path, reporter)
	if not data is Dictionary or data.get("exports", []).is_empty():
		return ""
	var entry = data.exports[0]
	var full = ExportFileUtils.get_full_export_path(data.export_root, data.plugin_folder, config_path, reporter)
	var package = full.path_join(ExportFileUtils.get_export_name(entry, data.plugin_folder, config_path, reporter))
	return package.path_join(ExportFileUtils.get_export_folder(entry, config_path)).trim_suffix("/")


## Swaps the dev-tree git snapshot for the lock. The released plugin.cfg is left alone: its
## require/deps are install-time, gdaddon's, and the build graph never came from them.
static func _finalize_export_dir(dir:String, lock:Dictionary) -> void:
	DirAccess.remove_absolute(dir.path_join(GIT_DETAILS_FILE))
	var file = FileAccess.open(dir.path_join(LOCK_FILE), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(lock, "\t"))
		file.close()


## Same packaging as PluginExporterStatic.export_plugin, redone because finalizing changed files.
static func _rezip(full_export_path:String) -> Array[String]:
	var written:Array[String] = []
	for dir in DirAccess.get_directories_at(full_export_path):
		var dir_path = full_export_path.path_join(dir)
		var search = UtilsRemote.GetFiles.open(dir_path)
		search.show_hidden = true
		search.enter_gdignore = true
		ExportFileUtils.write_zip_file(dir_path + ".zip", search.get_files())
		written.append(dir_path + ".zip")
	return written


## Keeps a failed release around for inspection, under a name nobody would ship by accident.
static func _mark_unverified(full_export_path:String) -> void:
	var src = full_export_path.trim_suffix("/")
	var dest = src + UNVERIFIED_SUFFIX
	if DirAccess.dir_exists_absolute(dest):
		ReleaseRunner.remove_dir(dest)
	DirAccess.rename_absolute(src, dest)


static func _cfg_version(dir:String) -> String:
	return str(DepResolver.PackageCfg.dir_value(dir, "version", ""))


static func _print_lock(lock:Dictionary, out) -> void:
	for entry in [lock.target] + lock.deps:
		var role = "target" if entry == lock.target else ("test" if entry.get("test", false) \
				else ("compile" if entry.get("verify", false) else "bundled"))
		var fetched = entry.get("kind", "source")
		if entry.get("asset", "") != "":
			fetched += " " + entry.asset
		out.info("  %-8s %-6s %s %s [%s] (%s) -> %s" % [role, entry.get("source", ""), entry.repo_id, entry.tag,
			fetched, entry.sha.substr(0, 7), entry.path])


## A compile_require dep is installed beside the export for verification, not bundled, so an
## installer has to add it too: it belongs in exported_require.
static func _warn_unexported_peers(config:Dictionary) -> void:
	var exported = {}
	var listed = config.get(ExportFileUtils.KeysConfig.EXPORTED_REQUIRE, config.get("options", {}).get(ExportFileUtils.KeysConfig.Options.EXPORTED_DEPS, []))
	for spec in (listed if listed is Array else [listed]):
		var dep = DepResolver.parse_dep(str(spec))
		if dep != null:
			exported[dep.repo_id] = true
	var compile = config.get(DepResolver.COMPILE_KEY, [])
	for spec in (compile if compile is Array else [compile]):
		var dep = DepResolver.parse_dep(str(spec))
		if dep != null and not exported.has(dep.repo_id):
			reporter.warn("Release export: %s is a compile_require but not in exported_require; installs of this release won't get it" % dep.repo_id)


## A local build is fine to try, but one others can't reproduce shouldn't pass silently - nor should
## a repo that quietly came from its remote when you expected your checkout.
static func _warn_unpushed(lock:Dictionary, dev_repos:Dictionary) -> void:
	for entry in [lock.target] + lock.deps:
		if entry.get("kind") == "release":
			reporter.warn("Release export: %s %s is a release asset (%s), fetched from GitHub" % [entry.repo_id, entry.tag, entry.asset])
			continue
		if entry.get("source") != "local":
			reporter.warn("Release export: %s %s has no local checkout with a matching origin; fetched from its remote" % [entry.repo_id, entry.tag])
			continue
		var output = []
		var dir = ProjectSettings.globalize_path(dev_repos[entry.repo_id])
		var code = OS.execute("git", ["-C", dir, "ls-remote", "--tags", "origin", "refs/tags/" + entry.tag], output)
		if code != 0:
			reporter.warn("Release export: couldn't check origin for %s %s" % [entry.repo_id, entry.tag])
		elif "".join(output).strip_edges() == "":
			reporter.warn("Release export: %s %s is not on origin yet" % [entry.repo_id, entry.tag])


static func _fail(message:String) -> bool:
	_note("Release export: " + message)
	return false


static func _note(line:String) -> void:
	reporter.error(line)

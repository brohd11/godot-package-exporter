@tool
extends EditorScript

## Tests for the release export's dependency resolver: spec parsing with /source and /release,
## build_require / compile_require read from export configs, tag ordering, MVS selection, verify
## flags, and packages located inside whole projects or release zips. Repos are a fake fetcher (git
## trees and single-asset releases), so no git or network.
##
##     load("res://addons/package_exporter/export_ignore/test/dep_resolver_test.gd").run_tests()

const DepResolver = preload("res://addons/package_exporter/src/class/release/dep_resolver.gd")
const ReleaseCache = preload("res://addons/package_exporter/src/class/release/release_cache.gd")

const EX = "export_ignore/plugin_export.yml"

static var _failures:Array[String] = []
static var _passed:int = 0


class FakeFetcher:
	var repos:Dictionary = {} # url -> {tag: {path: text}}, git trees
	var releases:Dictionary = {} # url -> {tag: {path: text}}, contents of a release's picked asset
	var assets:Dictionary = {} # "url@tag" -> uploaded asset names; picked with the real auto_asset
	var last_error:String = ""
	var asked_patterns:Array = [] # every non-empty asset pattern lookup() was given

	func add(spec:String, tag:String, files:Dictionary) -> String:
		return _put(repos, "https://github.com/" + spec, tag, files)

	func add_release(spec:String, tag:String, files:Dictionary, names:Array = ["pkg.zip"]) -> String:
		assets["https://github.com/%s@%s" % [spec, tag]] = names
		return _put(releases, "https://github.com/" + spec, tag, files)

	func _put(store:Dictionary, url:String, tag:String, files:Dictionary) -> String:
		if not store.has(url):
			store[url] = {}
		store[url][tag] = files
		return url

	func lookup(url:String, tag:String, kind:String, canonical:String, pattern:String = "") -> Dictionary:
		if pattern != "":
			asked_patterns.append(pattern)
		if kind == "release":
			if releases.has(canonical) and releases[canonical].has(tag):
				var uploads = assets.get("%s@%s" % [canonical, tag], []).map(func(n): return {"name": n})
				var pick = ReleaseCache.auto_asset({"tag_name": tag, "assets": uploads}, pattern)
				if pick.has("error"):
					last_error = pick.error
					return {}
				return {"kind": "release", "url": canonical, "tag": tag, "id": ("r" + canonical + tag).sha1_text(), "asset": pick.name}
			last_error = "no release asset at " + tag
			return {}
		if repos.has(url) and repos[url].has(tag):
			return {"kind": "source", "url": url, "tag": tag, "id": (url + tag).sha1_text(), "asset": ""}
		return {}

	func files(info:Dictionary) -> Array:
		return _tree(info).keys()

	func read_file(info:Dictionary, path:String):
		return _tree(info).get(path)

	func _tree(info:Dictionary) -> Dictionary:
		return (releases if info.kind == "release" else repos)[info.url][info.tag]


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_parse_dep()
	_test_export_config()
	_test_repo_id()
	_test_compare_tags()
	_test_mvs()
	_test_major_lines()
	_test_tag_v_toggle()
	_test_failures()
	_test_cycle()
	_test_local_override()
	_test_cfg_require_default()
	_test_cfg_require_ref()
	_test_addon_cfg()
	_test_verify()
	_test_kinds()
	_test_library_from_source()
	_test_resolve_tree()
	_test_test_require()
	_test_asset_pin()
	_test_target_layout()
	_test_export_ignore_names()

	var output:Array[String] = []
	output.append("dep_resolver: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_parse_dep() -> void:
	var d = DepResolver.parse_dep("Brohd11/Godot-Addon-Lib@v2.1.0")
	_check("short form host", d.host, "github.com")
	_check("short form id lowercased", d.repo_id, "github.com/brohd11/godot-addon-lib")
	_check("short form tag", d.tag, "v2.1.0")
	_check("short form url keeps case", d.repo_url, "https://github.com/Brohd11/Godot-Addon-Lib")
	_check("plain is source", d.kind, "source")

	var h = DepResolver.parse_dep("gitlab.com/o/r@1.0")
	_check("host form", [h.host, h.owner, h.repo, h.tag, h.kind], ["gitlab.com", "o", "r", "1.0", "source"])
	var s = DepResolver.parse_dep("brohd11/godot-yaml-parser/source@v2.1.0")
	_check("source marker", [s.kind, s.repo_id, s.tag], ["source", "github.com/brohd11/godot-yaml-parser", "v2.1.0"])
	_check("source with a slash before @", DepResolver.parse_dep("o/r/source/@v1").kind, "source")
	var rel = DepResolver.parse_dep("brohd11/godot-yaml-parser/release@v2.1.0")
	_check("release marker", [rel.kind, rel.repo_id, rel.tag], ["release", "github.com/brohd11/godot-yaml-parser", "v2.1.0"])
	var hs = DepResolver.parse_dep("gitlab.com/o/r/source@1")
	_check("host and source", [hs.host, hs.repo, hs.kind], ["gitlab.com", "r", "source"])
	_check("tagless", DepResolver.parse_dep("o/r").tag, "")
	var c = DepResolver.parse_dep("clone:brohd11/godot-util-r@v0.2.0")
	_check("gdaddon clone: prefix dropped", [c.repo_id, c.tag, c.kind], ["github.com/brohd11/godot-util-r", "v0.2.0", "source"])
	var pinned = DepResolver.parse_dep("brohd11/godot-gdscript-lsp/release@v0.2.1:gdscript-lsp-*.zip")
	_check("asset pin", [pinned.kind, pinned.tag, pinned.asset, pinned.repo_id], ["release", "v0.2.1", "gdscript-lsp-*.zip", "github.com/brohd11/godot-gdscript-lsp"])
	_check("no pin, no asset", DepResolver.parse_dep("o/r/release@v1").asset, "")
	_check("asset pin needs /release", [DepResolver.parse_dep("o/r@v1:x.zip"), DepResolver.parse_dep("o/r/source@v1:x.zip")], [null, null])
	_check("empty pin rejected", DepResolver.parse_dep("o/r/release@v1:"), null)
	_check("pin without a tag rejected", DepResolver.parse_dep("o/r/release:x.zip"), null)
	_check("one part rejected", DepResolver.parse_dep("justone@v1"), null)
	_check("three parts without a dotted host or marker rejected", DepResolver.parse_dep("a/b/c@v1"), null)
	_check("four parts rejected", DepResolver.parse_dep("a/b/c/d@v1"), null)
	_check("/clone rejected", [DepResolver.parse_dep("o/r/clone@main"), DepResolver.parse_dep("o/r/clone")], [null, null])


static func _test_export_config() -> void:
	var yml = DepResolver.requires_in_export_config(
		'export_root: "x"\nbuild_require:\n  - "a/b@v1"\n  - "bad"\ncompile_require: "c/d/release@v2"\n', "yml")
	_check("yaml: no error", yml.error, "")
	_check("yaml: list and single string", yml.requires.map(func(r): return [r.dep.repo_id, r.compile, r.dep.kind]),
		[["github.com/a/b", false, "source"], ["github.com/c/d", true, "release"]])
	var json = DepResolver.requires_in_export_config('{"build_require": ["a/b@v1"], "options": {}}', "json")
	_check("json", json.requires.map(func(r): return r.dep.repo_id), ["github.com/a/b"])
	_check("json: invalid is an error", DepResolver.requires_in_export_config("{nope", "json").error != "", true)
	_check("no keys, no requirements", DepResolver.requires_in_export_config("options:\n  overwrite: true\n", "yml").requires.size(), 0)

	var one_line = '[plugin]\nname="x"\nrequire=["a/b@v1", "c/d@v2"]\n'
	var multi = '[plugin]\nversion="1"\nrequire=[\n"a/b@v1",\n"c/d@v2",\n]\n\n[namespace]\npath="_ns"\n'
	var alone = DepResolver.requires_in_export_config('build_require: "@require"\n', "yml", one_line)
	_check("@require: single string, one-line cfg", [alone.error, alone.requires.map(func(r): return r.dep.repo_id)],
		["", ["github.com/a/b", "github.com/c/d"]])
	var mixed = DepResolver.requires_in_export_config(_ex(["e/f@v1", "@require"]), "yml", multi)
	_check("@require: mixed, multi-line cfg with trailing comma", [mixed.error, mixed.requires.map(func(r): return r.dep.repo_id)],
		["", ["github.com/e/f", "github.com/a/b", "github.com/c/d"]])
	var no_key = DepResolver.requires_in_export_config(_ex(["@require"]), "yml", '[plugin]\nname="x"\n')
	_check("@require: cfg without require is empty, not an error", [no_key.error, no_key.requires.size()], ["", 0])
	_check("@require: no cfg is an error", DepResolver.requires_in_export_config(_ex(["@require"]), "yml").error != "", true)
	_check("@require: compile_require is an error", DepResolver.requires_in_export_config(_ex([], ["@require"]), "yml", one_line).error != "", true)
	var clone = DepResolver.requires_in_export_config(_ex(["@require"]), "yml", '[plugin]\nrequire=["a/b@v1", "c/d/clone@main"]\n')
	_check("/clone in a cfg is one error, other specs kept", [clone.error.count("/clone is install-only"), clone.requires.map(func(r): return r.dep.repo_id)],
		[1, ["github.com/a/b"]])
	_check("cfg_require: [addon] list wins", DepResolver.cfg_require('[plugin]\nrequire=["a/b@v1"]\n[addon]\nrequire=[\n"c/d@v1",\n]\n'), ["c/d@v1"])
	_check("cfg_require: [plugin] list when [addon] has none", DepResolver.cfg_require('[addon]\nname="x"\n[plugin]\nrequire=["a/b@v1"]\n'), ["a/b@v1"])
	_check("cfg_require: other section ignored", DepResolver.cfg_require('[deps]\nrequire=["a/b@v1"]\n[plugin]\nname="x"\n').size(), 0)


static func _test_repo_id() -> void:
	_check("www and .git stripped", DepResolver.repo_id_from_url("https://www.github.com/Brohd11/X.git"), "github.com/brohd11/x")
	_check("scp remote", DepResolver.repo_id_from_url("git@github.com:o/R.git"), "github.com/o/r")
	_check("file url", DepResolver.repo_id_from_url("file:///tmp/a/o/r.git"), "local/o/r")
	_check("garbage", DepResolver.repo_id_from_url("nope"), "")


static func _test_compare_tags() -> void:
	_check("numeric not lexical", DepResolver.compare_tags("v1.0.10", "v1.0.9"), 1)
	_check("missing parts are zero", DepResolver.compare_tags("1.0", "v1.0.0"), 0)
	_check("pre-release suffix ignored", DepResolver.compare_tags("v1.2.0-beta", "1.2.0"), 0)
	_check("older", DepResolver.compare_tags("v0.9", "v1"), -1)
	_check("date is incomparable", DepResolver.compare_tags("2024-01-02", "v1"), DepResolver.TAGS_INCOMPARABLE)


## T requires A@1.0 and B@1.0; B requires A@1.2. A@1.2 needs C, while only A@1.0 needs D - so A
## resolves to 1.2, C is in, and D is pruned with the version that asked for it.
static func _test_mvs() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1.0.0", {"plugin.cfg": '[plugin]\nversion="1.0.0"\n', EX: _ex(["me/a@v1.0.0", "me/b@v1.0.0"])})
	f.add("me/a", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/lib/a"\n', EX: _ex(["me/d@v1"])})
	f.add("me/a", "v1.2.0", {"version.cfg": '[plugin]\npath="addons/lib/a"\n', EX: _ex(["me/c@v1"])})
	f.add("me/b", "v1.0.0", {"plugin.cfg": '[plugin]\npath="addons/b"\n', EX: _ex(["me/a@v1.2.0", "me/t@v1.0.0"])})
	f.add("me/c", "v1", {"project.godot": "", "addons/c/plugin.cfg": '[plugin]\nurl="https://github.com/me/c"\n'})
	f.add("me/d", "v1", {"plugin.cfg": '[plugin]\npath="addons/d"\n'})

	var r = DepResolver.new(f)
	var lock = r.resolve(t, "1.0.0", "res://addons/t")
	_check("mvs: no errors " + str(r.errors), r.errors.is_empty(), true)
	if lock.is_empty():
		return
	var got = {}
	for e in lock.deps:
		got[e.repo_id] = [e.tag, e.path, e.verify]
	_check("mvs: selection", got, {
		"github.com/me/a": ["v1.2.0", "res://addons/lib/a", false],
		"github.com/me/b": ["v1.0.0", "res://addons/b", false],
		"github.com/me/c": ["v1", "res://addons/c", false],
	})
	_check("mvs: whole-project package", _dep(lock, "github.com/me/c").package, "addons/c")
	_check("mvs: target tag", lock.target.tag, "v1.0.0")
	_check("mvs: target root cfg needs no path=", lock.target.path, "res://addons/t")
	_check("mvs: remote source", lock.target.source, "remote")
	_check("mvs: sha recorded", lock.target.sha != "", true)
	_check("mvs: hash stable", DepResolver.lock_hash(lock), DepResolver.lock_hash(lock.duplicate(true)))


## Go-style lines: v0 and v1 are one line, so 0.x -> 0.y and 0.x -> 1.x are plain upgrades, while
## 1.x -> 2.x fails naming both sides - unless the requirement came from an outvoted version.
static func _test_major_lines() -> void:
	_check("major_line: v0 joins v1", [DepResolver.major_line("v0.3"), DepResolver.major_line("1.9.0")], [1, 1])
	_check("major_line: later majors", DepResolver.major_line("v2.0.0-beta"), 2)
	_check("major_line: not a version", DepResolver.major_line("2024-01-02"), -1)

	for case in [["v0.1.0", "v0.9.0", true], ["v0.4.0", "v1.2.0", true], ["v1.2.0", "v2.0.0", false]]:
		var f = FakeFetcher.new()
		var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/u@" + case[0], "me/l@v1"])})
		f.add("me/l", "v1", {"version.cfg": '[plugin]\npath="addons/l"\n', EX: _ex(["me/u@" + case[1]])})
		f.add("me/u", case[0], {"version.cfg": '[plugin]\npath="addons/u"\n'})
		f.add("me/u", case[1], {"version.cfg": '[plugin]\npath="addons/u"\n'})
		var r = DepResolver.new(f)
		var lock = r.resolve(t, "v1", "res://addons/t")
		var label = "major %s -> %s" % [case[0], case[1]]
		if case[2]:
			_check(label + ": resolved " + str(r.errors), lock.is_empty(), false)
			_check(label + ": higher picked", _dep(lock, "github.com/me/u").get("tag"), case[1])
		else:
			_check(label + ": empty lock", lock, {})
			var err = r.errors[0] if r.errors.size() == 1 else str(r.errors)
			_check(label + ": names requirer, both lines and the winning chain " + err,
				"github.com/me/t@v1 needs v0/v1 (v1.2.0), but v2.0.0 is selected via github.com/me/t -> github.com/me/l -> github.com/me/u" in err, true)

	# a@v1.0.0 asks for u@v1 but loses to a@v1.2.0, whose u@v2 is the only live requirement.
	var f2 = FakeFetcher.new()
	var t2 = f2.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/a@v1.0.0", "me/b@v1"])})
	f2.add("me/a", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/a"\n', EX: _ex(["me/u@v1.0.0"])})
	f2.add("me/a", "v1.2.0", {"version.cfg": '[plugin]\npath="addons/a"\n', EX: _ex(["me/u@v2.0.0"])})
	f2.add("me/b", "v1", {"version.cfg": '[plugin]\npath="addons/b"\n', EX: _ex(["me/a@v1.2.0"])})
	f2.add("me/u", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/u"\n'})
	f2.add("me/u", "v2.0.0", {"version.cfg": '[plugin]\npath="addons/u"\n'})
	var r2 = DepResolver.new(f2)
	var lock2 = r2.resolve(t2, "v1", "res://addons/t")
	_check("major: outvoted requirement ignored " + str(r2.errors), lock2.is_empty(), false)
	_check("major: outvoted selection", _dep(lock2, "github.com/me/u").get("tag"), "v2.0.0")


static func _test_tag_v_toggle() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "1.0.0", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/a@1.0.0"])})
	f.add("me/a", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/a"\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "1.0.0", "res://addons/t")
	_check("v toggle: resolved " + str(r.errors), lock.is_empty(), false)
	if not lock.is_empty():
		_check("v toggle: dep tag is the real tag", lock.deps[0].tag, "v1.0.0")


static func _test_failures() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1.0.0", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/a@v1.0.0", "me/untagged"])})
	f.add("me/a", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/a"\n'})
	var r = DepResolver.new(f)
	_check("untagged: empty lock", r.resolve(t, "1.0.0", "res://addons/t"), {})
	_check("untagged: chain in error " + str(r.errors),
		r.errors.size() == 1 and "github.com/me/t -> github.com/me/untagged" in r.errors[0], true)

	var f2 = FakeFetcher.new()
	var t2 = f2.add("me/t", "v1.0.0", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/a@v9"])})
	f2.add("me/a", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/a"\n'})
	var r2 = DepResolver.new(f2)
	_check("missing tag: empty lock", r2.resolve(t2, "1.0.0", "res://addons/t"), {})
	_check("missing tag: named " + str(r2.errors), r2.errors.size() == 1 and "no usable tag v9" in r2.errors[0], true)

	var r3 = DepResolver.new(f2)
	_check("untagged target version", r3.resolve(t2, "2.0.0", "res://addons/t"), {})
	_check("untagged target: named", r3.errors.size() == 1 and "no tag for version 2.0.0" in r3.errors[0], true)

	var f4 = FakeFetcher.new()
	var t4 = f4.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/a@v1", "me/p@v1", "me/bad@v1"])})
	f4.add("me/a", "v1", {"README.md": ""})
	f4.add("me/p", "v1", {"plugin.cfg": '[plugin]\nname="p"\n'})
	f4.add("me/bad", "v1", {"plugin.cfg": '[plugin]\npath="addons/bad"\n', "export_ignore/plugin_export.json": "{nope"})
	var r4 = DepResolver.new(f4)
	_check("unplaceable: empty lock", r4.resolve(t4, "v1", "res://addons/t"), {})
	var joined = "\n".join(r4.errors)
	_check("unplaceable: no cfg named " + joined, "github.com/me/a@v1: no plugin.cfg" in joined, true)
	_check("unplaceable: root cfg without path= named", "github.com/me/p@v1: cfg at the package root but no path=" in joined, true)
	_check("invalid dep config named", "github.com/me/bad@v1: export_ignore/plugin_export.json: invalid JSON" in joined, true)

	var f5 = FakeFetcher.new()
	var t5 = f5.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', "export_ignore/plugin_export.json": "{nope"})
	var r5 = DepResolver.new(f5)
	_check("invalid target config: empty lock", r5.resolve(t5, "v1", "res://addons/t"), {})
	_check("invalid target config: named " + str(r5.errors), r5.errors.size() == 1 and "invalid JSON" in r5.errors[0], true)


static func _test_cycle() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/a@v1"])})
	f.add("me/a", "v1", {"version.cfg": '[plugin]\npath="addons/a"\n', EX: _ex(["me/b@v1"])})
	f.add("me/b", "v1", {"version.cfg": '[plugin]\npath="addons/b"\n', EX: _ex(["me/a@v1"])})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("cycle: terminates with both " + str(r.errors), lock.get("deps", []).size(), 2)


## --local: target and dep are fetched through override urls, but ids stay canonical - so a dep's
## requirement back on the target is still recognized as the target and skipped.
static func _test_local_override() -> void:
	var f = FakeFetcher.new()
	f.repos["file:///dev/addons/t"] = {"v1": {"plugin.cfg": '[plugin]\n', EX: _ex(["me/a@v1"])}}
	f.repos["file:///dev/addons/a"] = {"v1": {"version.cfg": '[plugin]\npath="addons/a"\n', EX: _ex(["me/t@v1"])}}
	var r = DepResolver.new(f, {}, {
		"github.com/me/t": "file:///dev/addons/t",
		"github.com/me/a": "file:///dev/addons/a",
	})
	var lock = r.resolve("https://github.com/me/t", "v1", "res://addons/t")
	_check("local: resolved " + str(r.errors), lock.is_empty(), false)
	if lock.is_empty():
		return
	_check("local: target id canonical", lock.target.repo_id, "github.com/me/t")
	_check("local: target fetched locally", [lock.target.url, lock.target.source], ["file:///dev/addons/t", "local"])
	_check("local: self requirement skipped", lock.deps.map(func(e): return e.repo_id), ["github.com/me/a"])
	_check("local: dep source", lock.deps[0].source, "local")


## plugin.cfg `require` is gdaddon's install list: the exporter never follows it, and a package
## without an export config declares nothing.
static func _test_cfg_require_default() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\nrequire=["me/ext@v1"]\n', EX: _ex(["me/lib@v1"])})
	# lib has no export config: its cfg require is the default, so me/other comes too.
	f.add("me/lib", "v1", {"plugin.cfg": '[plugin]\npath="addons/lib"\nrequire=["me/other@v1"]\n'})
	f.add("me/other", "v1", {"plugin.cfg": '[plugin]\npath="addons/other"\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("explicit build_require: resolved " + str(r.errors), lock.is_empty(), false)
	_check("explicit build_require replaces the cfg list; a config-less dep brings its own", lock.get("deps", []).map(func(e): return e.repo_id),
		["github.com/me/lib", "github.com/me/other"])

	var bare = f.add("me/bare", "v1", {"plugin.cfg": '[plugin]\nrequire=["me/lib@v1"]\n'})
	_check("no export config: cfg require", DepResolver.new(f).resolve(bare, "v1", "res://addons/bare").get("deps", []).map(func(e): return e.repo_id),
		["github.com/me/lib", "github.com/me/other"])
	var keyless = f.add("me/keyless", "v1", {"plugin.cfg": '[plugin]\nrequire=["me/other@v1"]\n', EX: 'export_root: "res://exports"\n'})
	_check("no build_require key: cfg require", DepResolver.new(f).resolve(keyless, "v1", "res://addons/keyless").get("deps", []).map(func(e): return e.repo_id),
		["github.com/me/other"])
	var none = f.add("me/none", "v1", {"plugin.cfg": '[plugin]\nrequire=["me/other@v1"]\n', EX: _ex([])})
	_check("build_require: [] means none", DepResolver.new(f).resolve(none, "v1", "res://addons/none").get("deps"), [])
	f.add_release("me/sealed", "v1", {"addons/sealed/plugin.cfg": '[plugin]\npath="addons/sealed"\nrequire=["me/missing@v1"]\n'})
	var uses_release = f.add("me/ur", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/sealed/release@v1"])})
	r = DepResolver.new(f)
	r.resolve(f.add("me/miss", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/sealed/release@v2"])}), "v1", "res://addons/miss")
	_check("the written tag's error is the one reported " + str(r.errors), "at v2)" in "".join(r.errors) and not "at 2)" in "".join(r.errors), true)
	r = DepResolver.new(f)
	_check("a release asset stays sealed " + str(r.errors), r.resolve(uses_release, "v1", "res://addons/ur").get("deps", []).map(func(e): return e.repo_id),
		["github.com/me/sealed"])


## `@require` follows the package's own cfg list at the fetched tag. A dep whose config lists
## build_require explicitly isn't followed into its cfg - me/other is never added, so that would fail.
static func _test_cfg_require_ref() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\nrequire=[\n"me/lib@v1",\n]\n', EX: _ex(["@require"])})
	f.add("me/lib", "v1", {"plugin.cfg": '[plugin]\npath="addons/lib"\nrequire=["me/other@v1"]\n', EX: _ex(["me/dep@v1"])})
	f.add("me/dep", "v1", {"plugin.cfg": '[plugin]\npath="addons/dep"\nrequire=["me/other@v1"]\n', EX: _ex([])})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("@require: resolved " + str(r.errors), lock.is_empty(), false)
	_check("@require: cfg list followed, explicit lists win", lock.get("deps", []).map(func(e): return e.repo_id),
		["github.com/me/dep", "github.com/me/lib"])


## addon.cfg is a package cfg too, and its [addon] keys win over [plugin]'s.
static func _test_addon_cfg() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\nrequire=["me/x@v1"]\n[addon]\nrequire=["me/a@v1"]\n', EX: _ex(["@require"])})
	f.add("me/a", "v1", {"addon.cfg": '[plugin]\npath="addons/wrong"\n[addon]\npath="addons/a"\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("addon.cfg: resolved " + str(r.errors), lock.is_empty(), false)
	if not lock.is_empty():
		_check("addon.cfg: [addon] require followed", lock.deps.map(func(e): return e.repo_id), ["github.com/me/a"])
		_check("addon.cfg: [addon] path= wins", lock.deps[0].path, "res://addons/a")


## compile_require marks its target for the compile check, and everything that target needs comes
## too. A repo in both keys is compile; a compile dep of a bundled dep is still compile.
static func _test_verify() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/lib@v1", "me/both@v1"], ["me/ext@v1", "me/both@v1"])})
	f.add("me/lib", "v1", {"plugin.cfg": '[plugin]\npath="addons/lib"\n', EX: _ex([], ["me/ext2@v1"])})
	f.add("me/ext", "v1", {"plugin.cfg": '[plugin]\npath="addons/ext"\n', EX: _ex(["me/extdep@v1"])})
	f.add("me/ext2", "v1", {"plugin.cfg": '[plugin]\npath="addons/ext2"\n'})
	f.add("me/extdep", "v1", {"plugin.cfg": '[plugin]\npath="addons/extdep"\n'})
	f.add("me/both", "v1", {"plugin.cfg": '[plugin]\npath="addons/both"\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("verify: resolved " + str(r.errors), lock.is_empty(), false)
	var got = {}
	for e in lock.get("deps", []):
		got[e.repo_id.trim_prefix("github.com/me/")] = e.verify
	_check("verify: flags", got, {"both": true, "ext": true, "ext2": true, "extdep": true, "lib": false})


## Plain builds from the tree even when a release exists, so the tree's own requirements join the
## selection; /release takes the sealed asset (declaring nothing) and fails without one. The same
## repo can't be asked for both ways.
static func _test_kinds() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/y@v2"])})
	f.add("me/y", "v2", {"project.godot": "", "addons/lib/y/version.cfg": '[plugin]\nurl="https://github.com/me/y"\n',
		"addons/lib/y/" + EX: _ex(["me/z@v1"])})
	f.add_release("me/y", "v2", {"y-2/lib/y/version.cfg": '[plugin]\nurl="https://github.com/me/y"\n', "y-2/lib/y/y.gd": ""})
	f.add("me/z", "v1", {"plugin.cfg": '[plugin]\npath="addons/z"\n'})

	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("plain: resolved " + str(r.errors), lock.is_empty(), false)
	if not lock.is_empty():
		var y = _dep(lock, "github.com/me/y")
		_check("plain: tree despite a release", [y.kind, y.asset, y.package, y.path], ["source", "", "addons/lib/y", "res://addons/lib/y"])
		_check("plain: nested export config followed", _dep(lock, "github.com/me/z").is_empty(), false)

	var t2 = f.add("me/t2", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/y/release@v2"])})
	var r2 = DepResolver.new(f)
	var lock2 = r2.resolve(t2, "v1", "res://addons/t2")
	_check("release: resolved " + str(r2.errors), lock2.is_empty(), false)
	if not lock2.is_empty():
		var y2 = _dep(lock2, "github.com/me/y")
		_check("release: entry", [y2.kind, y2.asset, y2.package, y2.path], ["release", "pkg.zip", "y-2/lib/y", "res://addons/lib/y"])
		_check("release: declares nothing", _dep(lock2, "github.com/me/z").is_empty(), true)

	var t3 = f.add("me/t3", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/z/release@v1"])})
	var r3 = DepResolver.new(f)
	_check("release without asset: empty lock", r3.resolve(t3, "v1", "res://addons/t3"), {})
	_check("release without asset: named " + str(r3.errors), r3.errors.size() == 1 and "no usable tag v1 (no release asset at v1)" in r3.errors[0], true)

	var t4 = f.add("me/t4", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/y/release@v2", "me/w@v1"])})
	f.add("me/w", "v1", {"plugin.cfg": '[plugin]\npath="addons/w"\n', EX: _ex(["me/y@v2"])})
	var r4 = DepResolver.new(f)
	_check("kind conflict: empty lock", r4.resolve(t4, "v1", "res://addons/t4"), {})
	_check("kind conflict: named " + str(r4.errors), r4.errors.size() == 1 and "required as both release and source" in r4.errors[0], true)


## The library case the build model is for: L@v1's source asks for U@v1.0, the target asks for
## U@v1.2 - both build against one U at v1.2, from source, with no release asset in the lock even
## though L publishes one with its own U bundled.
static func _test_library_from_source() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/l@v1.0.0", "me/u@v1.2.0"])})
	f.add("me/l", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/_lib/l"\n', "_export_ignore/plugin_export.yml": _ex(["me/u@v1.0.0"])})
	f.add_release("me/l", "v1.0.0", {"addons/_lib/l/version.cfg": '[plugin]\npath="addons/_lib/l"\n', "addons/_lib/l/src/remote/u.gd": ""})
	f.add("me/u", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/_lib/u"\n'})
	f.add("me/u", "v1.2.0", {"version.cfg": '[plugin]\npath="addons/_lib/u"\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("library: resolved " + str(r.errors), lock.is_empty(), false)
	_check("library: one U at the highest minimum, all source", lock.get("deps", []).map(func(e): return [e.repo_id, e.tag, e.kind]),
		[["github.com/me/l", "v1.0.0", "source"], ["github.com/me/u", "v1.2.0", "source"]])


## Test CI: the target's requires come from its working tree, not a tag; deps resolve as usual.
static func _test_resolve_tree() -> void:
	var dir = ProjectSettings.globalize_path("user://pe_resolve_tree_test")
	DirAccess.make_dir_recursive_absolute(dir.path_join(EX).get_base_dir())
	FileAccess.open(dir.path_join("version.cfg"), FileAccess.WRITE).store_string('[plugin]\npath="addons/_lib/t"\n')
	FileAccess.open(dir.path_join(EX), FileAccess.WRITE).store_string(_ex(["me/l@v1.0.0", "me/u@v1.2.0"]))
	var f = FakeFetcher.new()
	# The tagged target asks for an older U: the tree must win, and the target needs no tag at all.
	var t = f.add("me/t", "v1", {"version.cfg": '[plugin]\n', EX: _ex(["me/u@v1.0.0"])})
	f.add("me/l", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/_lib/l"\n', EX: _ex(["me/u@v1.1.0", "me/t@v1"])})
	f.add("me/u", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/_lib/u"\n'})
	f.add("me/u", "v1.1.0", {"version.cfg": '[plugin]\npath="addons/_lib/u"\n'})
	f.add("me/u", "v1.2.0", {"version.cfg": '[plugin]\npath="addons/_lib/u"\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve_tree(t, dir, "res://addons/_lib/t")
	_check("tree: resolved " + str(r.errors), lock.is_empty(), false)
	_check("tree: target from the tree", [lock.get("target", {}).get("tag"), lock.get("target", {}).get("source"), lock.get("target", {}).get("path")],
		[DepResolver.TREE_TAG, "tree", "res://addons/_lib/t"])
	_check("tree: deps from the tree's requires, MVS as usual", lock.get("deps", []).map(func(e): return [e.repo_id, e.tag]),
		[["github.com/me/l", "v1.0.0"], ["github.com/me/u", "v1.2.0"]])

	FileAccess.open(dir.path_join(EX), FileAccess.WRITE).store_string(_ex(["me/u@v1.0.0", "me/l@v1.0.0", "me/x@v2.0.0"]))
	f.add("me/x", "v2.0.0", {"version.cfg": '[plugin]\npath="addons/_lib/x"\n', EX: _ex(["me/u@v2.0.0"])})
	f.add("me/u", "v2.0.0", {"version.cfg": '[plugin]\npath="addons/_lib/u"\n'})
	r = DepResolver.new(f)
	_check("tree: major lines still checked", r.resolve_tree(t, dir, "res://addons/_lib/t").is_empty() and "major line" in "".join(r.errors), true)

	DirAccess.remove_absolute(dir.path_join(EX))
	r = DepResolver.new(f)
	lock = r.resolve_tree(t, dir, "res://addons/_lib/t")
	_check("tree: no export config, no deps " + str(r.errors), lock.get("deps", null), [])
	DirAccess.remove_absolute(dir.path_join(EX).get_base_dir())
	DirAccess.remove_absolute(dir.path_join("version.cfg"))
	r = DepResolver.new(f)
	_check("tree: no package cfg refused", r.resolve_tree(t, dir, "res://addons/_lib/t").is_empty() and "no " in "".join(r.errors), true)
	DirAccess.remove_absolute(dir)


## test_require counts for test CI's root only: its extras join selection and are marked test.
static func _test_test_require() -> void:
	var dir = ProjectSettings.globalize_path("user://pe_test_require_test")
	DirAccess.make_dir_recursive_absolute(dir.path_join(EX).get_base_dir())
	FileAccess.open(dir.path_join("version.cfg"), FileAccess.WRITE).store_string('[plugin]\npath="addons/t"\nrequire=["me/u@v1.0.0"]\n')
	FileAccess.open(dir.path_join(EX), FileAccess.WRITE).store_string('export_root: "res://exports"\ntest_require:\n  - "@require"\n  - "me/ext/release@v1"\n  - "me/u@v1.1.0"\n')
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"version.cfg": '[plugin]\n'})
	f.add("me/u", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/u"\n'})
	f.add("me/u", "v1.1.0", {"version.cfg": '[plugin]\npath="addons/u"\n'})
	f.add_release("me/ext", "v1", {"addons/ext/plugin.cfg": '[plugin]\npath="addons/ext"\n'})
	# A dep's own test_require is never read: me/never doesn't exist.
	f.add("me/lib", "v1", {"version.cfg": '[plugin]\npath="addons/lib"\n', EX: _ex([]) + 'test_require: ["me/never@v1"]\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve_tree(t, dir, "res://addons/t")
	_check("test_require: resolved " + str(r.errors), lock.is_empty(), false)
	_check("test_require: build deps plus extras, MVS across both", lock.get("deps", []).map(func(e): return [e.repo_id, e.tag, e.get("test", false)]),
		[["github.com/me/ext", "v1", true], ["github.com/me/u", "v1.1.0", false]])

	FileAccess.open(dir.path_join(EX), FileAccess.WRITE).store_string('export_root: "res://exports"\nbuild_require: ["me/lib@v1"]\n')
	r = DepResolver.new(f)
	lock = r.resolve_tree(t, dir, "res://addons/t")
	_check("test_require defaults to @require; deps' test_require ignored " + str(r.errors), lock.get("deps", []).map(func(e): return [e.repo_id, e.get("test", false)]),
		[["github.com/me/lib", false], ["github.com/me/u", true]])
	r = DepResolver.new(f)
	var release_lock = r.resolve(f.add("me/r", "v1", {"version.cfg": '[plugin]\n', EX: 'export_root: "x"\ntest_require: ["me/u@v1.0.0"]\n'}), "v1", "res://addons/r")
	_check("release resolve ignores test_require", release_lock.get("deps", null), [])
	for rel in [EX, "version.cfg"]:
		DirAccess.remove_absolute(dir.path_join(rel))
	DirAccess.remove_absolute(dir.path_join(EX).get_base_dir())
	DirAccess.remove_absolute(dir)


## A /release with several assets needs a `:<glob>`; the glob still works once MVS raises the tag,
## and one repo can't be pinned two ways.
static func _test_asset_pin() -> void:
	var f = FakeFetcher.new()
	var multi = ["lib-v1.0.0-linux.zip", "lib-v1.0.0-macos.zip", "lib-v1.0.0-linux.zip.sha256"]
	f.add_release("me/lib", "v1.0.0", {"addons/lib/plugin.cfg": '[plugin]\npath="addons/lib"\n'}, multi)
	f.add_release("me/lib", "v1.1.0", {"addons/lib/plugin.cfg": '[plugin]\npath="addons/lib"\n'}, ["lib-v1.1.0-linux.zip", "lib-v1.1.0-macos.zip"])
	f.add("me/mid", "v1", {"plugin.cfg": '[plugin]\npath="addons/mid"\n', EX: _ex(["me/lib/release@v1.1.0:*-linux.zip"])})

	var unpinned = f.add("me/a", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/lib/release@v1.0.0"])})
	var r = DepResolver.new(f)
	_check("several assets, no pin: errors with the choices", r.resolve(unpinned, "v1", "res://addons/a").is_empty() and "lib-v1.0.0-macos.zip" in "".join(r.errors), true)

	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/lib/release@v1.0.0:*-linux.zip", "me/mid@v1"])})
	r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("pin: resolved " + str(r.errors), lock.is_empty(), false)
	var lib = _dep(lock, "github.com/me/lib")
	_check("pin: glob holds across the MVS bump", [lib.get("tag"), lib.get("asset"), lib.get("asset_pattern")], ["v1.1.0", "lib-v1.1.0-linux.zip", "*-linux.zip"])
	_check("pin: unpinned entries keep their lock shape", _dep(lock, "github.com/me/mid").has("asset_pattern"), false)
	_check("pin: the fetcher was asked with the pattern", "*-linux.zip" in f.asked_patterns, true)

	var clash = f.add("me/c", "v1", {"plugin.cfg": '[plugin]\n', EX: _ex(["me/lib/release@v1.0.0:*-macos.zip", "me/mid@v1"])})
	r = DepResolver.new(f)
	_check("two pins for one repo: errors with both", r.resolve(clash, "v1", "res://addons/c").is_empty() and "'*-macos.zip' and '*-linux.zip'" in "".join(r.errors), true)


## The target goes through the same placement, and has to land where this project keeps it.
static func _test_target_layout() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"project.godot": "", "addons/other/plugin.cfg": '[plugin]\n'})
	var r = DepResolver.new(f)
	_check("target elsewhere: empty lock", r.resolve(t, "v1", "res://addons/t"), {})
	_check("target elsewhere: named " + str(r.errors), r.errors.size() == 1 and "installs at res://addons/other" in r.errors[0], true)


## Configs are found in _export_ignore/ as well, and it wins over export_ignore/ in the same package.
static func _test_export_ignore_names() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\n', "_export_ignore/plugin_export.yml": _ex(["me/a@v1"]), EX: _ex(["me/b@v1"])})
	f.add("me/a", "v1", {"plugin.cfg": '[plugin]\npath="addons/a"\n', "_export_ignore/plugin_export.json": '{"build_require": ["me/c@v1"]}'})
	f.add("me/b", "v1", {"plugin.cfg": '[plugin]\npath="addons/b"\n'})
	f.add("me/c", "v1", {"plugin.cfg": '[plugin]\npath="addons/c"\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("_export_ignore: resolved " + str(r.errors), lock.is_empty(), false)
	_check("_export_ignore: preferred config followed", lock.get("deps", []).map(func(e): return e.repo_id),
		["github.com/me/a", "github.com/me/c"])
	f.repos[t]["v1"]["_export_ignore/export.yml"] = _ex(["me/b@v1"])
	r = DepResolver.new(f)
	lock = r.resolve(t, "v1", "res://lib/t")
	_check("export.yml outside addons: resolved " + str(r.errors), lock.is_empty(), false)
	_check("export.yml preferred over legacy", lock.get("deps", []).map(func(e): return e.repo_id), ["github.com/me/b"])
	_check("non-addon target retained", lock.get("target", {}).get("path"), "res://lib/t")


## plugin_export.yml text with the given build_require / compile_require lists.
## Explicit even when empty: a missing build_require means @require.
static func _ex(build:Array, compile:Array = []) -> String:
	var text = 'export_root: "res://exports"\n'
	if build.is_empty():
		text += "build_require: []\n"
	else:
		text += "build_require:\n" + "".join(build.map(func(s): return '  - "%s"\n' % s))
	if not compile.is_empty():
		text += "compile_require:\n" + "".join(compile.map(func(s): return '  - "%s"\n' % s))
	return text


static func _dep(lock:Dictionary, id:String) -> Dictionary:
	for e in lock.get("deps", []):
		if e.repo_id == id:
			return e
	return {}


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])

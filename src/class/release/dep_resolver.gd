@tool
extends RefCounted
## Resolves an addon's build dependency graph to pinned tags for a release export. Requirements are
## `build_require` / `compile_require` (and, for test CI's root, `test_require`) in each package's
## export_ignore/plugin_export.*. build_require and test_require default to `@require`, the package
## cfg's `require` list; compile_require defaults to none. Versions are
## picked Go-MVS style: each repo gets the highest tag any reachable requirement names, and a pick
## on another major line than a requirement fails (v0 and v1 share a line, as in Go). Repo access
## goes through `fetcher` (PackageFetcher, or a fake in tests); each package's addon folder and
## install path come from PackageLayout.

const PackageLayout = preload("res://addons/package_exporter/src/class/release/package_layout.gd")
const ExportIgnore = preload("res://addons/package_exporter/src/class/export/export_ignore.gd")
const PackageCfg = preload("res://addons/package_exporter/src/class/export/package_cfg.gd")

const DEFAULT_HOST = "github.com"
const CFG_NAMES = PackageCfg.NAMES
const CONFIG_NAMES = ExportIgnore.CONFIG_NAMES
const BUILD_KEY = "build_require"
const COMPILE_KEY = "compile_require"
const TEST_KEY = "test_require"
const REQUIRE_REF = "@require" # build_require item standing for the package cfg's require list
const TAGS_INCOMPARABLE = -99
const KIND_SOURCE = "source"
const KIND_RELEASE = "release"
const KIND_CLONE = "clone" # gdaddon's install-only checkout marker; never valid in a require
const CLONE_PREFIX = "clone:"
const TREE_TAG = "worktree" # the target's "tag" in resolve_tree: whatever is on disk

class Dep:
	var host:String
	var owner:String
	var repo:String
	var tag:String
	var kind:String = "source"
	var asset:String = "" # a /release spec's `:<glob>` asset pin
	var repo_url:String
	var repo_id:String

var fetcher
var dev_paths:Dictionary = {} # repo_id -> res:// dir of a checkout in this project
var url_overrides:Dictionary = {} # repo_id -> clone url, e.g. a file:// checkout for --local
var errors:Array[String] = []

var _packages:Dictionary = {} # "kind|url|tag" -> {info, src, dest} or {error}
var _cfg_texts:Dictionary = {} # "id|dir" -> cfg text
var _requires_cache:Dictionary = {} # "id|src" -> {requires, error}
var _assets:Dictionary = {} # repo_id -> /release asset glob; one per repo, like its kind


func _init(fetcher_obj, dev_install_paths:Dictionary = {}, overrides:Dictionary = {}) -> void:
	fetcher = fetcher_obj
	dev_paths = dev_install_paths
	url_overrides = overrides


#region Parsing

## `owner/repo[/source|/release][@tag]`, optionally led by a host (`gitlab.com/owner/repo`). A first
## segment only counts as a host when it has a dot - that is what keeps `owner/repo/source` apart
## from gdaddon's `host/owner/repo`. Plain (or /source) is the tag's tree, whose own requirements
## join the selection; /release is its sealed release asset, for packages that can't be rebuilt
## from source (GDExtension, third-party zips). `/release@tag:<glob>` picks the asset when a release
## has several; git forbids `:` in tags, so the split is unambiguous. gdaddon's legacy `clone:` prefix
## is dropped (read as source); its `/clone` is install-only, null here and reported by
## requires_in_data. null for any other shape.
static func parse_dep(item:String) -> Dep:
	item = item.strip_edges().trim_prefix(CLONE_PREFIX)
	var repo_part = item
	var tag = ""
	var asset = ""
	var at = item.rfind("@")
	if at >= 0:
		repo_part = item.substr(0, at)
		tag = item.substr(at + 1).strip_edges()
		var colon = tag.find(":")
		if colon >= 0:
			asset = tag.substr(colon + 1).strip_edges()
			tag = tag.substr(0, colon).strip_edges()
			if asset == "":
				return null
	elif ":" in item:
		return null

	var parts = Array(repo_part.strip_edges().lstrip("/").rstrip("/").split("/"))
	var dep = Dep.new()
	dep.host = DEFAULT_HOST
	if parts.size() >= 3 and "." in parts[0]:
		dep.host = parts.pop_front()
	if parts.size() == 3 and parts[2] in [KIND_SOURCE, KIND_RELEASE]:
		dep.kind = parts[2]
		parts.pop_back()
	if parts.size() != 2 or parts[0] == "" or parts[1] == "":
		return null
	if asset != "" and dep.kind != KIND_RELEASE:
		return null
	dep.asset = asset

	dep.owner = parts[0]
	dep.repo = parts[1]
	dep.tag = tag
	dep.repo_url = "https://%s/%s/%s" % [dep.host, dep.owner, dep.repo]
	dep.repo_id = repo_id_from_url(dep.repo_url)
	return dep


## {requires: [{dep, compile, test}], error} from export config text; see requires_in_data.
static func requires_in_export_config(text:String, ext:String, cfg_text:String = "", with_tests:bool = false) -> Dictionary:
	var data = null
	if ext == "json":
		var json = JSON.new()
		if json.parse(text) != OK:
			return {"requires": [], "error": "invalid JSON: %s (line %d)" % [json.get_error_message(), json.get_error_line()]}
		data = json.data
	else:
		var parser = YAMLParser.new()
		if parser.parse(text) != OK:
			return {"requires": [], "error": "invalid YAML"}
		data = parser.data
	if data == null:
		data = {}
	if not data is Dictionary:
		return {"requires": [], "error": "the top level is not a mapping"}
	return requires_in_data(data, cfg_text, with_tests)


## {requires: [{dep, compile, test}], error} from a parsed export config ({} when the package has
## none). Each key holds a list of specs or a single spec; malformed specs are skipped, except a
## `/clone`, which is an error since it reads as a real requirement. An absent
## build_require / test_require means `@require`, which expands to `cfg_text`'s require list (the
## package's own cfg); an explicit [] means none. A repo under several keys yields an entry per
## key: compile wins for verify flags, and any non-test entry clears the test flag.
static func requires_in_data(data:Dictionary, cfg_text:String, with_tests:bool = false) -> Dictionary:
	var out = []
	var errors = []
	var keys = [BUILD_KEY, COMPILE_KEY] + ([TEST_KEY] if with_tests else [])
	for key in keys:
		var defaulted = not data.has(key)
		var value = data.get(key, [] if key == COMPILE_KEY else REQUIRE_REF)
		var items = value if value is Array else ([value] if value is String and value != "" else [])
		var specs = []
		for item in items:
			if str(item).strip_edges() != REQUIRE_REF:
				specs.append(str(item))
			elif key == COMPILE_KEY:
				errors.append("%s is not valid under %s" % [REQUIRE_REF, COMPILE_KEY])
			elif cfg_text == "":
				if not defaulted:
					errors.append("%s needs the package's cfg (%s)" % [REQUIRE_REF, "/".join(CFG_NAMES)])
			else:
				specs.append_array(cfg_require(cfg_text))
		for spec in specs:
			var dep = parse_dep(spec)
			if dep != null:
				out.append({"dep": dep, "compile": key == COMPILE_KEY, "test": key == TEST_KEY})
			elif _is_clone_spec(spec):
				var msg = "%s: /clone is install-only (gdaddon install); require the tag instead" % spec.strip_edges()
				if not msg in errors: # @require expands into build and test alike
					errors.append(msg)
	return {"requires": out, "error": "; ".join(errors)}


static func _is_clone_spec(spec:String) -> bool:
	return spec.strip_edges().get_slice("@", 0).rstrip("/").get_file() == KIND_CLONE


## Specs in the package cfg's `require` array, as gdaddon writes it: one line or several, with a
## trailing comma allowed. [addon]'s list wins over [plugin]'s, as in PackageCfg.section(), which
## can't read it - the array is collected up to its closing bracket.
static func cfg_require(cfg_text:String) -> Array[String]:
	var arrays = {} # section -> raw array text
	var current = ""
	var collecting = false
	for line in cfg_text.split("\n"):
		var stripped = line.strip_edges()
		if collecting:
			if not stripped.begins_with(";"):
				arrays[current] += "\n" + stripped
		elif stripped.begins_with("["):
			current = stripped.trim_prefix("[").trim_suffix("]").strip_edges()
			continue
		elif current in PackageCfg.SECTIONS and "=" in stripped and stripped.get_slice("=", 0).strip_edges() == "require":
			collecting = true
			arrays[current] = stripped.substr(stripped.find("=") + 1)
		if collecting and "]" in arrays[current]:
			collecting = false
	var array_text = ""
	for section in PackageCfg.SECTIONS:
		if arrays.has(section):
			array_text = arrays[section]
			break
	var out:Array[String] = []
	for m in RegEx.create_from_string('"([^"]*)"').search_all(array_text):
		if m.get_string(1).strip_edges() != "":
			out.append(m.get_string(1).strip_edges())
	return out


static func unquote(value:String) -> String:
	if value.length() >= 2 and value[0] in ["\"", "'"] and value[-1] == value[0]:
		return value.substr(1, value.length() - 2)
	return value


## `host/owner/repo`, lowercased, `www.` and `.git` dropped - gdaddon's source.RepoID. scp-style
## remotes are accepted; a file:// url has no host, so it is keyed under `local/`.
static func repo_id_from_url(url:String) -> String:
	url = url.strip_edges()
	var host = ""
	var path = ""
	if url.begins_with("file://"):
		host = "local"
		path = url.trim_prefix("file://")
	elif "://" in url:
		var rest = url.get_slice("://", 1)
		host = rest.get_slice("/", 0)
		path = rest.substr(host.length())
	elif "@" in url and ":" in url:
		host = url.get_slice("@", 1).get_slice(":", 0)
		path = url.get_slice(":", 1)
	else:
		return ""
	host = host.get_slice("@", host.get_slice_count("@") - 1).trim_prefix("www.")

	var parts = Array(path.lstrip("/").rstrip("/").split("/", false))
	if parts.size() < 2:
		return ""
	if host == "local":
		parts = parts.slice(parts.size() - 2) # keep it short; the full path is still the clone url
	return ("%s/%s/%s" % [host, parts[0], String(parts[1]).trim_suffix(".git")]).to_lower()

#endregion


#region Versions

## Dotted numeric parts with a leading v and -pre/+build suffix dropped, or [] when not a version.
## The suffix is only stripped after a dot, so a date like 2024-01-02 stays incomparable.
static func version_parts(v:String) -> Array[int]:
	var out:Array[int] = []
	v = v.strip_edges().trim_prefix("v").trim_prefix("V")
	var cut = -1
	for i in v.length():
		if v[i] in ["-", "+"]:
			cut = i
			break
	if cut >= 0 and "." in v.substr(0, cut):
		v = v.substr(0, cut)
	if v == "":
		return out
	for p in v.split("."):
		p = p.strip_edges()
		if not p.is_valid_int():
			return [] as Array[int]
		out.append(p.to_int())
	return out


## 1 / 0 / -1, or TAGS_INCOMPARABLE when either side isn't a version. Missing parts count as 0.
static func compare_tags(a:String, b:String) -> int:
	var na = version_parts(a)
	var nb = version_parts(b)
	if na.is_empty() or nb.is_empty():
		return TAGS_INCOMPARABLE
	for i in maxi(na.size(), nb.size()):
		var x = na[i] if i < na.size() else 0
		var y = nb[i] if i < nb.size() else 0
		if x != y:
			return 1 if x > y else -1
	return 0


## Go's compatibility line: v0 and v1 share one, each later major is its own. -1 when not a version.
static func major_line(tag:String) -> int:
	var parts = version_parts(tag)
	return -1 if parts.is_empty() else maxi(parts[0], 1)

#endregion


#region Resolve

## Lock for a target at `version`: {target: Entry, deps: [Entry]}, deps sorted by repo_id, where
## Entry = {repo_id, url, tag, sha, kind, asset, package, path, source, verify}. Returns {} and
## fills `errors` on any failure - a partial lock would silently export whatever the dev tree had.
## `target_url` must be the canonical origin: ids come from it, so deps naming the target still
## match it even when url_overrides fetches it from somewhere else. The target is always source.
func resolve(target_url:String, version:String, target_path:String) -> Dictionary:
	errors.clear()
	_packages.clear()
	_requires_cache.clear()
	_assets.clear()
	var root_id = repo_id_from_url(target_url)
	var root_url = url_overrides.get(root_id, target_url)
	var root_tag = _find_tag(root_url, version, KIND_SOURCE, target_url)
	if root_tag == "":
		_error("%s: no tag for version %s (tried %s)%s" % [root_id, version, ", ".join(tag_candidates(version)), _fetch_note()])
		return {}
	var root_pkg = _package(root_id, root_url, root_tag, KIND_SOURCE, target_url, target_path)
	if root_pkg.has("error"):
		_error("%s@%s: %s" % [root_id, root_tag, root_pkg.error])
		return {}
	if root_pkg.dest != target_path:
		_error("%s@%s: its addon installs at %s, but this project has it at %s" % [root_id, root_tag, root_pkg.dest, target_path])
		return {}
	var root = [root_id, root_url, root_tag, KIND_SOURCE, target_url]
	var root_requires = _requires(root, target_path)
	if root_requires.error != "":
		_error("%s@%s: %s" % [root_id, root_tag, root_requires.error])
		return {}
	var deps = _resolve_deps(root, target_path)
	if deps == null:
		return {}
	return {"target": _entry(root_id, root_pkg, false), "deps": deps}


## Lock for the target as it is on disk at `tree_dir`, uncommitted changes included, against its
## requires at their tags: what test CI runs. Deps resolve exactly as in resolve(). The target
## entry has tag TREE_TAG, source "tree" and no sha; the caller knows the checkout's HEAD.
func resolve_tree(target_url:String, tree_dir:String, target_path:String) -> Dictionary:
	errors.clear()
	_packages.clear()
	_requires_cache.clear()
	_assets.clear()
	var root_id = repo_id_from_url(target_url)
	var cfg_text = ""
	for nm in CFG_NAMES:
		if FileAccess.file_exists(tree_dir.path_join(nm)):
			cfg_text = FileAccess.get_file_as_string(tree_dir.path_join(nm))
			break
	if cfg_text == "":
		_error("%s: no %s in %s" % [root_id, " / ".join(CFG_NAMES), tree_dir])
		return {}
	var requires = requires_in_data({}, cfg_text, true)
	for path in ExportIgnore.candidates(tree_dir, CONFIG_NAMES):
		if FileAccess.file_exists(path):
			requires = requires_in_export_config(FileAccess.get_file_as_string(path), path.get_extension(), cfg_text, true)
			break
	if requires.error != "":
		_error("%s: %s" % [tree_dir, requires.error])
		return {}

	# Seeded so _explore/_prune treat the tree like any fetched root.
	var info = {"id": "", "url": target_url, "tag": TREE_TAG, "kind": KIND_SOURCE}
	var root_pkg = {"info": info, "src": "", "dest": target_path}
	_packages["%s|%s|%s|" % [KIND_SOURCE, target_url, TREE_TAG]] = root_pkg
	_requires_cache["|"] = requires
	var deps = _resolve_deps([root_id, target_url, TREE_TAG, KIND_SOURCE, target_url], target_path)
	if deps == null:
		return {}
	var target = _entry(root_id, root_pkg, false)
	target.source = "tree"
	return {"target": target, "deps": deps}


## Sorted dep entries for a root whose own package is already known, or null with `errors` filled.
func _resolve_deps(root:Array, target_path:String):
	var required = _explore(root, target_path)
	if not errors.is_empty():
		return null
	var pruned = _prune(root, target_path, required)
	if not errors.is_empty():
		return null

	var deps = []
	for id in pruned.selected:
		var sel = pruned.selected[id]
		var pkg = _package(id, sel.url, sel.tag, sel.kind, sel.canonical)
		if pkg.has("error"):
			_error("%s@%s: %s (%s)" % [id, sel.tag, pkg.error, sel.chain])
			continue
		var reqs = _requires([id, sel.url, sel.tag, sel.kind, sel.canonical], "")
		if reqs.error != "":
			_error("%s@%s: %s (%s)" % [id, sel.tag, reqs.error, sel.chain])
			continue
		var entry = _entry(id, pkg, pruned.verify.has(id))
		if pruned.test_only.has(id):
			entry.test = true # only test CI's lock has these; release locks (and hashes) never do
		deps.append(entry)
	if not errors.is_empty():
		return null
	deps.sort_custom(func(a, b): return a.repo_id < b.repo_id)
	return deps


## Walks every version any reachable config names, recording the highest per repo. Versions that
## lose still get walked: in MVS their requirements count toward the minimums too.
## A node is [id, url, tag, kind, canonical url].
func _explore(root:Array, root_path:String) -> Dictionary:
	var required = {} # repo_id -> {url, tag, kind, canonical, chain}
	var visited = {}
	var queue = [root + [root[0]]]
	while not queue.is_empty():
		var node = queue.pop_front()
		var key = "%s|%s@%s" % [node[3], node[0], node[2]]
		if visited.has(key):
			continue
		visited[key] = true

		for req in _requires(node, root_path if node[0] == root[0] else "").requires:
			var dep:Dep = req.dep
			if dep.repo_id == root[0]:
				continue
			var chain = "%s -> %s" % [node[5], dep.repo_id]
			if dep.tag == "":
				_error("untagged requirement (release exports need @tag): " + chain)
				continue
			var current = required.get(dep.repo_id)
			if current != null and current.kind != dep.kind:
				_error("%s is required as both %s and %s: %s; %s" % [dep.repo_id, current.kind, dep.kind, current.chain, chain])
				continue
			if current != null and current.asset != dep.asset:
				_error("%s is required with assets '%s' and '%s': %s; %s" % [dep.repo_id, current.asset, dep.asset, current.chain, chain])
				continue
			_assets[dep.repo_id] = dep.asset
			var url = url_overrides.get(dep.repo_id, dep.repo_url)
			var tag = _find_tag(url, dep.tag, dep.kind, dep.repo_url, dep.asset)
			if tag == "":
				_error("no usable tag %s%s: %s" % [dep.tag, _fetch_note(), chain])
				continue

			var entry = {"url": url, "tag": tag, "kind": dep.kind, "canonical": dep.repo_url, "chain": chain, "asset": dep.asset}
			if current == null:
				required[dep.repo_id] = entry
			else:
				var cmp = compare_tags(tag, current.tag)
				if cmp == TAGS_INCOMPARABLE and tag != current.tag:
					_error("can't order tags %s and %s of %s: %s" % [tag, current.tag, dep.repo_id, chain])
				elif cmp > 0:
					required[dep.repo_id] = entry
			queue.append([dep.repo_id, url, tag, dep.kind, dep.repo_url, chain])
	return required


## {selected, verify, test_only}: the repos reachable when every repo is taken at its selected tag
## (so a requirement only an outvoted version made isn't bundled), which of them the compile check
## needs, and which only test_require reaches. A compile_require marks its target, and everything
## that target needs is needed too. Major lines are checked here for the same reason: an outvoted
## version's requirements don't ship.
func _prune(root:Array, root_path:String, required:Dictionary) -> Dictionary:
	var selected = {}
	var edges = [] # [from id, to id, compile, test]
	var stack = [root]
	while not stack.is_empty():
		var node = stack.pop_back()
		for req in _requires(node, root_path if node[0] == root[0] else "").requires:
			var dep:Dep = req.dep
			if dep.repo_id == root[0] or not required.has(dep.repo_id):
				continue
			edges.append([node[0], dep.repo_id, req.compile, req.get("test", false)])
			var sel = required[dep.repo_id]
			_check_major_line(node, dep, sel)
			if selected.has(dep.repo_id):
				continue
			selected[dep.repo_id] = sel
			stack.append([dep.repo_id, sel.url, sel.tag, sel.kind, sel.canonical])

	var verify = {}
	var queue = []
	for e in edges:
		if e[2] and not verify.has(e[1]):
			verify[e[1]] = true
			queue.append(e[1])
	while not queue.is_empty():
		var id = queue.pop_back()
		for e in edges:
			if e[0] == id and not verify.has(e[1]):
				verify[e[1]] = true
				queue.append(e[1])

	# Only the root has test edges; whatever is reachable without them would ship.
	var shipped = {}
	var walk = [root[0]]
	while not walk.is_empty():
		var id = walk.pop_back()
		for e in edges:
			if e[0] == id and not e[3] and not shipped.has(e[1]):
				shipped[e[1]] = true
				walk.append(e[1])
	var test_only = {}
	for id in selected:
		if not shipped.has(id):
			test_only[id] = true
	return {"selected": selected, "verify": verify, "test_only": test_only}


func _check_major_line(node:Array, dep:Dep, sel:Dictionary) -> void:
	var wanted = major_line(dep.tag)
	var picked = major_line(sel.tag)
	if wanted < 0 or picked < 0 or wanted == picked:
		return
	_error("%s: %s@%s needs %s (%s), but %s is selected via %s; up- or downgrade one side so they share a major line" % [
		dep.repo_id, node[0], node[2], _line_name(wanted), dep.tag, sel.tag, sel.chain])


static func _line_name(line:int) -> String:
	return "v0/v1" if line == 1 else "v%d" % line


## {requires, error} from a node's located package's export config. A source package without one
## gets the defaults (its cfg's require); a release asset never ships a config, so it stays a sealed
## leaf. A package that can't be located declares nothing here - that error is reported on its own
## if the version ends up selected.
func _requires(node:Array, default_dest:String) -> Dictionary:
	var pkg = _package(node[0], node[1], node[2], node[3], node[4], default_dest)
	if pkg.has("error"):
		return {"requires": [], "error": ""}
	var key = "%s|%s" % [pkg.info.id, pkg.src]
	if _requires_cache.has(key):
		return _requires_cache[key]
	var result = null
	for rel in ExportIgnore.candidates(pkg.src, CONFIG_NAMES):
		var text = fetcher.read_file(pkg.info, rel)
		if text != null:
			result = requires_in_export_config(text, rel.get_extension(), _cfg_text(pkg.info, pkg.src))
			if result.error != "":
				result.error = "%s: %s" % [rel, result.error]
			break
	if result == null:
		var sealed = pkg.info.get("kind", KIND_SOURCE) == KIND_RELEASE
		result = {"requires": [], "error": ""} if sealed else requires_in_data({}, _cfg_text(pkg.info, pkg.src))
	_requires_cache[key] = result
	return result


## {info, src, dest} for a repo at a tag, or {error}. `default_dest` lets the target's own root cfg
## go without path=, since where it installs is already known.
func _package(id:String, url:String, tag:String, kind:String, canonical:String, default_dest:String = "") -> Dictionary:
	var asset = _assets.get(id, "")
	var key = "%s|%s|%s|%s" % [kind, url, tag, asset]
	if _packages.has(key):
		return _packages[key]
	var result = {}
	var info = fetcher.lookup(url, tag, kind, canonical, asset)
	if info.is_empty():
		result = {"error": "could not be fetched%s" % _fetch_note()}
	else:
		var cfg_value = func(dir:String, cfg_key:String) -> String:
			return unquote(PackageCfg.section(_cfg_text(info, dir)).get(cfg_key, ""))
		var located = PackageLayout.locate(fetcher.files(info), id, cfg_value, repo_id_from_url, default_dest)
		result = located if located.has("error") else {"info": info, "src": located.src, "dest": located.dest}
	_packages[key] = result
	return result


func _cfg_text(info:Dictionary, dir:String) -> String:
	var key = "%s|%s" % [info.id, dir]
	if _cfg_texts.has(key):
		return _cfg_texts[key]
	var text = ""
	for nm in CFG_NAMES:
		var found = fetcher.read_file(info, dir.path_join(nm) if dir != "" else nm)
		if found != null:
			text = found
			break
	_cfg_texts[key] = text
	return text


func _entry(id:String, pkg:Dictionary, verify:bool) -> Dictionary:
	var info = pkg.info
	var entry = {
		"repo_id": id,
		"url": info.url,
		"tag": info.tag,
		"sha": info.id,
		"kind": info.kind,
		"asset": info.get("asset", ""),
		"package": pkg.src,
		"path": pkg.dest,
		"source": "local" if url_overrides.get(id) == info.url else "remote",
		"verify": verify,
	}
	if _assets.get(id, "") != "":
		entry.asset_pattern = _assets[id] # only when pinned, so unpinned locks hash as before
	return entry


## The tag `dep` resolves to the way a build would fetch it (v toggled, its /release asset pin
## applied), or "" with the fetcher's last_error saying why.
func find_tag(dep:Dep) -> String:
	_assets[dep.repo_id] = dep.asset
	var url = url_overrides.get(dep.repo_id, dep.repo_url)
	return _find_tag(url, dep.tag, dep.kind, dep.repo_url, dep.asset)


## The dep's own spelling first, then with the leading v toggled - gdaddon's tagEqual.
## On failure the fetcher's last_error is the first spelling's, the one the config wrote: a
## missing toggled tag would otherwise hide why that one was refused.
func _find_tag(url:String, want:String, kind:String, canonical:String, asset:String = "") -> String:
	var first_error = null
	for candidate in tag_candidates(want):
		if not fetcher.lookup(url, candidate, kind, canonical, asset).is_empty():
			return candidate
		if first_error == null:
			first_error = fetcher.last_error
	if first_error != null:
		fetcher.last_error = first_error
	return ""


static func tag_candidates(want:String) -> Array:
	var bare = want.trim_prefix("v")
	var toggled = bare if want.begins_with("v") else "v" + bare
	return [want, toggled]


func _fetch_note() -> String:
	var err = fetcher.get("last_error")
	return " (%s)" % err if err is String and err != "" else ""


func _error(message:String) -> void:
	errors.append(message)

#endregion


#region Dev project

## repo_id -> res:// dir for project checkouts. A negative depth scans the whole tree.
static func scan_dev_repos(addons_dir:String = "res://", max_depth:int = -1) -> Dictionary:
	var out = {}
	_scan_dev_repos(addons_dir, max_depth, out)
	return out


static func _scan_dev_repos(dir:String, depth:int, out:Dictionary) -> void:
	if depth == 0:
		return
	var access = DirAccess.open(dir)
	if access == null:
		return
	for sub in access.get_directories():
		if sub.begins_with(".") or ExportIgnore.is_name(sub) or access.is_link(sub):
			continue
		var path = dir.path_join(sub)
		var git_path = path.path_join(".git")
		if DirAccess.dir_exists_absolute(git_path) or FileAccess.file_exists(git_path):
			var url = origin_url(path)
			var id = repo_id_from_url(url)
			if id != "" and not out.has(id):
				out[id] = path
		_scan_dev_repos(path, depth - 1 if depth > 0 else -1, out)


static func origin_url(dir:String) -> String:
	var output = []
	var code = OS.execute("git", ["-C", ProjectSettings.globalize_path(dir), "remote", "get-url", "origin"], output)
	return "".join(output).strip_edges() if code == 0 else ""


## Whether a checkout already carries one of the tag's spellings locally. False for a dir that is no
## checkout at all, so a caller has to know which case it is in before reporting one.
static func local_tag_exists(dir:String, tag:String) -> bool:
	for candidate in tag_candidates(tag):
		var output = []
		var code = OS.execute("git", ["-C", ProjectSettings.globalize_path(dir), "tag", "--list", candidate], output)
		if code == 0 and "".join(output).strip_edges() != "":
			return true
	return false


## Stable hash of a lock, used to key reusable workspaces.
static func lock_hash(lock:Dictionary) -> String:
	return JSON.stringify(lock, "", true).sha256_text().substr(0, 16)

#endregion

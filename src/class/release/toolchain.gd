@tool
extends RefCounted
## The released package_exporter a release export runs in its workspace - Go's toolchain, in effect.
## Its version is `toolchain` in the export config's options, or the dev exporter's version when
## unset. Always the GitHub release zip, downloaded once and cached - never this project's own copy.

const DepResolver = preload("res://addons/package_exporter/src/class/release/dep_resolver.gd")
const ReleaseRunner = preload("res://addons/package_exporter/src/class/release/release_runner.gd")

const NAME = "package_exporter"
const CONFIG_KEY = "toolchain"
const DEV_DIR = "res://addons/package_exporter"
const FALLBACK_REPO = "https://github.com/brohd11/godot-package-exporter"
const ASSET = "package-exporter-%s.zip"

var errors:Array[String] = []


## {dir, version, source: "remote", id}, or {} with `errors` filled.
func resolve(options:Dictionary, cache_root:String, refresh:bool) -> Dictionary:
	errors.clear()
	var version = pick_version(options, _cfg_version(DEV_DIR)).trim_prefix("v")
	if version == "":
		errors.append("no toolchain version: set options.%s or give %s a version=" % [CONFIG_KEY, DEV_DIR])
		return {}
	return _resolve_remote(version, cache_root, refresh)


static func pick_version(options:Dictionary, dev_version:String) -> String:
	var pinned = str(options.get(CONFIG_KEY, "")).strip_edges()
	return pinned if pinned != "" else dev_version


## Release asset urls to try, `v<ver>` tag first. Keeps the repo's own casing - only `www.` and
## `.git` go, and an scp-style remote becomes https.
static func asset_urls(repo_url:String, version:String) -> Array[String]:
	var base = repo_url.strip_edges().trim_suffix("/").trim_suffix(".git").replace("://www.", "://")
	if not "://" in base and "@" in base:
		base = "https://" + base.get_slice("@", 1).replace(":", "/")
	var bare = version.trim_prefix("v")
	var out:Array[String] = []
	for tag in ["v" + bare, bare]:
		out.append("%s/releases/download/%s/%s" % [base, tag, ASSET % bare])
	return out


func _resolve_remote(version:String, cache_root:String, refresh:bool) -> Dictionary:
	var dir = cache_root.path_join("toolchains").path_join("%s-%s" % [NAME, version])
	var zip_path = dir.path_join(ASSET % version)
	var plugin_dir = dir.path_join(DEV_DIR.trim_prefix("res://")) # release zips carry the install layout
	var cached = FileAccess.file_exists(zip_path) and FileAccess.file_exists(plugin_dir.path_join("plugin.cfg"))

	if refresh or not cached:
		if DirAccess.dir_exists_absolute(dir):
			ReleaseRunner.remove_dir(dir)
		DirAccess.make_dir_recursive_absolute(dir)
		if not _download(_repo_url(), version, zip_path):
			errors.append("no release %s for %s - publish it, or pin '%s' to a released version" % [
				ASSET % version, version, CONFIG_KEY])
			ReleaseRunner.remove_dir(dir)
			return {}
		var err = ReleaseRunner.unzip(zip_path, dir)
		if err != "":
			errors.append(err)
			ReleaseRunner.remove_dir(dir)
			return {}

	return _checked(plugin_dir, version, "remote", FileAccess.get_sha256(zip_path))


func _checked(plugin_dir:String, version:String, source:String, id:String) -> Dictionary:
	var found = _cfg_version(plugin_dir).trim_prefix("v")
	if found != version:
		errors.append("%s toolchain at %s is %s, expected %s" % [source, plugin_dir, found if found != "" else "unversioned", version])
		return {}
	return {"dir": plugin_dir, "version": version, "source": source, "id": id}


func _download(repo_url:String, version:String, zip_path:String) -> bool:
	for url in asset_urls(repo_url, version):
		var output = []
		if OS.execute("curl", ["-fsSL", "-o", zip_path, url], output, true) == 0:
			return true
	DirAccess.remove_absolute(zip_path)
	return false


static func _repo_url() -> String:
	var url = DepResolver.origin_url(DEV_DIR) if DirAccess.dir_exists_absolute(DEV_DIR) else ""
	return url if url != "" else FALLBACK_REPO


static func _cfg_version(dir:String) -> String:
	return str(DepResolver.PackageCfg.dir_value(dir, "version", ""))

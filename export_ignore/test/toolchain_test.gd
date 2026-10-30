@tool
extends EditorScript

## Tests for the release export's toolchain lookup: version pinning, release asset urls and
## cached remote toolchains. No network - a cached toolchain is laid
## out by hand, so resolve() never has a reason to download.
##
##     load("res://addons/package_exporter/export_ignore/test/toolchain_test.gd").run_tests()

const Toolchain = preload("res://addons/package_exporter/src/class/release/toolchain.gd")
const ReleaseRunner = preload("res://addons/package_exporter/src/class/release/release_runner.gd")

const DIR = "user://pe_toolchain_tests"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	var root = ProjectSettings.globalize_path(DIR)
	ReleaseRunner.remove_dir(root)

	_test_pick_version()
	_test_asset_urls()
	_test_cached_remote(root)
	_test_unzip(root)

	ReleaseRunner.remove_dir(root)
	var output:Array[String] = []
	output.append("toolchain: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_pick_version() -> void:
	_check("pin wins", Toolchain.pick_version({"toolchain": "0.7.2"}, "0.7.4"), "0.7.2")
	_check("blank pin falls back", Toolchain.pick_version({"toolchain": "  "}, "0.7.4"), "0.7.4")
	_check("no pin falls back", Toolchain.pick_version({}, "0.7.4"), "0.7.4")


static func _test_asset_urls() -> void:
	var urls = Toolchain.asset_urls("https://www.github.com/Brohd11/Godot-Package-Exporter.git", "0.7.4")
	_check("v tag first", urls[0], "https://github.com/Brohd11/Godot-Package-Exporter/releases/download/v0.7.4/package-exporter-0.7.4.zip")
	_check("bare tag second", urls[1], "https://github.com/Brohd11/Godot-Package-Exporter/releases/download/0.7.4/package-exporter-0.7.4.zip")
	_check("v in version not doubled", Toolchain.asset_urls("https://github.com/o/r", "v1.0")[0],
		"https://github.com/o/r/releases/download/v1.0/package-exporter-1.0.zip")
	_check("scp remote", Toolchain.asset_urls("git@github.com:o/r.git", "1.0")[0],
		"https://github.com/o/r/releases/download/v1.0/package-exporter-1.0.zip")


## A version already in the cache resolves as-is: trusted, like a mirrored tag.
static func _test_cached_remote(root:String) -> void:
	var cache_root = root.path_join("cache")
	var dir = cache_root.path_join("toolchains/package_exporter-9.9.9")
	_write(dir.path_join("addons/package_exporter/plugin.cfg"), '[plugin]\nversion="9.9.9"\n')
	_write(dir.path_join("package-exporter-9.9.9.zip"), "not really a zip")

	var tc = Toolchain.new()
	var info = tc.resolve({"toolchain": "v9.9.9"}, cache_root, false)
	_check("cached: resolved " + str(tc.errors), info.is_empty(), false)
	if not info.is_empty():
		_check("cached: dir", info.dir, dir.path_join("addons/package_exporter"))
		_check("cached: source", info.source, "remote")
		_check("cached: id is zip hash", info.id, FileAccess.get_sha256(dir.path_join("package-exporter-9.9.9.zip")))

	_write(dir.path_join("addons/package_exporter/plugin.cfg"), '[plugin]\nversion="9.9.8"\n')
	var mismatch = Toolchain.new()
	_check("cached: wrong version rejected", mismatch.resolve({"toolchain": "9.9.9"}, cache_root, false), {})
	_check("cached: mismatch named", mismatch.errors.size() == 1 and "is 9.9.8, expected 9.9.9" in mismatch.errors[0], true)


static func _test_unzip(root:String) -> void:
	var zip_path = root.path_join("unzip/src.zip")
	DirAccess.make_dir_recursive_absolute(zip_path.get_base_dir())
	var packer = ZIPPacker.new()
	packer.open(zip_path)
	for entry in ["package_exporter/sub/a.txt", "__MACOSX/package_exporter/._a.txt", "package_exporter/.DS_Store"]:
		packer.start_file(entry)
		packer.write_file("hello".to_utf8_buffer())
		packer.close_file()
	packer.close()

	var dest = root.path_join("unzip/out")
	_check("unzip ok", ReleaseRunner.unzip(zip_path, dest), "")
	_check("unzip content", FileAccess.get_file_as_string(dest.path_join("package_exporter/sub/a.txt")), "hello")
	_check("unzip skips __MACOSX", DirAccess.dir_exists_absolute(dest.path_join("__MACOSX")), false)
	_check("unzip skips .DS_Store", FileAccess.file_exists(dest.path_join("package_exporter/.DS_Store")), false)
	_check("unzip bad archive", ReleaseRunner.unzip(root.path_join("unzip/missing.zip"), dest).begins_with("could not open"), true)


static func _write(path:String, text:String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])

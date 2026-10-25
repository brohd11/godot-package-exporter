## `#!` tag handlers for the dependency scan. Registered on a DepMap.Scanner instance with
## add_tag_handler(), which documents the handler contract - a Callable taking one context
## dict and returning the metadata to hang on the edges it emits.

## Tag name without the "#!" prefix, the form add_tag_handler() takes.
const TAG = "dependency"
const IGNORE_REMOTE = "ignore-remote"
## File-level, like `#! remote`: within the first HEADER_LINES lines. The file is copied untouched,
## its dependencies aren't gathered, and the release compile check doesn't load it.
const SKIP_PARSE = "pe-skip-parse"
const HEADER_LINES = 10
## The key the handler hangs on the edges it emits; parse_base maps it onto the export dict's
## own key. Naming it here rather than reaching for KeysData is what leaves this file
## with no imports, so registering the handler cannot pull the export pipeline in behind it.
const DIR_KEY = "dir"
const DECLARING_FILE_KEY = "declaring_file"


## `#! dependency [destination]` optionally names the complete output file, including its name.
## Relative paths follow the declaring file; <package>/ anchors to the export's source root.
## "current" and "." keep the original filename beside the declaring file.
static func dependency_dir() -> Callable:
	return func(ctx:Dictionary) -> Variant:
		if ctx.raws.is_empty():
			return null
		var value:String = ctx.value
		# A quoted source may follow the tag; it is already in raws, so keep only its destination.
		if value.begins_with('"') or value.begins_with("'"):
			var end = value.find(value[0], 1)
			value = value.substr(end + 1) if end > -1 else ""
		value = value.strip_edges()
		if value == "":
			return {}
		return {DIR_KEY: value, DECLARING_FILE_KEY: ctx.file_path}


static func skips_parse(text:String) -> bool:
	var marker = "#! " + SKIP_PARSE
	var lines = text.split("\n", true, HEADER_LINES)
	for i in mini(lines.size(), HEADER_LINES):
		var line = lines[i].strip_edges()
		if line.begins_with(marker):
			var rest = line.substr(marker.length())
			if rest == "" or rest[0] in [" ", "\t", ";"]:
				return true
	return false


static func file_skips_parse(path:String) -> bool:
	if not path.get_extension() in ["gd", "tscn", "tres", "cs"]:
		return false
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	# only the header is read: this runs on every file the dependency crawl visits
	var head:PackedStringArray = []
	while head.size() < HEADER_LINES and not file.eof_reached():
		head.append(file.get_line())
	return skips_parse("\n".join(head))


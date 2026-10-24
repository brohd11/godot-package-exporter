@tool
extends RefCounted
## Rules for the paths an export config names. No preloads, so the export pipeline, release code
## and headless tests can all share it without dragging each other in.

const DEFAULT_BASE = "res://addons"


## Returns an unrenamed source-space destination, or empty if it leaves the exported plugin.
## declaring_dest is the declaring file's final placement, also in source space.
static func dependency_destination(raw:String, source:String, declaring_dest:String, filename:String) -> String:
	var path = raw.strip_edges().replace("\\", "/")
	if path == "current" or path == ".":
		path = filename
	if path == "" or path.ends_with("/") or path.get_file() in [".", "..", "<package>"]:
		return ""
	if path.begins_with("<package>/"):
		path = source.path_join(path.trim_prefix("<package>/"))
	elif path.is_relative_path():
		if declaring_dest == "":
			return ""
		path = declaring_dest.get_base_dir().path_join(path)
	var root = ProjectSettings.globalize_path(source).simplify_path().trim_suffix("/")
	var destination = ProjectSettings.globalize_path(path).simplify_path()
	if not destination.begins_with(root + "/"):
		return ""
	return source.trim_suffix("/").path_join(destination.trim_prefix(root + "/"))


## Command targets are addon-relative unless absolute. Only project resources can be exported.
## Empty means invalid; existence is checked by the caller so discovery and init can share this.
static func resolve_target(raw:String) -> String:
	var path = raw.strip_edges().replace("\\", "/")
	if path == "" or ("://" in path and not path.begins_with("res://")):
		return ""
	if not path.is_absolute_path():
		path = DEFAULT_BASE.path_join(path)
	var absolute = ProjectSettings.globalize_path(path).simplify_path()
	var root = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	if absolute != root and not absolute.begins_with(root + "/"):
		return ""
	return ProjectSettings.localize_path(absolute).trim_suffix("/") if absolute != root else "res://"


## A flat, collision-resistant cache name independent of how the caller spelled the target.
static func workspace_key(target:String) -> String:
	var path = resolve_target(target)
	if path == "":
		return ""
	return path.trim_suffix("/").get_file().validate_filename() + "-" + path.sha256_text().left(12)


## Why a configured export_folder can't be an install path, or "" when it can (empty means source).
## Takes the raw value, since a {{...}} template there is the old "<package>/<folder>" form.
static func export_folder_error(raw:String) -> String:
	var path = raw.strip_edges().trim_prefix("res://")
	if path.begins_with("/") or (path.length() > 1 and path[1] == ":"):
		return "is an absolute path"
	if ".." in path.split("/"):
		return "leaves the project"
	if "{{" in path:
		return "contains a {{...}} template - old \"<package>/<folder>\" form? move the package part to export_name"
	return ""


## Main Settings
 - export_root - root of export can be local or global scope, inside or outside project
 - plugin_folder - appended to export_root, by default it uses the plugin version, so all different version exports can exist in this folder
 - pre_script - optional script whose `pre_export()` runs before export; `""` skips it
 - post_script - optional script whose `post_export()` runs after export; `""` skips it. Both should `extends PackageExporter.ExportScript`, whose `_configure(export_data)` runs first and can be overridden to read more of the export
 - exports - array of export objects dictionaries
 - options - dictionary of options

### exports
 - source - source location of the plugin
 - exclude - directories, file_extensions, and files to ignore on export
 - remote_dir - where all out of plugin files will be recreated
 - export_name - package folder under export_root + plugin_folder, zipped as a whole. Defaults to the last segment of plugin_folder
 - export_folder - install path relative to res://, e.g. `addons/_lib/my_lib`. Recreated inside the package, so it extracts straight into a project. Any path relative to res:// (no `{{version}}` templates); defaults to source. A path different from source renames the plugin and rewrites its paths to match
 - other_transfers - other files to transfer into plugin on export. Each entry:
   - to - destination, relative to source unless it already starts with it. A file for a single-file `from`, a directory otherwise
   - from - a file, an array of files, or a directory. Omitted with a `to` ending in `.gdignore` to write an empty one
   - recursive - bool, defaults false. For a directory `from`, includes subdirectories, keeping their structure under `to`
   - ignore_deps - bool, defaults false. Files are copied and their paths rewritten, but never scanned for dependencies or global classes. For optional integrations that name classes from plugins that may be absent: ship them under a `.gdignore` so they don't compile until loaded
   - custom_tree_message - text appended to the file in the export tree view
   - Two sources resolving to the same destination abort the export
 - ignore_dependencies - do not export any dependencies for the files
 - parser_overide_settings - overide settings per export for the file parser
 
### options
 - include_import - bool
 - include_uid - bool
 - overwrite - bool, erases the contents of export_root + plugin_folder before export, if false, it will abort if any file already exists
 - include_docs - bool, defaults true. Copies the doc folder beside this config (export_ignore/doc) into the exported plugin as `.doc`, preserving its structure. No dependency crawl, the files are copied verbatim without uid or import sidecars. Dot-prefixed so Godot never imports them and they stay out of a game export, while DocViewer can still read them.
 - include_project_license - bool, defaults false. Licenses are gathered by matching every copied file against the closest LICENSE above it, so a nested library keeps its own. The project root (`res://LICENSE`) is held out of that matching - it contains everything, so it would otherwise claim every file no other license covers. Turn this on for a plugin that has no LICENSE of its own and takes the project's; it ships at the export root. Ignored when the plugin does have one.
 - parser_settings - Dictionary of settings for file parser. Applied to all exports unless overiden

#### parser_settings
these settings are passed to parsers. You can overide on a per export basis using "parser_overide_settings" in each export. This is the exact same data structure

##### general - applies to all extensions
 - use_relative_paths - Instead of absolute paths, uses relative paths from current file.
 - backport_target - target minor version for backport as int

##### parse_gd
 - replace_editor_interface - replaces 'EditorInterface' direct singleton access with 'Engine.get_singleton(&"EditorInterface")'
 - class_rename_ignore - Array of class_name to not strip and preload
 - reduce_access_paths - bool, default false. Rewrites dotted access paths to direct preloads: `ALibRuntime.Utils.UFile` becomes `UFile` with `const UFile = preload("...")` added to the script. Stops at the deepest segment that names a script file, so an inner class or enum on the end is kept (`A.B.UProfile.TimeFunction` -> `UProfile.TimeFunction`). Classes left with no bare use anywhere are then dropped from the export, which is what keeps a namespace hub from dragging in every file it preloads.
 - backport_string_renames - dictionary, key is the method to replace, value is a dictionary with key "replace":"replace_as", "min_ver": backport_target as int

##### parse_cs
 - namespace_rename - Dictionary with keys "namespace":"rename_as"


### GDScript optimizer

`plugin_init` seeds the following block in each new `export.yml`. Existing files
without it use the same defaults; omit individual keys to inherit their defaults.

```yaml
options:
  parser_settings:
    parse_gd:
      optimizer:
        enabled: true
        struct_mode: tagged # auto | tagged | off
        inline_mode: tagged # auto | tagged | off
        aggressive: false
        debug_tags: false
```

`enabled: false` bypasses the whole optimizer, including struct lowering and validation
of inactive optimization options. Packaging, path relocation, and backporting still run.
When enabled, invalid optimizer keys or values invalidate the export before its files
are copied. Unsupported inline sites remain unchanged with diagnostic reasons.

Structs run before inlining.
The shared optimizer uses `struct_mode` and `inline_mode` to select tagged definitions,
automatically discover eligible definitions, or disable each pass. `aggressive` admits
reference/Variant types and relaxes inline conversions/lifetimes. Struct usage checks remain.
Scalar replacement and typed-local field reads are included in struct optimization;
there is no field-read cast strategy. `#! struct; off` and `#! inline; off` exclude definitions.
Only explicit `#! inline; substitute` permits unchecked effectful arguments.
See the shared optimizer README for supported syntax and exact eligibility rules.

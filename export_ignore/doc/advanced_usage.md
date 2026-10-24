

### Automatic dependencies

Every exportable source file is scanned for references, and each discovered dependency is scanned
in turn. Preloads, inheritance, global classes, and scene/resource references are gathered without
any tag. An optional preload hub such as `utils_remote.gd` works the same as any other script.

Literal `load()` calls and ordinary path strings are only copied when marked `#! dependency`.
Use `#! dependency current` or an explicit output file path to choose where a dependency is placed.
Relative paths follow the declaring file's final exported location. The literal prefix
`<package>/` anchors a path to the active export's source folder, before export conversion
and renaming. It does not refer to the package that contains the declaring file.

Global classes can be used as normal.

### Remote Class

You can get a single un-named script from outside of the plugin like this:

``` gdscript
#! remote
extends "res://some_other/folder/my_class.gd"
```

On export, this file will be replaced with the extended class, and all dependencies copied to plugin.

"#! remote" must be within the first 10 lines of the file.

Because the file is replaced any changes will not be present in the copied file. I would use this if I want this file to be in a specific spot, or if I created another script to extend it and make changes there.

`#! remote` only enables this replacement behavior. It is unnecessary for dependency gathering; existing tags on files without a replaceable base are harmless.

**Note**: because this is extending the class, it is not the same as the class. It could have identical functionality, but if you need to type check, this class is not the same as the extended class. If you need to type check, use the plugin preload file method.

### Optional Preload Hub

This format can be used to make a master file that preloads out of plugin files. Typically, I will name this utils_remote.gd or something similar, to denote that these files are not local to the plugin. This file can either be preloaded in your plugin scripts, or given a global class name. 

This is useful if the desired files are not global classes, you can preload any classes that you want to use in your plugin.

You can also declare files as dependencies if they are not preloadable. Explicit destinations are
complete file paths, allowing the copy to be renamed, including to an extensionless name such as
`LICENSE`. `current` and `.` keep the original filename beside the exported declaring file,
including when that file moves to the remote directory, replaces a stub, or relocates as a global.

| Destination | Placement |
| --- | --- |
| `licenses/font/LICENSE` or `./licenses/font/LICENSE` | Named `LICENSE` below the declaring file's exported directory |
| `../licenses/font/LICENSE` | Relative to the parent of that directory |
| `current` or `.` | Original filename beside the exported declaring file |
| `<package>/licenses/font/LICENSE` | Named `LICENSE` below the active export's source root, then converted and renamed |
| `res://addons/my_plugin/licenses/font/LICENSE` | Absolute file path within the active export's source folder |
| Omitted | Default remote placement |

An absolute destination outside the active source folder, a relative destination escaping the
exported plugin, or a cycle of relative placements fails the export before copying. Shared
libraries should use `<package>/` for package-root assets so they work in every consuming plugin.
These rules affect the destination argument only; dependency source literals resolve as before.
Directory-only forms ending in `/` are rejected. Existing explicit directory destinations must
have the intended filename appended; the exporter no longer appends it automatically.

``` gdscript
class_name MyPluginUtilsRemote

const MyClass = preload("res://some_other/folder/my_class.gd")
const MyOtherClass = preload("res://some_other/folder/my_other_class.gd")

const MY_FILE = "res://some_other/folder/non-resource.file" #! dependency
const MY_CUST_FILE = "res://file.file" #! dependency res://addons/my_plugin/deps/renamed.file
const FONT_LICENSE = "res://some_library/font.LICENSE.txt" #! dependency <package>/licenses/font/LICENSE
```

In another script you can access like:

``` gdscript
## if you don't have a global name, preload the class
const UtilsRemote = preload("res://addons/my_plugin/utils_remote.gd")

func _ready():
	var my_instance = UtilsRemote.MyClass.new()
	UtilsRemote.MyOtherClass.static_func(my_instance)
```

On export, these files will be copied into your plugin, and have their paths adjusted. If you want to organize your scripts into a hierarchy, you can use my [pseudo-namespace](https://github.com/brohd11/Godot-Pseudo-Namespace) plugin. This works well with this workflow.

### Structs

A class tagged `#! struct` is written like any data class, but exports as a plain Array, which
skips object allocation and property lookup.

``` gdscript
#! struct
class Hit:
	var position: Vector2
	var damage := 1

	func _init(p_position: Vector2) -> void:
		position = p_position

func spawn(at: Vector2) -> Hit:
	return Hit.new(at)
```

exports as

``` gdscript
#! struct
class Hit:
	enum { POSITION, DAMAGE }
	static func create(p_position: Vector2) -> Array:
		return [p_position, 1]

func spawn(at: Vector2) -> Array:
	return [at, 1]
```

- Put the tag on the line above `class X:`. At the top of a file, followed by a blank line, it makes
  the whole script the struct.
- A struct holds only `var` fields and an `_init` that assigns fields from its arguments. Methods,
  signals, setters/getters, annotations, or extending anything but RefCounted/Object fail the export.
- `X.new(...)` becomes an array literal when the arguments are in field order and every other field
  defaults to a literal; otherwise it becomes `X.create(...)`.
- `: X`, `-> X`, `as X`, `Array[X]` and `Dictionary[K, X]` become `Array`.
- `hit.damage` becomes `hit[Hit.DAMAGE]` wherever `hit` is statically typed as the struct: a typed
  var, param, member or return, `:=`, a `for` over a typed Array, an index into one. A file that
  reads a field without naming the struct gets a `const` preload appended for the enum.
- A struct must keep its static type, because once it is an Array a field read through Variant
  compiles and only fails at runtime. So the export fails on:
  - an untyped `var x = <struct>`, or a var typed as something else
  - returning a struct from a func whose return type isn't that struct
  - assigning a struct into a slot not typed as it
  - passing a struct to an untyped parameter
  - appending or inserting one into an untyped Array
  - a struct inside an array or dict literal, unless the literal is the whole value of a var,
    assignment or return typed `Array[X]` or `Dictionary[K, X]`
  - an untyped element parameter in a lambda given to `map`, `filter`, `any`, `all`, `reduce`,
    `sort_custom`, `find_custom` or `rfind_custom` on an Array of structs, whether the lambda is
    written inline or bound to a var and passed by name
  - `is X`, `is_instance_valid()`, `get()`/`set()`/`call()` on a struct
- Lambdas may take structs: `func(hit: Hit): return hit.damage` is rewritten like any other typed
  read, inline or bound to a var, including several lambdas on one line.
- The export warns, with file and line, when a struct is passed to `emit`, `emit_signal`, `call`,
  `call_deferred`, `callv`, `bind`, `set_meta` or `rpc`, or when a Callable that isn't a lambda in
  scope iterates an Array of structs. Their receivers can't be seen, so type their parameters as the
  struct.
- Not checked: structs passed to other engine methods with Variant parameters. A struct is also a
  plain Array to anything outside the plugin, so keep structs out of a plugin's public API.

### Tags

There are a couple of tags you can use to change how files are processed.
 - "#! ignore-remote" - Skip dependency gathering and path rewriting for references on this line, including global-class and access-path discovery. Another untagged reference may still gather the same dependency. A standalone header tag does not opt out the whole file.
 - "#! dependency" - Explicitly gather a path, including optional `load()` targets and non-resource files such as config or JSON. An optional directory controls placement.
 - "#! singleton-module" - This is for a singleton class I use to share libraries between plugins. Only useful if extending one of the Singleton classes.
 - "#! struct" - Exports a data-only class as an Array, see [Structs](#structs).

A tag has the form `#! tag value` or `#! tag mods; args`, and has to open its comment.

The reason I mention the singleton-module tag is because you could add your own tags and parse them with your own custom parser. You can add any parsers to folder `package_exporter/src/class/export/parse/<extension>` replace with your file extension and the parser will be called on those files. You can add parameters in the `plugin_export.json` file under `parser_settings`, more info [here](./export_settings.md).

### Full Plugin Copy

Something I am experimenting with is creating "portable" plugins. These plugins would be agnostic to their location, and might interact with an instance of a class in the tree. This allows for packaging the plugin into multiple other plugins, but all can interact with each other, despite being technically different classes.

To copy an entire plugin in, I do this:
``` gdscript
#! remote
extends "res://addons/my_other_plugin/plugin.gd"

const PLUGIN_CFG = "res://addons/my_other_plugin/plugin.cfg" #! dependency current
```

This file would be in a folder for sub-plugins inside the main plugin. 

`res://addons/my_plugin/sub_plugins/plugin_to_copy/plugin.gd`

The other plugin.gd will replace the above file, and have it's config file copied next to it, allowing it to be enabled by Godot. All the dependencies will be placed in the designated remote directory, so they can share common files. As long as any required files are preloaded, global classes, or used in a tscn file, they will be copied over. If they are not directly referenced, you can add them to the above similar to the config file.

You don't want the main plugin to enable this sub plugin in your dev repo, and in fact you can't since plugin.cfg will not be present until export. So, to avoid errors I have a class that will enable and disable sub-plugins. I use the plugin exported flag to determine if the main plugin has been exported. Right clicking on an empty line in a script will give you the option to add the exported flag(avoids spelling mistakes).

``` gdscript
const PLUGIN_EXPORTED = false
const SUB_PLUGIN_DIR = "res://addons/my_plugin/sub_plugins"

func _enable_plugin():
	if PLUGIN_EXPORTED:
		SubPluginManager.toggle_plugins(SUB_PLUGIN_DIR, true)

func _disable_plugin():
	if PLUGIN_EXPORTED:
		SubPluginManager.toggle_plugins(SUB_PLUGIN_DIR, false)
```

On export, the exported flag will be changed to true, allowing the sub-plugins to be enabled. There is also a backport flag available, that can be used to change your logic depending on the backport target version.

Using this method, you can copy multiple sub-plugins into your plugin, while leaving their source intact for updates.


### Backport

In the "plugin_export.json" file, under "parser_settings" can change "backport_target" to the minor version you are targeting. ie: "backport_target": 3 == Godot 4.3.x

This will apply any backports necessary for your plugin. For example, if you use static vars, they will not need to be adjusted, but EditorContextMenuPlugins will. If the backport_target was 0, static vars would be adjusted too.

This does not have all incompatibilities fixed. It is mainly things I have run into with my own plugins. So a changed property name between versions in a random class is not likely to have been fixed yet. However, it is pretty simple to add extra rules to the backport parser, so substitutions can be made.

Main backports:
- EditorInterface direct singleton access converts to compatibility class
 - EditorContextMenuPlugin converts to compatibility class
 - static var are converted to a singleton using static func getters and setters
 - typed for loops and dictionaries stripped
 - raw strings converted to escaped strings
 - "X is not Y" syntax converted to "not X is Y"
 - various other methods recreated in a compatibility class
 - remove @abstract keyword
 - convert DPITexture resources to SVG


### Release Export

A normal export crawls the project as it is on disk, uncommitted changes and all. A release export
builds from tags instead:

```
package_exporter export --release my_plugin
package_exporter export --release --refresh my_plugin
package_exporter export --release --local my_plugin
```

1. **Resolve.** The plugin's `version=` must have a matching tag (`1.2.0` or `v1.2.0`) on its
   `origin` remote. Its `build_require` and `compile_require` (below) are read from
   `export_ignore/plugin_export.*` *at that tag*, then each dep's the same way at its tag, and so
   on. When two plugins ask for different tags of one repo, the highest wins (Go's minimal
   version selection). Every requirement needs an `@tag`; an untagged one fails the export and
   prints the chain that asked for it.
2. **Fetch.** Repos are mirrored under the OS cache dir (`package_exporter/repos`). A tag already
   mirrored is never re-fetched. `--refresh` checks every cached tag against its remote and fails
   if one was moved.
3. **Workspace.** Each dependency's addon folder, at its tag, is copied into its install path (see
   "Where a dependency installs" below). A released `package_exporter` (the
   toolchain, below) runs the export headless there. Workspaces are reused while the resolved tags
   and the toolchain stay the same.
4. **Verify.** Every exported variant is installed into an empty project, along with its
   `compile_require` deps (and whatever those need), and every script and resource is loaded. Any
   parse, compile or load error moves the output to `<plugin_folder>-unverified`.

**Build requirements.** A release export takes its dependencies from the main body of the export
config, declared once for every export entry. `require`/`deps` in `plugin.cfg` are install-time
only (gdaddon's), and the exporter ignores them unless `build_require` names `"@require"`, so an
optional dependency such as a GDExtension with a GDScript fallback never has to be built against.

```yaml
build_require:
  - brohd11/godot-addon-lib@v2.1.2
  - brohd11/godot-yaml-parser@v2.1.0
compile_require:
  - brohd11/godot-tree-sitter-gd@v1.0.5
```

- `build_require`: placed in the workspace; the export bundles whatever it uses.
- `compile_require`: also installed beside the exported plugin when it is verified, for extensions
  or plugins yours is meant to run with. A repo in both lists counts as `compile_require`.
- Each key takes a list of specs or a single spec.
- `"@require"` in `build_require` stands for the package cfg's own `require=` list (`[addon]`
  over `[plugin]`), so it isn't written twice. It can sit in a list beside explicit specs, and is the
  default for a new plugin. Not valid in `compile_require`. `require update` (below) drops it rather
  than expanding it: `require=` is gdaddon's install-time list and may name optional deps that were
  never built against, such as a plugin that adds functionality when present.
- The config lives in `_export_ignore/` or `export_ignore/`; when both hold one, `_export_ignore`
  wins. A package without either config declares nothing. A library that needs
  something can carry a config with only these keys.
- Release zips never include `export_ignore/`, so a dependency fetched as a release declares
  nothing. That's intended: an exported package already carries what it uses.

**Dependency kinds.** A plain `owner/repo@v1.0.0` means the release, picked the way gdaddon picks
it: the release's single uploaded asset, or the tag's source when nothing was uploaded (or the tag
has no release). Several uploads fail as ambiguous. `owner/repo/source@v1.0.0` always takes the
tag's source. A host can lead the spec (`gitlab.com/owner/repo`); only a first segment containing a
dot is read as a host. Releases are looked up through the GitHub API, which allows 60 requests an
hour without a token; set `GITHUB_TOKEN` to raise that. Assets are cached per tag.

**Where a dependency installs.** A package can be laid out three ways, and the same rules as gdaddon
place it:
- a cfg at the package root: the package is the addon, and its cfg must say where it goes with
  `path="addons/..."` (or `dir=`); without it the export fails
- a whole Godot project: the shallowest `addons/` folder is the anchor, so
  `addons/_lib/yaml_parser` installs at `res://addons/_lib/yaml_parser`
- anything else, such as a release zip: the cfg folder's path under the package root (after a single
  wrapper folder is stripped) is its path under `addons/`

When a package holds several addon folders, only the one whose cfg `url=` names the repo is used.
A `path=`/`dir=` in the chosen cfg always wins over the derived location.

To find out what to require, run `package_exporter require my_plugin`. It runs the export crawl
without writing anything and lists the packages the export pulls in (no tags). A package is the
nearest folder with a `plugin.cfg`, `addon.cfg` or `version.cfg`, so every file of one release counts once. Its
identity is the git `origin` when the folder is a checkout, or the cfg `url=` for a package installed
from a release zip. Packages are grouped by the package whose export config should list them, and
each is marked `declared (build)`, `declared (compile)` or `MISSING`. A package with no export
config is flagged, since it declares nothing.

`package_exporter require --self my_plugin` prints only that plugin's own list, one `owner/repo@tag`
per line and nothing else, for piping.

`package_exporter require update my_plugin` writes that list into the plugin's own `build_require`,
in the config it already has - only the target's, never a package it depends on. A tag is `v` plus
the required package's cfg `version=`; when that tag isn't in the package's checkout yet you get a
warning, since tagging comes after the update, and a package with no version to pin is an error that
writes nothing at all. Entries the config already lists keep their tag, so a deliberate older pin
survives; `--overwrite` re-pins them (a leading host and the `/source` marker are kept), and
`--prune` drops the ones the crawl no longer finds. A package already under `compile_require` is
left to it. Only the `build_require` block is rewritten - comments and key order elsewhere in the
config are untouched, and `plugin.cfg` is never written.

`--local` is for trying a release before pushing anything. Every repo with a checkout in this
project is fetched from that checkout instead of its remote; repos without one (a checkout counts
only if its `origin` is the same repo) still come from their remote, with a warning. A missing
local tag or local package_exporter export is an error, never a fallback. It is still tag-pinned, so only committed, tagged files are used - you tag, but
don't push. A local tag you move is followed rather than rejected. Lock entries are marked
`"source": "local"`, and each local tag that isn't on `origin` yet gets a warning.

**Toolchain.** The export is run by a *released* package_exporter rather than the one in this
project, so the exporter's own libraries can't clash with the pinned ones. Its version is
`toolchain` under `options` in the export config, or this project's package_exporter version when
unset. Normally it is the GitHub release zip (`package-exporter-<version>.zip` on tag
`v<version>`), downloaded once into the cache's `toolchains` folder and reused; `--refresh`
downloads it again. With `--local` it is this project's own export of package_exporter instead,
refused when any export script has changed since that export was made. If the toolchain's export
scripts don't compile, the release export fails before verification.

The export carries `.export_lock.json` (repo, tag, commit, path per dependency, and the toolchain) in place of
`.export_git_details`. Entries marked `verify` are the ones the compile check installed. The
released `plugin.cfg` is not modified.

### Shipping Docs

With `include_docs` on (the default), the `doc` folder beside your `export.yml` is copied
into the exported plugin as `.doc`, structure intact. Nothing in it is parsed or crawled for
dependencies, it is copied verbatim, and no `.uid`/`.import` sidecars come along. The dot prefix
keeps Godot from importing the folder, so it never reaches a game export.

The `DocViewer` component renders those docs. You provide the entry point - a button, a menu item,
whatever suits the plugin - and the addon directory to read from:

``` gdscript
const DocViewer = preload("res://addons/my_plugin/src/components/doc_viewer/doc_viewer.gd")

func _on_help_pressed() -> void:
	DocViewer.open("res://addons/my_plugin/")
```

`open()` puts the viewer in its own window that frees itself when closed. To embed it instead,
instance it as a normal Control and set `docs_path`.

It resolves a directory itself: `<addon>/.doc` in a released plugin, `<addon>/export_ignore/doc` in
this dev project, or the plugin's `README.md` when there is no doc folder at all. Docs are listed
depth first, files before folders, on a contents page, with navigation between them.

Give it a **file** instead and that file is the whole viewer - nothing is scanned or guessed at,
and the contents page and navigation stay out of the way:

``` gdscript
DocViewer.open("res://addons/my_plugin/README.md")   # window on one file
viewer.display("res://addons/my_plugin/README.md")   # same, on an embedded instance
```

Links follow through: a doc in the contents opens as a page, a `.md` outside it opens too (the
Contents button goes back), a `res://` file is revealed in the FileSystem dock, and anything else
is handed to the OS.

Markdown support covers headings, emphasis, lists, quotes, links, rules, images and fenced code.
Code fences render as read-only `CodeEdit`s - gdscript is highlighted out of the box, and
`highlighter_provider` takes a `(lang:String) -> SyntaxHighlighter` callable for anything else.
Heading sizes are ratios of the editor's own font size, so the whole view follows the editor scale.

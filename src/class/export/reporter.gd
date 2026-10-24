extends RefCounted
## One funnel for everything an export says. Every line still goes to the Output panel as it
## always has; a sink (the console command) also gets NOTE/WARN/ERROR, and INFO only when verbose.
## Repeated warnings and errors reach the sink once but are all kept in `entries`.

const _UtilsRemote = preload("res://addons/package_exporter/src/class/utils_remote.gd")
const _UEditor = _UtilsRemote.UEditor

const SELF = preload("res://addons/package_exporter/src/class/export/reporter.gd")

enum Level {INFO, NOTE, WARN, ERROR}

## [{level, text}] in the order they were reported.
var entries:Array = []
## (text:String, level:int) -> void. Unset reports to Output only.
var sink:Callable
var verbose := false
## Totals the caller fills in for its result line, e.g. {files, external}.
var stats:Dictionary = {}

var _sent:Dictionary = {}


## Statics reached without an export still report somewhere: a throwaway, Output-only one.
static func or_default(reporter) -> SELF:
	return reporter if reporter != null else SELF.new()


func info(text:String) -> void:
	print(text)
	_add(Level.INFO, text)

## Header and result lines - always shown.
func note(text:String) -> void:
	print_rich(text)
	_add(Level.NOTE, text)

func warn(text:String) -> void:
	_UEditor.print_warn(text)
	_add(Level.WARN, text)

func error(text:String, toast := false) -> void:
	printerr(text)
	# A headless release child has no toaster; print=false since printerr already covered it.
	if toast and DisplayServer.get_name() != "headless":
		_UEditor.push_toast(text, 2 as _UEditor.ToastSeverity, false)
	_add(Level.ERROR, text)


func count(level:Level) -> int:
	var n = 0
	for entry in entries:
		if entry.level == level:
			n += 1
	return n


func _add(level:Level, text:String) -> void:
	entries.append({"level": level, "text": text})
	if not sink.is_valid():
		return
	if level == Level.INFO and not verbose:
		return
	if level >= Level.WARN:
		if _sent.has(text):
			return
		_sent[text] = true
	sink.call(text, level)

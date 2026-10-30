extends RefCounted
## One funnel for everything an export says. Without a sink every line goes to the Output panel.
## A sink (the console command) replaces Output - the editor console prints into it already - and
## gets NOTE/WARN/ERROR, INFO only when verbose. Repeated warnings and errors reach the sink once
## but are all kept in `entries`.

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
	if not sink.is_valid():
		print(text)
	_add(Level.INFO, text)

## Header and result lines - always shown.
func note(text:String) -> void:
	if not sink.is_valid():
		print_rich(text)
	_add(Level.NOTE, text)

func warn(text:String) -> void:
	if not sink.is_valid():
		_UEditor.print_warn(text)
	_add(Level.WARN, text)

func error(text:String, toast := false) -> void:
	if not sink.is_valid():
		printerr(text)
	# A headless release child has no toaster; print=false since the line is already reported.
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

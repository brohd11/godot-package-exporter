@tool
extends EditorScript

## Tests for GlobalRename.rename_in_text, the export pass that suffixes renamed global classes.
## Strings and comments must come through untouched, including literals that span lines - a
## per-line pass can't see those, which is how SweetUI's code templates got renamed.
##
##     load("res://addons/package_exporter/export_ignore/test/global_rename_test.gd").run_tests()

const GlobalRename = preload("res://addons/package_exporter/src/class/export/parse/gd/global_class/global_rename.gd")

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_code()
	_test_single_line_strings()
	_test_multiline_strings()
	_test_comments_and_words()

	var output:Array[String] = []
	output.append("global_rename: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_code() -> void:
	_check("type hint", _rename("var a: Foo"), "var a: Foo_abc")
	_check("call and second class", _rename("var b = Foo.new(Bar.X)"), "var b = Foo_abc.new(Bar_abc.X)")


static func _test_single_line_strings() -> void:
	_check("double quoted", _rename('var s = "Foo" + Foo.NAME'), 'var s = "Foo" + Foo_abc.NAME')
	_check("single quoted", _rename("var s = 'Foo'"), "var s = 'Foo'")


static func _test_multiline_strings() -> void:
	var src = 'const T = \\\n"class X:\n\tvar _ui:Foo\n\tfunc ui() -> Foo:\n" + Foo.NAME'
	var out = 'const T = \\\n"class X:\n\tvar _ui:Foo\n\tfunc ui() -> Foo:\n" + Foo_abc.NAME'
	_check("multi-line string kept, code after it renamed", _rename(src), out)

	src = 'const T = """\nvar x: Foo\n"""\nvar y: Foo'
	_check("triple quoted", _rename(src), 'const T = """\nvar x: Foo\n"""\nvar y: Foo_abc')

	src = 'const T = """\nsay " Foo\n"""\nvar y: Foo'
	_check("lone quote inside triple quoted", _rename(src), 'const T = """\nsay " Foo\n"""\nvar y: Foo_abc')

	src = 'const T = "say \\"hi\\"\nvar x: Foo\n"\nvar y: Foo'
	_check("escaped quote doesn't close the string", _rename(src), 'const T = "say \\"hi\\"\nvar x: Foo\n"\nvar y: Foo_abc')


static func _test_comments_and_words() -> void:
	_check("comment kept", _rename("var a: Foo # Foo here"), "var a: Foo_abc # Foo here")
	_check("whole word only", _rename("var a: FooBar = Foo_x"), "var a: FooBar = Foo_x")


static func _rename(text:String) -> String:
	var renames = []
	for name in ["Foo", "Bar"]:
		var regex = RegEx.new()
		regex.compile("\\b%s\\b" % name)
		renames.append([regex, name + "_abc"])
	return GlobalRename.rename_in_text(text, renames)


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
	else:
		_failures.append("%s: expected %s, got %s" % [label, var_to_str(expected), var_to_str(got)])

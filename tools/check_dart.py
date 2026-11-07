"""Static checks on the Dart sources.

There is no Dart SDK in this environment and the SDK host is unreachable, so
`flutter analyze` cannot be run here. This does not replace it -- it checks the
specific ways a hand edit across many files goes wrong, so that what reaches a
machine with the SDK fails for interesting reasons rather than for a missing
bracket.

Checks:
  1. Delimiters balance, with strings, comments and interpolation skipped.
  2. Every relative import resolves to a file that exists.
  3. Every class is declared exactly once across the library.
  4. Every type named in a constructor call is declared somewhere reachable.
  5. Required named parameters are supplied at each constructor call site.
  6. Identifiers that were removed are not referenced anywhere.

Run from the repository root:
    python tools/check_dart.py nutriapp
"""

import re
import sys
from pathlib import Path

# Names deleted during the rewrite. Any surviving reference is a compile error.
REMOVED = [
    (r"\bProfile\.(dailyTarget|dietType|allergens|name)\b",
     "the removed hardcoded Profile constants"),
    (r"\bSignInGate\b", "a class that was dropped before it shipped"),
    (r"\b_dayKey\b", "the private day-key helper, now logic.dayKey"),
    (r"\bDemoAccount\b",
     "the demo sign-in stub, replaced by real accounts on the backend"),
    (r"\bseedFoods\b",
     "the 30 hand-entered foods, replaced by the bundled HPB assets/foods.db"),
    (r"\bFood\([^)]*\bbrand:",
     "Food.brand, which the HPB dataset has no equivalent for"),
]

# SessionStore.clear and LocalDb.resetEverything both delete the user's diary.
# They are meant to be called from exactly two places -- the deliberate
# sign-out and Start over, both on the profile screen -- plus the one inside
# SessionStore itself. Anywhere else is almost certainly data loss by
# accident, which is the kind of mistake a user cannot undo, so it is worth a
# check of its own rather than a comment nobody reads.
DESTRUCTIVE = {
    r"SessionStore\.instance\.clear\(": {
        "lib/screens/profile_screen.dart",
    },
    r"LocalDb\.instance\.resetEverything\(": {
        "lib/session.dart",
        "lib/screens/profile_screen.dart",
    },
}

# Types that come from Flutter, Dart or a package rather than this library.
EXTERNAL = {
    "MaterialApp", "Scaffold", "AppBar", "Text", "Column", "Row", "Expanded",
    "Container", "Padding", "SizedBox", "ListView", "Center", "Icon",
    "IconButton", "TextButton", "ElevatedButton", "OutlinedButton",
    "FilledButton", "TextField", "TextFormField", "Form", "GlobalKey",
    "FormState", "TextEditingController", "PageController", "PageView",
    "InkWell", "GestureDetector", "Wrap", "Stack", "Positioned", "Card",
    "ListTile", "RadioListTile", "RadioGroup", "DropdownButtonFormField",
    "DropdownMenuItem", "FilterChip", "LinearProgressIndicator",
    "CircularProgressIndicator", "SnackBar", "ScaffoldMessenger",
    "MaterialPageRoute", "Navigator", "FloatingActionButton",
    "BottomNavigationBar", "BottomNavigationBarItem", "BoxDecoration",
    "Border", "BorderSide", "BorderRadius", "EdgeInsets", "Color", "Colors",
    "TextStyle", "ThemeData", "ColorScheme", "AppBarTheme",
    "InputDecoration", "InputDecorationTheme", "OutlineInputBorder",
    "FractionallySizedBox", "CustomPaint", "CustomPainter", "Paint", "Path",
    "Offset", "Size", "Canvas", "ValueKey", "Key", "Duration", "DateTime",
    "DateTimeRange", "DateUtils", "DateFormat", "Uuid", "Database",
    "ConflictAlgorithm", "AlertDialog", "Dialog", "MaterialTapTargetSize",
    "WidgetsBinding", "WidgetsBindingObserver", "AppLifecycleState",
    "StatelessWidget", "StatefulWidget", "State", "Widget", "BuildContext",
    "Future", "List", "Map", "Set", "String", "int", "double", "bool",
    "Object", "Iterable", "TextCapitalization", "TextInputType",
    "TextAlign", "TextDecoration", "FontWeight", "MainAxisAlignment",
    "CrossAxisAlignment", "MainAxisSize", "Alignment", "PaintingStyle",
    "Curves", "TimeOfDay", "Client", "Uri", "FontStyle", "Border",
    "NeverScrollableScrollPhysics", "Icons", "ValueChanged", "VoidCallback",
    "Color", "Theme", "ScrollPhysics", "SafeArea", "SingleChildScrollView",
    "Brightness", "StrutStyle", "Locale", "Exception", "Error",
}

failures = []
notes = []


def strip_code(text):
    """Blank out comments, strings and interpolation, keeping length the same.

    Length is preserved so reported offsets still line up with the original.
    """
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if ch == "/" and nxt == "*":
            depth = 1
            out[i] = out[i + 1] = " "
            i += 2
            while i < n and depth:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                if text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        if ch in "'\"":
            # Triple-quoted strings first, so a ''' is not read as two quotes.
            triple = text[i:i + 3]
            if triple in ("'''", '"""'):
                out[i] = out[i + 1] = out[i + 2] = " "
                i += 3
                while i < n and text[i:i + 3] != triple:
                    if text[i] != "\n":
                        out[i] = " "
                    i += 1
                for k in range(i, min(i + 3, n)):
                    out[k] = " "
                i += 3
                continue

            quote = ch
            out[i] = " "
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\":
                    out[i] = " "
                    if i + 1 < n:
                        out[i + 1] = " "
                    i += 2
                    continue
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
            i += 1
            continue
        i += 1
    return "".join(out)


def check_delimiters(path, code):
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                failures.append(f"{path}: stray '{ch}' on line {line}")
                return
            opened, opened_line = stack.pop()
            if opened != pairs[ch]:
                failures.append(
                    f"{path}: '{ch}' on line {line} closes '{opened}' "
                    f"opened on line {opened_line}")
                return
    if stack:
        opened, opened_line = stack[-1]
        failures.append(
            f"{path}: '{opened}' opened on line {opened_line} is never closed")


def required_named_params(code):
    """Map class name -> set of required named constructor parameters.

    Handles both forms this codebase uses: `required this.recipe` on a widget,
    where the field supplies the type, and `required String name` on a plain
    data class. The first has no type token at all, which is why a
    type-then-name pattern finds nothing.
    """
    out = {}
    for match in re.finditer(r"\bclass\s+(\w+)", code):
        name = match.group(1)
        # Find a constructor for this class and read its brace-delimited
        # named-parameter block.
        for ctor in re.finditer(
                rf"(?:const\s+)?{re.escape(name)}\s*\(\s*\{{(.*?)\}}\s*\)",
                code[match.end():match.end() + 6000], re.S):
            block = ctor.group(1)
            required = set()
            for fragment in re.findall(r"required\s+([^,}]+)", block):
                # Drop any default value, then take the final identifier:
                # "this.recipe" -> recipe, "List<String> tags" -> tags.
                declaration = fragment.split("=")[0].strip()
                identifiers = re.findall(r"\w+", declaration)
                if identifiers:
                    required.add(identifiers[-1])
            if required:
                out.setdefault(name, set()).update(required)
            break
    return out


def call_sites(code, class_name):
    """Yield (line, argument-text) for each `ClassName(...)` call."""
    for match in re.finditer(rf"\b{re.escape(class_name)}\s*\(", code):
        start = match.end()
        depth = 1
        i = start
        while i < len(code) and depth:
            if code[i] in "([{":
                depth += 1
            elif code[i] in ")]}":
                depth -= 1
            i += 1
        yield code[:match.start()].count("\n") + 1, code[start:i - 1]


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1

    root = Path(sys.argv[1]).resolve()
    lib = root / "lib"
    files = sorted(lib.rglob("*.dart")) + sorted((root / "test").rglob("*.dart"))
    if not files:
        print(f"No Dart files under {root}")
        return 1

    sources = {}
    stripped = {}
    for path in files:
        text = path.read_text(encoding="utf-8")
        sources[path] = text
        stripped[path] = strip_code(text)

    print(f"Checking {len(files)} Dart files under {root.name}\n")

    # 1. Delimiters
    for path in files:
        check_delimiters(path.relative_to(root), stripped[path])
    print("  1. delimiters balance")

    # 2. Imports resolve
    for path in files:
        for match in re.finditer(r"import\s+'([^']+)'", sources[path]):
            target = match.group(1)
            if target.startswith(("dart:", "package:")):
                if target.startswith("package:nutriapp_diary/"):
                    rel = target.split("package:nutriapp_diary/", 1)[1]
                    if not (lib / rel).exists():
                        failures.append(
                            f"{path.relative_to(root)}: import '{target}' "
                            f"does not exist")
                continue
            if not (path.parent / target).exists():
                failures.append(
                    f"{path.relative_to(root)}: import '{target}' does not exist")
    print("  2. imports resolve")

    # 3. Classes declared once
    declared = {}
    for path in files:
        for match in re.finditer(r"\bclass\s+(\w+)", stripped[path]):
            name = match.group(1)
            if name in declared:
                failures.append(
                    f"{name} is declared in both "
                    f"{declared[name].relative_to(root)} and "
                    f"{path.relative_to(root)}")
            declared[name] = path
    print(f"  3. {len(declared)} classes each declared once")

    # 4. Constructor targets exist
    known = set(declared) | EXTERNAL
    unknown = {}
    for path in files:
        code = stripped[path]
        for match in re.finditer(r"(?<![\w.])([A-Z]\w+)\s*\(", code):
            name = match.group(1)
            if name in known or name.startswith("_"):
                continue
            unknown.setdefault(name, set()).add(path.relative_to(root))
    for name, where in sorted(unknown.items()):
        notes.append(f"{name} used in {', '.join(str(w) for w in sorted(where))} "
                     f"- not declared here; assumed external")
    print(f"  4. constructor targets resolved ({len(unknown)} assumed external)")

    # 5. Required named parameters at each call site
    all_code = "\n".join(stripped[p] for p in files if p.is_relative_to(lib))
    requirements = required_named_params(all_code)
    watched = {"RecipeDetailScreen", "SavedScreen", "OnboardingScreen",
               "AboutYouScreen", "ProfileReviewScreen", "DietaryGoalScreen",
               "DietaryPreferencesScreen", "DietaryRestrictionsScreen",
               "WireVBars", "WireSparkline", "WireStackBar", "WireField",
               "UserProfile", "WeightEntry", "DayTotal", "TrendSummary",
               "Recipe", "Entry", "Food", "Nutrition", "DaySummary"}
    checked = 0
    for name in sorted(watched & set(requirements)):
        needed = requirements[name]
        for path in files:
            for line, args in call_sites(stripped[path], name):
                # The constructor's own declaration looks like a call site.
                # It is the only one that declares parameters, so it is the
                # only one containing "required" or "super.key".
                if "required" in args or "super.key" in args:
                    continue
                if not args.strip():
                    failures.append(
                        f"{path.relative_to(root)}:{line}: {name}() called "
                        f"with no arguments but requires {sorted(needed)}")
                    checked += 1
                    continue
                # A call with no named arguments at all is positional; this
                # codebase has none, but do not guess about one.
                if not re.search(r"\w+\s*:", args):
                    continue
                missing = needed - set(re.findall(r"(\w+)\s*:", args))
                if missing:
                    failures.append(
                        f"{path.relative_to(root)}:{line}: {name}(...) is "
                        f"missing required {sorted(missing)}")
                checked += 1
    print(f"  5. {checked} call sites checked against required parameters "
          f"({len(watched & set(requirements))} classes)")

    # 6. Removed identifiers
    for pattern, description in REMOVED:
        for path in files:
            for match in re.finditer(pattern, stripped[path]):
                line = stripped[path][:match.start()].count("\n") + 1
                failures.append(
                    f"{path.relative_to(root)}:{line}: still references "
                    f"{description}: {match.group(0)}")
    print("  6. no references to removed identifiers")

    # 7. Redundant const inside a const context.
    #    Everything inside `const X(...)` is already constant, so an inner
    #    `const` is redundant and the analyser reports unnecessary_const. Easy
    #    to leave behind when adding an outer const to an existing widget.
    redundant = 0
    for path in files:
        code = stripped[path]
        for match in re.finditer(r"\bconst\s+[A-Z]\w*\s*\(", code):
            start = match.end()
            depth = 1
            i = start
            while i < len(code) and depth:
                if code[i] in "([{":
                    depth += 1
                elif code[i] in ")]}":
                    depth -= 1
                i += 1
            args = code[start:i - 1]
            # A constructor declaration is not an invocation. Its default
            # values are a const context of their own, where `const` is not
            # redundant, and the analyser does not flag them. Declarations are
            # the only ones that bind fields or forward to super.
            if "this." in args or "super." in args:
                continue
            for inner in re.finditer(r"\bconst\b", args):
                line = code[:start + inner.start()].count("\n") + 1
                failures.append(
                    f"{path.relative_to(root)}:{line}: redundant 'const' "
                    f"inside a const context ({match.group(0).strip()}...)")
            redundant += 1
    print(f"  7. {redundant} const contexts checked for a redundant inner const")

    # 8. Calls that destroy the user's local data stay where they belong.
    destructive_calls = 0
    for pattern, allowed in DESTRUCTIVE.items():
        for path in files:
            rel = path.relative_to(root).as_posix()
            hits = len(re.findall(pattern, stripped[path]))
            if not hits:
                continue
            destructive_calls += hits
            if rel not in allowed:
                call = pattern.replace("\\", "") + ")"
                failures.append(
                    f"{rel}: calls {call}, which deletes the user's diary. "
                    f"Allowed only in: {', '.join(sorted(allowed))}")
    print(f"  8. {destructive_calls} data-destroying calls all in "
          f"permitted files")

    # 9. Every relative import is actually used.
    #
    # The lint a deletion leaves behind: a file stops using a helper, the
    # helper goes, and the import stays pointing at it. Only relative imports
    # are checked, because the top-level names of a package cannot be read
    # from here without resolving it.
    # Patterns are anchored to column zero and must not cross a line break:
    # a character class containing \s would let `^` match an earlier line and
    # run on into an indented method, which collects every method name in the
    # file and matches `if`, `for` and `return` in the importer -- so every
    # import looks used and the check silently passes everything. It did, the
    # first time it was written. Hence TYPE_CHARS, which excludes newlines.
    TYPE_CHARS = r"[\w<>?,\[\]. ]"
    KEYWORDS = {"if", "for", "while", "switch", "return", "assert", "catch",
                "else", "do", "try", "super", "this", "new", "await"}
    top_level = {}
    for path in files:
        names = set()
        code = stripped[path]
        patterns = (
            r"^(?:abstract\s+)?(?:class|enum|mixin|extension|typedef)\s+(\w+)",
            rf"^(?:const|final|var)\s+{TYPE_CHARS}*?\b(\w+)\s*=",
            rf"^(?:{TYPE_CHARS}+\s+)?(\w+)\s*\(",
        )
        for pattern in patterns:
            names.update(re.findall(pattern, code, re.MULTILINE))
        # A leading underscore makes a name private to its own file, so it can
        # never be the reason another file imports it.
        top_level[path] = {n for n in names
                           if n and not n.startswith("_")
                           and n not in KEYWORDS}

    import_count = 0
    for path in files:
        code = stripped[path]
        for match in re.finditer(r"import\s+'([^']+)'", sources[path]):
            target = match.group(1)
            if target.startswith(("dart:", "package:")):
                continue
            resolved = (path.parent / target).resolve()
            if resolved not in top_level:
                continue
            import_count += 1
            exported = top_level[resolved]
            body = code.replace(match.group(0), "")
            if exported and not any(
                    re.search(rf"\b{re.escape(name)}\b", body)
                    for name in exported):
                failures.append(
                    f"{path.relative_to(root)}: imports '{target}' but uses "
                    f"nothing from it")
    print(f"  9. {import_count} relative imports all used")

    if notes:
        print("\nNotes:")
        for note in notes:
            print(f"  - {note}")

    print()
    if failures:
        print(f"{len(failures)} problem(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("No problems found. This is not a substitute for `flutter analyze`.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

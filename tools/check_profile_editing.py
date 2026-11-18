"""Check the per-field profile editing, which has no compiler to catch it here.

    python tools/check_profile_editing.py nutriapp

The profile screen now edits one field at a time instead of replaying the
setup flow. Three things about that arrangement fail quietly rather than
loudly, which is why they are checked here:

  1. A field wired to an editor that never saves. The row is tappable, the
     dialog opens, the value is typed, and nothing is written. Nothing on
     screen says so -- the old value is simply still there afterwards, which
     reads as "I must have tapped Cancel".

  2. A field saved with `copyWith` instead of `applyProfileChange`. The new
     height is stored, and the calorie target, macro split and allergen list
     still describe the old answers. The screen shows a consistent-looking
     profile whose numbers no longer follow from each other. This is the
     worst of the three: everything looks right.

  3. An option offered with no rule behind it. Adding "Extremely Active" to
     `activityOptions` without an entry in `activityMultipliers` gives a
     choice that is recorded, displayed, and silently computed as though it
     were the default. A wrong calorie target with nothing visibly wrong.

None of these is a syntax error, so `check_dart.py` will not see them and
neither would a build. Run this with the other checks.
"""

import re
import sys
from pathlib import Path


def read(path):
    return path.read_text(encoding="utf-8")


def check_editors_save(profile_screen, problems, notes):
    """Every `onTap:` handler must end at `_apply`, via `applyProfileChange`.

    `_logWeight` is allowed its own path: it writes a weight-log entry as
    well, which no other field does.
    """
    text = read(profile_screen)

    tapped = sorted(set(re.findall(r"onTap:\s*(_\w+)", text)))
    if not tapped:
        problems.append("profile_screen.dart: no tappable fields found at "
                        "all -- per-field editing is not wired up")
        return
    notes.append(f"{len(tapped)} tappable field(s): {', '.join(tapped)}")

    for name in tapped:
        # The method body: from its signature to the next top-level method.
        match = re.search(
            rf"\n  (?:Future<void>|void|Widget)\s+{re.escape(name)}\s*\(",
            text)
        if not match:
            problems.append(
                f"profile_screen.dart: a field taps {name}, which is not "
                f"defined in this file")
            continue
        start = match.start()
        following = re.search(r"\n  (?:Future<[^>]*>|void|Widget|String|bool)"
                              r"\s+_?\w+\s*\(", text[start + 4:])
        body = text[start: start + 4 + following.start()] if following \
            else text[start:]

        if "_apply(" not in body and "LocalDb.instance" not in body:
            problems.append(
                f"profile_screen.dart: {name} opens an editor but never "
                f"saves -- the value typed would be discarded silently")
            continue

        if "copyWith(" in body and name not in ("_editTarget",):
            problems.append(
                f"profile_screen.dart: {name} saves with copyWith, which "
                f"leaves the calorie target and allergen list describing "
                f"the previous answers -- use applyProfileChange")


def check_one_rebuild_path(lib, problems, notes):
    """Only profile_fields.dart and the setup flow may call buildProfile.

    Anywhere else means a screen assembling a profile by hand, listing every
    field -- a list that silently goes stale when the model gains one.
    """
    allowed = {"profile_fields.dart", "onboarding_screen.dart"}
    # The declaration in logic.dart is not a call. Removed before counting,
    # rather than exempting the whole file, so a stray call inside logic.dart
    # would still be reported.
    declaration = re.compile(r"UserProfile\s+buildProfile\s*\(")
    callers = []
    for path in sorted(lib.rglob("*.dart")):
        text = declaration.sub("", read(path))
        if "buildProfile(" in text:
            callers.append(path)
    stray = [p for p in callers if p.name not in allowed]
    for path in stray:
        problems.append(
            f"{path.name}: calls buildProfile directly. Route profile edits "
            f"through applyProfileChange so derived values stay in step")
    notes.append(f"buildProfile called from "
                 f"{', '.join(sorted(p.name for p in callers)) or 'nowhere'}")


def check_options_have_rules(lib, problems, notes):
    """Every activity level and goal offered must have a rule behind it."""
    fields = read(lib / "profile_fields.dart")
    logic = read(lib / "logic.dart")

    def listed(name, source):
        match = re.search(rf"{name}\s*=\s*\[(.*?)\]", source, re.DOTALL)
        return re.findall(r"'([^']+)'", match.group(1)) if match else []

    def keys(name):
        match = re.search(rf"{name}\s*=\s*\{{(.*?)\}};", logic, re.DOTALL)
        return re.findall(r"'([^']+)'\s*:", match.group(1)) if match else []

    for options, rules, what in (
            ("activityOptions", "activityMultipliers", "multiplier"),
            ("goalOptions", "goalAdjustments", "calorie adjustment")):
        offered = listed(options, fields)
        known = keys(rules)
        if not offered or not known:
            problems.append(f"could not read {options} or {rules}")
            continue
        missing = [o for o in offered if o not in known]
        for option in missing:
            problems.append(
                f"'{option}' is offered in {options} but has no {what} in "
                f"{rules} -- it would be accepted and silently treated as "
                f"the default")
        notes.append(f"{len(offered)} {options} all have a {what}"
                     if not missing else f"{options}: {len(missing)} without "
                     f"a {what}")


def check_no_duplicate_option_lists(lib, problems, notes):
    """The onboarding steps must not carry their own copies of the lists."""
    markers = {
        "'Lose Weight'": "goalOptions",
        "'Sedentary'": "activityOptions",
        "'Pescatarian'": "preferenceOptions",
        "'Shellfish'": "restrictionOptions",
        "'Non-binary'": "genderOptions",
    }
    fields = lib / "profile_fields.dart"
    for path in sorted(lib.rglob("*.dart")):
        if path == fields:
            continue
        text = read(path)
        for marker, canonical in markers.items():
            # One mention is a comparison; a list is several in one literal.
            if text.count(marker) and re.search(
                    rf"\[\s*(?:[^\]]*,\s*)?{re.escape(marker)}", text):
                problems.append(
                    f"{path.name}: has its own copy of a list that belongs "
                    f"in {canonical}. Two copies drift")
    notes.append("option lists exist only in profile_fields.dart")


def check_shared_names_are_imported(lib, problems, notes):
    """A file using a shared rule must import the file that defines it.

    Added because exactly this slipped through. A step screen was changed to
    call `goalUsesTargetWeight` and the import was not added; both static
    checks passed, because one verifies that the imports a file HAS resolve
    and the other that each is used -- neither asks whether a name a file
    USES was imported from anywhere. `flutter analyze` caught it, which is
    the right tool for it, but only once somebody ran a build.
    """
    fields = lib / "profile_fields.dart"
    source = read(fields)

    # The declarations this file exports, taken from its own text rather
    # than listed here, so a rule added later is covered without edit.
    exported = set()
    for pattern in (
            r"^const\s+(?:List<String>|int|double|Object)\s+(\w+)",
            r"^bool\s+get\s+(\w+)",
            r"^String\?\s+(\w+)\s*\(",
            r"^bool\s+(\w+)\s*\(",
            r"^UserProfile\s+(\w+)\s*\("):
        exported.update(re.findall(pattern, source, re.M))
    exported = {n for n in exported if not n.startswith("_")}
    if not exported:
        problems.append("profile_fields.dart: no exported names found; the "
                        "import check cannot run")
        return

    for path in sorted(lib.rglob("*.dart")):
        if path == fields:
            continue
        text = read(path)
        # Comments mention these names by design; only code counts.
        code = re.sub(r"//[^\n]*", "", text)
        used = sorted(n for n in exported if re.search(rf"\b{n}\b", code))
        # Match the import STATEMENT, not the filename anywhere in the file.
        # The original bug was introduced by a helper that skipped adding the
        # import when the text already mentioned profile_fields.dart -- and
        # the comment it had just written mentioned it. The first version of
        # this check repeated the mistake exactly, and missed the fault it
        # was written to catch.
        imported = re.search(r"import\s+'[^']*profile_fields\.dart'", text)
        if used and not imported:
            problems.append(
                f"{path.name}: uses {', '.join(used[:3])} but does not "
                f"import profile_fields.dart")
    notes.append(f"{len(exported)} shared name(s) imported wherever used")


def check_bounds_live_in_one_place(lib, problems, notes):
    """The numeric bounds must not reappear as literals in a screen."""
    fields = lib / "profile_fields.dart"
    suspicious = re.compile(
        r"(?:age|height|weight)\s*[<>]=?\s*(?:13|120|90|250|25|400)\b")
    for path in sorted(lib.rglob("*.dart")):
        if path == fields:
            continue
        for number, line in enumerate(read(path).splitlines(), 1):
            if suspicious.search(line):
                problems.append(
                    f"{path.name}:{number}: compares against a bound "
                    f"literal. The bounds belong in profile_fields.dart, "
                    f"where both edit paths read them")
    notes.append("bounds compared only inside profile_fields.dart")


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    root = Path(sys.argv[1]).resolve()
    lib = root / "lib" if (root / "lib").is_dir() else root
    if not lib.is_dir():
        print(f"no lib/ under {root}")
        return 1

    profile_screen = lib / "screens" / "profile_screen.dart"
    if not profile_screen.exists():
        print(f"missing {profile_screen}")
        return 1

    problems, notes = [], []
    check_editors_save(profile_screen, problems, notes)
    check_one_rebuild_path(lib, problems, notes)
    check_options_have_rules(lib, problems, notes)
    check_no_duplicate_option_lists(lib, problems, notes)
    check_shared_names_are_imported(lib, problems, notes)
    check_bounds_live_in_one_place(lib, problems, notes)

    print(f"Checking per-field profile editing under {lib}\n")
    for note in notes:
        print(f"  - {note}")
    print()
    if problems:
        print(f"{len(problems)} problem(s):")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("No problems found. This is not a substitute for `flutter analyze`.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

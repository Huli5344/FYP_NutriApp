/// What a profile field is: its options, its bounds, and how a change to it
/// is applied.
///
/// This file exists because the profile can now be edited two ways — the
/// guided setup flow, which runs once, and the profile screen, where a single
/// field can be corrected without answering everything again. Two forms over
/// the same fields is exactly the arrangement that drifts: the bounds get
/// written twice, one copy is widened, and the two disagree about what is
/// valid depending on which screen you happened to use.
///
/// It had already started. The weight bounds existed in both
/// `onboarding_screen.dart` and `profile_screen.dart`, and the option lists
/// were local variables inside each onboarding step, reachable from nowhere
/// else. So the rules live here now, once, and both paths read them.
///
/// Nothing in here draws anything. It is the answer to "what is allowed",
/// not "what does it look like".
library;

import 'logic.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// Options
//
// Each list was previously a local variable inside the onboarding step that
// displayed it. Moving them here is what lets the per-field editor offer the
// same choices without copying them.
// ---------------------------------------------------------------------------

const List<String> goalOptions = [
  'Lose Weight',
  'Maintain Weight',
  'Gain Weight',
  'Build Muscle',
  'Eat Healthier',
];

const List<String> genderOptions = [
  'Female',
  'Male',
  'Non-binary',
  'Prefer not to say',
];

/// Must match the keys of `activityMultipliers` in logic.dart: an option with
/// no multiplier silently falls back to the default, so the choice would
/// appear to be recorded and change nothing. `activityOptionsAreComplete`
/// below is what makes that a visible failure rather than a quiet one.
const List<String> activityOptions = [
  'Sedentary',
  'Lightly Active',
  'Moderately Active',
  'Very Active',
];

/// Every option maps to a tag the recipe data actually carries, via
/// `dietTokens` in logic.dart. An option with no counterpart in the data could
/// be chosen and would then change nothing, which is worse than not offering
/// it at all.
const List<String> preferenceOptions = [
  'Vegetarian',
  'Vegan',
  'Pescatarian',
  'Halal',
  'High protein',
  'High fibre',
  'Low carb',
];

const List<String> restrictionOptions = [
  'Peanuts',
  'Tree Nuts',
  'Dairy',
  'Eggs',
  'Gluten',
  'Soy',
  'Fish',
  'Shellfish',
  'Sesame',
];

/// True when every activity option has a multiplier behind it.
///
/// Checked by the test suite rather than at runtime. If somebody adds an
/// option here and forgets `activityMultipliers`, the app would still accept
/// the choice and quietly compute the target as though it were the default —
/// a wrong calorie target with nothing on screen to suggest it.
bool get activityOptionsAreComplete =>
    activityOptions.every(activityMultipliers.containsKey);

/// The same for goals and `goalAdjustments`.
bool get goalOptionsAreComplete =>
    goalOptions.every(goalAdjustments.containsKey);

// ---------------------------------------------------------------------------
// Bounds
//
// Deliberately wide. They exist to catch a centimetre value typed into the
// kilogram box, not to judge anyone's body.
// ---------------------------------------------------------------------------

const int minAge = 13;
const int maxAge = 120;

const double minHeightCm = 90;
const double maxHeightCm = 250;

const double minWeightKg = 25;
const double maxWeightKg = 400;

// ---------------------------------------------------------------------------
// Validation
//
// Each returns null when the input is acceptable, or the sentence to show.
// The message is part of the rule: a bound without an explanation leaves
// somebody guessing which direction to move.
// ---------------------------------------------------------------------------

String? validateName(String raw) {
  if (raw.trim().isEmpty) return 'Please enter your name.';
  return null;
}

String? validateAge(String raw) {
  final value = int.tryParse(raw.trim());
  if (value == null || value < minAge || value > maxAge) {
    return 'Please enter an age between $minAge and $maxAge.';
  }
  return null;
}

String? validateHeight(String raw) {
  final value = double.tryParse(raw.trim());
  if (value == null || value < minHeightCm || value > maxHeightCm) {
    return 'Please enter a height in centimetres, between '
        '${minHeightCm.toInt()} and ${maxHeightCm.toInt()}.';
  }
  return null;
}

String? validateWeight(String raw) {
  final value = double.tryParse(raw.trim());
  if (value == null || value < minWeightKg || value > maxWeightKg) {
    return 'Please enter a weight in kilograms, between '
        '${minWeightKg.toInt()} and ${maxWeightKg.toInt()}.';
  }
  return null;
}

/// A target weight may be left blank, which clears it.
String? validateTargetWeight(String raw) {
  if (raw.trim().isEmpty) return null;
  final value = double.tryParse(raw.trim());
  if (value == null || value < minWeightKg || value > maxWeightKg) {
    return 'Please enter a target weight in kilograms, or leave it empty.';
  }
  return null;
}

String? validateDailyTarget(String raw) {
  final value = int.tryParse(raw.trim());
  if (value == null || value < minDailyTarget || value > maxDailyTarget) {
    return 'Enter a target between $minDailyTarget and $maxDailyTarget kcal.';
  }
  return null;
}

/// Only some goals are about reaching a particular weight. For the others a
/// target weight is not asked for, and is cleared if one was already set —
/// leaving a stale figure attached to "Eat Healthier" would show a goal the
/// person is no longer working towards.
bool goalUsesTargetWeight(String goal) =>
    goal == 'Lose Weight' || goal == 'Gain Weight' || goal == 'Build Muscle';

// ---------------------------------------------------------------------------
// Applying a change
// ---------------------------------------------------------------------------

/// Distinguishes "leave this field alone" from "set this field to null".
/// Gender and target weight are both nullable, so a plain default of null
/// could not tell the two apart.
const Object _unset = Object();

/// Return `current` with one or more fields changed, everything derived from
/// them recomputed, and a manually set calorie target preserved.
///
/// Every edit goes through here rather than through `copyWith`, and that is
/// the point. `copyWith` would change height and leave the calorie target,
/// the macro split and the allergen list describing the old answers — the
/// screen would show the new height beside a target computed from the old
/// one, and nothing would look wrong. Rebuilding through `buildProfile`
/// means the derived values cannot fall out of step with what they were
/// derived from.
///
/// A target the person set by hand is kept. Someone who overrode the figure
/// once should not have it silently recalculated because they corrected a
/// typo in their height.
UserProfile applyProfileChange(
  UserProfile current, {
  String? name,
  int? age,
  Object? gender = _unset,
  double? heightCm,
  double? weightKg,
  String? activityLevel,
  String? goal,
  Object? targetWeightKg = _unset,
  List<String>? preferences,
  List<String>? restrictions,
}) {
  final newGoal = goal ?? current.goal;

  double? newTargetWeight;
  if (identical(targetWeightKg, _unset)) {
    newTargetWeight = current.targetWeightKg;
  } else {
    newTargetWeight = targetWeightKg as double?;
  }
  // A goal that is not about reaching a weight does not carry one.
  if (!goalUsesTargetWeight(newGoal)) newTargetWeight = null;

  return buildProfile(
    name: name ?? current.name,
    email: current.email,
    age: age ?? current.age,
    gender: identical(gender, _unset)
        ? current.gender
        : gender as String?,
    heightCm: heightCm ?? current.heightCm,
    weightKg: weightKg ?? current.weightKg,
    activityLevel: activityLevel ?? current.activityLevel,
    goal: newGoal,
    targetWeightKg: newTargetWeight,
    preferences: preferences ?? current.preferences,
    restrictions: restrictions ?? current.restrictions,
    manualTargetKcal: current.targetIsManual ? current.targetKcal : null,
  );
}

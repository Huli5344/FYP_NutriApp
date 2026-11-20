/// Build-time configuration for talking to Gemini directly.
///
/// This is no longer how the app normally reaches NutriBot. The key lives on
/// the Flask backend and the app calls `/api/chat`, so a build with no flags
/// has a working assistant and the APK carries no secret. See BackendClient,
/// and main.dart, where the choice between the two is made.
///
/// Setting GEMINI_API_KEY here overrides that and goes to Gemini directly:
///
///     flutter run --dart-define=GEMINI_API_KEY=...
///
/// which is for working on the chat without a server running. A key passed
/// this way IS compiled into the binary and can be read back out of the APK,
/// so a build made this way is not one to hand to anybody.
class AppConfig {
  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const String geminiModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-3.5-flash-lite',
  );

  static bool get hasApiKey => geminiApiKey.isNotEmpty;
}

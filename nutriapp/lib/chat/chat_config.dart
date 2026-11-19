/// Build-time configuration, injected with:
///   flutter run --dart-define-from-file=env.json
///
/// SECURITY: a key compiled into an app can be extracted by anyone who has the
/// APK. This is acceptable for local development only. Before publishing,
/// replace GeminiClient with a client that calls your own backend proxy
/// (see AiClient) so the key never ships in the app.
class AppConfig {
  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const String geminiModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-3.5-flash-lite',
  );

  static bool get hasApiKey => geminiApiKey.isNotEmpty;
}

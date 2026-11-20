"""NutriBot's connection to Gemini, held on the server.

The key used to be compiled into the APK with `--dart-define`, which meant
two things: anyone with the APK could extract it and spend it, and an app
built without the flag had no assistant at all. Both are fixed by the key
living here instead. The app sends a conversation; this module adds the key
and the system prompt and streams the reply back.

Three things are deliberately on this side of the wire rather than the app's:

  * The key, which is the whole point.
  * The system prompt, including the safety instructions. A modified client
    can send whatever history it likes, but it cannot replace the rules the
    model is given, because it never sends them.
  * The limits. `clean_history` is not tidying up after a well-behaved app;
    it is the only thing standing between a hand-written request and an
    unbounded bill.

No new dependency: urllib streams server-sent events perfectly well, and
requirements.txt is short on purpose.
"""

import json
import os
import urllib.error
import urllib.request

# Matches the client's own default so a build that still talks to Gemini
# directly and one that goes through here answer the same way.
DEFAULT_MODEL = "gemini-3.5-flash-lite"

# How long to wait for each read from the stream, not for the whole reply:
# a long answer arrives as many small chunks, and the clock restarts on each.
TIMEOUT_SECONDS = 30

# What a request may carry. These bound the cost of a single call: the app
# already trims to ten turns, so a request near these limits is not the app.
MAX_MESSAGES = 24
MAX_CHARS_PER_MESSAGE = 4000
MAX_CHARS_TOTAL = 24000

MAX_OUTPUT_TOKENS = 1024
TEMPERATURE = 0.6

# Kept in step with nutriapp/lib/chat/system_prompt.dart by
# tools/check_system_prompt.py, which fails if the two drift apart. The copy
# in the app is still used by a development build that talks to Gemini
# directly; this one is what every real conversation gets.
SYSTEM_PROMPT = """\
You are NutriBot, a friendly, evidence-based diet and nutrition assistant.

Style:
- Be concise and practical. Use short paragraphs, bullet lists and simple tables in Markdown.
- Give ranges and typical values rather than false precision. Say when numbers are estimates.
- Ask one brief clarifying question when key details (goal, allergies, diet type) are missing and matter.

Scope:
- Answer questions about food, nutrition, meal planning, healthy eating habits, and general weight and fitness nutrition.
- Politely decline unrelated topics and steer back to nutrition.

Safety:
- You are not a doctor or registered dietitian. Do not diagnose conditions or prescribe treatment.
- For pregnancy or breastfeeding, children, diabetes, kidney or heart disease, eating disorders, food allergies, or medication interactions, give general information only and recommend consulting a qualified healthcare professional.
- Never recommend crash diets, extreme calorie restriction, fasting for minors, or unsafe supplement doses. If a goal is unsafe, explain why and offer a safer alternative.
- If the user shows signs of disordered eating or distress, respond with care, avoid numbers or restriction tips, and encourage reaching out to a professional or a trusted person.
- Always respect stated allergies and dietary preferences.
"""


class AiError(Exception):
    """A failure with a message that is safe to show to the user.

    Every message raised from this module is written to be read by somebody
    using the app. None of them contains the key, the URL, or any part of
    the upstream response -- a 400 from Gemini can quote the request back,
    and the request contains the conversation.
    """

    def __init__(self, message, status=502):
        super().__init__(message)
        self.message = message
        self.status = status


def api_key():
    """The key, or None. Read per call so a restart is all a rotation needs."""
    return (os.environ.get("GEMINI_API_KEY") or "").strip() or None


def model_name():
    return (os.environ.get("GEMINI_MODEL") or "").strip() or DEFAULT_MODEL


def is_configured():
    return api_key() is not None


def clean_history(raw):
    """Validate what the app sent into something safe to forward.

    Rejects rather than repairs where the shape is wrong, and trims where it
    is merely too big. The app's own `_buildHistory` already does most of
    this; doing it again here is the point, because the app is the part an
    attacker controls.
    """
    if not isinstance(raw, list):
        raise AiError("The request was malformed.", 400)

    cleaned = []
    for item in raw:
        if not isinstance(item, dict):
            raise AiError("The request was malformed.", 400)
        role = item.get("role")
        text = item.get("text")
        if role not in ("user", "model") or not isinstance(text, str):
            raise AiError("The request was malformed.", 400)
        text = text.strip()
        if not text:
            continue
        if len(text) > MAX_CHARS_PER_MESSAGE:
            raise AiError("That message is too long.", 413)
        cleaned.append({"role": role, "text": text})

    # Keep the most recent turns: the end of a conversation is the part the
    # next answer depends on.
    cleaned = cleaned[-MAX_MESSAGES:]

    # Gemini requires the first turn to be the user's.
    while cleaned and cleaned[0]["role"] != "user":
        cleaned.pop(0)

    if not cleaned:
        raise AiError("There was nothing to send.", 400)
    if cleaned[-1]["role"] != "user":
        raise AiError("The request was malformed.", 400)
    if sum(len(m["text"]) for m in cleaned) > MAX_CHARS_TOTAL:
        raise AiError("That conversation is too long. Start a new one.", 413)
    return cleaned


def _request_body(history):
    return json.dumps({
        "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": [
            {"role": m["role"], "parts": [{"text": m["text"]}]}
            for m in history
        ],
        "generationConfig": {
            "temperature": TEMPERATURE,
            "maxOutputTokens": MAX_OUTPUT_TOKENS,
        },
    }).encode("utf-8")


def _friendly(status):
    """Upstream status -> something worth showing someone.

    Deliberately vague about 400 and 403. Both mean the server is
    misconfigured, which is not the user's problem to debug and not
    something to describe to whoever is asking.
    """
    if status in (400, 401, 403):
        return "The assistant is not configured correctly. Please tell the app owner."
    if status == 404:
        return "The assistant is not available right now."
    if status == 429:
        return "The assistant is busy right now. Please try again in a minute."
    if status in (500, 502, 503, 504):
        return "The assistant is busy right now. Please try again shortly."
    return "The assistant could not answer just now."


def _deltas(payload):
    """Text pieces out of one decoded SSE event."""
    if (payload.get("promptFeedback") or {}).get("blockReason"):
        raise AiError("That message was blocked by the safety filter.", 200)

    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        return

    candidate = candidates[0]
    if not isinstance(candidate, dict):
        return

    parts = (candidate.get("content") or {}).get("parts")
    if isinstance(parts, list):
        for part in parts:
            if isinstance(part, dict):
                text = part.get("text")
                if isinstance(text, str) and text:
                    yield text

    if candidate.get("finishReason") == "SAFETY":
        raise AiError("The reply was stopped by the safety filter.", 200)


def stream_reply(history, *, opener=None):
    """Yield the reply a piece at a time.

    `opener` exists for the tests, which stand a fake Gemini in front of this
    rather than reaching the real one: a test that needs the network is a
    test that fails on a train, and one that spends the key is worse.
    """
    key = api_key()
    if key is None:
        raise AiError("The assistant is not set up on this server.", 503)

    url = ("https://generativelanguage.googleapis.com/v1beta/models/"
           f"{model_name()}:streamGenerateContent?alt=sse")

    request = urllib.request.Request(
        url,
        data=_request_body(history),
        headers={
            "Content-Type": "application/json",
            # In a header, never the query string: a key in a URL is written
            # to every access log and proxy it passes through on the way.
            "x-goog-api-key": key,
        },
        method="POST",
    )

    open_stream = opener or urllib.request.urlopen
    try:
        response = open_stream(request, timeout=TIMEOUT_SECONDS)
    except urllib.error.HTTPError as exc:
        raise AiError(_friendly(exc.code)) from None
    except urllib.error.URLError:
        raise AiError("Could not reach the assistant. Please try again.") from None
    except TimeoutError:
        raise AiError("The assistant took too long to answer.", 504) from None

    try:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload:
                continue
            try:
                decoded = json.loads(payload)
            except ValueError:
                continue
            if isinstance(decoded, dict):
                yield from _deltas(decoded)
    finally:
        close = getattr(response, "close", None)
        if close:
            close()

"""
MoodMuse Lambda handler
Calls Amazon Bedrock Nova Micro (poem) + Nova Canvas (image).
Returns { poem: str, image_b64: str } or { error: str }.

MOCK_MODE
---------
Set env var MOCK_MODE=true (the default) to skip all Bedrock calls and return
hardcoded sample data. This lets the full app run locally without AWS credentials.
Set MOCK_MODE=false (or any other value) to use real Bedrock.

The boto3 client is lazy-instantiated — it is only created when MOCK_MODE is
false, so local testing never requires credentials or network access.

Spec fixes applied:
  - Nova Canvas request explicitly sets width=512, height=512, quality="standard"
    to keep generation time well under the HTTP API 30s hard cap.
  - Lambda timeout should be set to 29s in console/CLI (not configurable here).
  - CORS headers are set here (Lambda-side only) — do NOT also enable CORS on
    API Gateway, or the browser will see duplicate headers and block the request.
  - Titan Image Generator v1 fallback path included; swap MODEL_IMAGE constant
    if Nova Canvas access is unavailable in your account.
"""

import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── MOCK_MODE — defaults to "true" so local dev works without AWS credentials ──
# Set MOCK_MODE=false in the Lambda console environment variables when deploying.
MOCK_MODE: bool = os.environ.get("MOCK_MODE", "true").lower() == "true"

# ── Model IDs ──────────────────────────────────────────────────────────────────
MODEL_TEXT  = "amazon.nova-micro-v1:0"
MODEL_IMAGE = "amazon.nova-canvas-v1:0"
# Fallback: MODEL_IMAGE = "amazon.titan-image-generator-v1"

# ── Lazy Bedrock client — only instantiated when MOCK_MODE is false ────────────
# This avoids any boto3/credential lookup during local testing.
_bedrock = None

def _get_bedrock():
    global _bedrock
    if _bedrock is None:
        import boto3
        _bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
    return _bedrock

# ── Mock data ──────────────────────────────────────────────────────────────────
MOCK_POEM = """\
Rain taps the window like a soft reminder,
that stillness too has its own kind of sound.
The coffee grows cold on the sill beside me,
while Sunday unravels without being found.
Grey light and silence, an easy communion,
the world outside blurred to a watercolour smear.
There is nowhere to be on a morning like this one,
only here, only now, only beautifully here."""

# 64×64 solid purple square PNG, base64-encoded
MOCK_IMAGE_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsIts"
    "F+NZxgi+hcEKLF3zWgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
    "BAQEBAQELgvtb+G0ZukSEgAAAABJRU5ErkJggg=="
)

# ── CORS headers (added to every response) ────────────────────────────────────
CORS_HEADERS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type":                 "application/json",
}


def _respond(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers":    CORS_HEADERS,
        "body":       json.dumps(body),
    }


# ── Real Bedrock helpers (only called when MOCK_MODE = false) ──────────────────

def _generate_poem(prompt: str) -> str:
    """
    Calls Nova Micro via the Converse API.
    Returns the poem as a plain string.
    """
    bedrock = _get_bedrock()

    system_prompt = (
        "You are a creative poet. When given a mood or scene, "
        "write a single short poem of 4 to 8 lines. "
        "Output only the poem — no title, no commentary, no quotes."
    )
    user_message = f"Write a poem inspired by: {prompt}"

    response = bedrock.converse(
        modelId=MODEL_TEXT,
        system=[{"text": system_prompt}],
        messages=[{"role": "user", "content": [{"text": user_message}]}],
        inferenceConfig={
            "maxTokens": 300,
            "temperature": 0.85,
            "topP": 0.9,
        },
    )
    return response["output"]["message"]["content"][0]["text"].strip()


def _generate_image(prompt: str) -> str:
    """
    Calls Nova Canvas (or Titan fallback) via invoke_model.
    Returns base64-encoded PNG string.

    Width/height/quality are set explicitly to 512x512 standard so generation
    stays fast and reliably under the 30s API Gateway integration timeout.
    """
    bedrock = _get_bedrock()

    image_prompt = (
        f"A beautiful, artistic mood board image representing: {prompt}. "
        "Painterly style, rich colours, evocative atmosphere."
    )

    if "nova-canvas" in MODEL_IMAGE:
        # ── Nova Canvas request body ───────────────────────────────────────────
        body = {
            "taskType": "TEXT_IMAGE",
            "textToImageParams": {
                "text": image_prompt,
            },
            "imageGenerationConfig": {
                "numberOfImages": 1,
                "width":          512,   # explicit — default is 1024, too slow
                "height":         512,   # explicit — default is 1024, too slow
                "quality":        "standard",  # not "premium" — saves ~2-4s
                "cfgScale":       7.5,
            },
        }
    else:
        # ── Titan Image Generator v1 fallback ─────────────────────────────────
        body = {
            "taskType": "TEXT_IMAGE",
            "textToImageParams": {"text": image_prompt},
            "imageGenerationConfig": {
                "numberOfImages": 1,
                "width":  512,
                "height": 512,
                "cfgScale": 7.5,
            },
        }

    response = bedrock.invoke_model(
        modelId=MODEL_IMAGE,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(body),
    )

    result = json.loads(response["body"].read())

    # Nova Canvas and Titan both return images[0] as base64
    return result["images"][0]


# ── Entry point ────────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context) -> dict:
    """
    Handles:
      - OPTIONS preflight (browsers send this before POST)
      - POST with { "prompt": "<text>" }
    """
    logger.info("Event: %s", json.dumps(event))
    logger.info("MOCK_MODE: %s", MOCK_MODE)

    # ── Handle CORS preflight (outside the main try — it can't fail) ──────────
    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return _respond(200, {})

    try:
        # ── Parse body ────────────────────────────────────────────────────────
        try:
            body = json.loads(event.get("body") or "{}")
            prompt = body.get("prompt", "").strip()
        except (json.JSONDecodeError, AttributeError):
            return _respond(400, {"error": "Request body must be valid JSON."})

        if not prompt:
            return _respond(400, {"error": "prompt is required and cannot be empty."})

        if len(prompt) > 500:
            return _respond(400, {"error": "Prompt must be 500 characters or fewer."})

        # ── MOCK path — no AWS credentials needed ─────────────────────────────
        if MOCK_MODE:
            logger.info("MOCK_MODE is on — returning hardcoded sample data.")
            return _respond(200, {"poem": MOCK_POEM, "image_b64": MOCK_IMAGE_B64})

        # ── Real Bedrock path ─────────────────────────────────────────────────
        from botocore.exceptions import ClientError

        logger.info("Generating poem for prompt: %s", prompt)
        try:
            poem = _generate_poem(prompt)
        except ClientError as e:
            code = e.response["Error"]["Code"]
            logger.error("Bedrock text error: %s", e)
            if code == "AccessDeniedException":
                return _respond(403, {"error": "Bedrock model access not enabled. Request access to Nova Micro in the Bedrock console."})
            return _respond(502, {"error": f"Text generation failed: {code}"})

        logger.info("Generating image for prompt: %s", prompt)
        try:
            image_b64 = _generate_image(prompt)
        except ClientError as e:
            code = e.response["Error"]["Code"]
            logger.error("Bedrock image error: %s", e)
            if code == "AccessDeniedException":
                return _respond(403, {"error": "Bedrock model access not enabled. Request access to Nova Canvas in the Bedrock console."})
            return _respond(502, {"error": f"Image generation failed: {code}"})

        logger.info("Successfully generated poem and image.")
        return _respond(200, {"poem": poem, "image_b64": image_b64})

    except Exception:
        # Catch-all: anything not handled above (KeyError on Bedrock response,
        # unexpected boto3 exception, etc.) lands here. Log the full traceback
        # so CloudWatch has the real cause, then return a CORS-safe 500 so the
        # browser never sees a misleading CORS failure.
        logger.error("Unhandled exception in lambda_handler", exc_info=True)
        return _respond(500, {"error": "Unexpected server error. Check CloudWatch logs."})

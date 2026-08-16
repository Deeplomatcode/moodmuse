# MoodMuse — Design

> **SUPERSEDED — historical record only.**
> This spec was written against the original Nova Canvas / S3-static-website design.
> The deployed app uses Stability AI (`us.stability.stable-image-control-sketch-v1:0`)
> for images and AWS Amplify Hosting. For the current architecture see `README.md`;
> for the full build narrative see `ARTICLE.md`.

> Retroactive spec. The app is fully built and locally verified. This document
> describes what exists, not what is planned.

---

## Architecture

```
Browser (S3 static page)
        │
        │  POST /generate
        │  { "prompt": "rainy Sunday morning" }
        ▼
API Gateway (HTTP API, us-east-1)
        │
        │  Lambda proxy integration
        │  Payload format: 2.0
        ▼
Lambda  moodmuse-generate
        Python 3.12 | 256 MB | timeout 29s
        │
        ├── Bedrock converse()
        │   amazon.nova-micro-v1:0
        │   → poem string (4–8 lines)
        │
        └── Bedrock invoke_model()
            amazon.nova-canvas-v1:0
            → base64 PNG (512×512, standard quality)
                │
                ▼
        { poem: str, image_b64: str }
                │
                ▼
Browser renders poem as text + image as
<img src="data:image/png;base64,...">
```

No S3 image bucket. The image is returned as a base64 string directly in the
Lambda response and rendered with a data URI. Response payload ≈ 200–350 KB —
well within Lambda's 6 MB response limit.

---

## Components

### `lambda/handler.py`

Single Lambda handler. Responsibilities:

- Read `MOCK_MODE` environment variable (default `"true"`) at module load
- When `MOCK_MODE=true`: return hardcoded sample poem and placeholder base64 PNG
  without touching boto3 or making any network calls
- When `MOCK_MODE=false`: call Bedrock for real poem and image generation
- Lazy-instantiate the boto3 `bedrock-runtime` client (module-level `_bedrock = None`,
  created on first real call) — prevents credential lookup during local testing
- Parse and validate incoming prompt (required, max 500 chars)
- Handle `OPTIONS` preflight requests for CORS
- Return CORS headers (`Access-Control-Allow-Origin: *`) on **every** response path,
  including errors — ensured by an outer `try/except Exception` that catches anything
  the inner `ClientError` blocks miss

**MOCK_MODE** is the only environment variable the function reads. Set it to `false`
in the Lambda console when deploying.

**Bedrock text call** — `bedrock.converse()`:

```python
modelId  = "amazon.nova-micro-v1:0"
maxTokens    = 300
temperature  = 0.85
topP         = 0.9
```

System prompt instructs the model to write a 4–8 line poem with no title or
commentary.

**Bedrock image call** — `bedrock.invoke_model()`:

```python
modelId = "amazon.nova-canvas-v1:0"
# Fallback: "amazon.titan-image-generator-v1"

taskType = "TEXT_IMAGE"
width    = 512   # explicit — default is 1024×1024, risks 30s timeout
height   = 512
quality  = "standard"  # not "premium" — saves 2–4s
cfgScale = 7.5
```

Width/height/quality are set explicitly because Nova Canvas defaults to
1024×1024 standard, which can approach or exceed the HTTP API's hard 30s
integration timeout cap (which cannot be raised, unlike REST API timeouts).

**Fallback**: swap `MODEL_IMAGE` to `amazon.titan-image-generator-v1` if Nova
Canvas access is unavailable in the account. The request body structure is
identical; the branch is already in the code.

**Error handling**:

- `botocore.exceptions.ClientError` with `AccessDeniedException` → 403 with a
  human-readable message directing the user to the Bedrock console
- Any other `ClientError` → 502 with the error code
- Any other `Exception` → 500, logged with `exc_info=True` for CloudWatch,
  response still carries CORS headers

**CORS**: headers are set in the Lambda response dict only. API Gateway CORS
is deliberately disabled — enabling both produces duplicate
`Access-Control-Allow-Origin` headers, which browsers reject.

---

### `lambda/local_server.py`

Stdlib-only local development server (no Flask, no extra dependencies).
Listens on `localhost:8000`. Handles `POST /generate` and `OPTIONS /generate`.

Builds a minimal API Gateway HTTP API v2 event dict from the incoming HTTP
request and calls `handler.lambda_handler()` directly. Returns the handler's
response with the same headers — response shape is byte-for-byte identical
to what the deployed API returns, so no frontend code changes between local
and deployed.

```
Browser (file://)  →  local_server.py:8000  →  handler.lambda_handler()
```

`MOCK_MODE` defaults to `true`, so running `python3 local_server.py` requires
no AWS credentials and makes no network calls.

---

### `frontend/index.html`

Single self-contained HTML file. No build step, no npm, no framework.
Uploaded directly to S3 for hosting.

Key elements:
- `<textarea>` prompt input with 500-char max and live character counter
- "Generate" button: disabled + spinner while request is in flight
- Output area: CSS grid, poem card (left) + image card (right),
  collapses to single column on narrow screens
- `#error-banner`: inline error display, `role="alert"`, no `alert()` calls
- Image fade-in via CSS `opacity` transition on `onload`
- Keyboard shortcut: Ctrl/Cmd+Enter submits from the textarea

**`API_URL` constant** — the only line that changes between local and deployed:

```js
// ⚠️  THIS IS THE ONLY LINE THAT CHANGES WHEN YOU DEPLOY FOR REAL.
const API_URL = "http://localhost:8000/generate";
// Deployed: const API_URL = "https://<api-id>.execute-api.us-east-1.amazonaws.com/generate";
```

---

### IAM Role — `moodmuse-lambda-role`

| Policy | Type | Permissions |
|---|---|---|
| `AWSLambdaBasicExecutionRole` | AWS managed | CloudWatch Logs write |
| `moodmuse-bedrock-policy` | Inline | `bedrock:InvokeModel` on Nova Micro, Nova Canvas, Titan Image v1 ARNs |

No S3, no DynamoDB, no VPC, no network interface permissions — intentionally
minimal. The Titan Image v1 ARN is included in the policy to allow the
fallback without a policy change.

---

### S3 Bucket — `moodmuse-<account-id>-us-east-1`

- Static website hosting enabled, index document: `index.html`
- Block Public Access: all four settings disabled
- Bucket policy: `s3:GetObject` for `Principal: "*"` on all objects
- Contains only `index.html`
- Serves over **HTTP only** — S3 website endpoints do not support HTTPS;
  CloudFront would be required to add TLS, which is out of scope for this build

---

## Sequence — happy path (deployed)

```
1.  User types prompt, clicks Generate
2.  JS disables button, shows spinner
3.  fetch() POST to API Gateway /generate with { "prompt": "..." }
4.  API Gateway invokes Lambda (payload format 2.0)
5.  Lambda validates prompt
6.  Lambda calls Bedrock converse() → poem string
7.  Lambda calls Bedrock invoke_model() → base64 PNG
8.  Lambda returns { statusCode: 200, body: { poem, image_b64 }, CORS headers }
9.  API Gateway proxies response to browser
10. JS renders poem text and <img src="data:image/png;base64,...">
11. Image fades in via CSS transition
12. Button re-enabled
```

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Base64 image in Lambda response | Eliminates S3 image bucket, presigned URL management, and S3 CORS. Payload ≈ 200–350 KB, well within Lambda's 6 MB limit. |
| HTTP API over REST API | ~70% cheaper per request; no usage plans needed; simpler setup for a weekend build. |
| Nova Micro for text | Lowest latency and cost in the Nova family. Poem generation does not require Nova Pro reasoning. |
| 512×512 explicit in Canvas request | Nova Canvas defaults to 1024×1024. At that size, generation time risks exceeding the HTTP API's hard 30s cap. |
| Lambda timeout = 29s | HTTP API integration timeout is hard-capped at 30s and cannot be raised. 29s gives 1s headroom. |
| Lambda-only CORS headers | Duplicate `Access-Control-Allow-Origin` headers (one from Lambda, one from API GW) cause browsers to block the response. |
| MOCK_MODE default true | Full click-through testable locally without AWS credentials or network access. The only env var change needed at deploy time. |
| Outer try/except Exception | Without it, any unexpected exception (KeyError on a Bedrock response, etc.) causes Lambda to return a raw error with no CORS headers, which surfaces as a misleading CORS failure in the browser. |
| Vanilla JS, no framework | Zero build toolchain. Drop index.html in S3 and it works. Right call for a 48-hour build. |
| No DynamoDB / auth / history | Scope discipline — the brief is one clear creative job. Every extra service is IAM complexity and time against the Aug 17 deadline. |

---

## Model Lifecycle Note

`amazon.nova-canvas-v1:0` has a listed EOL of September 30, 2026 per AWS's
model card — approximately 6 weeks after this build. The app is built,
demoed, and published well before that date. Worth a note in the Builder
Center article, and a quick console check closer to publish time in case a
successor model ID exists.

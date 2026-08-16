# MoodMuse — Tasks

> **SUPERSEDED — historical record only.**
> This spec was written against the original Nova Canvas / S3-static-website design.
> The deployed app uses Stability AI (`us.stability.stable-image-control-sketch-v1:0`)
> for images and AWS Amplify Hosting. For the current architecture see `README.md`;
> for the full build narrative see `ARTICLE.md`.

> Retroactive spec. All tasks below are complete. Status is recorded for
> reference and for the Builder Center article write-up.

---

## Stage 1 — Lambda + Bedrock

- [x] Create project directory structure (`lambda/`, `iam/`, `frontend/`)
- [x] Write `iam/lambda-trust-policy.json` — allows Lambda service to assume the role
- [x] Write `iam/lambda-bedrock-policy.json` — `bedrock:InvokeModel` on Nova Micro,
      Nova Canvas, and Titan Image v1 ARNs (fallback included without a policy change)
- [x] Write `lambda/handler.py` — Bedrock text + image calls, CORS headers on all
      responses, spec fixes applied (512×512 explicit, lazy boto3 client, Lambda-only CORS)
- [x] Write `lambda/test_event.json` — API GW v2-shaped test event for Lambda console
- [x] Write `deploy-stage1.sh` — idempotent: creates IAM role, attaches managed policy,
      applies inline Bedrock policy, zips and deploys Lambda (timeout 29s, memory 256 MB)
- [x] Add `MOCK_MODE` env var toggle to `handler.py` — defaults `true`, lazy boto3
      import, hardcoded sample poem + placeholder base64 PNG returned when mocked,
      real Bedrock path fully intact behind the flag
- [x] Add outer `try/except Exception` to `lambda_handler` — ensures CORS headers are
      present on every response path including unexpected errors; log with `exc_info=True`
- [x] Remove dead `from botocore.exceptions import ClientError` import from
      `_generate_poem()` — `ClientError` is imported once where it is actually used

---

## Stage 2 — API Gateway

- [x] Write `deploy-stage2.sh` — idempotent: creates HTTP API `moodmuse-api`, Lambda
      proxy integration (payload format 2.0), route `POST /generate`, `$default` stage
      with auto-deploy, Lambda invoke permission scoped to this API; no API GW CORS config

---

## Stage 3 — Frontend

- [x] Write `frontend/index.html` — single file, no build step, vanilla JS:
  - Prompt `<textarea>` with 500-char max and live character counter
  - "Generate" button with disabled + spinner loading state
  - CSS grid output area: poem card (left) + image card (right), responsive
  - `#error-banner` inline error display (`role="alert"`, no `alert()`)
  - Image fade-in via CSS `opacity` transition on `onload`
  - Ctrl/Cmd+Enter keyboard shortcut
  - `API_URL` constant clearly marked as the only line that changes at deploy time
- [x] Write `lambda/local_server.py` — stdlib only (`http.server`), no extra deps:
  - Listens on `localhost:8000`
  - Handles `POST /generate` and `OPTIONS` preflight
  - Builds API GW v2 event dict, calls `handler.lambda_handler()` directly
  - Response shape byte-for-byte identical to deployed API — no frontend changes needed

---

## Stage 4 — S3 Deploy

- [x] Write `deploy-stage4.sh` — idempotent: pre-flight localhost check, creates bucket
      `moodmuse-<account-id>-us-east-1`, disables Block Public Access (all four settings),
      applies public-read bucket policy, enables static website hosting, uploads `index.html`

---

## Stage 5 — Deploy and Verify (remaining)

- [x] Run `deploy-stage1.sh` — create IAM role and deploy Lambda to AWS
- [x] Verify Lambda with test event — confirm `statusCode: 200`, poem present,
      `image_b64` present, CORS header present (verified via `aws lambda invoke`)
- [x] Set `MOCK_MODE=false` in Lambda environment variables
- [ ] Run `deploy-stage2.sh` — create API Gateway and wire Lambda integration
- [ ] Test API with curl using the printed invoke URL
- [ ] Update `API_URL` in `frontend/index.html` to the API Gateway invoke URL
- [ ] Run `deploy-stage4.sh` — create S3 bucket and upload frontend
- [ ] Open the S3 website URL in a browser, submit a real prompt end-to-end
- [ ] Take screenshot / record demo video for Builder Center submission

---

## Builder Center Article — Content Checklist

- [ ] Architecture summary (diagram + one-paragraph description)
- [ ] Key decisions made (table from design.md)
- [ ] Challenges hit and how they were solved:
  - Nova Canvas default 1024×1024 → 30s timeout risk → explicit 512×512 fix
  - HTTP API 30s hard cap (unlike REST API) → 29s Lambda timeout
  - Duplicate CORS headers → Lambda-only CORS, no API GW CORS config
  - No Bedrock free tier → cost framing correction ("$0 hosting, pennies in inference")
  - Nova Canvas EOL Sep 30 2026 → noted, checked at publish time
- [ ] What I learned (local mock server pattern, lazy boto3, base64-in-response tradeoffs)
- [ ] Working deployed URL or GitHub repo with README + screenshots/demo video

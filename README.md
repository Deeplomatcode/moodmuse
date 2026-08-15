# MoodMuse

AI Mood Board & Micro-Poem Generator — AWS Builder Center Weekend Challenge (Aug 2026)

Type a short mood or scene → get a 4–8 line poem from Amazon Bedrock Nova Micro and a matching mood board image from Amazon Bedrock Nova Canvas, side by side on one screen.

---

## Architecture

```
Browser (S3 static page)
    │
    │ POST /generate  { "prompt": "rainy Sunday morning" }
    ▼
API Gateway HTTP API
    │
    ▼
Lambda (Python 3.12, 29s timeout)
  ├── Bedrock Nova Micro  → poem string
  └── Bedrock Nova Canvas → base64 PNG
    │
    ▼
{ poem, image_b64 }  ← rendered directly in the browser
```

Image is returned as base64 in the Lambda response — no S3 image bucket, no presigned URLs.

---

## Stage Status

- [x] Stage 1 — Lambda + Bedrock
- [~] Stage 2 — API Gateway (script written, not yet deployed — no AWS account connected)
- [x] Stage 3 — Frontend (`frontend/index.html` complete, runs locally against local_server.py)
- [~] Stage 4 — S3 Deploy (script written, not yet deployed — no AWS account connected)
- [ ] Stage 5 — Polish

---

## Stage 1 — Manual Setup Steps

### 0. Prerequisites

```bash
# Confirm CLI is configured for us-east-1
aws sts get-caller-identity
aws configure get region   # should be us-east-1
```

### 1. Enable Bedrock model access (REQUIRED before anything works)

1. Open the [Bedrock console](https://console.aws.amazon.com/bedrock) in **us-east-1**
2. Left nav → **Model access** → **Manage model access**
3. Enable both:
   - `Amazon Nova Micro`  (text)
   - `Amazon Nova Canvas` (image)
4. Click **Save changes** — access is usually granted within a few seconds for Nova models.

> If Nova Canvas shows as unavailable in your account, enable `Amazon Titan Image Generator v1` instead,
> then edit `lambda/handler.py` line: `MODEL_IMAGE = "amazon.titan-image-generator-v1"`

### 2. Deploy with the script

```bash
cd "/Users/mohammedbakare/Mood Muse/moodmuse"
./deploy-stage1.sh
```

The script will:
1. Create IAM role `moodmuse-lambda-role` with least-privilege Bedrock permissions
2. Attach `AWSLambdaBasicExecutionRole` (CloudWatch Logs)
3. Zip and deploy `lambda/handler.py` as function `moodmuse-generate`
4. Set timeout = 29s, memory = 256 MB

### 3. Test in the Lambda console

1. Open Lambda console → `moodmuse-generate` → **Test** tab
2. Create a new test event, paste the contents of `lambda/test_event.json`:

```json
{
  "requestContext": { "http": { "method": "POST" } },
  "body": "{\"prompt\": \"rainy Sunday morning\"}"
}
```

3. Click **Test**

**Expected response:**
```json
{
  "statusCode": 200,
  "headers": { "Access-Control-Allow-Origin": "*", ... },
  "body": "{\"poem\": \"...\", \"image_b64\": \"...\"}"
}
```

The `image_b64` value will be a long base64 string (~200–350KB). That's correct.

**Common errors and fixes:**

| Error | Cause | Fix |
|---|---|---|
| `AccessDeniedException` | Model access not enabled | Step 1 above |
| `ResourceNotFoundException` | Wrong model ID or region | Confirm region = us-east-1 |
| Function timeout | Image gen took >29s | Rare at 512×512 standard; check CloudWatch logs |
| `ValidationException` | Bad request body to Bedrock | Check CloudWatch logs for the raw error |

---

## Stage 2 — API Gateway

Run **after** Stage 1 (Lambda must exist first).

```bash
cd "/Users/mohammedbakare/Mood Muse/moodmuse"
./deploy-stage2.sh
```

The script will:
1. Create HTTP API `moodmuse-api` (or reuse if it already exists)
2. Create a Lambda proxy integration with **payload format 2.0** (required — handler.py uses the v2 event shape)
3. Create route `POST /generate`
4. Create `$default` stage with auto-deploy enabled
5. Grant API Gateway permission to invoke the Lambda (source ARN scoped to this API only)

At the end it prints the invoke URL and the exact `API_URL` line to paste into `frontend/index.html`.

> **CORS**: `deploy-stage2.sh` does **not** enable CORS at the API Gateway level.
> CORS headers are returned by the Lambda handler only. Enabling both would produce
> duplicate `Access-Control-Allow-Origin` headers and break the browser.

After running the script, set `MOCK_MODE=false` in the Lambda console environment
variables before using the live API.

---

## File Map

```
moodmuse/
  lambda/
    handler.py          ← Lambda function (Stages 1–2)
    local_server.py     ← Local dev server (stdlib only, no deps)
    test_event.json     ← Paste into Lambda console Test tab
  iam/
    lambda-trust-policy.json   ← Allows Lambda service to assume the role
    lambda-bedrock-policy.json ← Allows bedrock:InvokeModel on Nova + Titan
  frontend/
    index.html          ← Full UI (Stage 3) — runs locally and from S3
  deploy-stage1.sh      ← Creates IAM role + deploys Lambda
  deploy-stage2.sh      ← Creates HTTP API + wires Lambda integration
  deploy-stage4.sh      ← Creates S3 bucket + uploads frontend
  README.md             ← This file
```

---

## IAM Permissions (what and why)

| Permission | Resource | Reason |
|---|---|---|
| `bedrock:InvokeModel` | Nova Micro ARN | Poem generation |
| `bedrock:InvokeModel` | Nova Canvas ARN | Image generation |
| `bedrock:InvokeModel` | Titan Image v1 ARN | Fallback if Nova Canvas unavailable |
| CloudWatch Logs (managed) | `AWSLambdaBasicExecutionRole` | Lambda execution logs |

No S3, no DynamoDB, no VPC — intentionally minimal.

---

## Cost Notes

- **Lambda / API Gateway / S3**: effectively $0 at demo volume (free tier covers it)
- **Bedrock inference**: NOT free tier
  - Nova Micro: ~$0.0001 per poem (sub-cent)
  - Nova Canvas: $0.06 per image (standard quality)
  - 20 test runs ≈ ~$1.20 in image costs — keep this in mind during testing

---

## Key Decisions (for Builder Center article)

| Decision | Why |
|---|---|
| Base64 image in response | Avoids S3 image bucket + presigned URL complexity for a 2-day build |
| HTTP API (not REST API) | ~70% cheaper, simpler CORS, no usage plans needed |
| Nova Micro for text | Lowest latency in the Nova family; poems don't need Pro reasoning |
| 512×512 explicit in request | Nova Canvas defaults to 1024×1024 — too slow for 30s API cap |
| 29s Lambda timeout | HTTP API hard cap is 30s and cannot be raised; 29s gives 1s headroom |
| Lambda-only CORS headers | Duplicate headers from both Lambda + API GW break browsers |
| Vanilla JS, no framework | Zero build step; drop index.html in S3 and it works |
| No DynamoDB / auth / history | Scope discipline — one clear creative job, Aug 17 deadline |

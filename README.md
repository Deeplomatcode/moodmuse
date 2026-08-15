# MoodMuse

AI Mood Board & Micro-Poem Generator — AWS Builder Center Weekend Challenge (Aug 2026)

Type a short mood or scene → get a 4–8 line poem from Amazon Bedrock Nova Micro and a matching mood board image from Stability AI's stable-image-control-sketch model, side by side on one screen.

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
  └── Bedrock Stability control-sketch (inference profile) → base64 PNG
    │
    ▼
{ poem, image_b64 }  ← rendered directly in the browser
```

Image is returned as base64 in the Lambda response — no S3 image bucket, no presigned URLs.

---

## Stage Status

- [x] Stage 1 — Lambda + Bedrock
- [x] Stage 2 — API Gateway
- [x] Stage 3 — Frontend (`frontend/index.html` complete, tested locally and live)
- [x] Stage 4 — S3 Deploy
- [ ] Stage 5 — Polish

---

## Stage 1 — Manual Setup Steps

### 0. Prerequisites

```bash
# Confirm CLI is configured for us-east-1
aws sts get-caller-identity
aws configure get region   # should be us-east-1
```

### 1. Bedrock model access

Foundation models in Bedrock are **auto-enabled on first invoke** — there is no
manual model-access toggle to set. The "Model access" page in the Bedrock console
has been retired. If a model returns `AccessDeniedException`, it is either not
available in your region or requires a Marketplace subscription (see IAM
permissions below).

### 2. Deploy with the script

```bash
cd "/path/to/moodmuse"
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

The `image_b64` value will be a long base64 string. That's correct.

**Common errors and fixes:**

| Error | Cause | Fix |
|---|---|---|
| `AccessDeniedException` | Model not available or not subscribed | Check Marketplace subscription for Stability model |
| `ResourceNotFoundException` | Wrong model/inference profile ID or region | Confirm region = us-east-1, confirm inference profile ID |
| Function timeout | Image gen took >29s | Check CloudWatch logs; confirm seed image size |
| `ValidationException` | Bad request body to Bedrock | Check CloudWatch logs for the raw error |

---

## Stage 2 — API Gateway

Run **after** Stage 1 (Lambda must exist first).

```bash
cd "/path/to/moodmuse"
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

## Stage 4 — S3 Deploy

Run **after** Stage 2 (API Gateway must be deployed and the invoke URL known).

### Prerequisites

Before running the script, update the `API_URL` constant in `frontend/index.html`:

```js
// Change this line:
const API_URL = "http://localhost:8000/generate";

// To the URL printed at the end of deploy-stage2.sh, e.g.:
const API_URL = "https://<api-id>.execute-api.us-east-1.amazonaws.com/generate";
```

The script will warn and prompt for confirmation if it detects `localhost:8000` is still in the file, but it's easier to fix it before running.

### Deploy

```bash
cd "/path/to/moodmuse"
./deploy-stage4.sh
```

The script will:
1. **Pre-flight check** — scans `frontend/index.html` for `localhost:8000` and warns if found, giving you a chance to abort before anything is uploaded
2. **Create S3 bucket** named `moodmuse-<account-id>-us-east-1` (account ID makes it globally unique), or skip creation if it already exists
3. **Disable Block Public Access** — all four settings are set to false; this is a common silent-failure point: if any remain true, the public-read policy in the next step takes no effect and every request returns 403 with no useful error
4. **Apply public-read bucket policy** — grants `s3:GetObject` to `Principal: "*"` on all objects, making the site publicly accessible
5. **Enable static website hosting** with `index.html` as the index document
6. **Upload `frontend/index.html`** to the bucket root with `Content-Type: text/html` and `Cache-Control: no-cache, must-revalidate`

At the end it prints the S3 website endpoint URL.

> **HTTP only**: S3 static website endpoints serve over HTTP, not HTTPS. The URL will be
> `http://moodmuse-<account-id>-us-east-1.s3-website-us-east-1.amazonaws.com`.
> This is fine for a demo submission — just worth knowing so you're not surprised
> by the browser's "Not secure" indicator. Adding HTTPS would require CloudFront,
> which is a stretch goal not needed for the Aug 17 deadline.

### Before sharing the link — checklist

1. `API_URL` in `frontend/index.html` points at the API Gateway invoke URL, not `localhost`
2. `MOCK_MODE=false` is set as an environment variable in the Lambda console — otherwise every request returns the hardcoded sample poem and purple square
3. Stability AI model subscription is active in AWS Marketplace for account

---

## File Map

```
moodmuse/
  lambda/
    handler.py          ← Lambda function
    local_server.py     ← Local dev server (stdlib only, no deps)
    test_event.json     ← Paste into Lambda console Test tab
  iam/
    lambda-trust-policy.json   ← Allows Lambda service to assume the role
    lambda-bedrock-policy.json ← Bedrock + Marketplace permissions (see IAM section)
  frontend/
    index.html          ← Full UI — runs locally and from S3
  deploy-stage1.sh      ← Creates IAM role + deploys Lambda
  deploy-stage2.sh      ← Creates HTTP API + wires Lambda integration
  deploy-stage4.sh      ← Creates S3 bucket + uploads frontend
  README.md             ← This file
```

---

## IAM Permissions (what and why)

| Permission | Resource | Reason |
|---|---|---|
| `bedrock:InvokeModel` | Nova Micro ARN (`us-east-1`) | Poem generation |
| `bedrock:InvokeModel` | Stability control-sketch foundation model ARN (wildcard region) | Image generation — base model |
| `bedrock:InvokeModel` | Stability control-sketch inference profile ARN (`us-east-1`, account-scoped) | Image generation — cross-region inference profile required for on-demand invocation |
| `aws-marketplace:ViewSubscriptions` | `*` | Required to invoke Marketplace-sourced Stability model |
| `aws-marketplace:Subscribe` | `*` | Required to invoke Marketplace-sourced Stability model |
| CloudWatch Logs (managed) | `AWSLambdaBasicExecutionRole` | Lambda execution logs |

No S3 data bucket, no DynamoDB, no VPC — intentionally minimal.

---

## Cost Notes

- **Lambda / API Gateway / S3**: effectively $0 at demo volume (free tier covers it)
- **Bedrock inference**: NOT free tier
  - Nova Micro: ~$0.0001 per poem (sub-cent)
  - Stability control-sketch: ~$0.07 per image (us-east-1)
  - 20 test runs ≈ ~$1.40 in image costs — keep this in mind during testing

---

## Key Decisions (for Builder Center article)

| Decision | Why |
|---|---|
| Base64 image in response | Avoids S3 image bucket + presigned URL complexity for a 2-day build |
| HTTP API (not REST API) | ~70% cheaper, simpler CORS, no usage plans needed |
| Nova Micro for text | Lowest latency in the Nova family; poems don't need Pro reasoning |
| Stability control-sketch via inference profile | Nova Canvas is marked LEGACY account-wide on new accounts with no prior invoke history — hard `AccessDenied` on first call. Titan Image Generator v1 has been fully retired. Stability control-sketch via a cross-region inference profile was the working path. A neutral 512×512 gray seed image with `control_strength: 0.15` lets the text prompt dominate output. |
| Seed image controls output size | Stability control-sketch output dimensions match the input seed image — no explicit width/height parameter in the request. 512×512 seed keeps the response payload under ~350 KB and generation well under 29s. |
| 29s Lambda timeout | HTTP API integration timeout is hard-capped at 30s and cannot be raised. 29s gives 1s headroom. |
| Lambda-only CORS headers | Duplicate `Access-Control-Allow-Origin` headers (one from Lambda, one from API GW) cause browsers to block the response. |
| MOCK_MODE default true | Full click-through testable locally without AWS credentials. The only env var change needed at deploy time. |
| Vanilla JS, no framework | Zero build step; drop index.html in S3 and it works |
| No DynamoDB / auth / history | Scope discipline — one clear creative job, Aug 17 deadline |

> **Historical note**: the original plan used Nova Canvas for images. It was
> superseded when the account returned a hard `AccessDenied` on first invoke
> (Nova Canvas is classified LEGACY on accounts with no prior usage history)
> and Titan Image Generator v1 was found to be fully retired and not listed in
> the account catalog at all. The pivot to Stability control-sketch via inference
> profile added about an hour of work but unblocked the build entirely.

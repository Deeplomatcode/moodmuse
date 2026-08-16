# Weekend Creative Challenge: MoodMuse

*Tag: creative-expression*

## Vision & What the App Does

MoodMuse is a tiny serverless app with one job: you type a short mood or scene — "rainy Sunday morning," "wet wood," "midnight city lights" — and it hands back an original short poem and a matching AI-generated mood board image, side by side, on one screen. No accounts, no history, no second screen to click through. Just a feeling in, a small piece of creative output back.

I built it for the AWS Builder Center Weekend Creative Challenge as a solo weekend project. I'm an AWS Solutions Architect Associate and the founder of a small agentic AI consultancy, so most of my week is spent on production systems with a lot of moving parts. This challenge was the opposite exercise on purpose: how much genuine creative delight can you ship with the smallest architecture that will hold it? Amazon Bedrock made that a real question rather than a rhetorical one — a single Lambda function calling Nova Micro for text and a Stability AI model for imagery turned out to be enough, though which imagery model actually got me there was not the one I planned to use.

## How You Built It

The build happened in two distinct phases: fully local first, then live on AWS — and the live phase turned into its own debugging story.

Locally, a `MOCK_MODE` environment variable in the Lambda handler (defaulting to `true`) let the whole app — frontend, API shape, loading and error states — get built and fully clicked-through with zero AWS dependency. A small stdlib-only local server replicated the exact API Gateway HTTP API (v2) request/response shape, so going live was meant to be a one-line change (the frontend's API URL) and one environment flip (`MOCK_MODE=false`).

That part worked exactly as planned. What didn't was the image model. The original design called for Amazon Nova Canvas, and it never got a single successful invocation once deployed — for reasons that had nothing to do with my code (see What I Learned). Getting from "Lambda deployed" to "a stranger can load this page and get a real poem and a real image" took a genuine live-debugging session: reading CloudWatch logs in real time, discovering an account-wide model restriction, picking a different model family entirely, then chasing that new model through an invocation-mode error, a cross-region IAM permission gap, an AWS Marketplace subscription requirement, a missing CORS preflight route, and a stale browser cache — each one a distinct, real bug with a distinct fix, found by reading the actual error rather than guessing. The final piece was moving hosting from a plain S3 static website (HTTP-only, which modern browsers auto-upgrade and then hang on) to AWS Amplify Hosting, which fronts the same static frontend with HTTPS and auto-deploys on every push to `main`.

I built this using Kiro, AWS's agentic IDE, for both the initial implementation stages and, later, for diagnosing the live issues — reading CloudWatch output, testing routes and permissions directly, and proposing fixes I reviewed before applying.

## AWS Services Used / Architecture Overview

**Services used:** Amazon Bedrock (Nova Micro for text, Stability AI's Stable Image Control Sketch for imagery), AWS Lambda, Amazon API Gateway (HTTP API), AWS Amplify Hosting (static frontend, HTTPS, GitHub auto-deploy), AWS IAM. All within AWS Free Tier except Bedrock inference itself, which is billed per-call.

```
Browser (Amplify Hosting, HTTPS)
        │  POST /generate
        ▼
API Gateway (HTTP API, us-east-1)
        │  Lambda proxy integration, payload format 2.0
        │  routes: POST /generate + OPTIONS /generate (CORS preflight)
        ▼
Lambda — Python 3.12, 256 MB, 29s timeout
        ├── Bedrock converse() — amazon.nova-micro-v1:0 → poem (4–8 lines)
        └── Bedrock invoke_model() — us.stability.stable-image-control-sketch-v1:0
            (cross-region inference profile; neutral seed image + low
            control_strength used as a text-to-image substitute) → base64 PNG
        │
        ▼
{ poem, image_b64 }  →  rendered directly in the browser
```

The image comes back as a base64 string embedded directly in the Lambda response — no S3 image bucket, no presigned URLs. It's a deliberate simplification: comfortably within Lambda's 6MB response limit, and it removes an entire category of infrastructure for a one-shot demo that doesn't need images to persist. No DynamoDB, no Cognito, no VPC: every service in the stack is one the app's single job actually requires.

## What You Learned

The honest version of this section is longer than I expected going in, because the live account didn't behave like the documentation.

**"Legacy" can mean hard-denied for a brand-new account.** Amazon Nova Canvas — the model this app was designed around — is marked Legacy in this account across all three regions it supports. New accounts with no prior 30-day usage history get an outright `AccessDenied`, even though the Bedrock console's manual model-access page has been retired in favor of "auto-enabled on first invoke." Titan Image Generator, the obvious fallback, has been fully retired from the catalog. A full unfiltered scan of the account's model list turned up no active pure text-to-image model at all — every active Stability model was an image-*editing* tool (upscale, inpaint, sketch-to-image) that requires an input image. The workaround: use the sketch-control model with a neutral gray seed image and a low `control_strength`, letting the text prompt dominate over an intentionally uninformative input — a genuine text-to-image substitute built from an editing tool.

**Third-party Bedrock models route through AWS Marketplace, silently.** `bedrock:InvokeModel` permission alone wasn't enough for the Stability model — the Lambda role also needed `aws-marketplace:ViewSubscriptions` and `aws-marketplace:Subscribe`, a permission boundary that doesn't exist for AWS's own Nova models and isn't obvious from the Bedrock IAM documentation.

**Cross-region inference profiles route where they want, not where you named them.** Some models can't be invoked by base model ID — only by an inference profile ID. The `us.` prefixed profile I used, created in us-east-1, actually routed the live invocation to us-east-2. An IAM policy scoped to a single region's model ARN fails against that silently; the fix is wildcarding the region on that resource entry.

**A missing CORS preflight route fails 100% silently.** Lambda-side CORS headers are correct and irrelevant if API Gateway has no `OPTIONS` route at all — the browser's preflight gets a 404 before Lambda is ever invoked, so CloudWatch shows zero errors and zero invocations. curl (which skips preflight) works perfectly the entire time, which makes this exact bug very easy to misdiagnose as "working."

**Plain S3 static hosting is HTTP-only, and browsers punish that.** Chrome silently auto-upgrades a bare `http://` S3 website URL to `https://`, which S3 static hosting doesn't serve — the page just hangs with no error. Moving the frontend to AWS Amplify Hosting fixed it for free: same static files, GitHub-connected auto-deploy, and real HTTPS via CloudFront underneath, with no certificate or DNS work required.

**No Bedrock free tier, and the number moved.** Lambda, API Gateway, and Amplify Hosting are genuinely $0 at demo volume. Bedrock inference isn't: Nova Micro is sub-cent per call, and the Stability control-sketch model runs $0.07/image in us-east-1 — pennies for a weekend, but worth being precise about "$0 hosting" versus "$0 total."

## Link to App or Repo

Live app: https://main.d3by0u4ajkuhk0.amplifyapp.com

Code: https://github.com/Deeplomatcode/moodmuse

Confirmed working end-to-end in a real browser across multiple prompts — a "wet wood after rain" prompt returns an original poem and a matching AI-generated image of rain-damp wooden planks; a "futuristic smart city at sunset" prompt returns a distinct poem and image, with the Generate button's accent color visibly shifting to match the generated artwork's dominant tone. No mock data, no placeholders.

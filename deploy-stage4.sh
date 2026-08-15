#!/usr/bin/env bash
# =============================================================================
# MoodMuse — Stage 4 deploy script
# Creates an S3 bucket configured for static website hosting and uploads
# frontend/index.html.
#
# Idempotent: safe to re-run. Bucket creation is skipped if the bucket already
# exists. Public-access settings, bucket policy, and website config are
# re-applied on every run (idempotent operations).
#
# Prerequisites:
#   - deploy-stage1.sh has been run (Lambda exists)
#   - deploy-stage2.sh has been run (API Gateway exists, invoke URL known)
#   - frontend/index.html has been updated: API_URL must point at the real
#     API Gateway invoke URL, NOT http://localhost:8000/generate
#
# Usage:
#   chmod +x deploy-stage4.sh
#   ./deploy-stage4.sh
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REGION="us-east-1"
INDEX_FILE="frontend/index.html"

# Resolve account ID automatically if not already set
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
echo "Using AWS account: $AWS_ACCOUNT_ID  region: $REGION"

# Bucket name: account ID makes it globally unique without any manual choice
BUCKET_NAME="moodmuse-${AWS_ACCOUNT_ID}-${REGION}"
echo "Bucket name      : $BUCKET_NAME"

# ── Step 0: Pre-flight — confirm index.html is not still pointing at localhost ─
echo ""
echo "── Step 0: Pre-flight checks ────────────────────────────────────────────"

if [ ! -f "$INDEX_FILE" ]; then
  echo "ERROR: $INDEX_FILE not found."
  echo "       Run this script from the moodmuse/ project root."
  exit 1
fi

if grep -q "localhost:8000" "$INDEX_FILE"; then
  echo ""
  echo "  ⚠️  WARNING: frontend/index.html still contains 'localhost:8000'."
  echo "     The deployed site will call localhost — which won't work for visitors."
  echo ""
  echo "     Before uploading, update the API_URL constant in index.html:"
  echo "       const API_URL = \"https://<api-id>.execute-api.us-east-1.amazonaws.com/generate\";"
  echo ""
  echo "     You can get the correct URL by running deploy-stage2.sh."
  echo ""
  read -r -p "  Upload anyway? (y/N) " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted. Update API_URL in index.html and re-run."
    exit 1
  fi
  echo "  Proceeding at your request."
fi

echo "Pre-flight OK."

# ── Step 1: Create S3 bucket (skip if already exists) ─────────────────────────
echo ""
echo "── Step 1: S3 bucket ────────────────────────────────────────────────────"

if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
  echo "Bucket '$BUCKET_NAME' already exists — skipping creation."
else
  # us-east-1 does not accept a LocationConstraint — it must be omitted
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION"
  echo "Created bucket: $BUCKET_NAME"
fi

# ── Step 2: Disable Block Public Access ───────────────────────────────────────
# This is the most common silent-failure point: if any of these four settings
# remain true, the public-read bucket policy (Step 3) will be silently rejected
# and the site will return 403 for every request with no useful error message.
echo ""
echo "── Step 2: Disable Block Public Access (required for public-read policy) ─"
echo "   Note: this is a common silent-failure point — the bucket policy in"
echo "   Step 3 will not take effect until all four BlockPublicAccess settings"
echo "   are set to false."

aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
  --region "$REGION"

echo "Block Public Access disabled."

# ── Step 3: Apply public-read bucket policy ───────────────────────────────────
echo ""
echo "── Step 3: Bucket policy (public read on all objects) ───────────────────"

BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
EOF
)

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy "$BUCKET_POLICY" \
  --region "$REGION"

echo "Bucket policy applied (s3:GetObject on $BUCKET_NAME/*)."

# ── Step 4: Enable static website hosting ─────────────────────────────────────
echo ""
echo "── Step 4: Static website hosting ──────────────────────────────────────"

aws s3api put-bucket-website \
  --bucket "$BUCKET_NAME" \
  --website-configuration '{"IndexDocument":{"Suffix":"index.html"}}' \
  --region "$REGION"

echo "Static website hosting enabled (index document: index.html)."

# ── Step 5: Upload index.html ─────────────────────────────────────────────────
echo ""
echo "── Step 5: Upload frontend/index.html ───────────────────────────────────"

aws s3 cp "$INDEX_FILE" "s3://${BUCKET_NAME}/index.html" \
  --content-type "text/html" \
  --region "$REGION"

echo "Uploaded index.html to s3://$BUCKET_NAME/index.html"

# ── Done — print website URL ──────────────────────────────────────────────────
# S3 website endpoints in us-east-1 use this hostname format.
WEBSITE_URL="http://${BUCKET_NAME}.s3-website-${REGION}.amazonaws.com"

echo ""
echo "── Done ─────────────────────────────────────────────────────────────────"
echo ""
echo "  Site URL: ${WEBSITE_URL}"
echo ""
echo "  Open that URL in a browser to confirm the app loads."
echo ""
echo "  ⚠️  Reminder checklist before sharing the link:"
echo "     1. API_URL in index.html points at your API Gateway URL (not localhost)"
echo "        — get it from the output of deploy-stage2.sh"
echo "     2. MOCK_MODE=false is set in the Lambda console environment variables"
echo "        — otherwise every request returns the hardcoded sample poem/image"
echo "     3. Bedrock model access for Nova Micro + Nova Canvas is enabled"
echo "        in the Bedrock console (us-east-1)"

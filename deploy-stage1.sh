#!/usr/bin/env bash
# =============================================================================
# MoodMuse — Stage 1 deploy script
# Creates the IAM role + Lambda function, or updates the function code if it
# already exists. Run from the moodmuse/ project root.
#
# Prerequisites:
#   - AWS CLI configured with credentials for your account (us-east-1)
#   - Your account ID set below, OR export AWS_ACCOUNT_ID before running
#
# Usage:
#   chmod +x deploy-stage1.sh
#   ./deploy-stage1.sh
# =============================================================================

set -euo pipefail

# ── Config — edit these ───────────────────────────────────────────────────────
REGION="us-east-1"
FUNCTION_NAME="moodmuse-generate"
ROLE_NAME="moodmuse-lambda-role"
POLICY_NAME="moodmuse-bedrock-policy"
RUNTIME="python3.12"
HANDLER="handler.lambda_handler"
TIMEOUT=29        # 29s — just under the HTTP API 30s hard cap
MEMORY=256        # MB — text+image gen is CPU-light

# Resolve account ID automatically if not already set
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
echo "Using AWS account: $AWS_ACCOUNT_ID  region: $REGION"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

# ── Step 1: Create IAM role (skip if it already exists) ───────────────────────
echo ""
echo "── Step 1: IAM role ─────────────────────────────────────────────────────"
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "Role $ROLE_NAME already exists — skipping creation."
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://iam/lambda-trust-policy.json \
    --region "$REGION"
  echo "Created role: $ROLE_NAME"
fi

# ── Step 2: Attach AWS managed policy for basic Lambda execution (CloudWatch) ─
echo ""
echo "── Step 2: Attach AWSLambdaBasicExecutionRole ───────────────────────────"
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
  2>/dev/null || echo "Policy already attached."

# ── Step 3: Create or update the inline Bedrock policy ───────────────────────
echo ""
echo "── Step 3: Bedrock inline policy ────────────────────────────────────────"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file://iam/lambda-bedrock-policy.json
echo "Inline policy applied: $POLICY_NAME"

# ── Step 4: Zip Lambda code ───────────────────────────────────────────────────
echo ""
echo "── Step 4: Packaging Lambda ─────────────────────────────────────────────"
cd lambda
zip -q -r ../function.zip handler.py
cd ..
echo "Created function.zip"

# ── Step 5: Create or update Lambda function ──────────────────────────────────
echo ""
echo "── Step 5: Deploy Lambda ────────────────────────────────────────────────"
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &>/dev/null; then
  echo "Function exists — updating code..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://function.zip \
    --region "$REGION"

  echo "Waiting for code update to finish propagating..."
  aws lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION"

  echo "Updating configuration..."
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --timeout "$TIMEOUT" \
    --memory-size "$MEMORY" \
    --region "$REGION"
else
  echo "Creating new function — waiting 10s for IAM role to propagate..."
  sleep 10

  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime "$RUNTIME" \
    --role "$ROLE_ARN" \
    --handler "$HANDLER" \
    --zip-file fileb://function.zip \
    --timeout "$TIMEOUT" \
    --memory-size "$MEMORY" \
    --region "$REGION"
fi

echo ""
echo "── Done ─────────────────────────────────────────────────────────────────"
echo "Function name : $FUNCTION_NAME"
echo "Region        : $REGION"
echo "Timeout       : ${TIMEOUT}s"
echo ""
echo "Next: test in the Lambda console using lambda/test_event.json"
echo "      then run deploy-stage2.sh to wire up API Gateway."

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f function.zip

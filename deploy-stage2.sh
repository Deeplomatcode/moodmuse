#!/usr/bin/env bash
# =============================================================================
# MoodMuse — Stage 2 deploy script
# Creates an API Gateway HTTP API and wires it to the moodmuse-generate Lambda.
#
# Idempotent: safe to re-run. Existing API / integration / route / stage are
# reused; only the Lambda permission may be re-added (harmless duplicate error
# is suppressed).
#
# Prerequisites:
#   - deploy-stage1.sh has already been run (Lambda function exists)
#   - AWS CLI configured for us-east-1
#
# Usage:
#   chmod +x deploy-stage2.sh
#   ./deploy-stage2.sh
#
# CORS NOTE: Do NOT enable CORS on the API Gateway. CORS headers are returned
# by the Lambda handler (handler.py CORS_HEADERS). Enabling both produces
# duplicate Access-Control-Allow-Origin headers and breaks browsers.
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REGION="us-east-1"
FUNCTION_NAME="moodmuse-generate"
API_NAME="moodmuse-api"

# Resolve account ID automatically if not already set
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
echo "Using AWS account: $AWS_ACCOUNT_ID  region: $REGION"

LAMBDA_ARN="arn:aws:lambda:${REGION}:${AWS_ACCOUNT_ID}:function:${FUNCTION_NAME}"

# ── Step 1: Confirm Lambda exists ─────────────────────────────────────────────
echo ""
echo "── Step 1: Confirm Lambda exists ────────────────────────────────────────"
if ! aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &>/dev/null; then
  echo "ERROR: Lambda function '$FUNCTION_NAME' not found in $REGION."
  echo "       Run deploy-stage1.sh first, then re-run this script."
  exit 1
fi
echo "Lambda function '$FUNCTION_NAME' found."

# ── Step 2: Create HTTP API (or reuse existing) ───────────────────────────────
echo ""
echo "── Step 2: HTTP API ─────────────────────────────────────────────────────"

# Look for an existing API with this name
EXISTING_API_ID=$(
  aws apigatewayv2 get-apis \
    --region "$REGION" \
    --query "Items[?Name=='${API_NAME}'].ApiId" \
    --output text
)

if [ -n "$EXISTING_API_ID" ] && [ "$EXISTING_API_ID" != "None" ]; then
  API_ID="$EXISTING_API_ID"
  echo "API '$API_NAME' already exists (id: $API_ID) — reusing."
else
  API_ID=$(
    aws apigatewayv2 create-api \
      --name "$API_NAME" \
      --protocol-type HTTP \
      --region "$REGION" \
      --query ApiId \
      --output text
  )
  echo "Created HTTP API '$API_NAME' (id: $API_ID)."
fi

# ── Step 3: Create Lambda integration (payload format 2.0) ───────────────────
echo ""
echo "── Step 3: Lambda integration (payload format 2.0) ──────────────────────"
# Payload format 2.0 is required: handler.py reads
# event["requestContext"]["http"]["method"], which is the v2 shape.
# If an integration for this function already exists, reuse it.

EXISTING_INTEGRATION_ID=$(
  aws apigatewayv2 get-integrations \
    --api-id "$API_ID" \
    --region "$REGION" \
    --query "Items[?IntegrationUri=='${LAMBDA_ARN}'].IntegrationId" \
    --output text
)

if [ -n "$EXISTING_INTEGRATION_ID" ] && [ "$EXISTING_INTEGRATION_ID" != "None" ]; then
  INTEGRATION_ID="$EXISTING_INTEGRATION_ID"
  echo "Integration already exists (id: $INTEGRATION_ID) — reusing."
else
  INTEGRATION_ID=$(
    aws apigatewayv2 create-integration \
      --api-id "$API_ID" \
      --integration-type AWS_PROXY \
      --integration-uri "$LAMBDA_ARN" \
      --payload-format-version "2.0" \
      --region "$REGION" \
      --query IntegrationId \
      --output text
  )
  echo "Created integration (id: $INTEGRATION_ID)."
fi

INTEGRATION_TARGET="integrations/${INTEGRATION_ID}"

# ── Step 4: Create POST /generate route (or reuse) ────────────────────────────
echo ""
echo "── Step 4: Route POST /generate ─────────────────────────────────────────"

EXISTING_ROUTE_ID=$(
  aws apigatewayv2 get-routes \
    --api-id "$API_ID" \
    --region "$REGION" \
    --query "Items[?RouteKey=='POST /generate'].RouteId" \
    --output text
)

if [ -n "$EXISTING_ROUTE_ID" ] && [ "$EXISTING_ROUTE_ID" != "None" ]; then
  echo "Route 'POST /generate' already exists (id: $EXISTING_ROUTE_ID) — reusing."
else
  ROUTE_ID=$(
    aws apigatewayv2 create-route \
      --api-id "$API_ID" \
      --route-key "POST /generate" \
      --target "$INTEGRATION_TARGET" \
      --region "$REGION" \
      --query RouteId \
      --output text
  )
  echo "Created route 'POST /generate' (id: $ROUTE_ID)."
fi

# ── Step 5: Create/update \$default stage with auto-deploy enabled ─────────────
echo ""
echo "── Step 5: \$default stage with auto-deploy ──────────────────────────────"

EXISTING_STAGE=$(
  aws apigatewayv2 get-stages \
    --api-id "$API_ID" \
    --region "$REGION" \
    --query "Items[?StageName=='\$default'].StageName" \
    --output text
)

if [ -n "$EXISTING_STAGE" ] && [ "$EXISTING_STAGE" != "None" ]; then
  echo "Stage '\$default' already exists — ensuring auto-deploy is on."
  aws apigatewayv2 update-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$REGION" > /dev/null
  echo "Stage '\$default' updated (auto-deploy: enabled)."
else
  aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$REGION" > /dev/null
  echo "Stage '\$default' created (auto-deploy: enabled)."
fi

# ── Step 6: Grant API Gateway permission to invoke the Lambda ─────────────────
echo ""
echo "── Step 6: Lambda invoke permission ─────────────────────────────────────"
# Source ARN is scoped to this specific API — not a wildcard.
SOURCE_ARN="arn:aws:execute-api:${REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/*/generate"

# add-permission is idempotent by statement ID; suppress the "already exists"
# error so a re-run doesn't fail the script.
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "moodmuse-apigw-invoke" \
  --action "lambda:InvokeFunction" \
  --principal "apigateway.amazonaws.com" \
  --source-arn "$SOURCE_ARN" \
  --region "$REGION" \
  2>/dev/null \
  && echo "Lambda invoke permission granted." \
  || echo "Lambda invoke permission already exists — skipping."

# ── Done — print invoke URL ───────────────────────────────────────────────────
INVOKE_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/generate"

echo ""
echo "── Done ─────────────────────────────────────────────────────────────────"
echo ""
echo "  API endpoint: ${INVOKE_URL}"
echo ""
echo "  To go live: open frontend/index.html and replace the API_URL constant:"
echo "    const API_URL = \"http://localhost:8000/generate\";"
echo "  with:"
echo "    const API_URL = \"${INVOKE_URL}\";"
echo ""
echo "  Also set MOCK_MODE=false in the Lambda console environment variables"
echo "  before deploying the frontend, or all requests will return mock data."
echo ""
echo "  Test with curl:"
echo "    curl -s -X POST ${INVOKE_URL} \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"prompt\": \"rainy Sunday morning\"}' | python3 -m json.tool"

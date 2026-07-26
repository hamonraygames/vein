#!/usr/bin/env bash
# Provisions (or updates) the leaderboard's AWS backend: two DynamoDB tables,
# an IAM role, a Lambda function, and an HTTP API in front of it. Plain
# aws-cli, no CDK/Terraform/SAM — matches deploy_web.sh's own approach for
# the rest of this project's infra. Safe to re-run: every step checks
# whether its resource already exists before creating it, and the Lambda
# code/config are always updated in place.
set -euo pipefail

cd "$(dirname "$0")"

REGION="eu-north-1"
PLAYERS_TABLE="vein-leaderboard-players"
META_TABLE="vein-leaderboard-meta"
ROLE_NAME="vein-leaderboard-lambda-role"
FUNCTION_NAME="vein-leaderboard-submit"
API_NAME="vein-leaderboard-api"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "==> Account $ACCOUNT_ID, region $REGION"

# --- DynamoDB ----------------------------------------------------------------

table_exists() {
	aws dynamodb describe-table --region "$REGION" --table-name "$1" >/dev/null 2>&1
}

if table_exists "$PLAYERS_TABLE"; then
	echo "==> Table $PLAYERS_TABLE already exists"
else
	echo "==> Creating table $PLAYERS_TABLE"
	aws dynamodb create-table --region "$REGION" \
		--table-name "$PLAYERS_TABLE" \
		--attribute-definitions AttributeName=player_id,AttributeType=S \
		--key-schema AttributeName=player_id,KeyType=HASH \
		--billing-mode PAY_PER_REQUEST >/dev/null
fi

if table_exists "$META_TABLE"; then
	echo "==> Table $META_TABLE already exists"
else
	echo "==> Creating table $META_TABLE"
	aws dynamodb create-table --region "$REGION" \
		--table-name "$META_TABLE" \
		--attribute-definitions AttributeName=id,AttributeType=S \
		--key-schema AttributeName=id,KeyType=HASH \
		--billing-mode PAY_PER_REQUEST >/dev/null
fi

for t in "$PLAYERS_TABLE" "$META_TABLE"; do
	aws dynamodb wait table-exists --region "$REGION" --table-name "$t"
done

# Seed the single meta counters item if it isn't there yet — the Lambda's
# `ADD total_plays :one` only works once the attribute exists as a number,
# and put-item with `attribute_not_exists` keeps this safe to re-run.
aws dynamodb put-item --region "$REGION" --table-name "$META_TABLE" \
	--item '{"id": {"S": "totals"}, "total_players": {"N": "0"}, "total_plays": {"N": "0"}}' \
	--condition-expression "attribute_not_exists(id)" >/dev/null 2>&1 || true

# --- IAM -----------------------------------------------------------------

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
	echo "==> Role $ROLE_NAME already exists"
else
	echo "==> Creating role $ROLE_NAME"
	aws iam create-role --role-name "$ROLE_NAME" \
		--assume-role-policy-document '{
			"Version": "2012-10-17",
			"Statement": [{
				"Effect": "Allow",
				"Principal": {"Service": "lambda.amazonaws.com"},
				"Action": "sts:AssumeRole"
			}]
		}' >/dev/null
	aws iam attach-role-policy --role-name "$ROLE_NAME" \
		--policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "vein-leaderboard-ddb" \
	--policy-document "{
		\"Version\": \"2012-10-17\",
		\"Statement\": [{
			\"Effect\": \"Allow\",
			\"Action\": [\"dynamodb:GetItem\", \"dynamodb:PutItem\", \"dynamodb:UpdateItem\", \"dynamodb:Scan\"],
			\"Resource\": [
				\"arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$PLAYERS_TABLE\",
				\"arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$META_TABLE\"
			]
		}]
	}" >/dev/null

ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"

# IAM role propagation is eventually consistent — a Lambda create right
# after a fresh role can fail with "role cannot be assumed." Only matters
# the very first run; harmless to wait every time.
echo "==> Waiting for IAM role to propagate"
sleep 10

# --- Lambda ----------------------------------------------------------------

echo "==> Zipping Lambda code"
rm -f /tmp/vein-leaderboard-submit.zip
zip -q -r /tmp/vein-leaderboard-submit.zip submit.js

ENV_VARS="Variables={PLAYERS_TABLE=$PLAYERS_TABLE,META_TABLE=$META_TABLE}"

if aws lambda get-function --region "$REGION" --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
	echo "==> Updating function $FUNCTION_NAME"
	aws lambda update-function-code --region "$REGION" --function-name "$FUNCTION_NAME" \
		--zip-file fileb:///tmp/vein-leaderboard-submit.zip >/dev/null
	aws lambda wait function-updated --region "$REGION" --function-name "$FUNCTION_NAME"
	aws lambda update-function-configuration --region "$REGION" --function-name "$FUNCTION_NAME" \
		--environment "$ENV_VARS" >/dev/null
else
	echo "==> Creating function $FUNCTION_NAME"
	aws lambda create-function --region "$REGION" --function-name "$FUNCTION_NAME" \
		--runtime nodejs20.x --handler submit.handler --role "$ROLE_ARN" \
		--zip-file fileb:///tmp/vein-leaderboard-submit.zip \
		--timeout 10 --memory-size 256 \
		--environment "$ENV_VARS" >/dev/null
fi
aws lambda wait function-active --region "$REGION" --function-name "$FUNCTION_NAME"

FUNCTION_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$FUNCTION_NAME"

# --- API Gateway (HTTP API) -------------------------------------------------

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
	--query "Items[?Name=='$API_NAME'].ApiId" --output text)"

if [[ -n "$API_ID" && "$API_ID" != "None" ]]; then
	echo "==> API $API_NAME already exists ($API_ID)"
else
	echo "==> Creating HTTP API $API_NAME"
	API_ID="$(aws apigatewayv2 create-api --region "$REGION" \
		--name "$API_NAME" --protocol-type HTTP \
		--cors-configuration 'AllowOrigins=*,AllowMethods=POST,OPTIONS,AllowHeaders=content-type' \
		--query ApiId --output text)"
	aws apigatewayv2 create-stage --region "$REGION" --api-id "$API_ID" \
		--stage-name '$default' --auto-deploy >/dev/null
fi

INTEGRATION_ID="$(aws apigatewayv2 get-integrations --region "$REGION" --api-id "$API_ID" \
	--query "Items[?IntegrationUri=='$FUNCTION_ARN'].IntegrationId" --output text)"
if [[ -z "$INTEGRATION_ID" || "$INTEGRATION_ID" == "None" ]]; then
	echo "==> Creating Lambda integration"
	INTEGRATION_ID="$(aws apigatewayv2 create-integration --region "$REGION" --api-id "$API_ID" \
		--integration-type AWS_PROXY --integration-uri "$FUNCTION_ARN" \
		--payload-format-version "2.0" --query IntegrationId --output text)"
fi

ROUTE_EXISTS="$(aws apigatewayv2 get-routes --region "$REGION" --api-id "$API_ID" \
	--query "Items[?RouteKey=='POST /score'].RouteId" --output text)"
if [[ -z "$ROUTE_EXISTS" || "$ROUTE_EXISTS" == "None" ]]; then
	echo "==> Creating route POST /score"
	aws apigatewayv2 create-route --region "$REGION" --api-id "$API_ID" \
		--route-key "POST /score" --target "integrations/$INTEGRATION_ID" >/dev/null
fi

# Idempotent: a statement-id collision means the permission is already
# there, which is exactly the state we want.
aws lambda add-permission --region "$REGION" --function-name "$FUNCTION_NAME" \
	--statement-id "vein-leaderboard-apigw" --action lambda:InvokeFunction \
	--principal apigateway.amazonaws.com \
	--source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*/score" \
	>/dev/null 2>&1 || true

ENDPOINT="$(aws apigatewayv2 get-api --region "$REGION" --api-id "$API_ID" --query ApiEndpoint --output text)"
echo "==> Done: POST $ENDPOINT/score"
echo "    Put that URL in scripts/game.gd's LEADERBOARD_URL constant."

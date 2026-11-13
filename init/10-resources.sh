#!/bin/sh
# Idempotent bootstrap, run by floci's `ready` hook (/bin/sh).
# A hook that exits non-zero SHUTS FLOCI DOWN, so this script never fails: every command tolerates
# "already exists" and the script always ends with exit 0.
#
# Settings (environment of the container, all optional):
#   LOCAL_AWS_BUCKETS     comma separated S3 buckets to create
#   LOCAL_AWS_CORS_BUCKETS comma separated buckets that get a permissive CORS configuration
#                         (browser uploads via presigned POST); created first if missing
#   LOCAL_AWS_QUEUES      comma separated SQS queue names; each gets `<name>-dead-letter-queue`,
#                         a 30 minute visibility timeout and a redrive after 3 receives
#   LOCAL_AWS_EVENT_BUS   EventBridge bus to create (default `local`). Events put on a missing bus are dropped.
#   LOCAL_AWS_MAIL_BUCKET bucket for the captured mails (default `local-mails`)

# The base image presets AWS_DEFAULT_REGION=us-east-1, so FLOCI_DEFAULT_REGION (the region floci serves) wins.
REGION="${FLOCI_DEFAULT_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_ENDPOINT_URL="http://localhost:4566"
BUS="${LOCAL_AWS_EVENT_BUS:-local}"
MAIL_BUCKET="${LOCAL_AWS_MAIL_BUCKET:-local-mails}"

make_bucket() {
  b="$1"
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    echo "[init] bucket $b exists"
  else
    # us-east-1 must not carry a LocationConstraint
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$b" >/dev/null 2>&1
    else
      aws s3api create-bucket --bucket "$b" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null 2>&1
    fi && echo "[init] bucket $b created" || echo "[init] WARN bucket $b not created"
  fi
}

make_queue() {
  q="$1"; dlq="$q-dead-letter-queue"
  aws sqs create-queue --queue-name "$dlq" >/dev/null 2>&1 || echo "[init] WARN dead-letter queue $dlq not created"
  dlq_url=$(aws sqs get-queue-url --queue-name "$dlq" --query QueueUrl --output text 2>/dev/null)
  dlq_arn=$(aws sqs get-queue-attributes --queue-url "$dlq_url" --attribute-names QueueArn \
    --query Attributes.QueueArn --output text 2>/dev/null)
  if [ -n "$dlq_arn" ] && [ "$dlq_arn" != "None" ]; then
    printf '{"VisibilityTimeout":"1800","RedrivePolicy":"{\\"deadLetterTargetArn\\":\\"%s\\",\\"maxReceiveCount\\":\\"3\\"}"}' \
      "$dlq_arn" > /tmp/queue-attributes.json
    aws sqs create-queue --queue-name "$q" --attributes file:///tmp/queue-attributes.json >/dev/null 2>&1 \
      && echo "[init] queue $q ready (dead-letter queue $dlq)" || echo "[init] WARN queue $q not created"
  else
    echo "[init] WARN no dead-letter queue arn, queue $q skipped"
  fi
}

put_cors() {
  b="$1"
  make_bucket "$b"
  printf '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","POST","PUT","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["ETag"]}]}' \
    > /tmp/cors.json
  aws s3api put-bucket-cors --bucket "$b" --cors-configuration file:///tmp/cors.json >/dev/null 2>&1 \
    && echo "[init] CORS on bucket $b" || echo "[init] WARN CORS on bucket $b not set"
}

old_ifs="$IFS"; IFS=','
for b in $LOCAL_AWS_BUCKETS; do [ -n "$b" ] && make_bucket "$b"; done
make_bucket "$MAIL_BUCKET"
for b in $LOCAL_AWS_CORS_BUCKETS; do [ -n "$b" ] && put_cors "$b"; done
for q in $LOCAL_AWS_QUEUES; do [ -n "$q" ] && make_queue "$q"; done
IFS="$old_ifs"

if aws events describe-event-bus --name "$BUS" >/dev/null 2>&1; then
  echo "[init] event bus $BUS exists"
else
  aws events create-event-bus --name "$BUS" >/dev/null 2>&1 \
    && echo "[init] event bus $BUS created" || echo "[init] WARN event bus $BUS not created"
fi

touch /tmp/local-aws-ready
exit 0

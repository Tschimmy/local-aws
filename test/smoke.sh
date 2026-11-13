#!/usr/bin/env bash
# Smoke test of the image: starts it, waits for "healthy" (floci up and init done), and checks the bootstrap, the event
# bridge and the mail capture. Usage: test/smoke.sh [image]   (default: local-aws:test, built from this folder)
set -euo pipefail

IMAGE="${1:-local-aws:test}"
NAME="local-aws-smoke-$$"
cd "$(dirname "$0")/.."
[ "$#" -eq 0 ] && docker build -q -t "$IMAGE" .

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -p 127.0.0.1:0:4566 -p 127.0.0.1:0:4599 \
  -e FLOCI_DEFAULT_REGION=eu-central-1 \
  -e LOCAL_AWS_BUCKETS=bucket-one,bucket-two \
  -e LOCAL_AWS_CORS_BUCKETS=uploads \
  -e LOCAL_AWS_QUEUES=jobs \
  -e LOCAL_AWS_EVENT_BUS=smoke-bus \
  -e LOCAL_AWS_SOURCE_PREFIX=app. \
  -e LOCAL_AWS_IMAGE_VARIANTS=x-small,small \
  "$IMAGE" >/dev/null

echo "waiting for healthy..."
for _ in $(seq 1 90); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = healthy ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = healthy ] || { docker logs "$NAME" | tail -30; echo "FAIL: not healthy"; exit 1; }

AWS=(docker exec "$NAME" aws --endpoint-url http://localhost:4566 --region eu-central-1)
BRIDGE="http://127.0.0.1:$(docker port "$NAME" 4599/tcp | head -1 | sed 's/.*://')"
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; docker logs "$NAME" | tail -30; exit 1; }

# 1. bootstrap
buckets=$("${AWS[@]}" s3api list-buckets --query 'Buckets[].Name' --output text)
for b in bucket-one bucket-two local-mails; do [[ "$buckets" == *"$b"* ]] || fail "bucket $b missing"; done; pass "buckets created"
queues=$("${AWS[@]}" sqs list-queues --query 'QueueUrls[]' --output text)
[[ "$queues" == *"/jobs"* && "$queues" == *"jobs-dead-letter-queue"* ]] || fail "queue and dead-letter queue missing"; pass "queue with dead-letter queue created"
"${AWS[@]}" events describe-event-bus --name smoke-bus >/dev/null || fail "bus missing"; pass "event bus created"

# 2. bridge: event -> bus -> rule -> queue
ARN=arn:aws:sqs:eu-central-1:000000000000:jobs
"${AWS[@]}" events put-rule --name r --event-bus-name smoke-bus --event-pattern '{"detail-type":["Thing"],"detail":{"kind":["a"]}}' >/dev/null
"${AWS[@]}" events put-targets --rule r --event-bus-name smoke-bus --targets "Id=q,Arn=$ARN" >/dev/null
code=$(curl -s -o /tmp/smoke-bridge.out -w '%{http_code}' -X POST -d '{"kind":"a"}' "$BRIDGE/svc/Thing"); [ "$code" = 200 ] && [ "$(cat /tmp/smoke-bridge.out)" = '{}' ] || fail "bridge answer $code"
curl -s -o /dev/null -X POST -d '{"kind":"b"}' "$BRIDGE/svc/Thing"
msg=$("${AWS[@]}" sqs receive-message --queue-url http://localhost:4566/000000000000/jobs --max-number-of-messages 10 --wait-time-seconds 3 --query 'Messages[].Body' --output text)
[[ "$msg" == *'"source": "app.svc"'* || "$msg" == *'"source":"app.svc"'* ]] || fail "event not on the queue with the source prefix: $msg"
[[ "$msg" != *'"kind": "b"'* && "$msg" != *'"kind":"b"'* ]] || fail "event that does not match the pattern arrived"
pass "event reaches the queue, pattern filters, source prefix applied"

# 3. mail capture and the handler folder
post() { curl -s -X POST -d "$2" "$BRIDGE$1"; }
post /_handler/begin '{"name":"my-handler"}' >/dev/null
post /notification/emailSend '{"to":{"address":"a@example.test"},"subject":"S1","html":"<p>one</p>"}' | grep -q '"id"' || fail "capture answer"
post /_handler/end '{"name":"my-handler"}' >/dev/null
post /mail/emailSend '{"to":{"address":"b@example.test"},"subject":"S2","html":"<p>two</p>"}' >/dev/null
keys=$("${AWS[@]}" s3api list-objects-v2 --bucket local-mails --query 'Contents[].Key' --output text)
[[ "$keys" == *"my-handler/"*".html"* && "$keys" == *"other/"*".json"* ]] || fail "mail folders wrong: $keys"
pass "mails captured, folder per handler (my-handler/, other/)"

# 4. notification stubs: idempotency dedupe, attachment presign, clear 501
first=$(post /notification/emailSend '{"to":{"address":"c@example.test"},"subject":"S3","idempotencyKey":"smoke-key-1","html":"<p>x</p>"}')
second=$(post /notification/emailSend '{"to":{"address":"c@example.test"},"subject":"S3","idempotencyKey":"smoke-key-1","html":"<p>x</p>"}')
[ "$first" = "$second" ] || fail "idempotencyKey not deduped: $first vs $second"
pass "repeated idempotencyKey answers the same id without a second capture"
upload=$(curl -s -X PUT -d '{"filename":"invite.ics"}' "$BRIDGE/notification/emailAttachmentRequestUpload")
[[ "$upload" == *'"preSignedUrl"'* && "$upload" == *'"key"'* ]] || fail "attachment stub answer: $upload"
url=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["preSignedUrl"])' "$upload")
akey=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["key"])' "$upload")
S3PORT="http://127.0.0.1:$(docker port "$NAME" 4566/tcp | head -1 | sed 's/.*://')"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary 'ics-content' "${url/http:\/\/localhost:4566/$S3PORT}")
[ "$code" = 200 ] || fail "presigned PUT answered $code"
"${AWS[@]}" s3api head-object --bucket local-mails --key "$akey" >/dev/null || fail "attachment object missing: $akey"
group=$(post /notification/sendingGroupCreate '{"name":"g"}')
[[ "$group" == *'"id"'* && "$group" == *'"status"'* ]] || fail "sendingGroupCreate stub answer: $group"
code=$(curl -s -o /tmp/smoke-501.out -w '%{http_code}' "$BRIDGE/notification/emailList")
[ "$code" = 501 ] && grep -q 'not implemented' /tmp/smoke-501.out || fail "GET operation not a clear 501: $code"
pass "attachment presign works end to end, sendingGroupCreate stubbed, reads answer 501"

# 5. CORS bucket and the image-resize Lambda stand-in
cors=$("${AWS[@]}" s3api get-bucket-cors --bucket uploads --query 'CORSRules[0].AllowedMethods' --output text 2>/dev/null)
[[ "$cors" == *POST* ]] || fail "CORS on bucket uploads missing: $cors"; pass "CORS configuration on the uploads bucket"
docker exec "$NAME" sh -c 'echo img > /tmp/pic.png' >/dev/null
"${AWS[@]}" s3 cp /tmp/pic.png s3://uploads/v1/f1/pic-original.png >/dev/null
code=$(curl -s -o /tmp/smoke-lambda.out -w '%{http_code}' -X POST -H 'X-Amz-Invocation-Type: Event' \
  -d '{"Records":[{"s3":{"bucket":{"name":"uploads"},"object":{"key":"v1/f1/pic-original.png"}}}]}' \
  "$BRIDGE/2015-03-31/functions/image-processing-dev/invocations")
[ "$code" = 202 ] || fail "lambda invoke answered $code"
variants=$("${AWS[@]}" s3api list-objects-v2 --bucket uploads --prefix v1/f1/ --query 'Contents[].Key' --output text)
[[ "$variants" == *"pic-x-small.png"* && "$variants" == *"pic-small.png"* ]] || fail "variant copies missing: $variants"
pass "lambda invoke answers 202 and copies the original to the variant keys"

# 6. restart keeps state
docker restart "$NAME" >/dev/null; sleep 3
for _ in $(seq 1 90); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = healthy ] && break; sleep 1; done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = healthy ] || fail "not healthy after restart"
"${AWS[@]}" s3api head-bucket --bucket bucket-one >/dev/null || fail "bucket lost after restart (restart of the same container)"; pass "restart: healthy again, init repeat-safe"

echo "all checks passed"

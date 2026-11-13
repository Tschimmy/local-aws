#!/usr/bin/env python3
"""Small HTTP bridge that runs next to floci inside the local-aws image (port 4599).

It replaces four things an app talks to over HTTP in a real environment:

  POST /<source>/<event>         put the request body on the event bus as one event
                                 (Source = LOCAL_AWS_SOURCE_PREFIX + <source>, DetailType = <event>,
                                 Detail = the raw body). Answers 200 and `{}`.
  POST /mail/<operation>         keep a mail instead of sending it: the JSON body (`to`, `from`, `subject`,
  POST /notification/<operation> `html`, ...) goes to the mail bucket as `<folder>/<time>-<operation>-<id>.json`
                                 and `.html`. Answers 200 and `{"id": "..."}` (the shape of EmailSendDto). Nothing is
                                 sent. A repeated `idempotencyKey` answers the first mail's id without a new capture,
                                 as the production notification service would. Two operations whose answers the
                                 eversports handlers read get schema-valid stubs: `emailAttachmentRequestUpload` (and
                                 the public variant, both PUT) answers `{preSignedUrl, key}` with a real presigned PUT
                                 URL into the mail bucket, and `sendingGroupCreate` answers a SendingGroupDto stub.
                                 Every other method or read operation (GET lists, statuses, ...) answers
                                 `501 {"error": ...}`: a clear failure instead of an empty 200 the caller misreads.
  POST /_handler/begin|end       {"name": "..."}: a consumer says which handler it is running. The folder of a
                                 captured mail is the name of the one handler that is running at that moment,
                                 `other` if none or several are. `GET /_handler` shows the state.
  POST /2015-03-31/functions/<name>/invocations
                                 the Lambda Invoke API, for an image-resize function an app calls after an
                                 upload: when the JSON body is S3-event shaped ({"Records": [{"s3": ...}]})
                                 and LOCAL_AWS_IMAGE_VARIANTS is set, each object whose key ends in
                                 `<suffix><ext>` (LOCAL_AWS_IMAGE_ORIGINAL_SUFFIX, default `-original`) is
                                 copied to one key per variant, `<suffix>` replaced by `-<variant>`. No
                                 resizing: the copies hold the original bytes. Answers 202 for
                                 InvocationType Event, otherwise 200 and `null`, like AWS.
  GET  /health                   {"ok": true}

Only the standard library and boto3 (part of the base image) are used.
"""
import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

ENDPOINT = os.environ.get("LOCAL_AWS_ENDPOINT", "http://localhost:4566")
# The base image presets AWS_DEFAULT_REGION=us-east-1, so FLOCI_DEFAULT_REGION (the region floci serves) wins.
REGION = os.environ.get("FLOCI_DEFAULT_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
BUS = os.environ.get("LOCAL_AWS_EVENT_BUS", "local")
MAIL_BUCKET = os.environ.get("LOCAL_AWS_MAIL_BUCKET", "local-mails")
SOURCE_PREFIX = os.environ.get("LOCAL_AWS_SOURCE_PREFIX", "")
PORT = int(os.environ.get("LOCAL_AWS_BRIDGE_PORT", "4599"))
IMAGE_VARIANTS = [v.strip() for v in os.environ.get("LOCAL_AWS_IMAGE_VARIANTS", "").split(",") if v.strip()]
IMAGE_ORIGINAL_SUFFIX = os.environ.get("LOCAL_AWS_IMAGE_ORIGINAL_SUFFIX", "-original")

_credentials = dict(
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
)
events = boto3.client("events", endpoint_url=ENDPOINT, region_name=REGION, **_credentials)
s3 = boto3.client(
    "s3", endpoint_url=ENDPOINT, region_name=REGION, config=Config(s3={"addressing_style": "path"}), **_credentials
)

_lock = threading.Lock()
_in_flight: dict = {}
_idempotency: dict = {}


def log(message: str) -> None:
    print(f"[bridge {time.strftime('%H:%M:%S')}] {message}", flush=True)


def current_handler() -> str:
    with _lock:
        active = [name for name, count in _in_flight.items() if count > 0]
    return active[0] if len(active) == 1 else "other"


def put_object(key: str, body: bytes, content_type: str) -> None:
    try:
        s3.put_object(Bucket=MAIL_BUCKET, Key=key, Body=body, ContentType=content_type)
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") != "NoSuchBucket":
            raise
        s3.create_bucket(Bucket=MAIL_BUCKET)
        s3.put_object(Bucket=MAIL_BUCKET, Key=key, Body=body, ContentType=content_type)


def capture_mail(operation: str, body: str) -> dict:
    mail_id = str(uuid.uuid4())
    try:
        payload = json.loads(body)
    except ValueError:
        payload = {"unparsable": body}
    if not isinstance(payload, dict):
        payload = {"payload": payload}
    html = payload.pop("html", None)
    folder = current_handler()
    base = f"{folder}/{int(time.time() * 1000)}-{operation}-{mail_id[:8]}"
    put_object(f"{base}.json", json.dumps({"operation": operation, "id": mail_id, **payload}, indent=2).encode(), "application/json")
    if isinstance(html, str):
        put_object(f"{base}.html", html.encode(), "text/html; charset=utf-8")
    to = payload.get("to")
    if isinstance(to, list):
        recipient = f"{len(to)} recipients"
    elif isinstance(to, dict):
        recipient = to.get("address")
    else:
        recipient = to
    log(f"mail: {operation} to {recipient}, subject {payload.get('subject')!r} -> s3://{MAIL_BUCKET}/{base}.html")
    return {"id": mail_id}


def ensure_mail_bucket() -> None:
    try:
        s3.head_bucket(Bucket=MAIL_BUCKET)
    except ClientError:
        s3.create_bucket(Bucket=MAIL_BUCKET)


def sending_group_stub() -> dict:
    now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    counts = (
        "sent", "delivered", "opened", "clicked", "bounced", "complaint", "reject",
        "renderedFailure", "deliveredDelay", "unsubscribed", "failed", "processing",
    )
    return {
        "id": str(uuid.uuid4()), "status": "processing", "createdAt": now, "updatedAt": now,
        "totalEmails": 0, **{f"{name}Count": 0 for name in counts},
    }


def handle_notification(operation: str, body: str, method: str):
    """One notification REST operation -> (status, payload). The dedupe on `idempotencyKey` mirrors the production
    notification service, so a redelivered queue message does not capture the mail twice."""
    if operation in ("emailAttachmentRequestUpload", "emailPublicAttachmentRequestUpload"):
        try:
            filename = json.loads(body or "{}").get("filename") or "attachment"
        except ValueError:
            filename = "attachment"
        ensure_mail_bucket()
        key = f"attachments/{uuid.uuid4().hex[:8]}-{filename}"
        url = s3.generate_presigned_url("put_object", Params={"Bucket": MAIL_BUCKET, "Key": key}, ExpiresIn=3600)
        log(f"attachment: {operation} {filename} -> s3://{MAIL_BUCKET}/{key}")
        return 200, {"preSignedUrl": url, "key": key}
    if operation == "sendingGroupCreate":
        group = sending_group_stub()
        log(f"sending group: stub {group['id']}")
        return 200, group
    if method != "POST":
        return 501, {"error": f"not implemented by the local-aws bridge: {method} {operation}"}
    try:
        idempotency_key = json.loads(body).get("idempotencyKey")
    except (ValueError, AttributeError):
        idempotency_key = None
    if idempotency_key:
        with _lock:
            known = _idempotency.get(idempotency_key)
        if known:
            log(f"mail: duplicate suppressed (idempotencyKey {idempotency_key})")
            return 200, {"id": known}
    result = capture_mail(operation, body)
    if idempotency_key:
        with _lock:
            _idempotency[idempotency_key] = result["id"]
    return 200, result


def copy_image_variants(function_name: str, body: str) -> None:
    """The stand-in for an image-resize Lambda: copy the original object to one key per variant."""
    try:
        records = json.loads(body or "{}").get("Records") or []
    except ValueError:
        records = []
    if not IMAGE_VARIANTS:
        log(f"lambda: {function_name} invoked, LOCAL_AWS_IMAGE_VARIANTS not set, nothing copied")
        return
    for record in records:
        s3_part = record.get("s3") or {}
        bucket = (s3_part.get("bucket") or {}).get("name")
        key = (s3_part.get("object") or {}).get("key")
        if not bucket or not key:
            continue
        stem, ext = os.path.splitext(key)
        if not stem.endswith(IMAGE_ORIGINAL_SUFFIX):
            log(f"lambda: {function_name}: key {key} does not end in {IMAGE_ORIGINAL_SUFFIX}{ext or ''}, skipped")
            continue
        base = stem[: -len(IMAGE_ORIGINAL_SUFFIX)]
        copied = 0
        for variant in IMAGE_VARIANTS:
            target = f"{base}-{variant}{ext}"
            try:
                s3.copy_object(Bucket=bucket, Key=target, CopySource={"Bucket": bucket, "Key": key})
                copied += 1
            except ClientError as error:
                log(f"lambda: {function_name}: copy to {target} failed: {error}")
        log(f"lambda: {function_name}: s3://{bucket}/{key} copied to {copied} variant key(s), no resize")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args) -> None:  # silence the default access log
        pass

    def _send(self, status: int, payload) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> str:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length).decode("utf-8") if length else ""

    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        if path == "/health":
            self._send(200, {"ok": True})
        elif path == "/_handler":
            with _lock:
                self._send(200, {"inFlight": {n: c for n, c in _in_flight.items() if c > 0}})
        else:
            parts = [p for p in path.split("/") if p]
            if len(parts) == 2 and parts[0] in ("mail", "notification"):
                self._send(501, {"error": f"not implemented by the local-aws bridge: GET {parts[1]}"})
            else:
                self._send(404, {})

    def do_POST(self) -> None:
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        body = self._body()
        try:
            if len(parts) == 2 and parts[0] == "_handler" and parts[1] in ("begin", "end"):
                name = json.loads(body or "{}").get("name")
                if not name:
                    return self._send(400, {"error": "name missing"})
                with _lock:
                    delta = 1 if parts[1] == "begin" else -1
                    _in_flight[name] = max(0, _in_flight.get(name, 0) + delta)
                return self._send(200, {})
            if len(parts) == 2 and parts[0] in ("mail", "notification"):
                status, payload = handle_notification(parts[1], body, self.command)
                return self._send(status, payload)
            if len(parts) == 4 and parts[0] == "2015-03-31" and parts[1] == "functions" and parts[3] == "invocations":
                copy_image_variants(parts[2], body)
                if self.headers.get("X-Amz-Invocation-Type", "RequestResponse") == "Event":
                    return self._send(202, None)
                return self._send(200, None)
            if len(parts) == 2:
                source, event = parts
                out = events.put_events(
                    Entries=[{"Source": SOURCE_PREFIX + source, "DetailType": event, "Detail": body, "EventBusName": BUS}]
                )
                if out.get("FailedEntryCount"):
                    log(f"event: put failed for {source}/{event}: {out.get('Entries')}")
                    return self._send(400, {})
                log(f"event: {source}/{event} -> bus {BUS}, id {out['Entries'][0].get('EventId')}")
                return self._send(200, {})
            self._send(404, {})
        except Exception as error:  # a failing bridge must answer, not hang the caller
            log(f"ERROR {self.path}: {error}")
            self._send(500, {"error": str(error)})

    # The notification API uses PUT for the attachment-upload and suppression operations.
    do_PUT = do_POST


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log(f"listening on :{PORT}, bus {BUS}, mail bucket {MAIL_BUCKET}, endpoint {ENDPOINT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)

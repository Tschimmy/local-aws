# local-aws

A local AWS in one container, started like a database. It is [floci](https://floci.io/) (a free, MIT-licensed AWS
emulator: S3, SQS, EventBridge, SES, ...) with three things baked in, so an app needs no AWS account and no setup
steps:

- **Bootstrap:** buckets, queues (with dead-letter queues) and an event bus are created at start, from environment
  variables. Starting again changes nothing that exists.
- **Event bridge:** an HTTP endpoint that puts a request body on the event bus, for apps that publish events over HTTP
  instead of calling EventBridge.
- **Mail capture:** an HTTP endpoint that keeps a mail (JSON and rendered HTML) in a bucket instead of sending it, in
  one folder per handler, so you can read it in the floci UI.

The image is `ghcr.io/tschimmy/local-aws`. It is rebuilt weekly on the latest floci (`latest-compat`, not pinned).

## Quick start

```bash
docker run -d --name local-aws -p 127.0.0.1:4566:4566 -p 127.0.0.1:4599:4599 \
  -e FLOCI_DEFAULT_REGION=eu-central-1 \
  -e LOCAL_AWS_BUCKETS=uploads,exports \
  -v local-aws-data:/app/data \
  ghcr.io/tschimmy/local-aws:latest
```

`docker ps` shows `healthy` when floci answers and the bootstrap has finished. In compose, use
`depends_on: local-aws: condition: service_healthy`; [`docker-compose.yml`](docker-compose.yml) is a complete example,
with the optional UI.

Point an app at it with environment variables only (recent AWS SDKs read `AWS_ENDPOINT_URL`):

```bash
AWS_ENDPOINT_URL=http://localhost:4566
AWS_REGION=eu-central-1
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
```

## Settings (container environment)

| Variable | Default | Meaning |
|---|---|---|
| `FLOCI_DEFAULT_REGION` | `us-east-1` | Region floci serves. Use the region of your app. |
| `LOCAL_AWS_BUCKETS` | none | Comma separated buckets to create. |
| `LOCAL_AWS_CORS_BUCKETS` | none | Comma separated buckets that get a permissive CORS configuration (browser uploads via presigned POST); created first if missing. |
| `LOCAL_AWS_IMAGE_VARIANTS` | none | Comma separated variant names for the Lambda stand-in: an invoked image-resize function copies `<key>-original<ext>` to `<key>-<variant><ext>` per name. Unset: an invoke is answered but copies nothing. |
| `LOCAL_AWS_IMAGE_ORIGINAL_SUFFIX` | `-original` | Key suffix (before the extension) the Lambda stand-in replaces with `-<variant>`. |
| `LOCAL_AWS_QUEUES` | none | Comma separated queues. Each gets `<name>-dead-letter-queue`, a 30 minute visibility timeout and a redrive after 3 receives. |
| `LOCAL_AWS_EVENT_BUS` | `local` | Event bus to create, and the bus the bridge puts events on. |
| `LOCAL_AWS_MAIL_BUCKET` | `local-mails` | Bucket for captured mails. |
| `LOCAL_AWS_SOURCE_PREFIX` | empty | Put before the `<source>` of a bridged event (`app.` makes `svc` into `app.svc`). |
| `LOCAL_AWS_BRIDGE_PORT` | `4599` | Port of the bridge. |

State lives in `/app/data` (hybrid storage). Mount a volume there to keep it across `docker rm`. Stop the container
with `docker stop`, not `docker kill`: writes of the last few seconds are flushed on a clean stop.

## The bridge (port 4599)

| Request | What happens |
|---|---|
| `POST /<source>/<event>` | The body becomes one event on the bus: `Source` = prefix + `<source>`, `DetailType` = `<event>`, `Detail` = the body. Answers `200` and `{}`. A bus that does not exist drops events silently, so it is created at start. |
| `POST /mail/<operation>` or `POST /notification/<operation>` | The JSON body (`to`, `from`, `subject`, `html`, ...) is stored in the mail bucket as `<folder>/<time>-<operation>-<id>.json` and `.html`. Answers `200` and `{"id": "..."}`. Nothing is sent. A repeated `idempotencyKey` answers the first mail's id without a new capture. Two operations get schema-valid stubs instead of a capture: `emailAttachmentRequestUpload` / `emailPublicAttachmentRequestUpload` (PUT) answer `{preSignedUrl, key}` with a real presigned PUT URL into the mail bucket, and `sendingGroupCreate` answers a sending-group stub. Other methods and read operations answer `501` with a JSON error. Sources named `mail`, `notification` or `_handler` are therefore not bridgeable. |
| `POST /_handler/begin`, `/_handler/end` | Body `{"name": "my-handler"}`. A consumer that runs handlers says which one is running. The folder of a captured mail is the name of the one handler running at that moment, `other` if none or several are. `GET /_handler` shows the state. |
| `POST /2015-03-31/functions/<name>/invocations` | The Lambda Invoke API, as a stand-in for an image-resize function. An S3-event-shaped body (`{"Records": [{"s3": {"bucket", "object"}}]}`) makes it copy the original object to one key per `LOCAL_AWS_IMAGE_VARIANTS` name — no resizing, the copies hold the original bytes. Answers `202` for `InvocationType: Event`, otherwise `200` and `null`, like AWS. Point only your app's Lambda client here (`AWS_ENDPOINT_URL_LAMBDA=http://localhost:4599`). |
| `GET /health` | `{"ok": true}` |

Rules and targets (which event goes to which queue) are not created here: the app, or a small script next to it, puts
them on the bus with the AWS API, as it would in a real account.

## Seeing what is inside

`docker compose --profile ui up -d` (see [`docker-compose.yml`](docker-compose.yml)) starts the
[floci UI](https://hub.docker.com/r/floci/floci-ui) on <http://localhost:4500>: AWS, then Storage for buckets and
objects, SQS for queues, EventBridge for the bus. Other projects reuse the service from
[`docker-compose.ui.yml`](docker-compose.ui.yml) (usage in its header). (The console built into floci at `/_floci/ui` needs the Docker
socket and does not start here.)

## Develop

```bash
test/smoke.sh          # builds the image and checks bootstrap, bridge, mail capture and restart
```

The GitHub Action ([`build.yml`](.github/workflows/build.yml)) builds on every push to `main` and weekly, runs the
smoke test, and pushes `latest`, the short commit and the date as tags, for `linux/amd64` and `linux/arm64`. The first
time, GitHub creates the package private: open the package in the repository's *Packages* settings and make it public
so that others can pull it without logging in.

## Limits

- floci does what it does: array-valued event patterns differ from AWS in some corners, and services that start
  containers (Lambda, RDS, ECS) need the Docker socket mounted, which this image does not assume.
- Presigned URLs and queue URLs name `localhost:4566`. Another container reaches the API at `http://local-aws:4566`,
  but those URLs still say `localhost`.
- It is a development tool. Do not put anything real into it.

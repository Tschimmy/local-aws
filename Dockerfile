# local-aws: floci (a local AWS emulator) with a bootstrap and a small bridge baked in, so that
# `docker run` or one compose service gives a ready AWS on http://localhost:4566, like a database image.
#
# `latest-compat` bundles the AWS CLI and boto3, which the init script and the bridge use.
# The base is not pinned on purpose: the image is rebuilt weekly and follows floci.
ARG FLOCI_TAG=latest-compat
FROM floci/floci:${FLOCI_TAG}

LABEL org.opencontainers.image.title="local-aws" \
      org.opencontainers.image.description="floci with bootstrap resources, an event bridge and a mail capture" \
      org.opencontainers.image.source="https://github.com/Tschimmy/local-aws"

USER root
COPY --chmod=0755 bin/run.sh /opt/local-aws/run.sh
COPY --chmod=0644 bridge/bridge.py /opt/local-aws/bridge.py
COPY --chmod=0755 init/10-resources.sh /etc/floci/init/ready.d/10-resources.sh

# Hybrid storage keeps state across restarts when /app/data is a volume.
ENV FLOCI_STORAGE_MODE=hybrid \
    AWS_ACCESS_KEY_ID=test \
    AWS_SECRET_ACCESS_KEY=test

EXPOSE 4566 4599

# Ready = floci answers and the init script has finished (it writes the marker; run.sh removes it at start).
HEALTHCHECK --interval=3s --timeout=3s --start-period=5s --retries=40 \
  CMD test -f /tmp/local-aws-ready && curl -fs http://localhost:4566/_floci/health >/dev/null || exit 1

# The base entrypoint drops root and then runs this command as the `floci` user.
CMD ["/opt/local-aws/run.sh"]

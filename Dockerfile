FROM python:3.12.4-alpine

RUN <<EOF
  apk update
  apk add --no-cache \
    bash \
    curl \
    postgresql17-client \
    py3-pip

  curl -sL https://sentry.io/get-cli/ | bash

  pip3 install awscli

  # Create non-root user for security
  addgroup -g 1000 appgroup
  adduser -D -u 1000 -G appgroup -h /home/appuser appuser
EOF

COPY --chown=appuser:appgroup application/ /data/
WORKDIR /data

USER appuser

CMD ["./entrypoint.sh"]

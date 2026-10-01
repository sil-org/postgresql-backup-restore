FROM python:3.12-alpine3.21

ARG GITHUB_REF_NAME=unknown
ARG GITHUB_SHA=unknown
ENV GITHUB_REF_NAME=${GITHUB_REF_NAME}
ENV GITHUB_SHA=${GITHUB_SHA}

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

# AWS RDS CA bundle covering all regions, for verifying the DB server certificate.
# Used only when PGSSLMODE=verify-full and PGSSLROOTCERT=/etc/ssl/rds-ca-bundle.pem are set.
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /etc/ssl/rds-ca-bundle.pem

COPY --chown=appuser:appgroup application/ /data/
WORKDIR /data

USER appuser

CMD ["./entrypoint.sh"]

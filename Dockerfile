FROM python:3.12.4-alpine

RUN <<EOF
  apk update
  apk add --no-cache \
    bash \
    curl \
    postgresql14-client \
    py3-pip

  curl -sL https://sentry.io/get-cli/ | bash

  pip3 install awscli
EOF

COPY application/ /data/
WORKDIR /data

CMD ["./entrypoint.sh"]

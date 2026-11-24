# Dispatcher image: dispatch.sh + launch.sh and the tools they call. No config,
# no credentials; both are mounted at run time.
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

ARG KUBECTL_VERSION=v1.36.2
ARG KUBECTL_SHA256=1e9045ec32bea85da43de85f0065358529ea7c7a152eca78154fba5b58c27d82

RUN apk add --no-cache bash ca-certificates curl github-cli jq openssl yq-go \
 && wget -qO /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/kubectl \
 && adduser -D -H -u 10001 dispatch

COPY launch.sh dispatch.sh /usr/local/bin/

LABEL org.opencontainers.image.source=https://github.com/shinsenkyo-net/github-jit-runner
USER 10001
ENV HOME=/tmp
ENTRYPOINT ["dispatch.sh"]

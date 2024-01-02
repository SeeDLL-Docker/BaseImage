# syntax=docker/dockerfile:1.4
#
# baseimage Dockerfile
#
# https://github.com/SeeDLL-Docker/docker-baseimage
#

ARG BASEIMAGE=unknown

ARG ALPINE_PKGS="\
    # For timezone support
    tzdata \
    # For 'groupmod' command
    shadow \
"

ARG DEBIAN_PKGS="\
    # For timezone support
    tzdata \
"

# Dockerfile cross-compilation helpers.
FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx

# Build UPX.
FROM --platform=$BUILDPLATFORM alpine:3.18 AS upx
RUN apk --no-cache add build-base curl make cmake git && \
    mkdir /tmp/upx && \
    curl -# -L https://github.com/upx/upx/releases/download/v4.1.0/upx-4.1.0-src.tar.xz | tar xJ --strip 1 -C /tmp/upx && \
    make -C /tmp/upx build/extra/gcc/release -j$(nproc) && \
    cp -v /tmp/upx/build/extra/gcc/release/upx /usr/bin/upx

# Build the init system and process supervisor.
FROM --platform=$BUILDPLATFORM alpine:3.18 AS cinit
ARG TARGETPLATFORM
COPY --from=xx / /
COPY src/cinit /tmp/cinit
RUN apk --no-cache add make clang && \
    xx-apk --no-cache add gcc musl-dev && \
    CC=xx-clang \
    make -C /tmp/cinit && \
    xx-verify --static /tmp/cinit/cinit
COPY --from=upx /usr/bin/upx /usr/bin/upx
RUN upx /tmp/cinit/cinit

# Build the log monitor.
FROM --platform=$BUILDPLATFORM alpine:3.18 AS logmonitor
ARG TARGETPLATFORM
ARG TARGETARCH
COPY --from=xx / /
COPY src/logmonitor /tmp/logmonitor
RUN apk --no-cache add make clang && \
    xx-apk --no-cache add gcc musl-dev linux-headers && \
    CC=xx-clang \
    make -C /tmp/logmonitor && \
    xx-verify --static /tmp/logmonitor/logmonitor
COPY --from=upx /usr/bin/upx /usr/bin/upx
RUN upx /tmp/logmonitor/logmonitor

# Build su-exec
FROM --platform=$BUILDPLATFORM alpine:3.18 AS su-exec
ARG TARGETPLATFORM
COPY --from=xx / /
RUN apk --no-cache add curl make clang && \
    xx-apk --no-cache add gcc musl-dev && \
    mkdir /tmp/su-exec && \
    curl -# -L https://github.com/ncopa/su-exec/archive/v0.2.tar.gz | tar xz --strip 1 -C /tmp/su-exec && \
    CC=xx-clang \
    CFLAGS="-Os -fomit-frame-pointer" \
    LDFLAGS="-static -Wl,--strip-all" \
    make -C /tmp/su-exec && \
    xx-verify --static /tmp/su-exec/su-exec
COPY --from=upx /usr/bin/upx /usr/bin/upx
RUN upx /tmp/su-exec/su-exec

# Build logrotate.
FROM --platform=$BUILDPLATFORM alpine:3.18 AS logrotate
ARG TARGETPLATFORM
COPY --from=xx / /
COPY src/logrotate /tmp/build
RUN /tmp/build/build.sh && \
    xx-verify --static /tmp/logrotate-install/usr/sbin/logrotate
COPY --from=upx /usr/bin/upx /usr/bin/upx
RUN upx /tmp/logrotate-install/usr/sbin/logrotate

# Build cache
FROM --platform=$BUILDPLATFORM alpine:3.18 AS buildcache
# Install the init system and process supervisor.
COPY --from=cinit /tmp/cinit/cinit /opt/base/sbin/
# Install the log monitor.
COPY --from=logmonitor /tmp/logmonitor/logmonitor /opt/base/bin/
# Install su-exec.
COPY --from=su-exec /tmp/su-exec/su-exec /opt/base/sbin/su-exec
# Install logrotate.
COPY --from=logrotate /tmp/logrotate-install/usr/sbin/logrotate /opt/base/sbin/
# Copy helpers.
COPY helpers/* /opt/base/bin/
# Copy rootfs.
COPY rootfs/ /tmp/rootfs/
#  tar files
RUN apk add coreutils && \
    cd /tmp/rootfs/ && \
    tar -czvf /opt/base/rootfs.tar.gz ./* && \
    cd /opt && \
    tar -czvf /tmp/base.tar.gz base/ && \
    ls -l /tmp

# Pull base image.
FROM ${BASEIMAGE}
ARG TARGETPLATFORM

# Define working directory.
WORKDIR /tmp

# Install the init system and process supervisor.
COPY --from=buildcache /tmp/base.tar.gz /opt/base.tar.gz

# Install system packages.
ARG ALPINE_PKGS
ARG DEBIAN_PKGS
RUN cd /opt && \
    tar -xzvf base.tar.gz && \
    rm base.tar.gz && \
    if [ -n "$(which apk)" ]; then \
        /opt/base/bin/add-pkg ${ALPINE_PKGS}; \
    else \
        /opt/base/bin/add-pkg ${DEBIAN_PKGS}; \
    fi; \
    if [ -f /root/.profile ]; then \
        echo "# Include Docker container definitions." >> /root/.profile && \
        echo ". /root/.docker_rc" >> /root/.profile; \
    fi ;\
    mkdir -p \
        /defaults \
        /opt/base/etc/logrotate.d \
        /etc/services.d \
        /etc/cont-env.d \
        /etc/cont-init.d \
        /etc/cont-finish.d \
        /etc/cont-logrotate.d \
    && true ; \
    if [ -f /etc/apk/repositories ]; then \
        cp /etc/apk/repositories /defaults/; \
    else \
        cp /etc/apt/sources.list /defaults/; \
    fi; \
    cd /opt/base/ ; \
    tar -xzvf rootfs.tar.gz -C / && \
    rm rootfs.tar.gz && \
    /opt/base/bin/set-cont-env DOCKER_IMAGE_PLATFORM "${TARGETPLATFORM:-}" && \
    true

# Set environment variables.
ENV \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/base/sbin:/opt/base/bin \
    ENV=/root/.docker_rc \
    USER_ID=1000 \
    GROUP_ID=1000 \
    SUP_GROUP_IDS= \
    UMASK=0022 \
    LANG=en_US.UTF-8 \
    TZ=Etc/UTC \
    KEEP_APP_RUNNING=0 \
    APP_NICENESS=0 \
    INSTALL_PACKAGES= \
    PACKAGES_MIRROR= \
    CONTAINER_DEBUG=0

# Define mountable directories.
VOLUME ["/config"]

# Define default command.
# Use the init system.
CMD ["/init"]

# Metadata.
ARG IMAGE_VERSION=unknown
LABEL \
      org.label-schema.name="baseimage" \
      org.label-schema.description="A minimal docker baseimage to ease creation of long-lived application containers" \
      org.label-schema.version="${IMAGE_VERSION}" \
      org.label-schema.vcs-url="https://github.com/SeeDLL-Docker/docker-baseimage" \
      org.label-schema.schema-version="1.0"

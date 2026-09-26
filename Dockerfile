# syntax=docker/dockerfile:1.7

# ---------- Remote artifacts (GitHub releases) ----------
# Separate stage so BuildKit downloads these in parallel with the apt/pip
# layers below. --checksum pins the content, so a cached build never
# re-contacts GitHub; bumping a version requires updating its sha256 too:
#   gh api repos/<owner>/<repo>/releases/tags/<tag> --jq '.assets[] | {name, digest}'
FROM scratch AS fetch
ARG CFR_VERSION=0.152
ARG CFR_SHA256=f686e8f3ded377d7bc87d216a90e9e9512df4156e75b06c655a16648ae8765b2
ARG PROCYON_VERSION=0.6.0
ARG PROCYON_SHA256=821da96012fc69244fa1ea298c90455ee4e021434bc796d3b9546ab24601b779
ARG VINEFLOWER_VERSION=1.12.0
ARG VINEFLOWER_SHA256=1dfcfe974395734fa467ce620661c7623d05ba83670de0529b1fbd63ff548b9d
ARG RADARE2_VERSION=6.2.0
ARG RADARE2_SHA256=eb82324e83315887fbee6f5d8632c982c593e056a87180f1bec5ccb06c463aeb
ADD --checksum=sha256:${CFR_SHA256} \
    "https://github.com/leibnitz27/cfr/releases/download/${CFR_VERSION}/cfr-${CFR_VERSION}.jar" /cfr.jar
ADD --checksum=sha256:${PROCYON_SHA256} \
    "https://github.com/mstrobel/procyon/releases/download/v${PROCYON_VERSION}/procyon-decompiler-${PROCYON_VERSION}.jar" /procyon.jar
ADD --checksum=sha256:${VINEFLOWER_SHA256} \
    "https://github.com/Vineflower/vineflower/releases/download/${VINEFLOWER_VERSION}/vineflower-${VINEFLOWER_VERSION}.jar" /vineflower.jar
ADD --checksum=sha256:${RADARE2_SHA256} \
    "https://github.com/radareorg/radare2/releases/download/${RADARE2_VERSION}/radare2_${RADARE2_VERSION}_amd64.deb" /radare2.deb

FROM python:3.13-slim AS base

ENV DEBIAN_FRONTEND=noninteractive \
    IDADIR=/opt/ida-pro \
    PYTHONUNBUFFERED=1 \
    IDA_MCP_LOG_LEVEL=DEBUG \
    DOTNET_ROOT=/usr/share/dotnet \
    PATH=/root/.local/bin:/usr/share/dotnet:$PATH \
    TVHEADLESS=1 \
    UV_LINK_MODE=copy

LABEL org.opencontainers.image.title="neo-rev-lab" \
      org.opencontainers.image.description="AI-assisted reverse engineering lab powered by Claude Code and MCP (Model Context Protocol). Runs IDA Pro, a .NET decompiler, angr, and a full Android toolchain (jadx, apktool, hermes-dec / hbctool for React Native Hermes bytecode) inside a Docker container, exposed to Claude Code as MCP tool servers and skills so you can analyze binaries conversationally." \
      org.opencontainers.image.source="https://github.com/neoz/neo-rev-lab" \
      org.opencontainers.image.licenses="MIT"

# ---------- APT mirrors (Vietnam first, then Singapore, then the Debian CDN) ----------
# apt's mirror+file method walks each list in order and falls back to the next
# entry on failure. Override with --build-arg to build from other regions.
ARG APT_MIRRORS="https://opensource.xtdv.net/debian https://mirror.bizflycloud.vn/debian https://mirror.sg.gs/debian http://deb.debian.org/debian"
ARG APT_SECURITY_MIRRORS="https://mirror.sg.gs/debian-security http://deb.debian.org/debian-security"
RUN mkdir -p /etc/apt/mirrors \
    && printf '%s\n' ${APT_MIRRORS} > /etc/apt/mirrors/debian.list \
    && printf '%s\n' ${APT_SECURITY_MIRRORS} > /etc/apt/mirrors/debian-security.list \
    && sed -i \
        -e 's#^URIs: http://deb.debian.org/debian$#URIs: mirror+file:/etc/apt/mirrors/debian.list#' \
        -e 's#^URIs: http://deb.debian.org/debian-security$#URIs: mirror+file:/etc/apt/mirrors/debian-security.list#' \
        /etc/apt/sources.list.d/debian.sources \
    && rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# ---------- System packages (one layer; .deb/list caches live in BuildKit cache mounts) ----------
# IDA runtime (Qt libs, etc.), build toolchain for angr, CLI triage utilities
# (file, xxd, ripgrep), Java runtime for the .jar tools, git for pip VCS
# installs, and ICU/OpenSSL for re-dotnet.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    libx11-6 \
    libxcb1 \
    libsm6 \
    libfontconfig1 \
    libxrender1 \
    libdbus-1-3 \
    curl \
    ca-certificates \
    unzip \
    gcc \
    g++ \
    libc6-dev \
    cmake \
    pkg-config \
    file \
    xxd \
    ripgrep \
    default-jre-headless \
    git \
    libicu76 \
    libssl3

# # ---------- Install .NET runtime (for running .NET apps) ----------
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     libicu-dev \
#     libssl3 \
#     && rm -rf /var/lib/apt/lists/* \
#     && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
#     && chmod +x /tmp/dotnet-install.sh \
#     && /tmp/dotnet-install.sh --channel 8.0 --runtime dotnet --install-dir ${DOTNET_ROOT} \
#     && ln -s ${DOTNET_ROOT}/dotnet /usr/local/bin/dotnet \
#     && rm /tmp/dotnet-install.sh

# ---------- Install bun ----------
RUN curl -fsSL https://bun.sh/install | bash \
    && ln -s /root/.bun/bin/bun /usr/local/bin/bun

# ---------- Python tooling: angr + unicorn, r2pipe, hermes-dec + hbctool ----------
# Independent of IDA, so it sits above the IDA layers and survives IDA bumps.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install \
        angr unicorn \
        r2pipe \
        git+https://github.com/P1sec/hermes-dec.git \
        git+https://github.com/bongtrop/hbctool.git

# ---------- Fix angr unicorn engine: libpyvex.so must be on ld path ----------
RUN echo /usr/local/lib/python3.13/site-packages/pyvex/lib > /etc/ld.so.conf.d/pyvex.conf \
    && ldconfig

# ---------- Java decompilers: jadx, apktool, CFR, Procyon, Vineflower (aliased as `fernflower`) ----------
COPY --link tools/jadx/jadx.jar /opt/jadx/jadx.jar
COPY --link tools/apktool/apktool.jar /opt/apktool/apktool.jar
COPY --link --from=fetch /cfr.jar /opt/cfr/cfr.jar
COPY --link --from=fetch /procyon.jar /opt/procyon/procyon.jar
COPY --link --from=fetch /vineflower.jar /opt/vineflower/vineflower.jar
RUN for t in jadx apktool cfr procyon vineflower; do \
        printf '#!/bin/sh\nexec java -jar /opt/%s/%s.jar "$@"\n' "$t" "$t" > /usr/local/bin/$t \
        && chmod +x /usr/local/bin/$t; \
    done \
    && ln -s /usr/local/bin/vineflower /usr/local/bin/fernflower

# ---------- Install Radare2 (prebuilt .deb from radareorg) ----------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,from=fetch,source=/radare2.deb,target=/tmp/radare2.deb \
    apt-get update \
    && apt-get install -y --no-install-recommends /tmp/radare2.deb

# ---------- Install IDA Pro ----------
# Bind-mounted instead of COPY'd: the ~600 MB installer never lands in an image layer.
RUN --mount=type=bind,source=tools/ida/ida-pro_94_x64linux.run,target=/tmp/ida-installer.run \
    /tmp/ida-installer.run --mode unattended --prefix ${IDADIR}

# ---------- Patch IDA + generate license via keygen.js ----------
COPY tools/ida/kg_patch/9.4/keygen.js /opt/ida-pro/keygen.js
RUN cd /opt/ida-pro && bun run keygen.js

# ---------- Activate IDA idalib for Python ----------
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install ${IDADIR}/idalib/python/idapro-*.whl \
    && python ${IDADIR}/idalib/python/py-activate-idalib.py -d ${IDADIR}

# ---------- Install hcli + accept EULA ----------
RUN curl -LsSf https://hcli.docs.hex-rays.com/install | sh \
    && hcli ida accept-eula

# ---------- Install uv + ida-mcp ----------
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /workspace
#RUN uv tool install ida-mcp # deprecated
# re-mcp-ida is the new name for the IDA MCP UV tool; it provides the same functionality but with a more consistent naming scheme across our MCP tools
RUN --mount=type=cache,target=/root/.cache/uv \
    uv tool install re-mcp-ida

# ---------- Frequently updated local binaries/scripts (last, so bumps rebuild only these layers) ----------
COPY --link --chmod=755 tools/idasql/idasql /opt/ida-pro/idasql
COPY --link --chmod=755 tools/re-dotnet/re-dotnet /opt/re-dotnet/re-dotnet
COPY --link --chmod=755 tools/scripts/delphi_reverser.py /opt/scripts/delphi_reverser.py
RUN ln -s /opt/ida-pro/idasql /usr/local/bin/idasql \
    && ln -s /opt/re-dotnet/re-dotnet /usr/local/bin/re-dotnet \
    && printf '#!/bin/sh\nexec python3 /opt/scripts/delphi_reverser.py "$@"\n' > /usr/local/bin/delphi-reverser \
    && chmod +x /usr/local/bin/delphi-reverser

EXPOSE 8081

CMD ["uvx", "re-mcp-ida"]

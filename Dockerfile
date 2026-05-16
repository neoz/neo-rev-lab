FROM python:3.13-slim AS base

ENV DEBIAN_FRONTEND=noninteractive \
    IDADIR=/opt/ida-pro-9.3 \
    PYTHONUNBUFFERED=1 \
    IDA_MCP_LOG_LEVEL=DEBUG \
    DOTNET_ROOT=/usr/share/dotnet \
    PATH=/root/.local/bin:/usr/share/dotnet:$PATH \
    TVHEADLESS=1

# Runtime deps for IDA Pro (Qt libs, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
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
    && rm -rf /var/lib/apt/lists/*

# ---------- Install bun ----------
RUN curl -fsSL https://bun.sh/install | bash \
    && ln -s /root/.bun/bin/bun /usr/local/bin/bun

# ---------- Install CLI triage utilities (file, xxd, ripgrep) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    file \
    xxd \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# ---------- Install Java runtime (for running .jar files) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    default-jre-headless \
    && rm -rf /var/lib/apt/lists/*

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

# ---------- Install IDA Pro ----------
COPY tools/ida/ida-pro_93_x64linux.run /tmp/ida-installer.run
RUN chmod +x /tmp/ida-installer.run \
    && /tmp/ida-installer.run --mode unattended --prefix ${IDADIR} \
    && ln -s ${IDADIR} /opt/ida-pro \
    && rm /tmp/ida-installer.run

# ---------- Patch IDA + generate license via keygen.js ----------
COPY tools/ida/kg_patch/kg_patch/keygen.js /opt/ida-pro/keygen.js
RUN cd /opt/ida-pro && bun run keygen.js

# ---------- Install idasql ----------
COPY tools/idasql/idasql /opt/ida-pro/idasql
RUN chmod +x /opt/ida-pro/idasql \
    && ln -s /opt/ida-pro/idasql /usr/local/bin/idasql


# ---------- Install jadx ----------
COPY tools/jadx/jadx.jar /opt/jadx/jadx.jar
RUN printf '#!/bin/sh\nexec java -jar /opt/jadx/jadx.jar "$@"\n' > /usr/local/bin/jadx \
    && chmod +x /usr/local/bin/jadx

# ---------- Install apktool ----------
COPY tools/apktool/apktool.jar /opt/apktool/apktool.jar
RUN printf '#!/bin/sh\nexec java -jar /opt/apktool/apktool.jar "$@"\n' > /usr/local/bin/apktool \
    && chmod +x /usr/local/bin/apktool

# ---------- Install CFR Java decompiler ----------
ARG CFR_VERSION=0.152
RUN mkdir -p /opt/cfr \
    && curl -fsSL "https://github.com/leibnitz27/cfr/releases/download/${CFR_VERSION}/cfr-${CFR_VERSION}.jar" \
       -o /opt/cfr/cfr.jar \
    && printf '#!/bin/sh\nexec java -jar /opt/cfr/cfr.jar "$@"\n' > /usr/local/bin/cfr \
    && chmod +x /usr/local/bin/cfr

# ---------- Install Procyon Java decompiler ----------
ARG PROCYON_VERSION=0.6.0
RUN mkdir -p /opt/procyon \
    && curl -fsSL "https://github.com/mstrobel/procyon/releases/download/v${PROCYON_VERSION}/procyon-decompiler-${PROCYON_VERSION}.jar" \
       -o /opt/procyon/procyon.jar \
    && printf '#!/bin/sh\nexec java -jar /opt/procyon/procyon.jar "$@"\n' > /usr/local/bin/procyon \
    && chmod +x /usr/local/bin/procyon

# ---------- Install Vineflower (maintained Fernflower successor; aliased as `fernflower`) ----------
ARG VINEFLOWER_VERSION=1.12.0
RUN mkdir -p /opt/vineflower \
    && curl -fsSL "https://github.com/Vineflower/vineflower/releases/download/${VINEFLOWER_VERSION}/vineflower-${VINEFLOWER_VERSION}.jar" \
       -o /opt/vineflower/vineflower.jar \
    && printf '#!/bin/sh\nexec java -jar /opt/vineflower/vineflower.jar "$@"\n' > /usr/local/bin/vineflower \
    && chmod +x /usr/local/bin/vineflower \
    && ln -s /usr/local/bin/vineflower /usr/local/bin/fernflower

# ---------- Install hermes-dec + hbctool (Hermes / React Native bytecode tooling) ----------
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir \
        git+https://github.com/P1sec/hermes-dec.git \
        git+https://github.com/bongtrop/hbctool.git

# ---------- Install Radare2 + radare2-mcp ----------
RUN apt-get update && apt-get install -y --no-install-recommends make patch \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 https://github.com/radareorg/radare2 /opt/radare2 \
    && /opt/radare2/sys/install.sh \
    && git clone --depth 1 https://github.com/radareorg/radare2-mcp /opt/radare2-mcp \
    && cd /opt/radare2-mcp && ./configure && make && make install

# ---------- Install dotnet-mcp ----------
COPY tools/dotnet-mcp/dotnet-mcp.tar /tmp/dotnet-mcp.tar
RUN mkdir -p /opt/dotnet-mcp \
    && tar -xf /tmp/dotnet-mcp.tar -C /opt/dotnet-mcp \
    && chmod +x /opt/dotnet-mcp/MCPPOC \
    && rm /tmp/dotnet-mcp.tar

# ---------- Install hcli + accept EULA ----------
RUN curl -LsSf https://hcli.docs.hex-rays.com/install | sh \
    && hcli ida accept-eula


# ---------- Install uv + ida-mcp ----------
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /workspace
#RUN uv tool install ida-mcp # deprecated
RUN uv tool install re-mcp-ida # re-mcp-ida is the new name for the IDA MCP UV tool; it provides the same functionality but with a more consistent naming scheme across our MCP tools

# ---------- Activate IDA idalib for Python ----------
RUN pip install ${IDADIR}/idalib/python/idapro-0.0.7-py3-none-any.whl \
    && pip install angr unicorn
RUN python ${IDADIR}/idalib/python/py-activate-idalib.py -d ${IDADIR}

# ---------- Fix angr unicorn engine: libpyvex.so must be on ld path ----------
RUN echo /usr/local/lib/python3.13/site-packages/pyvex/lib > /etc/ld.so.conf.d/pyvex.conf \
    && ldconfig

EXPOSE 8081

CMD ["uvx", "re-mcp-ida"]

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
    && rm -rf /var/lib/apt/lists/*

# ---------- Install bun ----------
RUN curl -fsSL https://bun.sh/install | bash \
    && ln -s /root/.bun/bin/bun /usr/local/bin/bun

# # ---------- Install Java runtime (for running .jar files) ----------
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     default-jre-headless \
#     && rm -rf /var/lib/apt/lists/*

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
RUN uv tool install ida-mcp

# ---------- Activate IDA idalib for Python ----------
RUN pip install ${IDADIR}/idalib/python/idapro-0.0.7-py3-none-any.whl
RUN python ${IDADIR}/idalib/python/py-activate-idalib.py -d ${IDADIR}

EXPOSE 8081

CMD ["uvx", "ida-mcp"]

FROM ubuntu:24.04

# ── Pinned tool versions ────────────────────────────────────────────────────
# capnp CLI: update when you want to validate a newer C++ compiler version.
# capnp/capnp-rpc crate versions are NOT managed here — see Cargo.toml and
# ci/update-capnp-version.sh for the version-matrix workflow.
ARG CAPNP_VERSION=1.0.1
ARG DART_VERSION=3.7.2
# Node.js: only needed to build/preview the Docusaurus docs site under website/.
ARG NODE_VERSION=24.18.0

ENV DEBIAN_FRONTEND=noninteractive

# ── System dependencies ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        curl \
        ca-certificates \
        git \
        unzip \
        wget \
        valgrind \
        linux-tools-common \
        linux-tools-generic \
        linux-tools-$(uname -r) \
    && rm -rf /var/lib/apt/lists/*

# ── capnp CLI (built from source for exact version pinning) ─────────────────
RUN wget -q "https://capnproto.org/capnproto-c++-${CAPNP_VERSION}.tar.gz" \
    && tar xf "capnproto-c++-${CAPNP_VERSION}.tar.gz" \
    && cmake -S "capnproto-c++-${CAPNP_VERSION}" -B capnp-build \
             -DCMAKE_BUILD_TYPE=Release \
             -DBUILD_TESTING=OFF \
    && cmake --build capnp-build --parallel "$(nproc)" \
    && cmake --install capnp-build \
    && rm -rf "capnproto-c++-${CAPNP_VERSION}" "capnproto-c++-${CAPNP_VERSION}.tar.gz" capnp-build

# ── Rust (stable, installed globally so any user can use it) ────────────────
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --no-modify-path \
    && chmod -R a+w /usr/local/rustup /usr/local/cargo

# ── Dart SDK ────────────────────────────────────────────────────────────────
RUN wget -q "https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-x64-release.zip" \
    && unzip -q dartsdk-linux-x64-release.zip -d /opt \
    && rm dartsdk-linux-x64-release.zip

ENV PATH=/opt/dart-sdk/bin:${PATH}

# ── Node.js (for the Docusaurus docs site under website/) ───────────────────
RUN wget -q "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && tar xf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /opt \
    && mv "/opt/node-v${NODE_VERSION}-linux-x64" /opt/node \
    && rm "node-v${NODE_VERSION}-linux-x64.tar.xz"

ENV PATH=/opt/node/bin:${PATH}

WORKDIR /workspace

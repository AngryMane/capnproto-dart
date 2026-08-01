FROM ubuntu:24.04

# ── Pinned tool versions ────────────────────────────────────────────────────
# capnp CLI: update when you want to validate a newer C++ compiler version.
# capnp/capnp-rpc crate versions are NOT managed here — see Cargo.toml and
# ci/update-capnp-version.sh for the version-matrix workflow.
ARG CAPNP_VERSION=1.0.1
# Flutter includes the matching Dart SDK. Keep the Flutter release pinned so
# local development and CI do not silently change when a new stable is
# published.
ARG FLUTTER_VERSION=3.44.4
# Node.js: only needed to build/preview the Docusaurus docs site under website/.
ARG NODE_VERSION=24.18.0

ENV DEBIAN_FRONTEND=noninteractive

# ── System dependencies ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        clang \
        cmake \
        curl \
        ca-certificates \
        git \
        gh \
        libglu1-mesa \
        libgtk-3-dev \
        liblzma-dev \
        ninja-build \
        openssh-client \
        pkg-config \
        unzip \
        wget \
        xz-utils \
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

# ── Flutter SDK (includes the matching Dart SDK) ────────────────────────────
# Install the Linux desktop toolchain even though the devcontainer does not
# launch GUI applications: it lets contributors create, analyze, test, and
# build Flutter samples entirely inside the container.
RUN wget -q \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
        -O flutter.tar.xz \
    && tar xf flutter.tar.xz -C /opt \
    && rm flutter.tar.xz \
    && ln -s /opt/flutter/bin/cache/dart-sdk /opt/dart-sdk \
    && git config --system --add safe.directory /opt/flutter \
    && /opt/flutter/bin/flutter config --no-analytics --enable-linux-desktop \
    && /opt/flutter/bin/flutter precache --linux

ENV PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}

# ── Node.js (for the Docusaurus docs site under website/) ───────────────────
RUN wget -q "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && tar xf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /opt \
    && mv "/opt/node-v${NODE_VERSION}-linux-x64" /opt/node \
    && rm "node-v${NODE_VERSION}-linux-x64.tar.xz"

ENV PATH=/opt/node/bin:${PATH}

WORKDIR /workspace

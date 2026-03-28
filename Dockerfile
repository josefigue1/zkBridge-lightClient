FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    git \
    libgmp-dev \
    libsodium-dev \
    libssl-dev \
    m4 \
    nasm \
    nlohmann-json3-dev \
    python3 \
    python3-pip \
    python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_VERSION=16
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g snarkjs@0.4.10

ARG CIRCOM_VERSION=2.0.8
RUN curl -fsSL "https://github.com/iden3/circom/releases/download/v${CIRCOM_VERSION}/circom-linux-amd64" -o /usr/local/bin/circom \
    && chmod +x /usr/local/bin/circom

ARG RAPIDSNARK_VERSION=main
RUN git clone https://github.com/iden3/rapidsnark.git /tmp/rapidsnark \
    && cd /tmp/rapidsnark \
    && git checkout ${RAPIDSNARK_VERSION} \
    && git submodule update --init --recursive \
    && ./build_gmp.sh host \
    && mkdir -p build_prover && cd build_prover \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j"$(nproc)" \
    && cp src/prover /usr/local/bin/rapidsnark \
    && chmod +x /usr/local/bin/rapidsnark \
    && cd / \
    && rm -rf /tmp/rapidsnark

COPY docker/node-memory.patch /tmp/node-memory.patch
RUN git clone https://github.com/nodejs/node.git /tmp/node \
    && cd /tmp/node \
    && git checkout 8beef5eeb82425b13d447b50beafb04ece7f91b1 \
    && patch -p1 < /tmp/node-memory.patch \
    && ./configure \
    && make -j"$(nproc)" \
    && mkdir -p /opt/patched-node/bin \
    && cp out/Release/node /opt/patched-node/bin/node \
    && chmod +x /opt/patched-node/bin/node \
    && cd / \
    && rm -rf /tmp/node /tmp/node-memory.patch

ENV PATCHED_NODE_PATH=/opt/patched-node/bin/node

RUN useradd -m -s /bin/bash -u 1001 app \
    && mkdir -p /workspace \
    && chown -R app:app /workspace

ENV PATH="/usr/local/bin:${PATH}"
ENV NODE_MEM=16384
WORKDIR /workspace
USER app

CMD ["/bin/sh"]

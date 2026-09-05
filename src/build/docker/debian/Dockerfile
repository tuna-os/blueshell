ARG DISTRO_VERSION="13"
FROM docker.io/library/debian:${DISTRO_VERSION}

# Install Dependencies
RUN DEBIAN_FRONTEND="noninteractive" apt-get -qq update && \
    apt-get -qq -y --no-install-recommends install \
    # Build Tools
    blueprint-compiler \
    build-essential \
    curl \
    libbz2-dev \
    libonig-dev \
    libxml2-utils \
    lintian \
    lsb-release \
    libxml2-utils \
    pandoc \
    # Ghostty Dependencies
    libadwaita-1-dev \
    libgtk-4-dev \
    libgtk4-layer-shell-dev && \
    # Clean up for better caching
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY ./build.zig ./build.zig.zon /src/

# Install zig
# https://ziglang.org/download/
#
# Checksum-verified: the tarball is checked against the shasum published in
# ziglang.org/download/index.json for this exact version + architecture
# before extraction. A tampered mirror/CDN or compromised release then fails
# the build instead of shipping attacker code into the produced images.
# (blueshell#41 — mirrors the org's checksum-verified rclone pattern.)
RUN export ZIG_VERSION=$(sed -n -E 's/^\s*\.?minimum_zig_version\s*=\s*"([^"]+)".*/\1/p' build.zig.zon) && \
    case "$(uname -m)" in \
      x86_64)  ZIG_SHA="02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239" ;; \
      aarch64|arm64) ZIG_SHA="958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f" ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/zig-$(uname -m)-linux-$ZIG_VERSION.tar.xz" && \
    echo "$ZIG_SHA  /tmp/zig.tar.xz" | sha256sum -c - && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    rm /tmp/zig.tar.xz && \
    ln -s "/opt/zig-$(uname -m)-linux-$ZIG_VERSION/zig" /usr/local/bin/zig

COPY . /src

RUN zig build \
    -Doptimize=Debug \
    -Dcpu=baseline

RUN ./zig-out/bin/ghostty +version

#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
# Base images are digest-pinned (blueshell#28): archlinux is a rolling
# release and nginx:alpine floats — mutable refs make the same commit build
# different images and let a bad :latest push silently change what ships.
FROM --platform=linux/amd64 archlinux@sha256:374011da98ed9bef569a91a00b6466a071414049c10054ae27e62a75615b7e8e AS builder

# Build argument for noindex header
ARG ADD_NOINDEX_HEADER=false
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    doxygen \
    graphviz && \
    pacman -Scc --noconfirm
WORKDIR /ghostty
COPY include/ ./include/
COPY images/ ./images/
COPY dist/doxygen/ ./dist/doxygen/
COPY src/terminal/c/types.schema.json ./src/terminal/c/types.schema.json
COPY example/ ./example/
COPY Doxyfile ./
COPY DoxygenLayout.xml ./
RUN mkdir -p zig-out/share/ghostty/doc/libghostty
RUN doxygen

#--------------------------------------------------------------------
# Host the static HTML
#--------------------------------------------------------------------
FROM nginx@sha256:6c7972b94d62ce93357d1e0d0ef6d3db8a2e9b8b6f3234d943d60ecbc4f4eb31 AS runtime

# Pass build arg to runtime stage
ARG ADD_NOINDEX_HEADER=false
ENV ADD_NOINDEX_HEADER=$ADD_NOINDEX_HEADER

# Copy documentation and entrypoint script
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html
COPY src/build/docker/lib-c-docs/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
CMD ["/entrypoint.sh"]

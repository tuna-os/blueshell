#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
# Base images are digest-pinned (blueshell#28): archlinux is a rolling
# release and nginx:alpine floats — mutable refs make the same commit build
# different images and let a bad :latest push silently change what ships.
FROM --platform=linux/amd64 archlinux@sha256:363129b67b2bc6c5a634f8fb4961a7e2eba213a2ec075d159127b1260290a722 AS builder

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
FROM nginx@sha256:59a9ae22b8933b536391e6c1708fa761297e922809c97675c5a56ba316be62af AS runtime

# Pass build arg to runtime stage
ARG ADD_NOINDEX_HEADER=false
ENV ADD_NOINDEX_HEADER=$ADD_NOINDEX_HEADER

# Copy documentation and entrypoint script
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html
COPY src/build/docker/lib-c-docs/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
CMD ["/entrypoint.sh"]

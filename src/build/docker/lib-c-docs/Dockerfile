#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
# Base images are digest-pinned (blueshell#28): archlinux is a rolling
# release and nginx:alpine floats — mutable refs make the same commit build
# different images and let a bad :latest push silently change what ships.
FROM --platform=linux/amd64 archlinux@sha256:dfc5be7be44cf1acf3d9b3b902e3e9c8a29f97ed41e35631823cdc9c97e5d4f0 AS builder

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
FROM nginx@sha256:8e0328743c8e52ead9fac9c198d0893d63cd38e41b1d9ea629e092a8ac229a93 AS runtime

# Pass build arg to runtime stage
ARG ADD_NOINDEX_HEADER=false
ENV ADD_NOINDEX_HEADER=$ADD_NOINDEX_HEADER

# Copy documentation and entrypoint script
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html
COPY src/build/docker/lib-c-docs/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
CMD ["/entrypoint.sh"]

#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
# Base images are digest-pinned (blueshell#28): archlinux is a rolling
# release and nginx:alpine floats — mutable refs make the same commit build
# different images and let a bad :latest push silently change what ships.
FROM --platform=linux/amd64 archlinux@sha256:fcee73ea1b96e236248f53a213f71276cc9072d9025b58bce9915e32f19963ae AS builder

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
FROM nginx@sha256:9aa9949a8f50829ed3e3f5e14c95afd99caa00b0b5a5444ded23aca599458add AS runtime

# Pass build arg to runtime stage
ARG ADD_NOINDEX_HEADER=false
ENV ADD_NOINDEX_HEADER=$ADD_NOINDEX_HEADER

# Copy documentation and entrypoint script
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html
COPY src/build/docker/lib-c-docs/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
CMD ["/entrypoint.sh"]

#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
# Base images are digest-pinned (blueshell#28): archlinux is a rolling
# release and nginx:alpine floats — mutable refs make the same commit build
# different images and let a bad :latest push silently change what ships.
FROM --platform=linux/amd64 archlinux@sha256:818793c894d94534c22f2149154a39ebaee57e4e67321023b0866a1d5722036c AS builder

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
COPY example/ ./example/
COPY Doxyfile ./
COPY DoxygenLayout.xml ./
RUN mkdir -p zig-out/share/ghostty/doc/libghostty
RUN doxygen

#--------------------------------------------------------------------
# Host the static HTML
#--------------------------------------------------------------------
FROM nginx@sha256:1f25fedd50aec27413031afb3a4f8ee4effcc9d843f6a76e81bfa92245ac5c06 AS runtime

# Pass build arg to runtime stage
ARG ADD_NOINDEX_HEADER=false
ENV ADD_NOINDEX_HEADER=$ADD_NOINDEX_HEADER

# Copy documentation and entrypoint script
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html
COPY src/build/docker/lib-c-docs/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
CMD ["/entrypoint.sh"]

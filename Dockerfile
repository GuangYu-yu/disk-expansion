FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    qemu-utils \
    libguestfs-tools \
    curl wget \
    xz-utils bzip2 zstd \
    unzip \
    numfmt \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY . .

ENTRYPOINT ["bash", "resize_disk.sh"]
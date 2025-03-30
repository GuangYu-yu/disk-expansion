#!/bin/bash
set -e

# 获取参数
IMAGE_URL=$1
EXPAND_OPTIONS=$2

if [ -z "$IMAGE_URL" ] || [ -z "$EXPAND_OPTIONS" ]; then
  echo "用法: $0 <镜像URL> <扩容选项，例如/dev/sda1 1G,/dev/sda2 200M>"
  exit 1
fi

# 下载原始镜像
ORIGINAL_NAME=$(basename "$IMAGE_URL")
echo "正在下载原始镜像..."
wget -O "$ORIGINAL_NAME" "$IMAGE_URL"

# 检查并解压缩文件
FILE_TYPE=$(file --mime-type -b "$ORIGINAL_NAME")
if [[ "$FILE_TYPE" == "application/x-7z-compressed" ]]; then
  echo "解压缩 7z 文件..."
  7z x "$ORIGINAL_NAME" -oextracted || true  # 忽略解压错误
  ORIGINAL_NAME=$(find extracted -type f | head -n 1)
elif [[ "$FILE_TYPE" == "application/x-tar" ]]; then
  echo "解压缩 tar 文件..."
  mkdir -p extracted
  tar --warning=no-unknown-keyword -xf "$ORIGINAL_NAME" -C extracted || true  # 忽略解压错误
  ORIGINAL_NAME=$(find extracted -type f | head -n 1)
fi

# 计算新的磁盘大小
TOTAL_EXPAND_SIZE=0
IFS=',' read -ra OPTIONS <<< "$EXPAND_OPTIONS"  # 解析扩容选项
for OPTION in "${OPTIONS[@]}"; do
  SIZE=$(echo "$OPTION" | awk '{print $2}')
  UNIT=${SIZE: -1}
  VALUE=${SIZE%?}
  if [[ "$UNIT" == "G" ]]; then
    TOTAL_EXPAND_SIZE=$(echo "$TOTAL_EXPAND_SIZE + $VALUE * 1024" | bc)
  elif [[ "$UNIT" == "M" ]]; then
    TOTAL_EXPAND_SIZE=$(echo "$TOTAL_EXPAND_SIZE + $VALUE" | bc)
  fi
done

# 创建新的扩容后的磁盘镜像
RESIZED_NAME="resized_${ORIGINAL_NAME}"
echo "创建新的磁盘镜像，大小为 ${TOTAL_EXPAND_SIZE}M..."
qemu-img create -f qcow2 "$RESIZED_NAME" "${TOTAL_EXPAND_SIZE}M"

# 解析扩容选项并进行扩容
IFS=',' read -ra OPTIONS <<< "$EXPAND_OPTIONS"
for OPTION in "${OPTIONS[@]}"; do
  PARTITION=$(echo "$OPTION" | awk '{print $1}')
  SIZE=$(echo "$OPTION" | awk '{print $2}')
  echo "正在扩展分区 $PARTITION 到大小 $SIZE..."
  virt-resize --expand "$PARTITION" "$ORIGINAL_NAME" "$RESIZED_NAME"
done

echo "扩容完成！新镜像: $RESIZED_NAME"
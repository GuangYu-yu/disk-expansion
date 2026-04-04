#!/bin/bash
set -e
set -o pipefail

export LIBGUESTFS_BACKEND=direct

RANDOM_SUFFIX=$RANDOM
TEMP_FILES=()

cleanup() {
  echo "清理临时文件..."
  for f in "${TEMP_FILES[@]}"; do
    [ -n "$f" ] && rm -rf "$f" 2>/dev/null || true
  done
}

trap cleanup EXIT

IMAGE_SOURCE=$1
EXPAND_OPTIONS=$2
OUTPUT_FILENAME=$3
PARTITION_NAME=$4
COMPRESS_COMMAND=$5

if [ -z "$IMAGE_SOURCE" ] || [ -z "$EXPAND_OPTIONS" ] || [ -z "$OUTPUT_FILENAME" ]; then
  echo "用法: $0 <镜像URL或本地文件路径> <扩容选项，例如 200M 或者 2G> <输出文件名> [分区名] [compress]"
  echo "  分区名: 可选，留空自动检测最大分区"
  exit 1
fi

if [[ "$IMAGE_SOURCE" =~ ^https?:// ]]; then
  echo "检测到URL，下载原始镜像..."
  ORIGINAL_NAME=$(basename "$IMAGE_SOURCE")
  wget -q --show-progress --tries=3 --timeout=30 -O "$ORIGINAL_NAME" "$IMAGE_SOURCE"
  TEMP_FILES+=("$ORIGINAL_NAME")
else
  if [ ! -f "$IMAGE_SOURCE" ]; then
    echo "错误：本地文件 $IMAGE_SOURCE 不存在"
    exit 1
  fi
  echo "使用本地文件: $IMAGE_SOURCE"
  ORIGINAL_NAME=$(basename "$IMAGE_SOURCE")
  if [ "$IMAGE_SOURCE" != "$ORIGINAL_NAME" ]; then
    cp "$IMAGE_SOURCE" "$ORIGINAL_NAME"
    TEMP_FILES+=("$ORIGINAL_NAME")
  fi
fi

EXTRACTED_FILE=""

case "$ORIGINAL_NAME" in
  *.gz)
    echo "检测到 gzip 压缩，解压中..."
    gunzip "$ORIGINAL_NAME" || true
    EXTRACTED_FILE="${ORIGINAL_NAME%.gz}"
    ;;
  *.xz)
    echo "检测到 xz 压缩，解压中..."
    xz -d "$ORIGINAL_NAME" || true
    EXTRACTED_FILE="${ORIGINAL_NAME%.xz}"
    ;;
  *.bz2)
    echo "检测到 bzip2 压缩，解压中..."
    bzip2 -d "$ORIGINAL_NAME" || true
    EXTRACTED_FILE="${ORIGINAL_NAME%.bz2}"
    ;;
  *.zip)
    echo "检测到 zip 压缩，解压中..."
    mkdir -p extracted
    unzip "$ORIGINAL_NAME" -d extracted || true
    EXTRACTED_FILE=$(find extracted -type f | head -n1)
    rm -f "$ORIGINAL_NAME"
    ;;
  *)
    echo "未压缩文件..."
    EXTRACTED_FILE="$ORIGINAL_NAME"
    ;;
esac

if [ -z "$EXTRACTED_FILE" ]; then
  echo "错误：解压失败或未找到解压后的文件"
  exit 1
fi

ORIGINAL_NAME="$EXTRACTED_FILE"
echo "解压完成，使用文件: $ORIGINAL_NAME"
TEMP_FILES+=("$ORIGINAL_NAME")

echo "验证文件..."
if ! qemu-img info "$ORIGINAL_NAME" &>/dev/null; then
  echo "错误：文件损坏或格式不支持"
  exit 1
fi
echo "文件验证通过"

echo "检查文件格式..."
FORMAT=$(qemu-img info "$ORIGINAL_NAME" 2>/dev/null | awk '/file format:/ {print $3}')
if [ -z "$FORMAT" ]; then
  FORMAT="raw"
fi
echo "检测到文件格式: $FORMAT"

if [[ "$FORMAT" != "raw" ]]; then
  echo "转换 $FORMAT 到 raw 格式..."
  RAW_FILE="raw_${RANDOM_SUFFIX}.raw"
  qemu-img convert -O raw "$ORIGINAL_NAME" "$RAW_FILE"
  TEMP_FILES+=("$RAW_FILE")
  ORIGINAL_NAME="$RAW_FILE"
  FORMAT="raw"
fi

case "${OUTPUT_FILENAME,,}" in
  *.qcow2) OUTPUT_FORMAT="qcow2" ;;
  *.raw|*.img) OUTPUT_FORMAT="raw" ;;
  *.vmdk) OUTPUT_FORMAT="vmdk" ;;
  *.vdi) OUTPUT_FORMAT="vdi" ;;
  *.vhd) OUTPUT_FORMAT="vpc" ;;
  *.vhdx) OUTPUT_FORMAT="vhdx" ;;
  *.qed) OUTPUT_FORMAT="qed" ;;
  *)
    echo "警告：未知格式，默认使用 raw"
    OUTPUT_FORMAT="raw"
    ;;
esac

if [[ "$EXPAND_OPTIONS" == "0" ]]; then
  echo "扩容大小为0，直接进行格式转换..."
  qemu-img convert -O "$OUTPUT_FORMAT" "$ORIGINAL_NAME" "$OUTPUT_FILENAME"
  echo "格式转换完成！"
else
  if [[ "$EXPAND_OPTIONS" =~ ^([0-9]+)([GMK])$ ]]; then
    SIZE_NUM=${BASH_REMATCH[1]}
    SIZE_UNIT=${BASH_REMATCH[2]}
    
    case "$SIZE_UNIT" in
      G) EXPAND_SIZE_MB=$((SIZE_NUM * 1024)) ;;
      M) EXPAND_SIZE_MB=$SIZE_NUM ;;
      K) EXPAND_SIZE_MB=$((SIZE_NUM / 1024)) ;;
    esac
    echo "扩容大小: ${EXPAND_SIZE_MB}M"
  else
    EXPAND_SIZE_MB=$EXPAND_OPTIONS
    echo "未指定单位，默认使用 ${EXPAND_SIZE_MB}M"
  fi
  
  ORIGINAL_SIZE=$(qemu-img info "$ORIGINAL_NAME" 2>/dev/null | grep "virtual size" | sed -E 's/.*\(([0-9]+) bytes\).*/\1/')
  if [ -z "$ORIGINAL_SIZE" ]; then
    ORIGINAL_SIZE=$(stat -c %s "$ORIGINAL_NAME" 2>/dev/null || stat -f %z "$ORIGINAL_NAME")
  fi
  echo "检测到镜像大小: $ORIGINAL_SIZE 字节"
  
  ORIGINAL_SIZE_MB=$(( (ORIGINAL_SIZE + 1048575) / 1048576 ))
  echo "向上取整后: ${ORIGINAL_SIZE_MB}MB"
  
  TOTAL_SIZE=$((ORIGINAL_SIZE_MB + EXPAND_SIZE_MB))
  
  echo "查找镜像中的分区..."
  echo "镜像中的分区信息表格:"
  virt-filesystems -a "$ORIGINAL_NAME" -l
  
  echo ""
  echo "检测 LVM..."
  if virt-filesystems -a "$ORIGINAL_NAME" -l 2>/dev/null | grep -qi "lvm"; then
    echo "错误：检测到 LVM，当前脚本不支持 LVM 自动扩容"
    echo "LVM 相关分区："
    virt-filesystems -a "$ORIGINAL_NAME" -l 2>/dev/null | grep -i "lvm" || true
    exit 1
  fi
  
  if [ -n "$PARTITION_NAME" ]; then
    PARTITION="$PARTITION_NAME"
    echo "使用指定分区: $PARTITION"
  else
    PARTITION=$(virt-filesystems -a "$ORIGINAL_NAME" -l | awk 'NR>1 {print $1, $5}' | sort -k2 -n | tail -n1 | awk '{print $1}')
    if [ -z "$PARTITION" ]; then
      echo "错误：无法在镜像中找到分区。"
      exit 1
    fi
    echo "找到最大分区: $PARTITION"
  fi
  
  RESIZED_NAME="stage2_${RANDOM_SUFFIX}.raw"
  TEMP_FILES+=("$RESIZED_NAME")
  
  echo "创建新的磁盘镜像，大小为 ${TOTAL_SIZE}M（原始 ${ORIGINAL_SIZE_MB}M + 扩容 ${EXPAND_SIZE_MB}M）..."
  qemu-img create -f "$FORMAT" "$RESIZED_NAME" "${TOTAL_SIZE}M"

  echo "正在将分区 $PARTITION 扩容 ${EXPAND_SIZE_MB}M..."
  virt-resize --expand "$PARTITION" "$ORIGINAL_NAME" "$RESIZED_NAME"

  echo "扩容完成！"

  if [[ "$OUTPUT_FORMAT" != "$FORMAT" ]]; then
    echo "转换扩容后的镜像为 $OUTPUT_FORMAT 格式..."
    qemu-img convert -O "$OUTPUT_FORMAT" "$RESIZED_NAME" "$OUTPUT_FILENAME"
  else
    mv "$RESIZED_NAME" "$OUTPUT_FILENAME"
  fi
fi

echo "处理完成，输出文件: $OUTPUT_FILENAME"

if [ "$COMPRESS_COMMAND" == "compress" ]; then
  echo "压缩最终文件..."
  7z a -mx=9 "${OUTPUT_FILENAME}.7z" "$OUTPUT_FILENAME"
  rm -f "$OUTPUT_FILENAME"
  echo "压缩完成"
fi
#!/bin/bash
set -e

# 获取参数
IMAGE_URL=$1
EXPAND_OPTIONS=$2
OUTPUT_FILENAME=$3  # 新增：输出文件名参数

if [ -z "$IMAGE_URL" ] || [ -z "$EXPAND_OPTIONS" ]; then
  echo "用法: $0 <镜像URL> <扩容选项，例如/dev/sda1 1G,/dev/sda2 200M> [输出文件名]"
  exit 1
fi

# 如果未提供输出文件名，使用默认名称
if [ -z "$OUTPUT_FILENAME" ]; then
  OUTPUT_FILENAME="expanded_image.qcow2"
fi

# 下载原始镜像
ORIGINAL_NAME=$(basename "$IMAGE_URL")
echo "正在下载原始镜像..."
wget -O "$ORIGINAL_NAME" "$IMAGE_URL"

# 检测文件类型
FILE_TYPE=$(file --mime-type -b "$ORIGINAL_NAME")

# 创建解压目录
mkdir -p extracted
EXTRACTED_FILE=""

# 处理不同的压缩格式
case "$FILE_TYPE" in
  application/gzip)
    echo "检测到 gzip 压缩，解压中..."
    gunzip -k "$ORIGINAL_NAME"
    EXTRACTED_FILE="${ORIGINAL_NAME%.gz}"
    ;;
  application/x-bzip2)
    echo "检测到 bzip2 压缩，解压中..."
    bzip2 -dk "$ORIGINAL_NAME"
    EXTRACTED_FILE="${ORIGINAL_NAME%.bz2}"
    ;;
  application/x-xz)
    echo "检测到 xz 压缩，解压中..."
    xz -dk "$ORIGINAL_NAME"
    EXTRACTED_FILE="${ORIGINAL_NAME%.xz}"
    ;;
  application/x-7z-compressed)
    echo "检测到 7z 压缩，解压中..."
    7z x "$ORIGINAL_NAME" -oextracted
    EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    ;;
  application/x-tar)
    echo "检测到 tar 压缩，解压中..."
    tar -xf "$ORIGINAL_NAME" -C extracted
    EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    ;;
  application/zip)
    echo "检测到 zip 压缩，解压中..."
    unzip "$ORIGINAL_NAME" -d extracted
    EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    ;;
  *)
    echo "未识别的文件类型，尝试按扩展名处理..."
    if [[ "$ORIGINAL_NAME" == *.gz ]]; then
      echo "按 .gz 处理..."
      gunzip -k "$ORIGINAL_NAME"
      EXTRACTED_FILE="${ORIGINAL_NAME%.gz}"
    elif [[ "$ORIGINAL_NAME" == *.bz2 ]]; then
      echo "按 .bz2 处理..."
      bzip2 -dk "$ORIGINAL_NAME"
      EXTRACTED_FILE="${ORIGINAL_NAME%.bz2}"
    elif [[ "$ORIGINAL_NAME" == *.xz ]]; then
      echo "按 .xz 处理..."
      xz -dk "$ORIGINAL_NAME"
      EXTRACTED_FILE="${ORIGINAL_NAME%.xz}"
    elif [[ "$ORIGINAL_NAME" == *.tar.gz || "$ORIGINAL_NAME" == *.tgz ]]; then
      echo "按 .tar.gz 处理..."
      tar -xzf "$ORIGINAL_NAME" -C extracted
      EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    elif [[ "$ORIGINAL_NAME" == *.tar.bz2 || "$ORIGINAL_NAME" == *.tbz2 ]]; then
      echo "按 .tar.bz2 处理..."
      tar -xjf "$ORIGINAL_NAME" -C extracted
      EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    elif [[ "$ORIGINAL_NAME" == *.tar.xz || "$ORIGINAL_NAME" == *.txz ]]; then
      echo "按 .tar.xz 处理..."
      tar -xJf "$ORIGINAL_NAME" -C extracted
      EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    elif [[ "$ORIGINAL_NAME" == *.zip ]]; then
      echo "按 .zip 处理..."
      unzip "$ORIGINAL_NAME" -d extracted
      EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    else
      echo "无法解压，文件可能未被压缩。"
      EXTRACTED_FILE="$ORIGINAL_NAME"
    fi
    ;;
esac

# 确保解压后有文件
if [ -z "$EXTRACTED_FILE" ]; then
  echo "解压失败或未找到解压后的文件，退出..."
  exit 1
fi

# 更新文件名
ORIGINAL_NAME="$EXTRACTED_FILE"
echo "解压完成，使用文件: $ORIGINAL_NAME"

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

# 重命名扩容后的镜像文件为用户指定的名称
mv "$RESIZED_NAME" "$OUTPUT_FILENAME"
echo "重命名扩容后的镜像为: $OUTPUT_FILENAME"

#!/bin/bash
set -e

# 获取参数
IMAGE_SOURCE=$1
EXPAND_OPTIONS=$2
OUTPUT_FILENAME=$3
PARTITION_NUMBER=$4
COMPRESS_COMMAND=$5

if [ -z "$IMAGE_SOURCE" ] || [ -z "$EXPAND_OPTIONS" ] || [ -z "$OUTPUT_FILENAME" ]; then
  echo "用法: $0 <镜像URL或本地文件路径> <扩容选项，例如 200M 或者 2G> <输出文件名> [分区号，默认2] [compress]"
  exit 1
fi

# 如果分区号为空，设置默认值为2
if [ -z "$PARTITION_NUMBER" ]; then
  PARTITION_NUMBER=2
  echo "未指定分区号，使用默认值: $PARTITION_NUMBER"
fi

# 判断是URL还是本地文件路径
if [[ "$IMAGE_SOURCE" =~ ^https?:// ]]; then
  # 是URL，下载原始镜像
  ORIGINAL_NAME=$(basename "$IMAGE_SOURCE")
  echo "检测到URL，正在下载原始镜像..."
  wget -O "$ORIGINAL_NAME" "$IMAGE_SOURCE"
else
  # 是本地文件路径，直接使用
  ORIGINAL_NAME=$(basename "$IMAGE_SOURCE")
  if [ ! -f "$IMAGE_SOURCE" ]; then
    echo "错误：本地文件 $IMAGE_SOURCE 不存在"
    exit 1
  fi
  echo "使用本地文件: $IMAGE_SOURCE"
  # 如果本地文件不在当前目录，复制到当前目录
  if [ "$IMAGE_SOURCE" != "$ORIGINAL_NAME" ]; then
    cp "$IMAGE_SOURCE" "$ORIGINAL_NAME"
  fi
fi

# 检测文件类型
FILE_TYPE=$(file --mime-type -b "$ORIGINAL_NAME")

# 创建解压目录
mkdir -p extracted
EXTRACTED_FILE=""

# 处理不同的压缩格式
case "$FILE_TYPE" in
  application/gzip)
    echo "检测到 gzip 压缩，解压中..."
    gunzip -k "$ORIGINAL_NAME" || true  # 忽略解压缩时的警告
    EXTRACTED_FILE="${ORIGINAL_NAME%.gz}"
    ;;
  application/x-bzip2)
    echo "检测到 bzip2 压缩，解压中..."
    bzip2 -dk "$ORIGINAL_NAME" || true
    EXTRACTED_FILE="${ORIGINAL_NAME%.bz2}"
    ;;
  application/x-xz)
    echo "检测到 xz 压缩，解压中..."
    xz -dk "$ORIGINAL_NAME" || true
    EXTRACTED_FILE="${ORIGINAL_NAME%.xz}"
    ;;
  application/x-7z-compressed)
    echo "检测到 7z 压缩，解压中..."
    7z x "$ORIGINAL_NAME" -oextracted || true
    EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    ;;
  application/x-tar)
    echo "检测到 tar 压缩，解压中..."
    tar -xf "$ORIGINAL_NAME" -C extracted || true
    EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    ;;
  application/zip)
    echo "检测到 zip 压缩，解压中..."
    unzip "$ORIGINAL_NAME" -d extracted || true
    EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    ;;
  *)
    echo "未识别的文件类型，尝试按扩展名处理..."
    if [[ "$ORIGINAL_NAME" == *.gz ]]; then
      echo "按 .gz 处理..."
      gunzip -k "$ORIGINAL_NAME" || true  # 忽略解压缩时的警告
      EXTRACTED_FILE="${ORIGINAL_NAME%.gz}"
    elif [[ "$ORIGINAL_NAME" == *.bz2 ]]; then
      echo "按 .bz2 处理..."
      bzip2 -dk "$ORIGINAL_NAME" || true
      EXTRACTED_FILE="${ORIGINAL_NAME%.bz2}"
    elif [[ "$ORIGINAL_NAME" == *.xz ]]; then
      echo "按 .xz 处理..."
      xz -dk "$ORIGINAL_NAME" || true
      EXTRACTED_FILE="${ORIGINAL_NAME%.xz}"
    elif [[ "$ORIGINAL_NAME" == *.tar.gz || "$ORIGINAL_NAME" == *.tgz ]]; then
      echo "按 .tar.gz 处理..."
      tar -xzf "$ORIGINAL_NAME" -C extracted || true
      EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    elif [[ "$ORIGINAL_NAME" == *.tar.bz2 || "$ORIGINAL_NAME" == *.tbz2 ]]; then
      echo "按 .tar.bz2 处理..."
      tar -xjf "$ORIGINAL_NAME" -C extracted || true
      EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    elif [[ "$ORIGINAL_NAME" == *.tar.xz || "$ORIGINAL_NAME" == *.txz ]]; then
      echo "按 .tar.xz 处理..."
      tar -xJf "$ORIGINAL_NAME" -C extracted || true
      EXTRACTED_FILE=$(find extracted -type f | head -n 1)
    elif [[ "$ORIGINAL_NAME" == *.zip ]]; then
      echo "按 .zip 处理..."
      unzip "$ORIGINAL_NAME" -d extracted || true
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

# 检测解压后的文件格式
echo "检查文件格式..."
# 使用文本解析方式获取格式
FORMAT=$(qemu-img info "$ORIGINAL_NAME" | grep "file format" | awk '{print $3}')
echo "检测到文件格式: $FORMAT"

# 如果格式不是 raw，则转换为 raw 格式
if [[ "$FORMAT" != "raw" ]]; then
  echo "转换 $FORMAT 到 raw 格式..."
  qemu-img convert -O raw "$ORIGINAL_NAME" "${ORIGINAL_NAME}.img"
  ORIGINAL_NAME="${ORIGINAL_NAME}.img"
  FORMAT="raw"
fi

# 获取输出文件的格式
OUTPUT_FORMAT=$(echo "$OUTPUT_FILENAME" | awk -F. '{print $NF}')
# 如果输出格式是img，则使用raw格式
if [[ "$OUTPUT_FORMAT" == "img" ]]; then
  OUTPUT_FORMAT="raw"
fi

# 如果扩容大小为0，直接进行格式转换
if [ "$EXPAND_OPTIONS" -eq 0 ]; then
  echo "扩容大小为0，直接进行格式转换..."
  qemu-img convert -O "$OUTPUT_FORMAT" "$ORIGINAL_NAME" "$OUTPUT_FILENAME"
  echo "格式转换完成！"
else
  # 解析扩容大小，将G或M转换为MB单位
  if [[ "$EXPAND_OPTIONS" =~ ([0-9]+)([GM])$ ]]; then
    SIZE_NUM=${BASH_REMATCH[1]}
    SIZE_UNIT=${BASH_REMATCH[2]}
    
    if [ "$SIZE_UNIT" == "G" ]; then
      # 如果是GB，转换为MB (1G = 1024M)
      EXPAND_SIZE_MB=$((SIZE_NUM * 1024))
      echo "将 ${SIZE_NUM}G 转换为 ${EXPAND_SIZE_MB}M"
    else
      # 如果已经是MB，直接使用
      EXPAND_SIZE_MB=$SIZE_NUM
      echo "使用 ${EXPAND_SIZE_MB}M"
    fi
  else
    # 如果没有单位，假设是MB
    EXPAND_SIZE_MB=$EXPAND_OPTIONS
    echo "未指定单位，默认使用 ${EXPAND_SIZE_MB}M"
  fi
  
  echo "使用 dd 命令将 $ORIGINAL_NAME 增加指定大小"
  dd if=/dev/zero bs=1M count=$EXPAND_SIZE_MB >> $ORIGINAL_NAME

  echo "使用 parted 进行分区管理..."
  echo "当前分区表..."
  parted $ORIGINAL_NAME print
  
  echo "调整分区 $PARTITION_NUMBER 大小..."
  # 使用传入的分区号
  parted $ORIGINAL_NAME resizepart $PARTITION_NUMBER 100%

  # 如果输出格式与当前格式不同，则进行转换
  if [[ "$OUTPUT_FORMAT" != "$FORMAT" ]]; then
    echo "转换扩容后的镜像为 $OUTPUT_FORMAT 格式..."
    qemu-img convert -O "$OUTPUT_FORMAT" "$ORIGINAL_NAME" "$OUTPUT_FILENAME"
  else
    cp "$ORIGINAL_NAME" "$OUTPUT_FILENAME"
  fi
fi

echo "处理完成，输出文件: $OUTPUT_FILENAME"

# 只有在传递了压缩命令时才压缩文件
if [ "$COMPRESS_COMMAND" == "compress" ]; then
  echo "压缩最终文件..."
  7z a -mx=9 "${OUTPUT_FILENAME}.7z" "$OUTPUT_FILENAME"
  echo "压缩完成"
else
  echo "处理完成"
fi

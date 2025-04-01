#!/bin/bash
set -e

# 获取参数
IMAGE_SOURCE=$1
EXPAND_OPTIONS=$2
OUTPUT_FILENAME=$3
COMPRESS_COMMAND=$4

if [ -z "$IMAGE_SOURCE" ] || [ -z "$EXPAND_OPTIONS" ] || [ -z "$OUTPUT_FILENAME" ]; then
  echo "用法: $0 <镜像URL或本地文件路径> <扩容选项，例如/dev/sda1 1G,/dev/sda2 200M 或者 2G> [输出文件名]"
  exit 1
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

# 检测解压后的文件格式
FORMAT=$(qemu-img info --output=json "$ORIGINAL_NAME" | jq -r '.format')

# 如果格式不是 raw 或 qcow2，则转换为 raw 格式
if [[ "$FORMAT" != "raw" && "$FORMAT" != "qcow2" ]]; then
  echo "转换 $FORMAT 到 raw 格式..."
  qemu-img convert -O raw "$ORIGINAL_NAME" "${ORIGINAL_NAME}.img"
  ORIGINAL_NAME="${ORIGINAL_NAME}.img"
fi

# 计算新的磁盘大小
TOTAL_EXPAND_SIZE=0
declare -a PARSED_OPTIONS
declare -a PARSED_PARTITIONS
declare -a PARSED_SIZES

# 首先判断整个EXPAND_OPTIONS是否只是一个简单的大小值
if [[ "$EXPAND_OPTIONS" =~ ^[0-9]+[GM]$ ]]; then
  # 如果是单纯的大小值，直接使用
  PARSED_OPTIONS=("$EXPAND_OPTIONS")
else
  # 否则按逗号分隔解析
  IFS=',' read -ra PARSED_OPTIONS <<< "$EXPAND_OPTIONS"
fi

for OPTION in "${PARSED_OPTIONS[@]}"; do
  # 检查每个选项是否只有一个值（纯大小格式，如"8G"）
  if [[ "$OPTION" =~ ^[0-9]+[GM]$ ]]; then
    SIZE="$OPTION"
    # 暂时不确定分区，后面再处理
    PARTITION=""
  else
    PARTITION=$(echo "$OPTION" | awk '{print $1}')
    SIZE=$(echo "$OPTION" | awk '{print $2}')
  fi
  
  # 保存解析结果
  PARSED_PARTITIONS+=("$PARTITION")
  PARSED_SIZES+=("$SIZE")
  
  UNIT=${SIZE: -1}
  VALUE=${SIZE%?}
  if [[ "$UNIT" == "G" ]]; then
    TOTAL_EXPAND_SIZE=$(echo "$TOTAL_EXPAND_SIZE + $VALUE * 1024" | bc)
  elif [[ "$UNIT" == "M" ]]; then
    TOTAL_EXPAND_SIZE=$(echo "$TOTAL_EXPAND_SIZE + $VALUE" | bc)
  fi
done

# 获取输出文件的格式
OUTPUT_FORMAT=$(echo "$OUTPUT_FILENAME" | awk -F. '{print $NF}')
# 如果输出格式是img，则使用raw格式
if [[ "$OUTPUT_FORMAT" == "img" ]]; then
  OUTPUT_FORMAT="raw"
fi

# 如果扩容大小为0，直接进行格式转换
if [ "$TOTAL_EXPAND_SIZE" -eq 0 ]; then
  echo "扩容大小为0，直接进行格式转换..."
  qemu-img convert -O "$OUTPUT_FORMAT" "$ORIGINAL_NAME" "$OUTPUT_FILENAME"
  echo "格式转换完成！"
else
  # 创建新的扩容后的磁盘镜像
  RESIZED_NAME="resized_${ORIGINAL_NAME}"
  echo "创建新的磁盘镜像，大小为 ${TOTAL_EXPAND_SIZE}M..."
  qemu-img create -f "$FORMAT" "$RESIZED_NAME" "${TOTAL_EXPAND_SIZE}M"

  # 使用之前解析好的选项进行扩容
  for i in "${!PARSED_OPTIONS[@]}"; do
    PARTITION="${PARSED_PARTITIONS[$i]}"
    SIZE="${PARSED_SIZES[$i]}"
    
    # 如果分区为空（即只指定了大小），找到最大的分区
    if [ -z "$PARTITION" ]; then
      echo "未指定分区，查找镜像中的最大分区..."
      # 打印完整的分区表格，便于在GitHub日志中查看
      echo "镜像中的分区信息表格:"
      virt-filesystems -a "$ORIGINAL_NAME" -l
      
      # 使用virt-filesystems获取镜像中的分区信息，并提取最大分区
      PARTITION=$(virt-filesystems -a "$ORIGINAL_NAME" -l | awk 'NR>1 {print $1, $5}' | sort -k2 -n | tail -n1 | awk '{print $1}')
      if [ -z "$PARTITION" ]; then
        echo "错误：无法在镜像中找到分区。请手动指定分区。"
        exit 1
      fi
      echo "找到镜像中的最大分区: $PARTITION"
    fi
    
    echo "正在扩展分区 $PARTITION 到大小 $SIZE..."
    virt-resize --expand "$PARTITION" "$ORIGINAL_NAME" "$RESIZED_NAME"
  done

  echo "扩容完成！新镜像: $RESIZED_NAME"

  # 如果输出格式与当前格式不同，则进行转换
  if [[ "$OUTPUT_FORMAT" != "raw" && "$OUTPUT_FORMAT" != "$FORMAT" ]]; then
    echo "转换扩容后的镜像为 $OUTPUT_FORMAT 格式..."
    qemu-img convert -O "$OUTPUT_FORMAT" "$RESIZED_NAME" "$OUTPUT_FILENAME"
    rm "$RESIZED_NAME"  # 删除中间文件
  else
    mv "$RESIZED_NAME" "$OUTPUT_FILENAME"
  fi
fi

echo "重命名扩容后的镜像为: $OUTPUT_FILENAME"

# 只有在传递了压缩命令时才压缩文件
if [ "$COMPRESS_COMMAND" == "compress" ]; then
  echo "压缩最终文件..."
  7z a -mx=9 "${OUTPUT_FILENAME}.7z" "$OUTPUT_FILENAME"
  echo "压缩完成"
else
  echo "处理完成"
fi

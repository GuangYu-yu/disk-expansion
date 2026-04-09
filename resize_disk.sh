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

# ==========================================
# 参数解析与验证
# ==========================================
IMAGE_SOURCE=$1
OUTPUT_FILENAME=$2
RESIZE_RULE=$3

if [ -z "$IMAGE_SOURCE" ] || [ -z "$OUTPUT_FILENAME" ] || [ -z "$RESIZE_RULE" ]; then
  echo "用法: $0 <镜像URL或本地文件路径> <输出文件名> <扩容规则>"
  echo ""
  echo "扩容规则:"
  echo "  0                         仅格式转换"
  echo "  2G                        自动选择分区，扩容 2G"
  echo "  +10%                      自动选择分区，增加 10%"
  echo "  =10G                      自动选择分区，增至 10G"
  echo "  /dev/sda2                 指定分区填满剩余空间"
  echo "  /dev/sda2+2G              分区增加 2G"
  echo "  /dev/sda2=10G             分区增至 10G"
  echo "  /dev/sda2+10%             分区增加 10%"
  echo "  /dev/vg/lv+2G             LVM 逻辑卷增加 2G"
  echo "  /dev/sda1+100M,/dev/sda2  多分区调整（逗号分隔）"
  echo ""
  exit 1
fi

# ==========================================
# 镜像获取与解压
# ==========================================
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

# 根据扩展名获取格式
get_format_from_ext() {
  local filename="$1"
  local ext="${filename##*.}"
  ext="${ext,,}"
  case "$ext" in
    qcow2) echo "qcow2" ;;
    raw|img) echo "raw" ;;
    vmdk) echo "vmdk" ;;
    vdi) echo "vdi" ;;
    vhd) echo "vpc" ;;
    vhdx) echo "vhdx" ;;
    qed) echo "qed" ;;
    luks) echo "luks" ;;
    hdd) echo "parallels" ;;
    *) echo "" ;;
  esac
}

is_valid_image() {
  local filename="$1"
  [ -n "$(get_format_from_ext "$filename")" ]
}

EXTRACTED_FILE=""

# 解压逻辑
case "$ORIGINAL_NAME" in
  *.gz)
    echo "检测到 gzip 压缩，解压中..."
    EXTRACTED_FILE="${ORIGINAL_NAME%.gz}"
    gunzip -c "$ORIGINAL_NAME" 2>/dev/null | dd of="$EXTRACTED_FILE" conv=sparse || true
    rm -f "$ORIGINAL_NAME"
    ;;
  *.xz)
    echo "检测到 xz 压缩，解压中..."
    EXTRACTED_FILE="${ORIGINAL_NAME%.xz}"
    xz -dc "$ORIGINAL_NAME" 2>/dev/null | dd of="$EXTRACTED_FILE" conv=sparse || true
    rm -f "$ORIGINAL_NAME"
    ;;
  *.bz2)
    echo "检测到 bzip2 压缩，解压中..."
    EXTRACTED_FILE="${ORIGINAL_NAME%.bz2}"
    bzip2 -dc "$ORIGINAL_NAME" 2>/dev/null | dd of="$EXTRACTED_FILE" conv=sparse || true
    rm -f "$ORIGINAL_NAME"
    ;;
  *.zip)
    echo "检测到 zip 压缩，解压中..."
    mkdir -p extracted
    unzip -q -o "$ORIGINAL_NAME" -d extracted || true
    EXTRACTED_FILE=$(find extracted -type f | while read -r f; do
      if is_valid_image "$f"; then
        echo "$f"
        break
      fi
    done)
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
[ -z "$FORMAT" ] && FORMAT="raw"
echo "检测到文件格式: $FORMAT"

OUTPUT_FORMAT=$(get_format_from_ext "$OUTPUT_FILENAME")
[ -z "$OUTPUT_FORMAT" ] && { echo "警告：未知格式，默认使用 raw"; OUTPUT_FORMAT="raw"; }
echo "输出格式: $OUTPUT_FORMAT"

# ==========================================
# 工具函数
# ==========================================

# 解析大小字符串为字节数（支持 K/M/G/T 及 KB/MB/GB 等）
parse_size_to_bytes() {
  local size_str="$1"
  size_str="${size_str^^}"
  if [[ "$size_str" =~ ^([0-9]+)(B|KB|MB|GB|K|M|G)?$ ]]; then
    local size_num=${BASH_REMATCH[1]}
    local size_unit=${BASH_REMATCH[2]}
    case "$size_unit" in
      G|GB) echo $((size_num * 1073741824)) ;;
      M|MB) echo $((size_num * 1048576)) ;;
      K|KB) echo $((size_num * 1024)) ;;
      B|'') echo "$size_num" ;;
    esac
  else
    echo "0"
  fi
}

# 从 FS_INFO 中获取某分区的大小（字节）
get_partition_size_bytes() {
  local partition="$1"
  echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v size_col="$COL_SIZE" -v part="$partition" '
    NR>1 && $name_col == part {print $size_col; exit}
  '
}

# 根据操作符和大小字符串计算需要增加的字节数（已对齐到 64K）
calc_expand_bytes() {
  local size_str="$1"
  local current_bytes="$2"
  
  if [[ "$size_str" =~ ^([0-9]+)%$ ]]; then
    local percent=${BASH_REMATCH[1]}
    local expand_bytes=$(( current_bytes * percent / 100 ))
    echo $(( (expand_bytes + 65535) / 65536 * 65536 ))
  else
    local target_bytes=$(parse_size_to_bytes "$size_str")
    if [ "$target_bytes" -gt "$current_bytes" ]; then
      local expand_bytes=$(( target_bytes - current_bytes ))
      echo $(( (expand_bytes + 65535) / 65536 * 65536 ))
    else
      echo "0"
    fi
  fi
}

# 判断给定名称是否为 LVM 逻辑卷
is_lv() {
  local name="$1"
  echo "$LV_LIST" | awk '{print $1}' | grep -Fxq "$name"
}

# ==========================================
# 仅格式转换分支
# ==========================================
if [[ "$RESIZE_RULE" == "0" ]]; then
  echo "扩容大小为0，直接进行格式转换..."
  qemu-img convert -O "$OUTPUT_FORMAT" "$ORIGINAL_NAME" "$OUTPUT_FILENAME"
  echo "格式转换完成！"
  echo "处理完成，输出文件: $OUTPUT_FILENAME"
  exit 0
fi

# ==========================================
# 获取镜像基础信息（缓存所有必要数据）
# ==========================================
ORIGINAL_SIZE=$(qemu-img info "$ORIGINAL_NAME" 2>/dev/null | grep "virtual size" | sed -E 's/.*\(([0-9]+) bytes\).*/\1/')
if [ -z "$ORIGINAL_SIZE" ]; then
  ORIGINAL_SIZE=$(stat -c %s "$ORIGINAL_NAME" 2>/dev/null || stat -f %z "$ORIGINAL_NAME")
fi
echo "检测到镜像大小: $ORIGINAL_SIZE 字节"

echo "查找镜像中的分区..."
echo "镜像中的分区信息表格:"
virt-filesystems -a "$ORIGINAL_NAME" -l

echo ""
echo "检测 LVM..."
HAS_LVM=false
LV_LIST=""
if virt-filesystems -a "$ORIGINAL_NAME" --lvs 2>/dev/null | grep -q .; then
  HAS_LVM=true
  LV_LIST=$(virt-filesystems -a "$ORIGINAL_NAME" --lvs 2>/dev/null)
  echo "检测到 LVM 逻辑卷："
  echo "$LV_LIST"
fi

FS_INFO=$(virt-filesystems -a "$ORIGINAL_NAME" -l 2>/dev/null)
HEADER=$(echo "$FS_INFO" | head -n1)

COL_NAME=$(echo "$HEADER" | awk '{for(i=1;i<=NF;i++) if($i=="Name") print i}')
COL_VFS=$(echo "$HEADER" | awk '{for(i=1;i<=NF;i++) if($i=="VFS") print i}')
COL_LABEL=$(echo "$HEADER" | awk '{for(i=1;i<=NF;i++) if($i=="Label") print i}')
COL_SIZE=$(echo "$HEADER" | awk '{for(i=1;i<=NF;i++) if($i=="Size") print i}')

# ==========================================
# 自动选择扩容分区
# ==========================================
find_expand_partition() {
  local pv_list
  pv_list=$(virt-filesystems -a "$ORIGINAL_NAME" --pv 2>/dev/null)
  
  if [ -n "$pv_list" ]; then
    local pv_count
    pv_count=$(echo "$pv_list" | grep -c .)
    
    if [ "$pv_count" -gt 1 ]; then
      echo "错误：检测到多个 PV，请手动指定分区规则" >&2
      echo "可用 PV：" >&2
      echo "$pv_list" >&2
      exit 1
    fi
    
    local pv
    pv=$(echo "$pv_list" | head -n1)
    
    local is_part
    is_part=$(echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v p="$pv" '
      NR>1 && $name_col == p {print 1; exit}
    ')
    
    if [ "$is_part" = "1" ]; then
      echo "$pv"
      return
    fi
    
    echo "$FS_INFO" | awk -v vfs_col="$COL_VFS" -v name_col="$COL_NAME" -v size_col="$COL_SIZE" '
      NR>1 && tolower($vfs_col) ~ /lvm/ {
        print $name_col, $size_col
      }
    ' | sort -k2 -n | tail -n1 | awk '{print $1}'
    
    return
  fi
  
  # 普通分区：根据 Label、文件系统类型和大小选择
  echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v vfs_col="$COL_VFS" -v label_col="$COL_LABEL" -v size_col="$COL_SIZE" '
    BEGIN {
      part_idx = 0
    }
    NR>1 && $name_col ~ /^\/dev\// {
      part_idx++
      names[part_idx] = $name_col
      vfs[part_idx] = tolower($vfs_col)

      lbl = tolower($label_col)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", lbl)
      labels[part_idx] = lbl

      sizes[part_idx] = $size_col + 0
    }

    END {
      if (part_idx == 0) exit

      # 优先匹配常见 root 分区 Label
      for (i = 1; i <= part_idx; i++) {
        if (labels[i] ~ /^(cloudimg-rootfs|rootfs|root|img-rootfs)$/) {
          print names[i]
          exit
        }
      }

      # 次选：常见 Linux 文件系统，容量 > 100MB，排除首分区过小的情况
      for (i = 1; i <= part_idx; i++) {
        v = vfs[i]
        s = sizes[i]
        is_first = (i == 1)

        if (v ~ /^(ext4|ext3|xfs|btrfs)$/) {
          if (s > 104857600) {
            if (!(is_first && s <= 1073741824)) {
              print names[i]
              exit
            }
          }
        }
      }

      # 兜底：放宽文件系统类型限制
      for (i = 1; i <= part_idx; i++) {
        v = vfs[i]
        s = sizes[i]
        if (v ~ /^(ext4|ext3|xfs|btrfs)$/ && v != "vfat" && v != "swap" && s > 52428800) {
          print names[i]
          exit
        }
      }

      # 最后兜底：不限制文件系统类型
      for (i = 1; i <= part_idx; i++) {
        v = vfs[i]
        s = sizes[i]
        if (v != "vfat" && v != "swap" && s > 52428800) {
          print names[i]
          exit
        }
      }
    }
  '
}

# ==========================================
# 解析扩容规则
# ==========================================
RESIZE_OPTS=""
EXPAND_PARTITION=""
LV_EXPAND=""
EXPAND_SIZE_BYTES=0

IFS=',' read -ra RULES <<< "$RESIZE_RULE"
RULE_COUNT=${#RULES[@]}

for i in "${!RULES[@]}"; do
  rule="${RULES[$i]}"
  rule=$(echo "$rule" | xargs)
  
  # 判断是否为设备路径规则
  if [[ "$rule" =~ ^/dev/ ]]; then
    # 检查是否带操作符 (= 或 +)
    if [[ "$rule" =~ ^(/dev/[^+=%]+)([+=])(.+)$ ]]; then
      partition="${BASH_REMATCH[1]}"
      operator="${BASH_REMATCH[2]}"
      size_spec="${BASH_REMATCH[3]}"
      
      if is_lv "$partition"; then
        # LVM 逻辑卷处理
        [ -z "$EXPAND_PARTITION" ] && EXPAND_PARTITION=$(find_expand_partition)
        LV_EXPAND="$partition"
        if [ "$operator" == "+" ]; then
          echo "规则: LV $partition 增加 $size_spec"
        else
          echo "规则: LV $partition 增至 $size_spec"
        fi
        current_bytes=$(get_partition_size_bytes "$partition")
        size_bytes=$(calc_expand_bytes "$size_spec" "$current_bytes")
        EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
      else
        # 普通分区带操作符
        if [ "$operator" == "+" ]; then
          RESIZE_OPTS="$RESIZE_OPTS --resize ${partition}=+${size_spec}"
          echo "规则: 分区 $partition 增加 $size_spec"
        else
          RESIZE_OPTS="$RESIZE_OPTS --resize ${partition}=${size_spec}"
          echo "规则: 分区 $partition 增至 $size_spec"
        fi
        current_bytes=$(get_partition_size_bytes "$partition")
        size_bytes=$(calc_expand_bytes "$size_spec" "$current_bytes")
        EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
      fi
    else
      # 纯设备路径，无操作符
      partition="$rule"
      if is_lv "$partition"; then
        [ -z "$EXPAND_PARTITION" ] && EXPAND_PARTITION=$(find_expand_partition)
        LV_EXPAND="$partition"
        echo "规则: LV $partition 填满剩余空间"
      else
        if [ $((i + 1)) -eq $RULE_COUNT ]; then
          EXPAND_PARTITION="$partition"
          echo "规则: 分区 $partition 填满剩余空间"
        else
          RESIZE_OPTS="$RESIZE_OPTS --resize ${partition}=+0"
          echo "规则: 分区 $partition 保持大小"
        fi
      fi
    fi
  else
    # 非设备路径规则（自动选择）
    # 纯数字带可选单位，如 2G（表示增加指定大小）
    if [[ "$rule" =~ ^[0-9]+[KMGT]?$ ]]; then
      size_bytes=$(parse_size_to_bytes "$rule")
      if [ "$size_bytes" -gt 0 ]; then
        EXPAND_PARTITION=$(find_expand_partition)
        if [ -n "$EXPAND_PARTITION" ]; then
          echo "规则: 自动选择分区 $EXPAND_PARTITION，扩容 $rule"
          EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
        fi
      fi
    # 以 = 或 + 开头，如 =10G 或 +10%
    elif [[ "$rule" =~ ^([+=])(.+)$ ]]; then
      operator="${BASH_REMATCH[1]}"
      size_spec="${BASH_REMATCH[2]}"
      EXPAND_PARTITION=$(find_expand_partition)
      if [ -n "$EXPAND_PARTITION" ]; then
        current_bytes=$(get_partition_size_bytes "$EXPAND_PARTITION")
        if [ "$operator" == "+" ]; then
          RESIZE_OPTS="$RESIZE_OPTS --resize ${EXPAND_PARTITION}=+${size_spec}"
          size_bytes=$(calc_expand_bytes "$size_spec" "$current_bytes")
          echo "规则: 自动选择分区 $EXPAND_PARTITION，增加 $size_spec"
        else
          RESIZE_OPTS="$RESIZE_OPTS --resize ${EXPAND_PARTITION}=${size_spec}"
          size_bytes=$(calc_expand_bytes "$size_spec" "$current_bytes")
          echo "规则: 自动选择分区 $EXPAND_PARTITION，增至 $size_spec"
        fi
        EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
      fi
    else
      echo "错误：无法解析规则 '$rule'"
      exit 1
    fi
  fi
done

# ==========================================
# 检查扩容参数有效性
# ==========================================
if [ -z "$EXPAND_PARTITION" ]; then
  echo "错误：无法确定要扩容的分区"
  exit 1
fi

if [ $EXPAND_SIZE_BYTES -eq 0 ]; then
  echo "错误：没有指定扩容大小"
  echo "示例: 2G 或 +10% 或 /dev/sda2+2G"
  exit 1
fi

# ==========================================
# 计算总大小并创建新镜像
# ==========================================
TOTAL_SIZE=$((ORIGINAL_SIZE + EXPAND_SIZE_BYTES))

RESIZED_NAME="stage2_${RANDOM_SUFFIX}.${OUTPUT_FORMAT}"
TEMP_FILES+=("$RESIZED_NAME")

echo "创建新的磁盘镜像，大小为 ${TOTAL_SIZE} 字节（原始 ${ORIGINAL_SIZE} + 扩容 ${EXPAND_SIZE_BYTES}）..."
qemu-img create -f "$OUTPUT_FORMAT" "$RESIZED_NAME" "$TOTAL_SIZE"

# ==========================================
# 组装 virt-resize 命令
# ==========================================
RESIZE_CMD="virt-resize --expand $EXPAND_PARTITION"
[ -n "$RESIZE_OPTS" ] && RESIZE_CMD="$RESIZE_CMD $RESIZE_OPTS"

# 忽略 swap 分区（除了扩容分区本身）
SWAP_PARTITIONS=$(echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v vfs_col="$COL_VFS" -v part="$EXPAND_PARTITION" '
  NR>1 && $vfs_col == "swap" && $name_col != part {print $name_col}
')
if [ -n "$SWAP_PARTITIONS" ]; then
  echo "将忽略 swap 分区以加速复制："
  for swap_part in $SWAP_PARTITIONS; do
    RESIZE_CMD="$RESIZE_CMD --ignore $swap_part"
    echo "  - $swap_part"
  done
fi

if [ -n "$LV_EXPAND" ]; then
  RESIZE_CMD="$RESIZE_CMD --LV-expand $LV_EXPAND"
  echo "将扩容 LVM 逻辑卷: $LV_EXPAND"
elif [ "$HAS_LVM" = true ]; then
  echo "提示：检测到 LVM 但未指定 LV，仅扩容 PV。如需扩容 LV 请在规则中指定 LV 名"
fi

# ==========================================
# 执行扩容并重命名输出
# ==========================================
echo "执行: $RESIZE_CMD \"$ORIGINAL_NAME\" \"$RESIZED_NAME\""
$RESIZE_CMD "$ORIGINAL_NAME" "$RESIZED_NAME"

echo "扩容完成！"
mv "$RESIZED_NAME" "$OUTPUT_FILENAME"

echo "处理完成，输出文件: $OUTPUT_FILENAME"

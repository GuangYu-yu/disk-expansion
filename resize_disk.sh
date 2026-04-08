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
OUTPUT_FILENAME=$2
RESIZE_RULE=$3

if [ -z "$IMAGE_SOURCE" ] || [ -z "$OUTPUT_FILENAME" ] || [ -z "$RESIZE_RULE" ]; then
  echo "用法: $0 <镜像URL或本地文件路径> <输出文件名> <扩容规则>"
  echo ""
  echo "扩容规则:"
  echo "  0                         仅格式转换"
  echo "  2G                        自动选择分区，扩容 2G"
  echo "  +10%                      自动选择分区，增加 10%"
  echo "  =10G                      自动选择分区，设为 10G"
  echo "  /dev/sda2                 指定分区填满剩余空间"
  echo "  /dev/sda2+2G              分区增加 2G"
  echo "  /dev/sda2=10G             分区设为 10G"
  echo "  /dev/sda2+10%             分区增加 10%"
  echo "  /dev/vg/lv+2G             LVM 逻辑卷增加 2G"
  echo "  /dev/sda1+100M,/dev/sda2  多分区调整（逗号分隔）"
  echo ""
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
if [ -z "$FORMAT" ]; then
  FORMAT="raw"
fi
echo "检测到文件格式: $FORMAT"

OUTPUT_FORMAT=$(get_format_from_ext "$OUTPUT_FILENAME")
if [ -z "$OUTPUT_FORMAT" ]; then
  echo "警告：未知格式，默认使用 raw"
  OUTPUT_FORMAT="raw"
fi
echo "输出格式: $OUTPUT_FORMAT"

parse_size_to_bytes() {
  local size_str="$1"
  local size_num size_unit
  
  size_str="${size_str^^}"
  
  if [[ "$size_str" =~ ^([0-9]+)(B|KB|MB|GB|K|M|G)?$ ]]; then
    size_num=${BASH_REMATCH[1]}
    size_unit=${BASH_REMATCH[2]}
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

get_partition_size_bytes() {
  local partition="$1"
  echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v size_col="$COL_SIZE" -v part="$partition" '
    NR>1 && $name_col == part {print $size_col; exit}
  '
}

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

if [[ "$RESIZE_RULE" == "0" ]]; then
  echo "扩容大小为0，直接进行格式转换..."
  qemu-img convert -O "$OUTPUT_FORMAT" "$ORIGINAL_NAME" "$OUTPUT_FILENAME"
  echo "格式转换完成！"
else
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
  COL_TYPE=$(echo "$HEADER" | awk '{for(i=1;i<=NF;i++) if($i=="Type") print i}')
  
  RESIZE_OPTS=""
  EXPAND_PARTITION=""
  LV_EXPAND=""
  EXPAND_SIZE_BYTES=0
  
  is_lv() {
    local name="$1"
    echo "$LV_LIST" | awk '{print $1}' | grep -Fxq "$name"
  }
  
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
      is_part=$(echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v type_col="$COL_TYPE" -v p="$pv" '
        NR>1 && $name_col == p && $type_col == "partition" {print 1}
      ')
      
      if [ "$is_part" = "1" ]; then
        echo "$pv"
        return
      fi
      
      local lvm_devs
      lvm_devs=$(echo "$FS_INFO" | awk -v vfs_col="$COL_VFS" -v name_col="$COL_NAME" '
        NR>1 && $vfs_col == "lvm" {print $name_col}
      ')
      
      echo "$FS_INFO" | awk -v type_col="$COL_TYPE" -v name_col="$COL_NAME" -v size_col="$COL_SIZE" -v lvm="$lvm_devs" '
        BEGIN {
          split(lvm, arr, "\n")
          for (i in arr) map[arr[i]] = 1
        }
        NR>1 && $type_col == "partition" && map[$name_col] {print $name_col, $size_col}
      ' | sort -k2 -n | tail -n1 | awk '{print $1}'
      return
    fi
    
    local label_whitelist="root rootfs cloudimg-rootfs system linux"
    local vfs_blacklist="swap vfat efi unknown"
    local min_size=52428800
    local first_part_protect=209715200
    
    local partitions
    partitions=$(echo "$FS_INFO" | awk -v type_col="$COL_TYPE" -v name_col="$COL_NAME" '
      NR>1 && $type_col == "partition" {print $name_col}
    ')
    
    if [ -z "$partitions" ]; then
      return 1
    fi
    
    local first_part
    first_part=$(echo "$partitions" | head -n1)
    
    local result
    result=$(echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v label_col="$COL_LABEL" -v wl="$label_whitelist" '
      BEGIN {
        split(wl, arr, " ")
        for (i in arr) whitelist[arr[i]] = 1
      }
      NR>1 {
        label = $label_col
        gsub(/^[ \t]+|[ \t]+$/, "", label)
        label = tolower(label)
        if (whitelist[label]) {
          print $name_col
          exit
        }
      }
    ')
    
    if [ -n "$result" ]; then
      echo "$result"
      return
    fi
    
    result=$(echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v vfs_col="$COL_VFS" -v label_col="$COL_LABEL" -v size_col="$COL_SIZE" \
      -v vfs_bl="$vfs_blacklist" -v min_sz="$min_size" -v first_part="$first_part" -v first_protect="$first_part_protect" '
      BEGIN {
        split(vfs_bl, vfs_arr, " ")
        for (i in vfs_arr) vfs_blacklist_map[vfs_arr[i]] = 1
      }
      NR>1 && $type_col == "partition" {
        name = $name_col
        vfs = tolower($vfs_col)
        size = $size_col + 0
        
        label = $label_col
        gsub(/^[ \t]+|[ \t]+$/, "", label)
        label_lower = tolower(label)
        
        if (vfs_blacklist_map[vfs]) next
        if (label_lower ~ /boot|efi|esp/) next
        if (size <= min_sz) next
        if (name == first_part && size <= first_protect) next
        
        print name
        exit
      }
    ')
    
    if [ -n "$result" ]; then
      echo "$result"
      return
    fi
    
    result=$(echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v vfs_col="$COL_VFS" -v size_col="$COL_SIZE" -v min_sz="$min_size" '
      NR>1 && $type_col == "partition" {
        vfs = tolower($vfs_col)
        size = $size_col + 0
        if (vfs != "ext4" && vfs != "xfs" && vfs != "btrfs") next
        if (size <= min_sz) next
        print $name_col
        exit
      }
    ')
    
    if [ -n "$result" ]; then
      echo "$result"
      return
    fi
    
    result=$(echo "$FS_INFO" | awk -v name_col="$COL_NAME" -v vfs_col="$COL_VFS" -v size_col="$COL_SIZE" -v min_sz="$min_size" '
      NR>1 && $type_col == "partition" {
        vfs = tolower($vfs_col)
        size = $size_col + 0
        if (vfs == "swap" || vfs == "vfat") next
        if (size <= min_sz) next
        print $name_col
        exit
      }
    ')
    
    if [ -n "$result" ]; then
      echo "$result"
      return
    fi
    
    return 1
  }
  
  IFS=',' read -ra RULES <<< "$RESIZE_RULE"
  RULE_COUNT=${#RULES[@]}
  
  for i in "${!RULES[@]}"; do
    rule="${RULES[$i]}"
    rule=$(echo "$rule" | xargs)
    
    if [[ "$rule" =~ ^/dev/ ]]; then
      if [[ "$rule" =~ ^(/dev/[^+=%]+)([+=])(.+)$ ]]; then
        partition="${BASH_REMATCH[1]}"
        operator="${BASH_REMATCH[2]}"
        size="${BASH_REMATCH[3]}"
        
        if is_lv "$partition"; then
          if [ -z "$EXPAND_PARTITION" ]; then
            EXPAND_PARTITION=$(find_expand_partition)
          fi
          if [ "$operator" == "+" ]; then
            LV_EXPAND="$partition"
            echo "规则: LV $partition 增加 $size"
            if [[ "$size" =~ %$ ]]; then
              current_bytes=$(get_partition_size_bytes "$partition")
              size_bytes=$(calc_expand_bytes "$size" "$current_bytes")
            else
              size_bytes=$(parse_size_to_bytes "$size")
            fi
            EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
          else
            LV_EXPAND="$partition"
            echo "规则: LV $partition 设为 $size"
            current_bytes=$(get_partition_size_bytes "$partition")
            size_bytes=$(calc_expand_bytes "$size" "$current_bytes")
            EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
          fi
        else
          if [ "$operator" == "+" ]; then
            RESIZE_OPTS="$RESIZE_OPTS --resize ${partition}=+${size}"
            echo "规则: 分区 $partition 增加 $size"
            if [[ "$size" =~ %$ ]]; then
              current_bytes=$(get_partition_size_bytes "$partition")
              size_bytes=$(calc_expand_bytes "$size" "$current_bytes")
            else
              size_bytes=$(parse_size_to_bytes "$size")
            fi
            EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
          else
            RESIZE_OPTS="$RESIZE_OPTS --resize ${partition}=${size}"
            echo "规则: 分区 $partition 设为 $size"
            current_bytes=$(get_partition_size_bytes "$partition")
            size_bytes=$(calc_expand_bytes "$size" "$current_bytes")
            EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
          fi
        fi
      else
        partition="$rule"
        
        if is_lv "$partition"; then
          if [ -z "$EXPAND_PARTITION" ]; then
            EXPAND_PARTITION=$(find_expand_partition)
          fi
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
      EXPAND_SIZE_BYTES=$(parse_size_to_bytes "$rule")
      if [ "$EXPAND_SIZE_BYTES" -gt 0 ]; then
        EXPAND_PARTITION=$(find_expand_partition)
        if [ -n "$EXPAND_PARTITION" ]; then
          echo "规则: 自动选择分区 $EXPAND_PARTITION，扩容 $rule"
        fi
      elif [[ "$rule" =~ ^([+=])(.+)$ ]]; then
        operator="${BASH_REMATCH[1]}"
        size="${BASH_REMATCH[2]}"
        
        EXPAND_PARTITION=$(find_expand_partition)
        if [ -n "$EXPAND_PARTITION" ]; then
          
          current_bytes=$(get_partition_size_bytes "$EXPAND_PARTITION")
          
          if [ "$operator" == "+" ]; then
            if [[ "$size" =~ %$ ]]; then
              RESIZE_OPTS="$RESIZE_OPTS --resize ${EXPAND_PARTITION}=+${size}"
              size_bytes=$(calc_expand_bytes "$size" "$current_bytes")
              echo "规则: 自动选择分区 $EXPAND_PARTITION，增加 $size"
            else
              RESIZE_OPTS="$RESIZE_OPTS --resize ${EXPAND_PARTITION}=+${size}"
              size_bytes=$(parse_size_to_bytes "$size")
              echo "规则: 自动选择分区 $EXPAND_PARTITION，增加 $size"
            fi
          else
            RESIZE_OPTS="$RESIZE_OPTS --resize ${EXPAND_PARTITION}=${size}"
            size_bytes=$(calc_expand_bytes "$size" "$current_bytes")
            echo "规则: 自动选择分区 $EXPAND_PARTITION，设为 $size"
          fi
          EXPAND_SIZE_BYTES=$((EXPAND_SIZE_BYTES + size_bytes))
        fi
      else
        echo "错误：无法解析规则 '$rule'"
        exit 1
      fi
    fi
  done
  
  if [ -z "$EXPAND_PARTITION" ]; then
    echo "错误：无法确定要扩容的分区"
    exit 1
  fi
  
  if [ $EXPAND_SIZE_BYTES -eq 0 ]; then
    echo "错误：没有指定扩容大小"
    echo "示例: 2G 或 +10% 或 /dev/sda2+2G"
    exit 1
  fi
  
  TOTAL_SIZE=$((ORIGINAL_SIZE + EXPAND_SIZE_BYTES))
  
  RESIZED_NAME="stage2_${RANDOM_SUFFIX}.${OUTPUT_FORMAT}"
  TEMP_FILES+=("$RESIZED_NAME")
  
  echo "创建新的磁盘镜像，大小为 ${TOTAL_SIZE} 字节（原始 ${ORIGINAL_SIZE} + 扩容 ${EXPAND_SIZE_BYTES}）..."
  qemu-img create -f "$OUTPUT_FORMAT" "$RESIZED_NAME" "$TOTAL_SIZE"

  RESIZE_CMD="virt-resize --expand $EXPAND_PARTITION"
  
  if [ -n "$RESIZE_OPTS" ]; then
    RESIZE_CMD="$RESIZE_CMD $RESIZE_OPTS"
  fi
  
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
  
  echo "执行: $RESIZE_CMD \"$ORIGINAL_NAME\" \"$RESIZED_NAME\""
  $RESIZE_CMD "$ORIGINAL_NAME" "$RESIZED_NAME"

  echo "扩容完成！"

  mv "$RESIZED_NAME" "$OUTPUT_FILENAME"
fi

echo "处理完成，输出文件: $OUTPUT_FILENAME"

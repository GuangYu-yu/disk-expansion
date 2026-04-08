#!/bin/bash
set -o pipefail

export LIBGUESTFS_BACKEND=direct

# -------------------- 全局变量 --------------------
RANDOM_SUFFIX=$RANDOM
TEMP_FILES=()
CLEANUP_DONE=false

# -------------------- 清理函数 --------------------
cleanup() {
    if [[ "$CLEANUP_DONE" == true ]]; then
        return
    fi
    echo "[INFO] 清理临时文件..."
    for f in "${TEMP_FILES[@]}"; do
        [[ -n "$f" ]] && rm -rf "$f" 2>/dev/null || true
    done
    CLEANUP_DONE=true
}

trap cleanup EXIT

# -------------------- 日志函数 --------------------
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; exit 1; }

# -------------------- 参数解析 --------------------
IMAGE_SOURCE="$1"
OUTPUT_FILENAME="$2"
RESIZE_RULE="$3"

if [[ -z "$IMAGE_SOURCE" || -z "$OUTPUT_FILENAME" || -z "$RESIZE_RULE" ]]; then
    cat <<EOF
用法: $0 <镜像URL或本地文件路径> <输出文件名> <扩容规则>

扩容规则示例:
  0                         仅格式转换
  2G                        自动选择分区，扩容 2G
  +10%                      自动选择分区，增加 10%
  =10G                      自动选择分区，增至 10G
  /dev/sda2                 指定分区填满剩余空间
  /dev/sda2+2G              分区增加 2G
  /dev/sda2=10G             分区增至 10G
  /dev/sda2+10%             分区增加 10%
  /dev/vg/lv+2G             LVM 逻辑卷增加 2G
  /dev/sda1+100M,/dev/sda2  多分区调整（逗号分隔）
EOF
    exit 1
fi

# -------------------- 工具函数：文件格式 --------------------
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
        *) echo "" ;;
    esac
}

is_valid_image() {
    [[ -n "$(get_format_from_ext "$1")" ]]
}

# -------------------- 工具函数：单位转换 --------------------
parse_size_to_bytes() {
    local size_str="$1"
    size_str="${size_str^^}"
    if [[ "$size_str" =~ ^([0-9]+)(B|KB|MB|GB|K|M|G)?$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        case "$unit" in
            G|GB) echo $((num * 1073741824)) ;;
            M|MB) echo $((num * 1048576)) ;;
            K|KB) echo $((num * 1024)) ;;
            B|'') echo "$num" ;;
        esac
    else
        echo "0"
    fi
}

# 将大小字符串（可能是绝对值或百分比）转换为扩容字节数
# 参数: size_spec  例如 "2G", "+10%", "=5G"
#       current_bytes 当前分区大小（用于百分比计算）
# 返回: 需要增加的字节数（已对齐到64K）
calc_expand_bytes() {
    local spec="$1"
    local current_bytes="$2"

    # 去掉前导 +/=
    local clean_spec="${spec#[+=]}"

    if [[ "$clean_spec" =~ ^([0-9]+)%$ ]]; then
        local percent="${BASH_REMATCH[1]}"
        local expand=$(( current_bytes * percent / 100 ))
        echo $(( (expand + 65535) / 65536 * 65536 ))
    else
        local target_bytes
        target_bytes=$(parse_size_to_bytes "$clean_spec")
        if [[ "$target_bytes" -gt "$current_bytes" ]]; then
            local expand=$(( target_bytes - current_bytes ))
            echo $(( (expand + 65535) / 65536 * 65536 ))
        else
            echo "0"
        fi
    fi
}

# -------------------- 分区信息缓存模块 --------------------
# 使用全局关联数组存储分区/LV 信息，避免重复解析
declare -A PART_SIZE    # 分区/LV -> 字节大小
declare -A PART_VFS     # 分区/LV -> 文件系统类型
declare -A PART_TYPE    # 分区/LV -> 类型 (partition/lvm/...)
declare -A PART_LABEL   # 分区/LV -> 标签

load_partition_info() {
    local image="$1"
    local csv
    
    # 获取分区列表 (CSV格式)
    csv=$(virt-filesystems -a "$image" -l --csv 2>/dev/null) || {
        log_error "无法获取镜像分区信息"
    }

    # 解析 CSV
    # 列顺序: Name,Type,VFS,Label,MBR,Size,Parent
    # 示例: /dev/sda1,partition,ext4,cloudimg-rootfs,-,2147483648,-
    while IFS=',' read -r name type vfs label mbr size parent; do
        [[ -z "$name" || "$name" == "Name" ]] && continue
        PART_SIZE["$name"]="$size"
        PART_VFS["$name"]="$vfs"
        PART_TYPE["$name"]="$type"
        PART_LABEL["$name"]="$label"
    done <<< "$csv"

    # 获取 LVM 逻辑卷列表
    local lv_list
    lv_list=$(virt-filesystems -a "$image" --lvs 2>/dev/null) || true
    while read -r lv; do
        [[ -z "$lv" ]] && continue
        # 确保 LV 被标记为 lvm 类型，方便后续判断
        PART_TYPE["$lv"]="lvm"
        # 获取 LV 大小（通过 virt-filesystems -l 也会列出，但保险起见再次查询）
        local lv_size
        lv_size=$(virt-filesystems -a "$image" -l --csv 2>/dev/null | awk -F',' -v lv="$lv" '$1==lv {print $6}')
        PART_SIZE["$lv"]="${lv_size:-0}"
    done <<< "$lv_list"
}

# 判断是否为 LVM 逻辑卷
is_lv() {
    local name="$1"
    [[ "${PART_TYPE[$name]}" == "lvm" ]]
}

# 获取分区大小（字节）
get_partition_bytes() {
    local name="$1"
    echo "${PART_SIZE[$name]:-0}"
}

# -------------------- 自动分区选择策略 --------------------
# 每个策略函数输出分区名（成功时返回0），无输出且返回1表示不匹配

# 策略1: 根据标签白名单匹配
strategy_by_label_whitelist() {
    local whitelist="root rootfs cloudimg-rootfs system linux"
    for name in "${!PART_LABEL[@]}"; do
        local label="${PART_LABEL[$name],,}"
        for w in $whitelist; do
            [[ "$label" == "$w" ]] && echo "$name" && return 0
        done
    done
    return 1
}

# 策略2: 最大的非启动/EFI的ext4/xfs/btrfs分区
strategy_largest_data_partition() {
    local candidates=()
    local exclude_vfs="swap vfat efi unknown"
    local min_size=$((50 * 1024 * 1024))  # 50MB
    
    for name in "${!PART_TYPE[@]}"; do
        [[ "${PART_TYPE[$name]}" != "partition" ]] && continue
        
        local vfs="${PART_VFS[$name],,}"
        local label="${PART_LABEL[$name],,}"
        local size="${PART_SIZE[$name]}"
        
        # 排除条件
        [[ " $exclude_vfs " =~ " $vfs " ]] && continue
        [[ "$label" =~ boot|efi|esp ]] && continue
        [[ "$size" -lt "$min_size" ]] && continue
        
        candidates+=("$name:$size")
    done
    
    if [[ ${#candidates[@]} -gt 0 ]]; then
        # 按大小降序，返回第一个
        printf '%s\n' "${candidates[@]}" | sort -t':' -k2 -nr | head -n1 | cut -d':' -f1
        return 0
    fi
    return 1
}

# 策略3: 最大的非swap非vfat分区（放宽条件）
strategy_largest_non_swap() {
    local candidates=()
    local exclude_vfs="swap vfat"
    local min_size=$((50 * 1024 * 1024))
    
    for name in "${!PART_TYPE[@]}"; do
        [[ "${PART_TYPE[$name]}" != "partition" ]] && continue
        
        local vfs="${PART_VFS[$name],,}"
        local size="${PART_SIZE[$name]}"
        
        [[ " $exclude_vfs " =~ " $vfs " ]] && continue
        [[ "$size" -lt "$min_size" ]] && continue
        
        candidates+=("$name:$size")
    done
    
    if [[ ${#candidates[@]} -gt 0 ]]; then
        printf '%s\n' "${candidates[@]}" | sort -t':' -k2 -nr | head -n1 | cut -d':' -f1
        return 0
    fi
    return 1
}

# 自动选择扩容目标分区
select_auto_target() {
    local strategies=(
        strategy_by_label_whitelist
        strategy_largest_data_partition
        strategy_largest_non_swap
    )
    
    for strat in "${strategies[@]}"; do
        local target
        target=$($strat) && echo "$target" && return 0
    done
    
    log_error "无法自动确定要扩容的分区，请手动指定"
}

# -------------------- 规则解析模块 --------------------
# 规则对象存储格式: "target|operator|value_spec|bytes"
# operator: "+" (增加), "=" (设为), "fill" (填满剩余), "ignore" (忽略)
# value_spec: 原始规格字符串，如 "2G", "10%"
# bytes: 预计算的增加字节数（对于 fill 为0，后续计算）

parse_single_rule() {
    local raw="$1"
    raw=$(echo "$raw" | xargs)  # 去除首尾空格

    local target operator value_spec bytes

    # 使用模式匹配统一处理
    case "$raw" in
        0)
            # 特殊规则：仅格式转换
            echo "none|convert|0|0"
            return
            ;;
        /dev/*+*)
            target="${raw%%+*}"
            value_spec="${raw#*+}"
            operator="+"
            ;;
        /dev/*=*)
            target="${raw%%=*}"
            value_spec="${raw#*=}"
            operator="="
            ;;
        /dev/*)
            target="$raw"
            operator="fill"
            value_spec=""
            ;;
        +*)
            value_spec="${raw#+}"
            operator="+"
            target="auto"
            ;;
        =*)
            value_spec="${raw#=}"
            operator="="
            target="auto"
            ;;
        *)
            # 纯数字+单位，自动选择分区扩容
            value_spec="$raw"
            operator="+"
            target="auto"
            ;;
    esac

    # 输出初始规则（bytes 稍后计算）
    echo "$target|$operator|$value_spec|0"
}

# 补全规则：将 "auto" 目标替换为实际分区，并计算扩容字节数
resolve_rule() {
    local rule="$1"
    IFS='|' read -r target op val_spec _ <<< "$rule"

    # 特殊规则：仅转换
    if [[ "$target" == "none" && "$op" == "convert" ]]; then
        echo "$rule"
        return
    fi

    # 自动选择目标
    if [[ "$target" == "auto" ]]; then
        target=$(select_auto_target)
        log_info "自动选择扩容目标: $target"
    fi

    # 检查目标是否存在
    if [[ -z "${PART_SIZE[$target]}" ]]; then
        log_error "目标 '$target' 在镜像中不存在"
    fi

    local current_bytes="${PART_SIZE[$target]}"
    local expand_bytes

    case "$op" in
        fill)
            # fill 不在此计算，由后续的 --expand 参数处理
            expand_bytes=0
            ;;
        +|*)
            expand_bytes=$(calc_expand_bytes "$val_spec" "$current_bytes")
            if [[ "$expand_bytes" -eq 0 ]]; then
                log_warn "扩容大小为0，目标分区将保持不变"
            fi
            ;;
    esac

    echo "$target|$op|$val_spec|$expand_bytes"
}

# -------------------- 主处理流程 --------------------
main() {
    # ---------- 1. 获取原始镜像 ----------
    if [[ "$IMAGE_SOURCE" =~ ^https?:// ]]; then
        log_info "下载镜像: $IMAGE_SOURCE"
        ORIGINAL_NAME=$(basename "$IMAGE_SOURCE")
        wget -q --show-progress --tries=3 --timeout=30 -O "$ORIGINAL_NAME" "$IMAGE_SOURCE"
        TEMP_FILES+=("$ORIGINAL_NAME")
    else
        if [[ ! -f "$IMAGE_SOURCE" ]]; then
            log_error "本地文件不存在: $IMAGE_SOURCE"
        fi
        log_info "使用本地文件: $IMAGE_SOURCE"
        ORIGINAL_NAME=$(basename "$IMAGE_SOURCE")
        if [[ "$IMAGE_SOURCE" != "$ORIGINAL_NAME" ]]; then
            cp "$IMAGE_SOURCE" "$ORIGINAL_NAME"
            TEMP_FILES+=("$ORIGINAL_NAME")
        fi
    fi

    # ---------- 2. 解压处理 ----------
    EXTRACTED_FILE=""
    case "$ORIGINAL_NAME" in
        *.gz)
            log_info "解压 gzip..."
            EXTRACTED_FILE="${ORIGINAL_NAME%.gz}"
            gunzip -c "$ORIGINAL_NAME" 2>/dev/null | dd of="$EXTRACTED_FILE" conv=sparse status=none
            rm -f "$ORIGINAL_NAME"
            ;;
        *.xz)
            log_info "解压 xz..."
            EXTRACTED_FILE="${ORIGINAL_NAME%.xz}"
            xz -dc "$ORIGINAL_NAME" 2>/dev/null | dd of="$EXTRACTED_FILE" conv=sparse status=none
            rm -f "$ORIGINAL_NAME"
            ;;
        *.bz2)
            log_info "解压 bzip2..."
            EXTRACTED_FILE="${ORIGINAL_NAME%.bz2}"
            bzip2 -dc "$ORIGINAL_NAME" 2>/dev/null | dd of="$EXTRACTED_FILE" conv=sparse status=none
            rm -f "$ORIGINAL_NAME"
            ;;
        *.zip)
            log_info "解压 zip..."
            mkdir -p extracted
            unzip -q -o "$ORIGINAL_NAME" -d extracted
            EXTRACTED_FILE=$(find extracted -type f | while read -r f; do
                if is_valid_image "$f"; then
                    echo "$f"
                    break
                fi
            done)
            rm -f "$ORIGINAL_NAME"
            ;;
        *)
            EXTRACTED_FILE="$ORIGINAL_NAME"
            ;;
    esac

    [[ -z "$EXTRACTED_FILE" ]] && log_error "解压失败或未找到镜像文件"
    ORIGINAL_NAME="$EXTRACTED_FILE"
    TEMP_FILES+=("$ORIGINAL_NAME")
    log_info "镜像文件: $ORIGINAL_NAME"

    # ---------- 3. 验证镜像 ----------
    if ! qemu-img info "$ORIGINAL_NAME" &>/dev/null; then
        log_error "文件损坏或格式不支持"
    fi
    log_info "镜像验证通过"

    # ---------- 4. 格式检测 ----------
    FORMAT=$(qemu-img info "$ORIGINAL_NAME" 2>/dev/null | awk '/file format:/ {print $3}')
    FORMAT="${FORMAT:-raw}"
    OUTPUT_FORMAT=$(get_format_from_ext "$OUTPUT_FILENAME")
    OUTPUT_FORMAT="${OUTPUT_FORMAT:-raw}"
    log_info "输入格式: $FORMAT，输出格式: $OUTPUT_FORMAT"

    # ---------- 5. 规则为0时的快速路径 ----------
    if [[ "$RESIZE_RULE" == "0" ]]; then
        log_info "规则为0，仅执行格式转换"
        qemu-img convert -O "$OUTPUT_FORMAT" "$ORIGINAL_NAME" "$OUTPUT_FILENAME"
        log_info "格式转换完成: $OUTPUT_FILENAME"
        compress_output
        return
    fi

    # ---------- 6. 加载分区信息 ----------
    log_info "分析镜像分区布局..."
    load_partition_info "$ORIGINAL_NAME"

    # 显示分区信息表格（便于用户确认）
    virt-filesystems -a "$ORIGINAL_NAME" -l

    # 原始镜像大小
    ORIGINAL_SIZE=$(qemu-img info "$ORIGINAL_NAME" 2>/dev/null | grep "virtual size" | sed -E 's/.*\(([0-9]+) bytes\).*/\1/')
    [[ -z "$ORIGINAL_SIZE" ]] && ORIGINAL_SIZE=$(stat -c %s "$ORIGINAL_NAME" 2>/dev/null || stat -f %z "$ORIGINAL_NAME")
    log_info "原始镜像虚拟大小: $ORIGINAL_SIZE 字节"

    # ---------- 7. 解析并补全规则 ----------
    IFS=',' read -ra RAW_RULES <<< "$RESIZE_RULE"
    declare -a RESOLVED_RULES
    TOTAL_EXPAND=0
    FILL_TARGET=""
    LV_EXPAND_TARGET=""

    for raw in "${RAW_RULES[@]}"; do
        rule=$(parse_single_rule "$raw")
        rule=$(resolve_rule "$rule")
        IFS='|' read -r target op val_spec bytes <<< "$rule"
        
        RESOLVED_RULES+=("$rule")
        
        case "$op" in
            fill)
                FILL_TARGET="$target"
                ;;
            +|=)
                TOTAL_EXPAND=$((TOTAL_EXPAND + bytes))
                ;;
        esac

        # 记录 LV 扩容请求
        if is_lv "$target"; then
            LV_EXPAND_TARGET="$target"
        fi
    done

    # ---------- 8. 计算总大小 ----------
    TOTAL_SIZE=$((ORIGINAL_SIZE + TOTAL_EXPAND))
    if [[ "$TOTAL_SIZE" -le "$ORIGINAL_SIZE" ]]; then
        log_error "扩容大小无效，总大小未增加"
    fi
    log_info "新镜像大小: $TOTAL_SIZE 字节 (增加 $TOTAL_EXPAND 字节)"

    # ---------- 9. 创建新镜像 ----------
    RESIZED_NAME="stage2_${RANDOM_SUFFIX}.${OUTPUT_FORMAT}"
    TEMP_FILES+=("$RESIZED_NAME")
    qemu-img create -f "$OUTPUT_FORMAT" "$RESIZED_NAME" "$TOTAL_SIZE"

    # ---------- 10. 构建 virt-resize 参数 ----------
    resize_args=()
    
    # 处理 fill 目标
    if [[ -n "$FILL_TARGET" ]]; then
        resize_args+=( --expand "$FILL_TARGET" )
    fi

    # 处理其他调整规则
    for rule in "${RESOLVED_RULES[@]}"; do
        IFS='|' read -r target op val_spec bytes <<< "$rule"
        case "$op" in
            +)
                resize_args+=( --resize "$target=+$val_spec" )
                ;;
            =)
                resize_args+=( --resize "$target=$val_spec" )
                ;;
        esac
    done

    # 忽略 swap 分区（加速）
    local swap_list=()
    for name in "${!PART_VFS[@]}"; do
        [[ "${PART_VFS[$name],,}" == "swap" ]] && swap_list+=("$name")
    done
    if [[ ${#swap_list[@]} -gt 0 ]]; then
        log_info "忽略 swap 分区: ${swap_list[*]}"
        for sw in "${swap_list[@]}"; do
            resize_args+=( --ignore "$sw" )
        done
    fi

    # LVM 扩容支持
    if [[ -n "$LV_EXPAND_TARGET" ]]; then
        resize_args+=( --LV-expand "$LV_EXPAND_TARGET" )
        log_info "将扩容 LVM 逻辑卷: $LV_EXPAND_TARGET"
    elif virt-filesystems -a "$ORIGINAL_NAME" --lvs 2>/dev/null | grep -q .; then
        log_warn "检测到 LVM 但未指定 LV 扩容规则，仅扩容 PV"
    fi

    # ---------- 11. 执行扩容 ----------
    log_info "执行: virt-resize ${resize_args[*]} $ORIGINAL_NAME $RESIZED_NAME"
    virt-resize "${resize_args[@]}" "$ORIGINAL_NAME" "$RESIZED_NAME"

    mv "$RESIZED_NAME" "$OUTPUT_FILENAME"
    log_info "扩容完成，输出文件: $OUTPUT_FILENAME"
}

# -------------------- 入口 --------------------
main "$@"
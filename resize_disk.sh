#!/bin/bash
# =============================================================================
# Disk Expansion Tool - 磁盘镜像扩容工具
# =============================================================================
# 功能：支持从 URL 或本地路径获取镜像，自动/手动选择分区进行扩容
# 特性：
#   - 流式处理，峰值磁盘占用低
#   - 支持多种压缩格式（gz/xz/bz2/zst/zip）
#   - 支持多种磁盘格式（qcow2/raw/vmdk/vdi 等）
#   - 智能识别 root 分区和 LVM 结构
#   - 支持自动选择分区或手动指定
# =============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# 常量定义
# ---------------------------------------------------------------------------
readonly ALIGNMENT=$((64 * 1024))                # 64K 对齐
readonly MIN_ROOT_SIZE=$((100 * 1024 * 1024))    # 100MB
readonly MIN_FALLBACK_SIZE=$((50 * 1024 * 1024)) # 50MB

# ---------------------------------------------------------------------------
# 全局状态
# ---------------------------------------------------------------------------
declare -a CLEANUP_ITEMS=()
declare -i BUILD_SUCCESS=0

# ---------------------------------------------------------------------------
# 退出清理
# ---------------------------------------------------------------------------
cleanup() {
    local item
    if [[ ${BUILD_SUCCESS} -eq 0 ]]; then
        log_warn "构建中断，执行清理..."
    fi
    for item in "${CLEANUP_ITEMS[@]}"; do
        [[ -n "${item}" ]] || continue
        if [[ -d "${item}" ]]; then
            rm -rf "${item}" 2>/dev/null || true
        elif [[ -e "${item}" ]]; then
            rm -f "${item}" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# 日志输出
# ---------------------------------------------------------------------------
log_info()  { echo "[INFO]  $*" >&2; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_phase() { echo "" >&2; echo "========================================" >&2; echo "  $*" >&2; echo "========================================" >&2; }
log_step()  { echo "  → $*" >&2; }

# ---------------------------------------------------------------------------
# 重试机制
# ---------------------------------------------------------------------------
retry() {
    local max="${1}" delay="${2}"
    shift 2
    local i
    for i in $(seq 1 "${max}"); do
        if "$@"; then return 0; fi
        [[ ${i} -eq ${max} ]] && { log_error "重试 ${max} 次后仍失败: $*"; return 1; }
        log_warn "第 ${i}/${max} 次重试，${delay} 秒后..."
        sleep "${delay}"
    done
}

# ---------------------------------------------------------------------------
# 使用说明
# ---------------------------------------------------------------------------
show_help() {
    cat << EOF
Disk Expansion Tool - 虚拟磁盘镜像扩容工具

用法: ${SCRIPT_NAME} <镜像来源> <输出文件> <扩容规则>

参数:
  镜像来源    URL (http/https) 或本地文件路径
  输出文件    输出镜像文件名（扩展名决定格式）
  扩容规则    分区扩容规则

扩容规则:
  0                         仅格式转换，不扩容
  2G                        自动选择分区，扩容 2G
  +10%                      自动选择分区，增加 10%
  =10G                      自动选择分区，增至 10G
  /dev/sda2                 指定分区填满剩余空间
  /dev/sda2+2G              指定分区增加 2G
  /dev/sda2=10G             指定分区增至 10G
  /dev/sda2+10%             指定分区增加 10%
  /dev/vg/lv_root+2G        LVM 逻辑卷增加 2G
  /dev/sda1+100M,/dev/sda2  多分区调整（逗号分隔）

支持的输入压缩格式:
  .gz .xz .bz2 .zst .zip

支持的输入/输出磁盘格式:
  qcow2, raw, vmdk, vdi, vhd, vhdx, qed, luks

示例:
  ${SCRIPT_NAME} https://example.com/image.img.gz output.qcow2 5G
  ${SCRIPT_NAME} ./image.raw output.qcow2 /dev/sda2+10G
  ${SCRIPT_NAME} ./image.qcow2 output.raw 0
EOF
}

# ---------------------------------------------------------------------------
# 参数解析与验证
# ---------------------------------------------------------------------------
parse_args() {
    if [[ $# -lt 3 ]]; then
        show_help
        exit 1
    fi

    readonly IMAGE_SOURCE="${1}"
    readonly OUTPUT_FILENAME="${2}"
    readonly RESIZE_RULE="${3}"

    if [[ -z "${IMAGE_SOURCE}" || -z "${OUTPUT_FILENAME}" || -z "${RESIZE_RULE}" ]]; then
        log_error "参数不能为空"
        show_help
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 格式识别
# ---------------------------------------------------------------------------
get_format_from_ext() {
    local filename="${1}"
    local ext="${filename##*.}"
    ext="${ext,,}"
    case "${ext}" in
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

is_valid_image_ext() {
    local filename="${1}"
    [[ -n "$(get_format_from_ext "${filename}")" ]]
}

# ---------------------------------------------------------------------------
# 大小解析
# ---------------------------------------------------------------------------
parse_size_to_bytes() {
    local size_str="${1}"

    # 百分比：原样返回，调用方特殊处理
    if [[ "${size_str}" =~ ^([0-9]+)%$ ]]; then
        echo "${size_str}"
        return
    fi

    # 纯数字（字节）
    if [[ "${size_str}" =~ ^[0-9]+$ ]]; then
        echo "${size_str}"
        return
    fi

    # 使用 numfmt 解析带单位的大小（IEC: K/M/G/T = 1024 进制）
    # numfmt 要求单位大写，先转换
    local upper_str
    upper_str=$(echo "${size_str}" | tr '[:lower:]' '[:upper:]')
    local result
    result=$(numfmt --from=iec "${upper_str}" 2>/dev/null)
    if [[ -n "${result}" ]]; then
        echo "${result}"
        return
    fi

    # 解析失败
    echo "0"
}

# ---------------------------------------------------------------------------
# 获取镜像虚拟大小（字节）
# ---------------------------------------------------------------------------
get_image_virtual_size() {
    local image="${1}"
    local size
    size=$(qemu-img info --output=json "${image}" 2>/dev/null | \
           sed -n 's/.*"virtual-size": \([0-9]*\).*/\1/p')
    if [[ -z "${size}" ]]; then
        size=$(qemu-img info "${image}" 2>/dev/null | \
               sed -n 's/.*virtual size: .*(\([0-9]*\) bytes).*/\1/p')
    fi
    echo "${size:-0}"
}

# ---------------------------------------------------------------------------
# 获取镜像格式
# ---------------------------------------------------------------------------
get_image_format() {
    local image="${1}"
    local fmt
    fmt=$(qemu-img info "${image}" 2>/dev/null | awk '/file format:/ {print $3}')
    echo "${fmt:-raw}"
}

# ---------------------------------------------------------------------------
# 流式获取输入镜像
# ---------------------------------------------------------------------------
fetch_input_image() {
    local source="${1}"
    local tmp_raw="${2}"
    local extract_dir="extracted_$$"

    if [[ "${source}" =~ ^https?:// ]]; then
        _fetch_remote "${source}" "${tmp_raw}" "${extract_dir}"
    else
        _fetch_local "${source}" "${tmp_raw}" "${extract_dir}"
    fi
}

_fetch_remote() {
    local url="${1}"
    local tmp_raw="${2}"
    local extract_dir="${3}"

    log_step "从远程获取: ${url}"

    case "${url}" in
        *.zip)
            local zip_tmp="tmp_$$.zip"
            CLEANUP_ITEMS+=("${zip_tmp}" "${extract_dir}")
            retry 3 5 curl -sL "${url}" -o "${zip_tmp}"
            unzip -o "${zip_tmp}" -d "${extract_dir}"
            rm -f "${zip_tmp}"
            _find_image_in_dir "${extract_dir}" "${tmp_raw}"
            ;;
        *)
            curl -sL --retry 3 --retry-delay 5 "${url}" | _decompress_stream "${url}" "" > "${tmp_raw}"
            ;;
    esac
}

_fetch_local() {
    local path="${1}"
    local tmp_raw="${2}"
    local extract_dir="${3}"

    if [[ ! -e "${path}" ]]; then
        log_error "本地文件不存在: ${path}"
        exit 1
    fi

    log_step "使用本地文件: ${path}"

    case "${path}" in
        *.zip)
            CLEANUP_ITEMS+=("${extract_dir}")
            unzip -o "${path}" -d "${extract_dir}"
            _find_image_in_dir "${extract_dir}" "${tmp_raw}"
            ;;
        *.gz|*.xz|*.bz2|*.zst)
            _decompress_stream "${path}" "${path}" > "${tmp_raw}"
            ;;
        *)
            # 未压缩文件：CoW 复制（不占用额外空间），失败则普通复制
            # 注意：不使用硬链接，避免 fallocate --dig-holes 破坏原文件
            if cp --reflink=auto "${path}" "${tmp_raw}" 2>/dev/null; then
                : # CoW 复制成功（Btrfs/ZFS 等）
            else
                cp "${path}" "${tmp_raw}"
            fi
            ;;
    esac
}

_decompress_stream() {
    local source="${1}"
    local input="${2:-}"
    case "${source}" in
        *.gz)  gunzip -c ${input:+"$input"} 2>/dev/null || true ;;
        *.xz)  xz -dc ${input:+"$input"} ;;
        *.bz2) bzip2 -dc ${input:+"$input"} ;;
        *.zst) zstd -dc ${input:+"$input"} ;;
        *)     cat ${input:+"$input"} ;;
    esac
}

_find_image_in_dir() {
    local dir="${1}"
    local out="${2}"
    local found
    found=$(find "${dir}" -maxdepth 2 -type f \( \
        -name "*.raw" -o -name "*.img" -o -name "*.qcow2" -o \
        -name "*.vmdk" -o -name "*.vdi" \) | head -1)
    if [[ -z "${found}" ]]; then
        log_error "在解压目录中未找到镜像文件"
        exit 1
    fi
    local count
    count=$(find "${dir}" -maxdepth 2 -type f \( \
        -name "*.raw" -o -name "*.img" -o -name "*.qcow2" -o \
        -name "*.vmdk" -o -name "*.vdi" \) | wc -l)
    if [[ ${count} -gt 1 ]]; then
        log_warn "找到 ${count} 个镜像文件，使用第一个: $(basename "${found}")"
    fi
    if ! mv -f "${found}" "${out}" 2>/dev/null; then
        cp "${found}" "${out}" || { log_error "复制镜像文件失败"; exit 1; }
        rm -f "${found}"
    fi
}

# ---------------------------------------------------------------------------
# 稀疏化 raw 文件（修复 dd conv=sparse 截断问题）
# ---------------------------------------------------------------------------
sparsify_raw() {
    local file="${1}"
    if command -v fallocate &>/dev/null; then
        fallocate --dig-holes "${file}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# 分区信息分析
# ---------------------------------------------------------------------------
analyze_partitions() {
    local image="${1}"
    log_step "分析镜像分区..."
    virt-filesystems -a "${image}" -l || true
}

# ---------------------------------------------------------------------------
# 检测 LVM
# ---------------------------------------------------------------------------
detect_lvm() {
    local image="${1}"
    local lv_list
    lv_list=$(virt-filesystems -a "${image}" --lvs 2>/dev/null)
    if [[ -n "${lv_list}" ]]; then
        echo "true"
        echo "${lv_list}"
    else
        echo "false"
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# 获取分区大小
# ---------------------------------------------------------------------------
get_partition_size_bytes() {
    local fs_info="${1}"
    local name_col="${2}"
    local size_col="${3}"
    local partition="${4}"
    echo "${fs_info}" | awk -v nc="${name_col}" -v sc="${size_col}" -v part="${partition}" '
        NR>1 && $nc == part {print $sc; exit}
    '
}

# ---------------------------------------------------------------------------
# 计算扩容字节数（64K 对齐）
# ---------------------------------------------------------------------------
calc_expand_bytes() {
    local size_spec="${1}"
    local current_bytes="${2}"
    local expand_bytes=0

    if [[ "${size_spec}" =~ ^([0-9]+)%$ ]]; then
        local percent="${BASH_REMATCH[1]}"
        expand_bytes=$(( current_bytes * percent / 100 ))
    else
        local target_bytes
        target_bytes=$(parse_size_to_bytes "${size_spec}")
        # 确保 target_bytes 是纯数字（百分比已被上面处理）
        if [[ "${target_bytes}" =~ ^[0-9]+$ ]]; then
            if [[ ${target_bytes} -gt ${current_bytes} ]]; then
                expand_bytes=$(( target_bytes - current_bytes ))
            fi
        fi
    fi

    # 64K 对齐
    echo $(( (expand_bytes + ALIGNMENT - 1) / ALIGNMENT * ALIGNMENT ))
}

# ---------------------------------------------------------------------------
# 判断是否为 LVM 逻辑卷
# ---------------------------------------------------------------------------
is_lv() {
    local name="${1}"
    local lv_list="${2}"
    [[ -n "${lv_list}" ]] && echo "${lv_list}" | awk '{print $1}' | grep -Fxq "${name}"
}

# ---------------------------------------------------------------------------
# 自动选择扩容分区
# ---------------------------------------------------------------------------
find_expand_partition() {
    local image="${1}" dev

    # LVM
    dev=$(virt-filesystems -a "${image}" --lvs 2>/dev/null | tail -n1)
    [[ -n "${dev}" ]] && { echo "${dev}"; return 0; }

    # Label
    dev=$(virt-filesystems -a "${image}" -l 2>/dev/null | awk '
        NR==1 {for(i=1;i<=NF;i++) {if($i=="Name") n=i; if($i=="Label") l=i}}
        NR>1 && l {
            lbl = tolower($l)
            gsub(/^["\047[:space:]]+|["\047[:space:]]+$/, "", lbl)
            if (lbl ~ /^(cloudimg-rootfs|rootfs|root|img-rootfs)$/) {
                print $n
                exit
            }
        }
    ')

    [[ -n "${dev}" ]] && { echo "${dev}"; return 0; }
    return 1
}

# ---------------------------------------------------------------------------
# 解析扩容规则
# ---------------------------------------------------------------------------
parse_resize_rules() {
    local rule_str="${1}"
    local image="${2}"
    local fs_info
    local header
    local -i col_name col_size

    fs_info=$(virt-filesystems -a "${image}" -l 2>/dev/null)
    header=$(echo "${fs_info}" | head -n1)
    col_name=$(echo "${header}" | awk '{for(i=1;i<=NF;i++) if($i=="Name") print i}')
    col_size=$(echo "${header}" | awk '{for(i=1;i<=NF;i++) if($i=="Size") print i}')

    local lv_list=""
    local has_lvm="false"
    local lvm_info
    lvm_info=$(detect_lvm "${image}")
    has_lvm=$(echo "${lvm_info}" | head -n1)
    lv_list=$(echo "${lvm_info}" | tail -n +2)

    local resize_opts=""
    local expand_partition=""
    local lv_expand=""
    local -i expand_size_bytes=0

    local -a rules
    IFS=',' read -ra rules <<< "${rule_str}"
    local -i rule_count=${#rules[@]}
    local -i i

    for i in "${!rules[@]}"; do
        local rule="${rules[$i]}"
        rule=$(echo "${rule}" | xargs)
        [[ -n "${rule}" ]] || continue

        if [[ "${rule}" =~ ^/dev/ ]]; then
            # 设备路径规则
            if [[ "${rule}" =~ ^(/dev/[^+=%]+)([+=])(.+)$ ]]; then
                local partition="${BASH_REMATCH[1]}"
                local operator="${BASH_REMATCH[2]}"
                local size_spec="${BASH_REMATCH[3]}"

                if is_lv "${partition}" "${lv_list}"; then
                    [[ -n "${expand_partition}" ]] || expand_partition=$(find_expand_partition "${image}")
                    lv_expand="${partition}"
                    local current_bytes
                    current_bytes=$(get_partition_size_bytes "${fs_info}" "${col_name}" "${col_size}" "${partition}")
                    local size_bytes
                    size_bytes=$(calc_expand_bytes "${size_spec}" "${current_bytes}")
                    expand_size_bytes=$((expand_size_bytes + size_bytes))
                    log_step "规则: LV ${partition} ${operator} ${size_spec} (+${size_bytes} 字节)"
                else
                    if [[ "${operator}" == "+" ]]; then
                        resize_opts="${resize_opts} --resize ${partition}=+${size_spec}"
                    else
                        resize_opts="${resize_opts} --resize ${partition}=${size_spec}"
                    fi
                    local current_bytes
                    current_bytes=$(get_partition_size_bytes "${fs_info}" "${col_name}" "${col_size}" "${partition}")
                    local size_bytes
                    size_bytes=$(calc_expand_bytes "${size_spec}" "${current_bytes}")
                    expand_size_bytes=$((expand_size_bytes + size_bytes))
                    log_step "规则: 分区 ${partition} ${operator} ${size_spec} (+${size_bytes} 字节)"
                fi
            else
                # 纯设备路径，无操作符
                local partition="${rule}"
                if is_lv "${partition}" "${lv_list}"; then
                    [[ -n "${expand_partition}" ]] || expand_partition=$(find_expand_partition "${image}")
                    lv_expand="${partition}"
                    log_step "规则: LV ${partition} 填满剩余空间"
                else
                    if [[ $((i + 1)) -eq ${rule_count} ]]; then
                        expand_partition="${partition}"
                        log_step "规则: 分区 ${partition} 填满剩余空间"
                    else
                        resize_opts="${resize_opts} --resize ${partition}=+0"
                        log_step "规则: 分区 ${partition} 保持大小"
                    fi
                fi
            fi
        else
            # 非设备路径规则（自动选择）
            if [[ "${rule}" =~ ^[0-9]+[KMGTkmgt]?$ ]]; then
                local size_bytes
                size_bytes=$(parse_size_to_bytes "${rule}")
                if [[ ${size_bytes} -gt 0 ]]; then
                    expand_partition=$(find_expand_partition "${image}")
                    if [[ -n "${expand_partition}" ]]; then
                        log_step "规则: 自动选择分区 ${expand_partition}，扩容 ${rule}"
                        expand_size_bytes=$((expand_size_bytes + size_bytes))
                    fi
                fi
            elif [[ "${rule}" =~ ^([+=])(.+)$ ]]; then
                local operator="${BASH_REMATCH[1]}"
                local size_spec="${BASH_REMATCH[2]}"
                expand_partition=$(find_expand_partition "${image}")
                if [[ -n "${expand_partition}" ]]; then
                    local current_bytes
                    current_bytes=$(get_partition_size_bytes "${fs_info}" "${col_name}" "${col_size}" "${expand_partition}")
                    local size_bytes
                    size_bytes=$(calc_expand_bytes "${size_spec}" "${current_bytes}")
                    if [[ "${operator}" == "+" ]]; then
                        resize_opts="${resize_opts} --resize ${expand_partition}=+${size_spec}"
                        log_step "规则: 自动选择分区 ${expand_partition}，增加 ${size_spec}"
                    else
                        resize_opts="${resize_opts} --resize ${expand_partition}=${size_spec}"
                        log_step "规则: 自动选择分区 ${expand_partition}，增至 ${size_spec}"
                    fi
                    expand_size_bytes=$((expand_size_bytes + size_bytes))
                fi
            else
                log_error "无法解析规则 '${rule}'"
                return 1
            fi
        fi
    done

    # 验证
    if [[ -z "${expand_partition}" ]]; then
        log_error "无法确定要扩容的分区"
        return 1
    fi
    if [[ ${expand_size_bytes} -eq 0 ]]; then
        log_error "没有指定有效的扩容大小"
        return 1
    fi

    # 输出结果
    echo "${expand_partition}"
    echo "${expand_size_bytes}"
    echo "${resize_opts}"
    echo "${lv_expand}"
    echo "${has_lvm}"
}

# ---------------------------------------------------------------------------
# 获取 swap 分区列表（用于 --ignore）
# ---------------------------------------------------------------------------
get_swap_partitions() {
    local image="${1}"
    local expand_part="${2}"
    local fs_info header col_name col_vfs

    fs_info=$(virt-filesystems -a "${image}" -l 2>/dev/null)
    header=$(echo "${fs_info}" | head -n1)
    col_name=$(echo "${header}" | awk '{for(i=1;i<=NF;i++) if($i=="Name") print i}')
    col_vfs=$(echo "${header}" | awk '{for(i=1;i<=NF;i++) if($i=="VFS") print i}')

    echo "${fs_info}" | awk -v nc="${col_name}" -v vc="${col_vfs}" -v ep="${expand_part}" '
        NR>1 && $vc == "swap" && $nc != ep {print $nc}
    '
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    export LIBGUESTFS_BACKEND="direct"

    local output_format
    output_format=$(get_format_from_ext "${OUTPUT_FILENAME}")
    [[ -n "${output_format}" ]] || output_format="raw"

    log_phase "Disk Expansion Tool"
    log_info "镜像来源: ${IMAGE_SOURCE}"
    log_info "输出文件: ${OUTPUT_FILENAME}"
    log_info "输出格式: ${output_format}"
    log_info "扩容规则: ${RESIZE_RULE}"

    # ========== 仅格式转换分支 ==========
    if [[ "${RESIZE_RULE}" == "0" ]]; then
        log_phase "仅格式转换"
        local tmp_raw="tmp_$$.raw"
        CLEANUP_ITEMS+=("${tmp_raw}")
        fetch_input_image "${IMAGE_SOURCE}" "${tmp_raw}"
        log_step "转换格式..."
        qemu-img convert -O "${output_format}" "${tmp_raw}" "${OUTPUT_FILENAME}"
        BUILD_SUCCESS=1
        log_info "格式转换完成: ${OUTPUT_FILENAME}"
        exit 0
    fi

    # ========== 正常扩容流程 ==========
    log_phase "获取输入镜像"
    local tmp_raw="tmp_$$.raw"
    CLEANUP_ITEMS+=("${tmp_raw}")
    fetch_input_image "${IMAGE_SOURCE}" "${tmp_raw}"

    log_step "验证镜像..."
    if ! qemu-img info "${tmp_raw}" &>/dev/null; then
        log_error "文件损坏或格式不支持"
        exit 1
    fi

    local input_format
    input_format=$(get_image_format "${tmp_raw}")
    log_info "输入格式: ${input_format}"

    # 获取真实大小
    local real_size
    if [[ "${input_format}" == "raw" ]]; then
        sparsify_raw "${tmp_raw}"
        real_size=$(stat -c %s "${tmp_raw}")
    else
        real_size=$(get_image_virtual_size "${tmp_raw}")
    fi
    log_info "镜像大小: ${real_size} 字节 ($((real_size / 1024 / 1024 / 1024)) GB)"

    # 分析分区
    analyze_partitions "${tmp_raw}"

    # 解析扩容规则
    log_phase "解析扩容规则"
    local parsed
    if ! parsed=$(parse_resize_rules "${RESIZE_RULE}" "${tmp_raw}"); then
        log_error "扩容规则解析失败"
        exit 1
    fi
    local expand_partition="$(echo "${parsed}" | sed -n '1p')"
    local expand_size_bytes="$(echo "${parsed}" | sed -n '2p')"
    local resize_opts="$(echo "${parsed}" | sed -n '3p')"
    local lv_expand="$(echo "${parsed}" | sed -n '4p')"
    local has_lvm="$(echo "${parsed}" | sed -n '5p')"

    log_info "扩容分区: ${expand_partition}"
    log_info "扩容大小: ${expand_size_bytes} 字节"

    # 计算总大小
    local -i total_size=$((real_size + expand_size_bytes))
    log_info "输出总大小: ${total_size} 字节"

    # 创建输出镜像
    log_phase "创建输出镜像"
    if [[ "${output_format}" == "qcow2" ]]; then
        qemu-img create -f qcow2 -o preallocation=metadata "${OUTPUT_FILENAME}" "${total_size}" 2>/dev/null || \
        qemu-img create -f qcow2 "${OUTPUT_FILENAME}" "${total_size}"
    else
        qemu-img create -f "${output_format}" "${OUTPUT_FILENAME}" "${total_size}"
    fi

    # 组装 virt-resize 命令
    log_phase "执行扩容"
    local resize_cmd="virt-resize --expand ${expand_partition}"
    [[ -n "${resize_opts}" ]] && resize_cmd="${resize_cmd} ${resize_opts}"

    # 忽略 swap 分区
    local swap_parts
    swap_parts=$(get_swap_partitions "${tmp_raw}" "${expand_partition}")
    if [[ -n "${swap_parts}" ]]; then
        log_step "忽略 swap 分区以加速复制:"
        local sp
        for sp in ${swap_parts}; do
            resize_cmd="${resize_cmd} --ignore ${sp}"
            log_step "  - ${sp}"
        done
    fi

    # LVM 逻辑卷扩容
    if [[ -n "${lv_expand}" ]]; then
        resize_cmd="${resize_cmd} --LV-expand ${lv_expand}"
        log_step "扩容 LVM 逻辑卷: ${lv_expand}"
    elif [[ "${has_lvm}" == "true" ]]; then
        log_warn "检测到 LVM 但未指定 LV，仅扩容 PV"
        log_warn "如需扩容 LV，请在规则中指定 LV 名称"
    fi

    log_step "执行: ${resize_cmd}"
    ${resize_cmd} "${tmp_raw}" "${OUTPUT_FILENAME}"

    BUILD_SUCCESS=1
    log_phase "完成"
    log_info "输出文件: ${OUTPUT_FILENAME}"
    log_info "文件大小: $(du -h "${OUTPUT_FILENAME}" | awk '{print $1}')"
}

main "$@"
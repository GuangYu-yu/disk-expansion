#!/bin/bash
# =============================================================================
# Disk Expansion Tool - 磁盘镜像扩容工具
# =============================================================================
# 功能：支持从 URL 或本地路径获取镜像，自动/手动选择分区进行扩容
# 特性：
#   - 支持多种压缩格式（gz/xz/bz2/zst/zip）
#   - 支持多种磁盘格式（qcow2/raw/vmdk/vdi 等）
#   - 智能识别 root 分区和 LVM 结构
#   - 支持自动选择分区或手动指定
# =============================================================================

set -euo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# 常量定义
# ---------------------------------------------------------------------------
readonly ALIGNMENT=$((64 * 1024))                # 64K 对齐

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
  /dev/sda2+2G              指定分区扩容 2G
  /dev/sda2=10G             指定分区增至 10G
  /dev/sda2+10%             指定分区增加 10%
  /dev/vg/lv_root+2G        LVM 逻辑卷扩容 2G
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

# ---------------------------------------------------------------------------
# 字节大小格式化
# ---------------------------------------------------------------------------
format_bytes() {
    local bytes="${1}"
    awk "BEGIN{u=1024*1024; s=\"MB\"; if(${bytes}>=1024*1024*1024){u=1024*1024*1024; s=\"GB\"}; printf \"%.2f %s\", ${bytes}/u, s}"
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
    size=$(qemu-img info "${image}" 2>/dev/null | \
           sed -n '/virtual size:/s/.*(\([0-9]*\) bytes).*/\1/p')
    echo "${size:-0}"
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
            curl -sLf --retry 3 --retry-delay 5 "${url}" | _decompress_stream "${url}" "" > "${tmp_raw}"
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
            cp --reflink=auto "${path}" "${tmp_raw}" 2>/dev/null || cp "${path}" "${tmp_raw}"
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
    local all_files count found
    all_files=$(find "${dir}" -maxdepth 2 -type f \( \
        -name "*.raw" -o -name "*.img" -o -name "*.qcow2" -o \
        -name "*.vmdk" -o -name "*.vdi" \))
    found=$(echo "${all_files}" | head -1)
    if [[ -z "${found}" ]]; then
        log_error "在解压目录中未找到镜像文件"
        exit 1
    fi
    count=$(echo "${all_files}" | wc -l)
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
    virt-filesystems -a "${image}" --lvs 2>/dev/null || true
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
    local operator="${1}"
    local size_spec="${2}"
    local current_bytes="${3}"
    local expand_bytes=0

    if [[ "${size_spec}" =~ ^([0-9]+)%$ ]]; then
        local percent="${BASH_REMATCH[1]}"
        expand_bytes=$(( current_bytes * percent / 100 ))
    else
        local target_bytes
        target_bytes=$(parse_size_to_bytes "${size_spec}")
        if [[ "${target_bytes}" =~ ^[0-9]+$ ]]; then
            if [[ "${operator}" == "+" ]]; then
                expand_bytes=${target_bytes}
            elif [[ "${operator}" == "=" ]]; then
                [[ ${target_bytes} -gt ${current_bytes} ]] && expand_bytes=$(( target_bytes - current_bytes ))
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
    [[ -n "${lv_list}" ]] && echo "${lv_list}" | grep -qF "${name}"
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
# 获取表头列索引
# ---------------------------------------------------------------------------
get_col_index() {
    local header="${1}"
    local col_name="${2}"
    echo "${header}" | awk -v name="${col_name}" '{for(i=1;i<=NF;i++) if($i==name) print i}'
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
    col_name=$(get_col_index "${header}" "Name")
    col_size=$(get_col_index "${header}" "Size")

    local lv_list=""
    local has_lvm="false"
    lv_list=$(detect_lvm "${image}")
    [[ -n "${lv_list}" ]] && has_lvm="true"

    local resize_opts=""
    local expand_partition=""
    local lv_expand=""
    local -i expand_size_bytes=0
    local -i auto_budget=0

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
                    local label="LV"
                else
                    local flag="+"; [[ "${operator}" == "=" ]] && flag=""
                    resize_opts="${resize_opts} --resize ${partition}=${flag}${size_spec}"
                    local label="分区"
                fi
                local current_bytes
                current_bytes=$(get_partition_size_bytes "${fs_info}" "${col_name}" "${col_size}" "${partition}")
                local size_bytes
                size_bytes=$(calc_expand_bytes "${operator}" "${size_spec}" "${current_bytes}")
                expand_size_bytes=$((expand_size_bytes + size_bytes))
                log_step "规则: ${label} ${partition} ${operator} ${size_spec} (+$(format_bytes "${size_bytes}"))"
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
            local auto_partition
            auto_partition=$(find_expand_partition "${image}")
            [[ -n "${auto_partition}" ]] || continue
            expand_partition="${auto_partition}"

            local size_bytes; local operator; local size_spec
            if [[ "${rule}" =~ ^[0-9]+[KMGTkmgt]?$ ]]; then
                size_bytes=$(parse_size_to_bytes "${rule}")
                [[ ${size_bytes} -gt 0 ]] || continue
            elif [[ "${rule}" =~ ^([+=])(.+)$ ]]; then
                operator="${BASH_REMATCH[1]}"
                size_spec="${BASH_REMATCH[2]}"
                local current_bytes
                current_bytes=$(get_partition_size_bytes "${fs_info}" "${col_name}" "${col_size}" "${expand_partition}")
                size_bytes=$(calc_expand_bytes "${operator}" "${size_spec}" "${current_bytes}")
            else
                log_error "无法解析规则 '${rule}'"
                return 1
            fi
            log_step "规则: 自动选择分区 ${expand_partition}，扩容 $(format_bytes "${size_bytes}")"
            auto_budget=$((auto_budget + size_bytes))
        fi
    done

    # 总预算 >0 时，以总预算为最终扩容大小
    if [[ ${auto_budget} -gt 0 ]]; then
        expand_size_bytes=${auto_budget}
    fi

    # 验证
    if [[ -z "${expand_partition}" && -z "${resize_opts}" ]]; then
        log_error "无法确定要扩容的分区"
        return 1
    fi
    if [[ ${expand_size_bytes} -eq 0 ]]; then
        if [[ -n "${lv_expand}" ]]; then
            log_error "LV '${lv_expand}' 需配合扩容大小使用"
        else
            log_error "没有指定有效的扩容大小"
        fi
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
    col_name=$(get_col_index "${header}" "Name")
    col_vfs=$(get_col_index "${header}" "VFS")

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
    local tmp_raw="tmp_$$.raw"
    if [[ "${RESIZE_RULE}" == "0" ]]; then
        log_phase "仅格式转换"
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
    CLEANUP_ITEMS+=("${tmp_raw}")
    fetch_input_image "${IMAGE_SOURCE}" "${tmp_raw}"

    log_step "验证镜像..."
    local qemu_info
    qemu_info=$(qemu-img info "${tmp_raw}" 2>/dev/null) || {
        log_error "文件损坏或格式不支持"
        exit 1
    }

    local input_format
    input_format=$(echo "${qemu_info}" | awk '/file format:/ {print $3}')
    log_info "输入格式: ${input_format}"

    # 获取真实大小
    local real_size
    if [[ "${input_format}" == "raw" ]]; then
        sparsify_raw "${tmp_raw}"
        real_size=$(stat -c %s "${tmp_raw}")
    else
        real_size=$(get_image_virtual_size "${tmp_raw}")
    fi
    log_info "镜像大小: ${real_size} 字节 ($(format_bytes "${real_size}"))"

    # 分析分区
    analyze_partitions "${tmp_raw}"

    # 解析扩容规则
    log_phase "解析扩容规则"
    local parsed
    if ! parsed=$(parse_resize_rules "${RESIZE_RULE}" "${tmp_raw}"); then
        log_error "扩容规则解析失败"
        exit 1
    fi
    local expand_partition; local expand_size_bytes; local resize_opts; local lv_expand; local has_lvm
    { read -r expand_partition; read -r expand_size_bytes; read -r resize_opts; read -r lv_expand; read -r has_lvm; } <<< "${parsed}"

    log_info "扩容分区: ${expand_partition}"
    log_info "扩容大小: $(format_bytes "${expand_size_bytes}")"

    # 计算总大小
    local -i total_size=$((real_size + expand_size_bytes))
    log_info "输出总大小: $(format_bytes "${total_size}")"

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
    local resize_cmd="virt-resize${expand_partition:+ --expand ${expand_partition}}"
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

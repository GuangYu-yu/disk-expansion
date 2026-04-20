# Disk Expansion Tool

虚拟磁盘镜像扩容工具，支持从 URL 或本地路径获取镜像，自动/手动选择分区进行扩容。

## 功能特性

- **流式处理**：峰值磁盘占用低
- **多种压缩格式**：支持 `gz`、`xz`、`bz2`、`zst`、`zip`
- **多种磁盘格式**：支持 `qcow2`、`raw`、`vmdk`、`vdi`、`vhd`、`vhdx`、`qed`、`luks`
- **智能识别**：自动识别 root 分区和 LVM 结构
- **灵活扩容**：支持自动选择分区或手动指定

## 用法

```bash
resize_disk.sh <镜像来源> <输出文件> <扩容规则>
```

### 参数说明

| 参数 | 说明 |
|------|------|
| `镜像来源` | URL（http/https）或本地文件路径 |
| `输出文件` | 输出镜像文件名（扩展名决定格式） |
| `扩容规则` | 分区扩容规则（见下表） |

### 扩容规则

| 规则 | 说明 |
|------|------|
| `0` | 仅格式转换，不扩容 |
| `2G` | 自动选择分区，扩容 2G |
| `+10%` | 自动选择分区，增加 10% |
| `=10G` | 自动选择分区，增至 10G |
| `/dev/sda2` | 指定分区填满剩余空间 |
| `/dev/sda2+2G` | 指定分区增加 2G |
| `/dev/sda2=10G` | 指定分区增至 10G |
| `/dev/sda2+10%` | 指定分区增加 10% |
| `/dev/vg/lv_root+2G` | LVM 逻辑卷增加 2G |
| `/dev/sda1+100M,/dev/sda2` | 多分区调整（逗号分隔） |

## 示例

```bash
# 从 URL 下载并扩容 5G
resize_disk.sh https://example.com/image.img.gz output.qcow2 5G

# 本地镜像，指定分区扩容
resize_disk.sh ./image.raw output.qcow2 /dev/sda2+10G

# 仅格式转换
resize_disk.sh ./image.qcow2 output.raw 0
```

## Docker 使用

```bash
docker build -t disk-expansion .
docker run --rm -v $(pwd):/build disk-expansion <镜像来源> <输出文件> <扩容规则>
```

## 依赖

- `qemu-utils`
- `libguestfs-tools`
- `curl` / `wget`
- `xz-utils` / `bzip2` / `zstd`
- `unzip`
- `numfmt`
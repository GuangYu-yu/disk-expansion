<div align="center">

# Disk Expansion

**磁盘镜像扩容工具，支持从 URL 或本地路径获取镜像，自动/手动选择分区进行扩容**

<p align="center">
  <img src="https://img.shields.io/badge/language-bash-yellow?style=flat-square&logo=gnubash" alt="Bash">
  <img src="https://img.shields.io/badge/dockerfile-ready-blue?style=flat-square&logo=docker" alt="Dockerfile">
</p>

<p align="center">
  <a href="https://github.com/GuangYu-yu/disk-expansion">
    <img src="https://img.shields.io/github/stars/GuangYu-yu/disk-expansion?style=flat-square&label=Star&color=00ADD8&logo=github" alt="GitHub Stars">
  </a>
  <a href="https://github.com/GuangYu-yu/disk-expansion/forks">
    <img src="https://img.shields.io/github/forks/GuangYu-yu/disk-expansion?style=flat-square&label=Fork&color=00ADD8&logo=github" alt="GitHub Forks">
  </a>
</p>

<p align="center">
  <a href="https://deepwiki.com/GuangYu-yu/disk-expansion">
    <img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki">
  </a>
  <a href="https://zread.ai/GuangYu-yu/disk-expansion">
    <img src="https://img.shields.io/badge/Ask_Zread-_.svg?style=flat&color=00b0aa&labelColor=000000&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB3aWR0aD0iMTYiIGhlaWdodD0iMTYiIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTQuOTYxNTYgMS42MDAxSDIuMjQxNTZDMS44ODgxIDEuNjAwMSAxLjYwMTU2IDEuODg2NjQgMS42MDE1NiAyLjI0MDFWNC45NjAxQzEuNjAxNTYgNS4zMTM1NiAxLjg4ODEgNS42MDAxIDIuMjQxNTYgNS42MDAxSDQuOTYxNTZDNS4zMTUwMiA1LjYwMDEgNS42MDE1NiA1LjMxMzU2IDUuNjAxNTYgNC45NjAxVjIuMjQwMUM1LjYwMTU2IDEuODg2NjQgNS4zMTUwMiAxLjYwMDEgNC45NjE1NiAxLjYwMDFaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik00Ljk2MTU2IDEwLjM5OTlIMi4yNDE1NkMxLjg4ODEgMTAuMzk5OSAxLjYwMTU2IDEwLjY4NjQgMS42MDE1NiAxMS4wMzk5VjEzLjc1OTlDMS42MDE1NiAxNC4xMTM0IDEuODg4MSAxNC4zOTk5IDIuMjQxNTYgMTQuMzk5OUg0Ljk2MTU2QzUuMzE1MDIgMTQuMzk5OSA1LjYwMTU2IDE0LjExMzQgNS42MDE1NiAxMy43NTk5VjExLjAzOTlDNS42MDE1NiAxMC42ODY0IDUuMzE1MDIgMTAuMzk5OSA0Ljk2MTU2IDEwLjM5OTlaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik0xMy43NTg0IDEuNjAwMUgxMS4wMzg0QzEwLjY4NSAxLjYwMDEgMTAuMzk4NCAxLjg4NjY0IDEwLjM5ODQgMi4yNDAxVjQuOTYwMUMxMC4zOTg0IDUuMzEzNTYgMTAuNjg1IDUuNjAwMSAxMS4wMzg0IDUuNjAwMUgxMy43NTg0QzE0LjExMTkgNS42MDAxIDE0LjM5ODQgNS4zMTM1NiAxNC4zOTg0IDQuOTYwMVYyLjI0MDFDMTQuMzk4NCAxLjg4NjY0IDE0LjExMTkgMS42MDAxIDEzLjc1ODQgMS42MDAxWiIgZmlsbD0iI2ZmZiIvPgo8cGF0aCBkPSJNNCAxMkwxMiA0TDQgMTJaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik00IDEyTDEyIDQiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgo8L3N2Zz4K&logoColor=ffffff" alt="zread">
  </a>
</p>

</div>

## 功能特性

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
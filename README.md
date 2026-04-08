# 🖥️ 磁盘扩容工具包

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/GuangYu-yu/disk-expansion)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)

## 📋 项目简介

这是一个磁盘扩容自动化工具，能够一键完成各种磁盘的容量扩展或格式转换。它封装了 qemu-img、virt-resize 等底层工具，提供友好的命令行接口和智能的自动分区检测功能，适用于云镜像定制、虚拟机磁盘调整、格式迁移等场景。

## ✨ 功能特性

- 🚀 **一键扩容**：自动化完成磁盘扩容全流程
- 📊 **智能检测**：自动识别磁盘类型和文件系统

| 功能模块           | 子功能                                    | 说明                                          |
| -------------- | -------------------------------------- | ------------------------------------------- |
| **输入镜像获取**     | 本地文件                                       | 支持任意存在的本地文件                                 |
|                | URL 下载                                     | 使用 wget 下载远程镜像，支持重试和超时                      |
| **解压缩**        | gzip (.gz)                                 | 自动解压，保持稀疏文件                                 |
|                | bzip2 (.bz2)                               | 自动解压，保持稀疏文件                                 |
|                | xz (.xz)                                   | 自动解压，保持稀疏文件                                 |
|                | zip (.zip)                                 | 自动解压，提取第一个有效镜像                              |
|                | 未识别压缩/无压缩                                  | 当作原文件处理                                     |
| **镜像格式检测与转换**  | raw                                        | 原生支持，可扩容                                    |
|                | qcow2/vmdk/vdi/vhd/vhdx/qed/luks/hdd        | 支持多种格式转换                                    |
|                | 未识别格式                                  | 可能无法处理，需要人工确认                               |
| **扩容**         | qemu-img + virt-resize                      | 支持指定大小（K/M/G）、百分比（%）、设为指定大小（=）              |
|                | 自动选择分区                                     | 自动检测最大非 swap 分区进行扩容                         |
|                | 指定分区                                       | 可手动指定要扩容的分区                                 |
|                | 扩容为 0                                      | 跳过扩容操作，仅格式转换                                |
|                | LVM 支持                                     | 支持 LVM 逻辑卷扩容                                |
| **格式转换**       | qemu-img convert                           | 可在扩容后将镜像转换为 raw/qcow2/vmdk/vdi/vhd/vhdx/qed 等格式 |
| **清理操作**       | 临时文件                                    | trap 自动清理所有临时文件                             |

## 📁 项目结构

```
disk-expansion/
├── 📜 resize_disk.sh          # 主扩容脚本
├── 📁 .github/
│   └── 📁 workflows/
│       └── 📜 resize_disk.yml    # GitHub Actions 扩容工作流
└── 📜 README.md             # 项目文档
```

## 🚀 使用方法

### 命令行

```bash
./resize_disk.sh <镜像URL或本地文件路径> <输出文件名> <扩容规则>
```

### 扩容规则

| 规则 | 说明 |
|------|------|
| `0` | 仅格式转换，不扩容 |
| `2G` | 自动选择分区，扩容 2G |
| `500M` | 自动选择分区，扩容 500M |
| `+10%` | 自动选择分区，增加 10% |
| `=10G` | 自动选择分区，增至 10G |
| `/dev/sda2` | 指定分区填满剩余空间 |
| `/dev/sda2+2G` | 分区增加 2G |
| `/dev/sda2=10G` | 分区增至 10G |
| `/dev/sda2+10%` | 分区增加 10% |
| `/dev/vg_name/lv_name+2G` | LVM 逻辑卷增加 2G（自动调用 --LV-expand） |
| `/dev/sda1+100M,/dev/sda2` | 多分区调整（逗号分隔） |

### 示例

```bash
# 下载镜像并扩容 1G，输出为 raw 格式
./resize_disk.sh https://example.com/image.img.gz output.img 1G

# 本地文件扩容 2G，输出为 qcow2 格式
./resize_disk.sh ./local-image.img output.qcow2 2G

# 仅格式转换
./resize_disk.sh ./image.img output.qcow2 0

# 指定分区扩容
./resize_disk.sh ./image.img output.img /dev/sda2+5G

# LVM 逻辑卷扩容
./resize_disk.sh ./image.img output.img /dev/vg0/root+10G

# 多分区组合调整
./resize_disk.sh ./image.img output.img "/dev/sda1+200M,/dev/sda2"
```

### GitHub Actions

1. **Fork 此仓库**到你的 GitHub 账户
2. **进入 Actions 标签页**，选择 "Resize Disk" 工作流
3. **点击 "Run workflow"**，填写参数：
   - 镜像来源（URL 或本地路径）
   - 输出文件名
   - 扩容规则
4. **运行完成后**，从 Artifacts 下载处理后的镜像文件

> ⚠️ 注意：GitHub Actions 的存储和运行时间有限，超大镜像建议本地执行。

### 环境依赖

脚本运行需要以下工具：

| 工具 | 包名（Ubuntu/Debian） | 包名（CentOS/RHEL） |
|------|----------------------|---------------------|
| qemu-img | qemu-utils | qemu-img |
| virt-resize | libguestfs-tools | libguestfs-tools |
| wget/unzip/xz/bzip2 | wget, unzip, xz-utils, bzip2 | wget, unzip, xz, bzip2 |
| 7z（可选） | p7zip-full | p7zip |

### 注意事项

1. **安全优先**：扩容操作不会修改原始镜像，所有操作均在副本上进行
2. **Windows 镜像**：扩容后首次启动可能会触发磁盘检查（chkdsk），属正常现象
3. **LVM 镜像**：建议显式指定逻辑卷进行扩容，否则只扩容 PV 而 LV 不会自动扩展
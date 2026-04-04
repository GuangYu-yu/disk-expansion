# 🖥️ 磁盘扩容工具包

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/GuangYu-yu/disk-expansion)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)

## 📋 项目简介

这是一个磁盘扩容自动化工具，扩展虚拟磁盘容量或格式转换

## ✨ 功能特性

- 🚀 **一键扩容**：自动化完成磁盘扩容全流程
- 📊 **智能检测**：自动识别磁盘类型和文件系统

| 功能模块           | 子功能                                    | 说明                                          |
| -------------- | -------------------------------------- | ------------------------------------------- |
| **输入镜像获取**     | 本地文件                                       | 支持任意存在的本地文件                                 |
|                | URL 下载                                     | 使用 wget 下载远程镜像，支持重试和超时                      |
| **解压缩**        | gzip (.gz)                                 | 自动解压                                        |
|                | bzip2 (.bz2)                               | 自动解压                                        |
|                | xz (.xz)                                   | 自动解压                                        |
|                | zip (.zip)                                 | 自动解压，提取第一个文件                                |
|                | 未识别压缩/无压缩                                  | 当作原文件处理                                     |
| **镜像格式检测与转换**  | raw                                        | 原生支持，可扩容                                    |
|                | qcow2/vmdk/vdi/vhd/vhdx/qed                | 使用 qemu-img convert 转 raw 后操作               |
|                | 未识别格式                                  | 可能无法处理，需要人工确认                               |
| **扩容**         | qemu-img + virt-resize                      | 可以增加指定大小（K/M/G）                             |
|                | 指定分区                                       | 可选指定要扩容的分区，留空自动检测最大分区                       |
|                | 扩容为 0                                      | 跳过扩容操作，直接格式转换                               |
| **格式转换**       | qemu-img convert                           | 可在扩容后将镜像转换为 raw/qcow2/vmdk/vdi/vhd/vhdx/qed 等格式 |
| **压缩输出**       | 7z 压缩                                      | 可选压缩最终镜像，压缩等级最大（-mx=9）                      |
| **LVM 检测**     | 自动检测                                       | 检测到 LVM 时报错退出，不支持 LVM 自动扩容                  |
| **清理操作**       | 临时文件                                       | trap 自动清理所有临时文件                             |

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

### GitHub Actions

1. **Fork 此仓库**
2. **手动触发工作流**:
   - 进入 GitHub Actions 页面
   - 选择 "Resize Disk" 工作流
   - 点击 "Run workflow" 并输入参数

## 🔍 工作原理

1. **下载/获取镜像**：支持 URL 下载或本地文件
2. **解压缩**：自动识别压缩格式并解压
3. **格式转换**：非 raw 格式转换为 raw
4. **分区检测**：使用 virt-filesystems 检测分区
5. **LVM 检测**：检测 LVM 并报错退出
6. **扩容**：qemu-img 创建新镜像 + virt-resize 扩容分区
7. **格式转换**：按输出文件名转换格式
8. **清理**：自动清理所有临时文件
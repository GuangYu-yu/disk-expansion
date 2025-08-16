# 🖥️ 磁盘扩容工具包

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/GuangYu-yu/disk-expansion)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)

## 📋 项目简介

这是一个磁盘扩容自动化工具包，扩展虚拟磁盘容量或格式转换

## ✨ 功能特性

- 🚀 **一键扩容**：自动化完成磁盘扩容全流程
- 📊 **智能检测**：自动识别磁盘类型和文件系统

| 功能模块           | 子功能                                    | 说明                                          |
| -------------- | -------------------------------------- | ------------------------------------------- |
| **输入镜像获取**     | 本地文件                                       | 支持任意存在的本地文件                                 |
|                | URL 下载                                     | 使用 wget 下载远程镜像                              |
| **解压缩**        | gzip (.gz)                                 | 自动解压                                        |
|                | bzip2 (.bz2)                               | 自动解压                                        |
|                | xz (.xz)                                   | 自动解压                                        |
|                | 7z (.7z)                                   | 自动解压，提取第一个文件                                |
|                | tar (.tar, .tar.gz, .tar.bz2, .tar.xz)     | 自动解压，提取第一个文件                                |
|                | zip (.zip)                                 | 自动解压，提取第一个文件                                |
|                | 未识别压缩/无压缩                                  | 当作原文件处理                                     |
| **镜像格式检测与转换**  | raw                                        | 原生支持，可扩容                                    |
|                | qcow2/vmdk/vdi/vhd/vhdx/qed                | 使用 qemu-img convert 转 raw 后操作               |
|                | SquashFS/ISO                               | 可扩容 overlay 空间，但文件系统本体只读                    |
|                | 未识别格式                                  | 可能无法处理，需要人工确认                               |
| **扩容**         | dd 扩容                                      | 可以增加指定大小（M/G）                               |
|                | parted 调整分区                                | 支持普通分区和 EFI 分区（带 expect 脚本）                 |
|                | 扩容为 0                                      | 跳过扩容操作，直接格式转换                               |
| **格式转换**       | qemu-img convert                           | 可在扩容后将镜像转换为 raw/qcow2/vmdk/vdi/vhd/vhdx 等格式 |
| **压缩输出**       | 7z 压缩                                      | 可选压缩最终镜像，压缩等级最大（-mx=9）                      |
| **overlay 支持** | SquashFS overlay 扩展                        | 增加 img 文件大小，使 overlay 可写空间增大                |
| **分区处理**       | EFI 镜像                                     | 使用 expect 自动处理 parted 交互                    |
|                | 非 EFI 镜像                                   | 直接使用 parted resizepart                      |
| **清理操作**       | 临时解压目录                                     | 解压后自动清理 `extracted` 目录                      |
|                | 临时文件                                       | qemu-img 转换或压缩后可删除中间文件                      |

## 📁 项目结构

```
disk-expansion/
├── 📜 resize_disk.sh          # 主扩容脚本
├── 📜 img2kvm.sh            # KVM镜像转换工具
├── 📜 old.sh                # 旧版本兼容脚本
├── 📁 .github/
│   └── 📁 workflows/
│       ├── 📜 resize_disk.yml    # GitHub Actions工作流
│       └── 📜 old              # 旧工作流文件
└── 📜 README.md             # 项目文档
```

### 使用GitHub Actions自动扩容

   **Fork此仓库**
   **手动触发工作流**:
   - 进入GitHub Actions页面
   - 选择"Resize Disk"工作流
   - 点击"Run workflow"并输入参数

## 🔍 工作原理

- **扩容磁盘**：使用qemu-img调整磁盘大小
- **分区调整**：自动识别并扩展分区
- **文件系统扩容**：根据文件系统类型执行扩容
- **验证结果**：确认扩容成功并清理临时文件

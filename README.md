# 🖥️ 磁盘扩容工具包

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/GuangYu-yu/disk-expansion)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)

## 📋 项目简介

这是一个磁盘扩容自动化工具包，扩展虚拟磁盘容量或格式转换

## ✨ 功能特性

- 🚀 **一键扩容**：自动化完成磁盘扩容全流程
- 📊 **智能检测**：自动识别磁盘类型和文件系统

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

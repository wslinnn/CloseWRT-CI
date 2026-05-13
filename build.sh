#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
#
# CloseWRT-CI 本地一键编译脚本
# 适用于 Ubuntu 24.04，以普通用户运行（需要 sudo 权限）
# 用法: bash build.sh          # 完整编译
#       bash build.sh --test   # 仅输出配置文件

set -e

if [[ "$(id -u)" -eq 0 ]]; then
    echo "请勿以 root 用户运行此脚本"
    exit 1
fi

# ==================== 用户配置区域 ====================

# 编译配置
WRT_CONFIG="MT7981"
# 默认主题
WRT_THEME="aurora"
# 默认主机名
WRT_NAME="CWRT"
# 默认WIFI名称
WRT_SSID="CWRT"
# 默认WIFI密码
WRT_WORD="12345678"
# 默认登录地址
WRT_IP="192.168.10.1"
# 默认登录密码（仅作提示）
WRT_PW="无"

# 源码链接
WRT_REPO="https://github.com/Yuzhii0718/immortalwrt-mt798x-6.6-padavanonly.git"
# 源码分支
WRT_BRANCH="openwrt-24.10-6.6"
# 源码名称
WRT_SOURCE="Yuzhii0718/immortalwrt-mt798x-6.6-padavanonly"

# 手动调整插件包（可选，多个用\n隔开）
WRT_PACKAGE=""
# 仅输出配置文件不编译
WRT_TEST="false"

# ==================== 脚本正文 ====================

if [[ "$1" == "--test" ]]; then
    WRT_TEST="true"
fi

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${WORK_DIR}"

# 导出环境变量供子脚本使用
export GITHUB_WORKSPACE="${WORK_DIR}"
export GITHUB_ENV="${WORK_DIR}/.build_env"
> "${GITHUB_ENV}"

export WRT_CONFIG WRT_THEME WRT_NAME WRT_SSID WRT_WORD WRT_IP WRT_PW
export WRT_REPO WRT_BRANCH WRT_SOURCE WRT_PACKAGE WRT_TEST

echo "========================================"
echo "  CloseWRT-CI 本地编译"
echo "========================================"

# ---------- [1/10] 初始化编译环境 ----------
echo ">>> [1/10] 初始化编译环境"

export DEBIAN_FRONTEND=noninteractive
sudo -E apt -yqq update
sudo -E apt -yqq install dos2unix libfuse-dev
sudo bash -c 'bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)'
sudo -E timedatectl set-timezone "Asia/Shanghai" 2>/dev/null || true

mkdir -p "${WORK_DIR}/wrt"

# ---------- [2/10] 初始化变量 ----------
echo ">>> [2/10] 初始化变量"

export WRT_DATE=$(TZ=UTC-8 date +"%y.%m.%d-%H.%M.%S")
export WRT_MARK="local"
export WRT_INFO="${WRT_SOURCE%%/*}"
export WRT_TARGET=$(grep -m 1 -oP '^CONFIG_TARGET_\K[\w]+(?=\=y)' "./Config/${WRT_CONFIG}.txt")
export WRT_WIFI="wifi-yes"
export WRT_KVER="none"
export WRT_LIST="none"

echo "    日期: ${WRT_DATE}"
echo "    平台: ${WRT_TARGET}"
echo "    源码: ${WRT_SOURCE}"
echo "    分支: ${WRT_BRANCH}"

# ---------- [3/10] 克隆源码 ----------
echo ">>> [3/10] 克隆源码"

if [ ! -d "${WORK_DIR}/wrt/.git" ]; then
    git clone --depth=1 --single-branch --branch "${WRT_BRANCH}" "${WRT_REPO}" "${WORK_DIR}/wrt/"
fi

cd "${WORK_DIR}/wrt/"
export WRT_HASH=$(git log -1 --pretty=format:'%h')

if [ ! -d "defconfig" ]; then
    echo "    defconfig 目录不存在, 请检查源码"
    exit 1
fi

echo "    提交: ${WRT_HASH}"
cd "${WORK_DIR}"

# ---------- [4/10] 处理脚本格式 ----------
echo ">>> [4/10] 处理脚本格式"

find ./ -maxdepth 3 -type f -iregex ".*\(txt\|sh\)$" -exec dos2unix {} \; -exec chmod +x {} \;

# ---------- [5/10] 缓存管理 ----------
# 注意: workflow 中此步骤会移除国内下载源 (GitHub Actions 在国外访问困难)
# 本地编译保留国内源, 下载速度更快
echo ">>> [5/10] 缓存管理"

if [ -d "${WORK_DIR}/wrt/staging_dir" ]; then
    find "${WORK_DIR}/wrt/staging_dir" -type d -name "stamp" -not -path "*target*" | while read -r DIR; do
        find "$DIR" -type f -exec touch {} +
    done
    mkdir -p "${WORK_DIR}/wrt/tmp" && echo "1" > "${WORK_DIR}/wrt/tmp/.build"
    echo "    已刷新缓存时间戳, 跳过 toolchain 编译"
else
    echo "    无缓存, 将进行完整编译"
fi

# ---------- [6/10] 更新 Feeds ----------
echo ">>> [6/10] 更新 Feeds"

cd "${WORK_DIR}/wrt/"
./scripts/feeds update -a
./scripts/feeds install -a
cd "${WORK_DIR}"

# ---------- [7/10] 自定义软件包 ----------
echo ">>> [7/10] 自定义软件包"

cd "${WORK_DIR}/wrt/package/"
"${WORK_DIR}/Scripts/Packages.sh"
"${WORK_DIR}/Scripts/Handles.sh"
cd "${WORK_DIR}"

# ---------- [8/10] 自定义设置 ----------
echo ">>> [8/10] 自定义设置"

cd "${WORK_DIR}/wrt/"

rm -f .config

if [[ "${WRT_CONFIG,,}" == *"test"* ]]; then
    cat "${WORK_DIR}/Config/${WRT_CONFIG}.txt" >> .config
else
    cat "${WORK_DIR}/Config/${WRT_CONFIG}.txt" "${WORK_DIR}/Config/GENERAL.txt" >> .config
fi

"${WORK_DIR}/Scripts/Settings.sh"

# 读取 Settings.sh 通过 GITHUB_ENV 写入的变量
if [ -s "${GITHUB_ENV}" ]; then
    while IFS='=' read -r _key _value; do
        [ -n "$_key" ] && export "$_key=$_value"
    done < "${GITHUB_ENV}"
fi

make defconfig -j$(nproc) && make clean -j$(nproc)
cd "${WORK_DIR}"

if [[ "${WRT_TEST}" != "true" ]]; then

    # ---------- [9/10] 下载软件包 ----------
    echo ">>> [9/10] 下载软件包"

    cd "${WORK_DIR}/wrt/"
    make download -j$(nproc)
    cd "${WORK_DIR}"

    # ---------- [10/10] 编译固件 ----------
    echo ">>> [10/10] 编译固件"

    cd "${WORK_DIR}/wrt/"
    make -j$(nproc) || make -j1 V=s
    cd "${WORK_DIR}"

else
    echo ">>> 测试模式: 仅输出配置文件, 跳过编译"
fi

# ---------- 显示编译信息 ----------
echo ">>> 编译信息"

cd "${WORK_DIR}/wrt/"
echo "======================="
lscpu | grep -E "name|Core|Thread"
echo "======================="
df -h
echo "======================="
du -h --max-depth=1
echo "======================="
cd "${WORK_DIR}"

# ---------- 打包固件 ----------
echo ">>> 打包固件"

cd "${WORK_DIR}/wrt/"
mkdir -p ./upload/

cp -f ./.config "./upload/Config-${WRT_CONFIG}-${WRT_INFO}-${WRT_BRANCH}-${WRT_DATE}.txt"

if [[ "${WRT_TEST}" != "true" ]]; then
    WRT_KVER=$(find ./bin/targets/ -type f -name "*.manifest" -exec grep -oP '^kernel - \K[\d\.]+' {} \;)
    WRT_LIST=$(find ./bin/targets/ -type f -name "*.manifest" -exec grep -oP '^luci-(app|theme)[^ ]*' {} \; | tr '\n' ' ')

    find ./bin/targets/ -iregex ".*\(buildinfo\|json\|sha256sums\|packages\)$" -exec rm -rf {} +

    for FILE in $(find ./bin/targets/ -type f -iname "*${WRT_TARGET}*"); do
        EXT=$(basename "$FILE" | cut -d '.' -f 2-)
        NAME=$(basename "$FILE" | cut -d '.' -f 1 | grep -io "\(${WRT_TARGET}\).*")
        NEW_FILE="${NAME}-${WRT_INFO}-${WRT_BRANCH}-${WRT_WIFI}-${WRT_DATE}.${EXT}"
        mv -f "$FILE" "./upload/${NEW_FILE}"
    done

    find ./bin/targets/ -type f -exec mv -f {} ./upload/ \;
fi

cd "${WORK_DIR}"

# 清理
rm -f "${GITHUB_ENV}"

echo "========================================"
echo "  编译完成!"
echo "  固件目录: ${WORK_DIR}/wrt/upload/"
echo "  登录地址: ${WRT_IP}"
echo "  登录密码: ${WRT_PW}"
echo "  WIFI名称: ${WRT_SSID}"
echo "  WIFI密码: ${WRT_WORD}"
echo "  内核版本: ${WRT_KVER}"
echo "========================================"

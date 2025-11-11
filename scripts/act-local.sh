#!/bin/bash

set -euo pipefail

echo "[act-local] 本地使用 act 测试 GitHub Actions 工作流"

# 检查 act 是否已安装
if ! command -v act >/dev/null 2>&1; then
  echo "[act-local] 未检测到 act，请先安装：brew install act"
  exit 1
fi

# 检查 Docker 是否可用
if ! command -v docker >/dev/null 2>&1; then
  echo "[act-local] 未检测到 docker 命令，请安装并启动 Docker Desktop，或使用 Colima: brew install colima && colima start"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "[act-local] 无法连接到 Docker daemon，请启动 Docker Desktop（或 colima start）后重试"
  exit 1
fi

# 若使用 colima，上下文设置 DOCKER_HOST，避免 act 无法识别 docker.sock
CURRENT_CTX=$(docker context show 2>/dev/null || echo "default")
if [ "$CURRENT_CTX" = "colima" ]; then
  COLIMA_HOST=$(docker context inspect colima --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null || echo "")
  if [ -n "$COLIMA_HOST" ]; then
    export DOCKER_HOST="$COLIMA_HOST"
    echo "[act-local] 检测到 Docker context=colima，已设置 DOCKER_HOST=$DOCKER_HOST"
  fi
fi

# 预设平台镜像映射（macos-latest 用 ubuntu 镜像模拟）
UBUNTU_IMG="ghcr.io/catthehacker/ubuntu:act-22.04"

echo "[act-local] 运行 pull_request 事件的构建作业（包含多系统/多架构矩阵）"

HOST_ARCH=$(uname -m)
CONTAINER_ARCH="linux/amd64"
if [ "$HOST_ARCH" = "arm64" ] || [ "$HOST_ARCH" = "aarch64" ]; then
  CONTAINER_ARCH="linux/arm64"
fi

act pull_request \
  -j build-coredns-with-plugins \
  -P ubuntu-latest=${UBUNTU_IMG} \
  -P macos-latest=${UBUNTU_IMG} \
  --container-architecture ${CONTAINER_ARCH}

echo "[act-local] 运行完成，构建工件可在 ./build-output/ 下查看（若作业成功）"
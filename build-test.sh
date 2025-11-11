#!/bin/bash

# 本地编译测试脚本 - 无交互自动化集成版本
set -e
ROOT=$(pwd)
echo "开始本地编译测试..."

# 检查是否提供了CoreDNS源码目录
COREDNS_SRC=${1:-""}
if [ -z "$COREDNS_SRC" ]; then
    echo "用法: $0 <coredns源码目录路径>"
    echo "示例: $0 /path/to/coredns"
    echo ""
    echo "如果没有CoreDNS源码，请先下载："
    echo "git clone https://github.com/coredns/coredns.git /path/to/coredns"
    exit 1
fi

# 检查CoreDNS源码目录是否存在
if [ ! -d "$COREDNS_SRC" ]; then
    echo "错误: CoreDNS源码目录不存在: $COREDNS_SRC"
    exit 1
fi

# 检查是否是有效的CoreDNS源码目录
if [ ! -f "$COREDNS_SRC/go.mod" ] || [ ! -f "$COREDNS_SRC/plugin.cfg" ]; then
    echo "错误: 指定的目录不是有效的CoreDNS源码目录: $COREDNS_SRC"
    exit 1
fi

echo "使用CoreDNS源码目录: $COREDNS_SRC"

# 创建临时工作目录
TEMP_DIR=$(mktemp -d)
echo "使用临时工作目录: $TEMP_DIR"

# 复制CoreDNS源码到临时目录
echo "复制CoreDNS源码..."
cp -r "$COREDNS_SRC" "$TEMP_DIR/coredns"

# 复制插件源码（确保复制到 coredns/plugin/ 的一级目录，而不是多一层 plugins/）
echo "复制插件源码..."
cp -r plugins/azroute "$TEMP_DIR/coredns/plugin/"
cp -r plugins/splitnet "$TEMP_DIR/coredns/plugin/"
cp -r plugins/georoute "$TEMP_DIR/coredns/plugin/"

# 移除插件子目录中的独立 go.mod/go.sum，避免形成嵌套模块导致 replaced/not required 错误
for p in azroute splitnet georoute; do
    if [ -f "$TEMP_DIR/coredns/plugin/$p/go.mod" ] || [ -f "$TEMP_DIR/coredns/plugin/$p/go.sum" ]; then
        rm -f "$TEMP_DIR/coredns/plugin/$p/go.mod" "$TEMP_DIR/coredns/plugin/$p/go.sum"
        echo "✅ 已移除 $p 插件中的 go.mod/go.sum，避免嵌套模块导致构建报错"
    fi
done

# 修改 plugin.cfg - 避免重复追加
echo "修改 plugin.cfg..."
PLUGIN_CFG="$TEMP_DIR/coredns/plugin.cfg"

# 检查并添加azroute插件
ls -l "$PLUGIN_CFG"
echo "当前 plugin.cfg 预览(前20行):"
head -n 20 "$PLUGIN_CFG" || true

# 使用跨平台 awk 在 hosts 之后插入三款插件，若已存在则跳过插入
if ! grep -q "^azroute:" "$PLUGIN_CFG" || ! grep -q "^splitnet:" "$PLUGIN_CFG" || ! grep -q "^georoute:" "$PLUGIN_CFG"; then
    echo "使用 awk 在 hosts:hosts 之后插入 azroute/splitnet/georoute (macOS/Linux 通用)"
    awk '
        BEGIN { inserted=0 }
        /^hosts:hosts$/ && inserted==0 {
            print;
            print "azroute:azroute";
            print "splitnet:splitnet";
            print "georoute:georoute";
            inserted=1;
            next
        }
        { print }
    ' "$PLUGIN_CFG" > "$PLUGIN_CFG.tmp" && mv "$PLUGIN_CFG.tmp" "$PLUGIN_CFG"
fi

# 兜底：若仍不存在，则追加到文件末尾
if ! grep -q "^azroute:" "$PLUGIN_CFG"; then echo "azroute:azroute" >> "$PLUGIN_CFG"; fi
if ! grep -q "^splitnet:" "$PLUGIN_CFG"; then echo "splitnet:splitnet" >> "$PLUGIN_CFG"; fi
if ! grep -q "^georoute:" "$PLUGIN_CFG"; then echo "georoute:georoute" >> "$PLUGIN_CFG"; fi

echo "修改后的 plugin.cfg 预览(前30行):"
head -n 30 "$PLUGIN_CFG" || true

# 进入 CoreDNS 目录
cd "$TEMP_DIR/coredns"

# 保持 CoreDNS module 路径不变 (github.com/coredns/coredns)，避免导入路径不一致问题
echo "保持 CoreDNS module 路径不变，直接使用本地源码进行编译"

# 规范化 go.mod 的 go 版本格式，去掉补丁号（例如 1.24.0 -> 1.24），避免 'invalid go version' 错误
if grep -qE '^go [0-9]+\.[0-9]+\.[0-9]+' go.mod; then
    echo "规范化 go.mod 的 go 版本为不带补丁号的格式"
    sed -i.bak -E 's/^go ([0-9]+)\.([0-9]+)\.[0-9]+$/go \1.\2/' go.mod || true
fi
# 同步规范化 toolchain 行（如果存在补丁号）
if grep -qE '^toolchain go[0-9]+\.[0-9]+\.[0-9]+' go.mod 2>/dev/null; then
    echo "规范化 go.mod 的 toolchain 版本为不带补丁号的格式"
    sed -i.bak -E 's/^toolchain go([0-9]+)\.([0-9]+)\.[0-9]+$/toolchain go\1.\2/' go.mod || true
fi

# 处理依赖
echo "处理依赖..."
go mod tidy
go generate

# 生成后的校验：确保 azroute/splitnet/georoute 被包含到生成代码
if [ -f plugin/zz.go ]; then
    echo "生成的 plugin/zz.go 预览(前60行):"
    head -n 60 plugin/zz.go || true
    missing_plugins=""
    grep -q "azroute" plugin/zz.go || missing_plugins="${missing_plugins} azroute"
    grep -q "splitnet" plugin/zz.go || missing_plugins="${missing_plugins} splitnet"
    grep -q "georoute" plugin/zz.go || missing_plugins="${missing_plugins} georoute"
    if [ -n "$missing_plugins" ]; then
        echo "⚠️  go generate 未包含以下插件到生成代码:${missing_plugins}"
        echo "请检查 plugin.cfg，或稍后手动回退到直接编辑 plugin/zz.go 的方案"
    else
        echo "✅ 所有插件已包含到生成代码"
    fi
else
    echo "⚠️  未找到 plugin/zz.go，可能 go generate 未执行或失败"
fi

# 尝试编译
echo "开始编译..."
if go build -o coredns; then
    echo "✅ 编译成功！"
    echo "编译后的文件大小: $(ls -lh coredns)"
    echo "编译后的文件位置: $TEMP_DIR/coredns/coredns"
    
    # 询问是否复制编译结果到当前目录
    OUTPUT_DIR="${ROOT}/bin"
    mkdir -p "$OUTPUT_DIR"
    cp coredns "$OUTPUT_DIR/coredns-with-plugins"
    echo "✅ 编译结果已复制到: $OUTPUT_DIR/coredns-with-plugins"
    
    # 显示编译信息
    echo ""
    echo "🎉 编译完成！"
    echo "=========================================="
    echo "编译信息:"
    echo "- 临时工作目录: $TEMP_DIR"
    echo "- 输出文件: $OUTPUT_DIR/coredns-with-plugins"
    echo "- 文件大小: $(ls -lh $OUTPUT_DIR/coredns-with-plugins | awk '{print $5}')"
    echo ""
    echo "集成的插件:"
    echo "- azroute: 可用区智能路由"
    echo "- splitnet: 内外网区分解析"
    echo "- georoute: 地理路由就近解析"
    echo ""
    echo "使用方法:"
    echo "./build-output/coredns-with-plugins -conf Corefile"
    echo ""
    echo "注意: 临时目录将在脚本结束后自动清理"
fi

./bin/coredns-with-plugins -conf Corefile

# 在启动前尝试列出编译进二进制的插件（若支持）
if ./bin/coredns-with-plugins -plugins >/dev/null 2>&1; then
    echo "已编译进二进制的插件列表:"
    ./bin/coredns-with-plugins -plugins
fi

# # 清理临时文件
# if [ -n "$CI" ]; then
#     echo "CI环境下跳过长时间sleep，立即清理临时文件..."
# else
#     echo "清理临时文件..."
#     sleep 3600
# fi
# rm -rf "$TEMP_DIR"

echo "✅ 测试完成！"
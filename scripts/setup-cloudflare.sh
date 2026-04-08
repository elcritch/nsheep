#!/bin/bash
#
# NSheep Cloudflare 设置脚本
# 一键设置 R2 + KV + Tunnel
#

set -e

echo "🐑 NSheep Cloudflare 设置脚本"
echo ""

# 检查依赖
if ! command -v wrangler &> /dev/null; then
    echo "需要安装 wrangler: npm install -g wrangler"
    exit 1
fi

# 登录检查
echo "1️⃣  检查 Cloudflare 登录状态..."
wrangler whoami || wrangler login

# 获取 Account ID
if [ -z "$CF_ACCOUNT_ID" ]; then
    echo ""
    echo "输入你的 Cloudflare Account ID:"
    echo "(可以在 Cloudflare Dashboard 右侧找到)"
    read CF_ACCOUNT_ID
fi

export CF_ACCOUNT_ID

# 创建 R2 Bucket
echo ""
echo "2️⃣  创建 R2 Bucket..."
BUCKET_NAME="nsheep-packages"

if wrangler r2 bucket list 2>/dev/null | grep -q "$BUCKET_NAME"; then
    echo "   Bucket '$BUCKET_NAME' 已存在"
else
    wrangler r2 bucket create "$BUCKET_NAME"
    echo "   ✅ Bucket 创建成功"
fi

# 创建 KV Namespace
echo ""
echo "3️⃣  创建 KV Namespace..."
KV_RESULT=$(wrangler kv:namespace create "NSHEEP_INDEX" 2>&1 || true)

if echo "$KV_RESULT" | grep -q "already exists"; then
    echo "   KV namespace 已存在，获取 ID..."
    # 尝试从 list 获取
    KV_LIST=$(wrangler kv:namespace list 2>/dev/null || echo "[]")
    KV_ID=$(echo "$KV_LIST" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
else
    echo "   ✅ KV namespace 创建成功"
    KV_ID=$(echo "$KV_RESULT" | grep -oP 'id = "\K[^"]+' || echo "")
fi

if [ -z "$KV_ID" ]; then
    echo "⚠️  无法自动获取 KV ID"
    echo "   请在 Workers & Pages → KV 中找到并手动输入:"
    read KV_ID
fi

echo "   KV ID: $KV_ID"

# 提示创建 API Token
echo ""
echo "4️⃣  API Token 设置"
echo "   请在 Cloudflare Dashboard 中创建:"
echo "   https://dash.cloudflare.com/profile/api-tokens"
echo ""
echo "   推荐权限:"
echo "   - R2:Edit"
echo "   - Workers KV Storage:Edit"
echo "   - Cloudflare Tunnel:Edit (如果使用 Tunnel)"
echo ""
echo "   输入 API Token:"
read API_TOKEN

# R2 凭证
echo ""
echo "5️⃣  R2 S3 兼容凭证"
echo "   在 Dashboard → R2 → Manage R2 API Tokens 中创建"
echo "   输入 Access Key ID:"
read R2_ACCESS_KEY_ID
echo "   输入 Secret Access Key:"
read R2_SECRET_KEY

# 生成 .env 文件
echo ""
echo "6️⃣  生成环境变量文件..."

cat > .env << EOF
# Cloudflare Account
CF_ACCOUNT_ID=$CF_ACCOUNT_ID
CF_API_TOKEN=$API_TOKEN

# R2 Storage
CF_R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
CF_R2_SECRET_ACCESS_KEY=$R2_SECRET_KEY
CF_R2_BUCKET=$BUCKET_NAME

# KV Storage
CF_KV_NAMESPACE_ID=$KV_ID
EOF

echo ""
echo "✅ 设置完成！"
echo ""
echo "环境变量已保存到 .env 文件"
echo ""
echo "下一步:"
echo "1. 检查 .env 文件内容"
echo "2. 将值添加到 GitHub Secrets:"
echo "   https://github.com/YOUR_USERNAME/nsheep/settings/secrets/actions"
echo ""
echo "3. 或在本地运行:"
echo "   source .env && ./nsheep"
echo ""
echo "测试:"
echo "   curl http://localhost:8080/health"

#!/usr/bin/env bash 
# gost-api-cli.sh — GOST API 管理脚本（修复版）
set -u

API_URL="${GOST_API_URL:-http://127.0.0.1:18080}"
API_AUTH="${GOST_API_AUTH:-}"
CONFIG_FILE="${GOST_CONFIG_FILE:-/etc/gost/config.json}"
CURL_SILENT="-s"
CURL_AUTH_OPTS=()
if [ -n "${API_AUTH}" ]; then CURL_AUTH_OPTS+=("-u" "${API_AUTH}"); fi

_pp() { if command -v jq >/dev/null 2>&1; then jq . 2>/dev/null || cat; else cat; fi; }
pause() { echo; read -e -rp "按回车继续..."; }
api_get_raw() { curl ${CURL_SILENT} "${CURL_AUTH_OPTS[@]}" -X GET "${API_URL}$1"; }
api_get() { api_get_raw "$1" | _pp; }
api_post_raw() { 
  local path="$1"; local data="$2"
  curl ${CURL_SILENT} "${CURL_AUTH_OPTS[@]}" -X POST \
    -H "Content-Type: application/json" -d "${data}" \
    -w "\n%{http_code}" "${API_URL}${path}"
}
api_put_raw() {
  local path="$1"; local data="$2"
  curl ${CURL_SILENT} "${CURL_AUTH_OPTS[@]}" -X PUT \
    -H "Content-Type: application/json" -d "${data}" \
    -w "\n%{http_code}" "${API_URL}${path}"
}
api_delete_raw() { 
  local path="$1"
  curl ${CURL_SILENT} "${CURL_AUTH_OPTS[@]}" -X DELETE \
    -w "\n%{http_code}" "${API_URL}${path}"
}

_check_service_exists() {
  local name="$1"; local resp
  resp=$(api_get_raw "/config/services/${name}")
  if echo "$resp" | grep -q '"data": null'; then return 1; fi
  if echo "$resp" | grep -qi "not found" || echo "$resp" | grep -qi "404"; then return 1; fi
  if echo "$resp" | jq -e '.name' >/dev/null 2>&1; then return 0; fi
  if [ -z "$(echo "$resp" | tr -d ' \n\r')" ] || [ "$resp" = "{}" ]; then return 1; fi
  return 1
}

_normalize_laddr() {
  local input="$1"
  input="$(echo -n "$input" | tr -d ' \t\r\n')"
  if [ -z "$input" ]; then echo ""; return; fi
  if echo "$input" | grep -Eq '^[0-9]+$'; then input=":${input}"; fi
  echo "$input"
}

# ===== 检测 GOST API 是否可访问 =====
check_gost_api_status() {
  local api="${API_URL:-http://127.0.0.1:18080}"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "${api}/config" 2>/dev/null || echo "000")

  if [ "$code" = "200" ]; then
    echo "API 状态：✅ 正常连接"
  elif [ "$code" = "401" ]; then
    echo "API 状态：⚠️ 需要认证（401 Unauthorized）"
  elif [ "$code" = "404" ]; then
    echo "API 状态：⚠️ 返回 404（接口未启用或路径错误）"
  else
    echo "API 状态：❌ 无法访问（返回码 ${code}）"
  fi
}

# ===== 可选：确保依赖（如未在脚本中已有 ensure_dependencies，则使用此） =====
ensure_dependencies() {
  local SUDO="${1:-}"
  [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ] && SUDO="sudo"

  local need=()
  command -v curl >/dev/null 2>&1 || need+=("curl")
  command -v jq >/dev/null 2>&1 || need+=("jq")
  command -v tar >/dev/null 2>&1 || need+=("tar")
  command -v gzip >/dev/null 2>&1 || need+=("gzip")

  if [ ${#need[@]} -eq 0 ]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y || true
    $SUDO apt-get install -y "${need[@]}" || true
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y "${need[@]}" || true
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y "${need[@]}" || true
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache "${need[@]}" || true
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm "${need[@]}" || true
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper install -y "${need[@]}" || true
  else
    echo "警告：未识别到包管理器，请手动安装： ${need[*]}"
  fi
  return 0
}


# ========== 检测 GOST 安装与运行状态 ==========
get_gost_status() {
  local gost_bin gost_active gost_enabled

  # 检查 gost 二进制是否存在
  if command -v gost >/dev/null 2>&1; then
    gost_bin="$(command -v gost)"
    install_status="已安装 ($gost_bin)"
  else
    install_status="未安装"
  fi

  # 检查 systemd 服务状态
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "^gost.service"; then
    if systemctl is-active --quiet gost.service; then
      gost_active="● 服务运行中"
    else
      gost_active="○ 服务未运行"
    fi
  else
    # systemd 不存在或未配置 gost.service
    gost_active="○ 服务未配置或非 systemd 环境"
  fi

  # 输出状态行（供主菜单调用）
  echo "服务状态：${gost_active}"
  echo "安装状态：${install_status}"
}






install_gost_and_setup() {
  set -e
  local SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"

  # 简单辅助：检测 HTTP code（用于内部逻辑）
  _get_api_code() {
    curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${API_URL:-http://127.0.0.1:18080}/config" 2>/dev/null || echo "000"
  }

  # 智能依赖安装：仅安装缺失的工具
  ensure_dependencies() {
    local SUDO="$1"
    [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    local need=()
    command -v curl >/dev/null 2>&1 || need+=("curl")
    command -v jq >/dev/null 2>&1 || need+=("jq")
    command -v tar >/dev/null 2>&1 || need+=("tar")
    command -v gzip >/dev/null 2>&1 || need+=("gzip")
    if [ ${#need[@]} -eq 0 ]; then
      return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
      echo "使用 apt-get 安装依赖：${need[*]}"
      $SUDO apt-get update -y || true
      $SUDO apt-get install -y "${need[@]}" || true
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf install -y "${need[@]}" || true
    elif command -v yum >/dev/null 2>&1; then
      $SUDO yum install -y "${need[@]}" || true
    elif command -v apk >/dev/null 2>&1; then
      $SUDO apk add --no-cache "${need[@]}" || true
    elif command -v pacman >/dev/null 2>&1; then
      $SUDO pacman -Sy --noconfirm "${need[@]}" || true
    elif command -v zypper >/dev/null 2>&1; then
      $SUDO zypper install -y "${need[@]}" || true
    else
      echo "警告：未识别包管理器，请手动安装： ${need[*]}"
      return 2
    fi
    return 0
  }

  # 决定是否使用 GitHub 镜像（如果在中国大陆会提示）
decide_github_proxy_for_cn() {
  DOWNLOAD_PREFIX=""
  local PROXIES=( \
    "https://ghproxy.com/https://"
    "https://ghproxy.net/https://"
    "https://ghproxy.org/https://"
    "https://download.fastgit.org/https://"
    "https://ghproxy.cn/https://"
  )
  local country=""
  # 多个服务尝试，提高成功率
  country=$(curl -s --max-time 3 https://ipapi.co/country 2>/dev/null || true)
  country=${country:-$(curl -s --max-time 3 https://ipinfo.io/country 2>/dev/null || true)}
  country=${country:-$(curl -s --max-time 3 https://ifconfig.co/country_code 2>/dev/null || true)}
  country=$(echo -n "${country}" | tr '[:lower:]' '[:upper:]')

  if [ "${country}" = "CN" ]; then
    echo "检测到可能位于中国大陆 (country=${country})，建议使用镜像以加速下载。"
    read -rp "是否使用镜像下载二进制以加速? (Y/n) " yn
    yn=${yn:-Y}
    if [[ "${yn}" =~ ^[Yy]$ ]]; then
      for p in "${PROXIES[@]}"; do
        # 测试代理能否访问 raw.githubusercontent.com（HEAD）
        if curl -s --head --max-time 4 "${p}raw.githubusercontent.com/" >/dev/null 2>&1; then
          DOWNLOAD_PREFIX="$p"
          echo "选用镜像: ${DOWNLOAD_PREFIX}"
          break
        fi
      done
      if [ -z "$DOWNLOAD_PREFIX" ]; then
        echo "未检测到可用镜像代理，是否仍尝试使用首选代理 ${PROXIES[0]} ?"
        read -rp "(y/N) " yn2
        if [[ "${yn2}" =~ ^[Yy]$ ]]; then
          DOWNLOAD_PREFIX="${PROXIES[0]}"
        fi
      fi
    else
      DOWNLOAD_PREFIX=""
      echo "将不使用镜像，直接从 GitHub 下载（可能较慢/失败）。"
    fi
  else
    # 非中国大陆，直接跳过，无需询问
    DOWNLOAD_PREFIX=""
  fi

  if [ -n "$DOWNLOAD_PREFIX" ]; then
    echo "注意：使用第三方镜像可能会将下载请求路由到该服务，请在受信任环境使用。"
  fi

  export DOWNLOAD_PREFIX
  return 0
}


  # ---------- 1) 若 API 已可达，则认为已安装并退出 ----------
  local existing_code
  existing_code=$(_get_api_code)
  if [ "$existing_code" = "200" ]; then
    # 打印人类可读状态（若用户已有 check_gost_api_status 函数，调用它）
    if declare -f check_gost_api_status >/dev/null 2>&1; then
      check_gost_api_status
    else
      echo "API 状态：✅ GOST API 已开放 (200)"
    fi
    echo "检测到 GOST API 已可用，跳过安装。"
    return 0
  fi

  echo "开始安装 GOST（因 API 当前不可用）..."
  # 2) 安装缺失依赖（仅安装缺失项）
  ensure_dependencies "$SUDO" || true

  # 3) 查找 GitHub Release 的 asset（latest）
  local UNAME_M ARCH_LABEL latest_json api_url asset_url tag_name
  UNAME_M=$(uname -m 2>/dev/null || echo "x86_64")
  case "$UNAME_M" in
    x86_64|amd64) ARCH_LABEL="linux_amd64" ;;
    aarch64|arm64) ARCH_LABEL="linux_arm64" ;;
    armv7*|armv6*) ARCH_LABEL="linux_armv7" ;;
    *) ARCH_LABEL="linux_amd64" ;;
  esac

  api_url="https://api.github.com/repos/go-gost/gost/releases/latest"
  latest_json=$(curl -fsSL "${api_url}" 2>/dev/null || "")
  if [ -z "$latest_json" ]; then
    echo "错误：无法从 GitHub API 获取 release 信息（网络或被限流）。"
    return 1
  fi

  tag_name=$(echo "$latest_json" | jq -r '.tag_name // .name // empty' 2>/dev/null || echo "")
  # 优先匹配架构
  asset_url=$(echo "$latest_json" | jq -r --arg arch "${ARCH_LABEL}" '.assets[]?.browser_download_url | select(test($arch))' 2>/dev/null | head -n1 || echo "")
  # 回退匹配 linux_amd64
  if [ -z "$asset_url" ]; then
    asset_url=$(echo "$latest_json" | jq -r '.assets[]?.browser_download_url | select(test("linux_amd64"))' 2>/dev/null | head -n1 || echo "")
  fi

  if [ -z "$asset_url" ]; then
    echo "错误：未在 release 中找到适合的 linux tarball（asset）。请手动下载并安装。"
    return 2
  fi

  echo "发现 release: ${tag_name:-<unknown>}"
  echo "asset url: ${asset_url}"

  # 4) 决定是否使用 GitHub 镜像（会设置 DOWNLOAD_PREFIX）
  decide_github_proxy_for_cn

  # 5) 下载：优先使用 DOWNLOAD_PREFIX（若为空则直接下载 asset_url）
  local tmpdir gost_candidate dest cfg download_url
  tmpdir=$(mktemp -d /tmp/gost_install.XXXXXX)
  trap 'rm -rf "$tmpdir" >/dev/null 2>&1 || true' EXIT
  cd "$tmpdir" || return 3

  # prepare download urls to try: prefixed first (if any), then direct
  download_url=""
  if [ -n "${DOWNLOAD_PREFIX:-}" ]; then
    download_url="${DOWNLOAD_PREFIX}${asset_url}"
  else
    download_url="${asset_url}"
  fi

  echo "下载中（尝试）: ${download_url}"
  if ! curl -fsSL -o gost_release.tar.gz "${download_url}"; then
    echo "警告：使用首选方式下载失败： ${download_url}"
    # 如果使用了代理，回退到直连尝试一次
    if [ -n "${DOWNLOAD_PREFIX:-}" ]; then
      echo "回退到直连下载（不使用镜像）: ${asset_url}"
      if ! curl -fsSL -o gost_release.tar.gz "${asset_url}"; then
        echo "错误：直连下载也失败，安装终止。"
        rm -rf "$tmpdir" || true
        return 4
      fi
    else
      echo "错误：下载失败，安装终止。"
      rm -rf "$tmpdir" || true
      return 4
    fi
  fi

  # 6) 解压并查找 gost 可执行
  if ! tar -xzf gost_release.tar.gz; then
    echo "错误：解压归档失败。"
    rm -rf "$tmpdir" || true
    return 5
  fi

  gost_candidate=$(find . -type f -name 'gost' -perm /111 -print -quit || true)
  [ -z "$gost_candidate" ] && gost_candidate=$(find . -type f -name 'gost' -print -quit || true)
  if [ -z "$gost_candidate" ]; then
    echo "错误：未在解压内容中找到 gost 可执行文件。"
    rm -rf "$tmpdir" || true
    return 6
  fi

  # 7) 安装到 /usr/local/bin/gost
  dest="/usr/local/bin/gost"
  echo "安装 gost 到 ${dest} ..."
  $SUDO install -m 0755 "$gost_candidate" "$dest" || { echo "错误：install 到 ${dest} 失败"; rm -rf "$tmpdir" || true; return 7; }
  $SUDO chmod +x "$dest" || true

  # 8) 写入最小 config.json（备份原文件）
  cfg="${CONFIG_FILE:-/etc/gost/config.json}"
  $SUDO mkdir -p "$(dirname "$cfg")"
  if [ -f "$cfg" ]; then
    $SUDO cp -a "$cfg" "${cfg}.backup.$(date +%Y%m%d_%H%M%S)" || true
  fi
  cat > "${tmpdir}/config.json" <<'JSON'
{
  "api": {
    "addr": "127.0.0.1:18080"
  },
  "services": []
}
JSON
  $SUDO mv -f "${tmpdir}/config.json" "${cfg}"
  $SUDO chmod 0644 "${cfg}" || true

  # 9) systemd 单元
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    local unit="/etc/systemd/system/gost.service"
    echo "创建/更新 systemd 单元 ${unit} ..."
    $SUDO tee "${unit}" >/dev/null <<EOF
[Unit]
Description=gost proxy
After=network.target

[Service]
Type=simple
ExecStart=${dest} -C ${cfg}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now gost.service || true
    # restart to ensure latest binary/config applied
    $SUDO systemctl restart gost.service >/dev/null 2>&1 || $SUDO service gost restart >/dev/null 2>&1 || true

    # 短暂等待再检测
    sleep 2

    local api_code
    api_code=$(_get_api_code)
    # 打印友好状态（优先调用用户自定义函数）
    if declare -f check_gost_api_status >/dev/null 2>&1; then
      check_gost_api_status
    else
      if [ "$api_code" = "200" ]; then
        echo "API 状态：✅ 正常连接"
      else
        echo "API 状态：❌ 无法访问（返回码 ${api_code}）"
      fi
    fi

    if [ "$api_code" = "200" ]; then
      echo "安装并启动成功：GOST API 已可用 (HTTP 200)."
      rm -rf "$tmpdir" || true
      trap - EXIT
      return 0
    else
      echo "警告：GOST 启动后 API 仍不可用（HTTP ${api_code}）。请用 'systemctl status gost' 与 'journalctl -u gost' 排查。"
      rm -rf "$tmpdir" || true
      trap - EXIT
      return 8
    fi
  else
    echo "未检测到 systemd，已安装二进制并写入配置 ${cfg}。请手动后台运行："
    echo "  sudo nohup ${dest} -C ${cfg} >/var/log/gost.log 2>&1 &"
    # 打印状态供参考
    if declare -f check_gost_api_status >/dev/null 2>&1; then
      check_gost_api_status
    fi
    rm -rf "$tmpdir" || true
    trap - EXIT
    return 0
  fi
}






# ========== 保存配置到文件（JSON 版，保留 services[].status） ==========
save_config_to_file() {
  local cfg="${CONFIG_FILE}"
  local config_data tmp jq_ok

  # 从 API 拉取完整配置
  config_data=$(api_get_raw "/config")
  if [ -z "$(echo -n "${config_data}" | tr -d ' \t\r\n')" ]; then
    echo "错误：无法从 API 获取配置（空响应）。" >&2
    return 1
  fi

  # 验证是不是合法 JSON
  if ! echo "${config_data}" | jq empty >/dev/null 2>&1; then
    echo "错误：从 API 获取的内容不是有效 JSON；未保存。" >&2
    printf "%s\n" "${config_data}" > "${cfg}.raw.$(date +%s)" 2>/dev/null || true
    echo "原始响应已另存为 ${cfg}.raw.TIMESTAMP（用于调试）" >&2
    return 2
  fi

  # 确保目录存在
  mkdir -p "$(dirname "${cfg}")" 2>/dev/null || true

  tmp="$(mktemp "${cfg}.tmp.XXXXXX")" || tmp="/tmp/gost_config_tmp.$$"

  # 若有 jq 则做漂亮的格式化输出，否则直接写入
  if command -v jq >/dev/null 2>&1; then
    echo "${config_data}" | jq '.' > "${tmp}" 2>/dev/null || {
      echo "错误：jq 格式化失败，未保存。" >&2
      rm -f "${tmp}" 2>/dev/null || true
      return 3
    }
  else
    printf "%s\n" "${config_data}" > "${tmp}" || {
      echo "错误：写入临时文件失败。" >&2
      rm -f "${tmp}" 2>/dev/null || true
      return 4
    }
  fi

  # 原子替换目标文件（安静）
  if ! mv -f "${tmp}" "${cfg}" 2>/dev/null; then
    echo "错误：无法移动临时文件到 ${cfg}（权限不足？）" >&2
    rm -f "${tmp}" 2>/dev/null || true
    return 5
  fi

  # 静默成功返回
  return 0
}





# ========== 修复后的列表展示函数 ==========
list_transfers_table() {
  # 固定列宽（Realm 风格）
  local WIDTH_IDX=5
  local WIDTH_LOCAL=25
  local WIDTH_REMOTE=40
  local WIDTH_NAME=25

  _trim() { echo -n "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

  echo
  echo "                   当前 GOST 转发规则                   "
  printf "%-5s| %-25s| %-40s| %-25s\n" "序号" "本地地址:端口" "目标地址:端口" "转发名称"
  local sep_len=$((WIDTH_IDX + WIDTH_LOCAL + WIDTH_REMOTE + WIDTH_NAME + 9))
  printf '%*s\n' "$sep_len" '' | tr ' ' '-'

  # 拉取并规范 JSON（兼容多种返回形态）
  local raw list_json
  raw=$(api_get_raw "/config/services")

  if [ -z "$(echo "$raw" | tr -d ' \n\r')" ]; then
    echo "没有转发（空响应）"
    return
  fi

  # 解析可能的封装：data.list / list / array / single object / null
  if echo "$raw" | jq -e 'has("data") and (.data|has("list"))' >/dev/null 2>&1; then
    list_json=$(echo "$raw" | jq -c '.data.list' 2>/dev/null)
  elif echo "$raw" | jq -e 'has("list")' >/dev/null 2>&1; then
    list_json=$(echo "$raw" | jq -c '.list' 2>/dev/null)
  else
    # try raw type
    local typ
    typ=$(echo "$raw" | jq -r 'type' 2>/dev/null || echo "invalid")
    if [ "$typ" = "array" ]; then
      list_json="$raw"
    elif [ "$typ" = "object" ]; then
      # wrap single object into array
      list_json=$(echo "[$raw]")
    else
      # unknown or null
      list_json="null"
    fi
  fi

  # robust判空：如果 list_json 为 null 或 空数组 -> 直接返回
  # 兼容 jq 可能报错的情况，用一个安全的 count 计算
  local count
  count=$(echo "$list_json" | jq -r 'if .==null then 0 elif type=="array" then length elif type=="object" then 1 else 0 end' 2>/dev/null || echo 0)

  if [ "$count" -eq 0 ]; then
    echo "当前无转发规则。"
    return
  fi

  # 生成 TSV：name, local addr, remote addr
  local tsv
  tsv=$(echo "$list_json" | jq -r '
    .[] |
    (
      (.name // "unnamed") as $name |
      (.addr // "-") as $local |
      ((.forwarder.nodes[0].addr // .chain.nodes[0].addr // .nodes[0].addr // "-")) as $remote |
      [$name, $local, $remote] | @tsv
    )
  ' 2>/dev/null)

  # 如果 tsv 为空（保险判断），则说明没有实际条目
  if [ -z "$(echo "$tsv" | tr -d ' \n\r')" ]; then
    echo "当前无转发规则。"
    return
  fi

  # 合并 -tcp/-udp，输出：idx \t local \t remote \t basename
  local agg
  agg=$(echo "$tsv" | awk -F'\t' '
  {
    name=$1; local=$2; remote=$3
    base=name; sub(/-tcp$/,"",base); sub(/-udp$/,"",base)
    if (!(base in seen)) {
      seen[base]=1; order[++n]=base
      locals[base]=local
      remotes[base]=remote
    }
  }
  END {
    for (i=1;i<=n;i++) printf("%d\t%s\t%s\t%s\n", i, locals[order[i]], remotes[order[i]], order[i])
  }')

  # 再次保险：如果 agg 为空，提示无条目
  if [ -z "$(echo "$agg" | tr -d ' \n\r')" ]; then
    echo "当前无转发规则。"
    return
  fi

  # 打印行（Realm 风格固定宽度）
  local idx local remote name
  while IFS=$'\t' read -r idx local remote name; do
    idx="$(_trim "$idx")"
    local="$(_trim "$local")"
    remote="$(_trim "$remote")"
    name="$(_trim "$name")"
    printf "%-5s| %-25s| %-40s| %-25s\n" "$idx" "$local" "$remote" "$name"
  done <<<"$agg"

  printf '%*s\n' "$sep_len" '' | tr ' ' '-'
  echo
  echo "总计: $(echo "$agg" | wc -l) 条转发"
  echo
}
# ========== 添加转发（TCP+UDP），并带上 metadata ==========
add_forward_combined() {
  echo "添加转发（同时创建 TCP + UDP）"
  read -e -rp "本地监听端口或地址 (例: 1111 / :1111 / 127.0.0.1:1111): " laddr_raw
  read -e -rp "目标地址 (例: 192.168.1.100:8080): " raddr
  read -e -rp "转发名称 (例: test): " base

  if [ -z "$laddr_raw" ] || [ -z "$raddr" ]; then
    echo "输入不能为空"
    pause
    return
  fi

  # 地址规范化
  local laddr
  if echo "$laddr_raw" | grep -Eq '^[0-9]+$'; then
    laddr="[::]:${laddr_raw}"
  elif echo "$laddr_raw" | grep -Eq '^:[0-9]+$'; then
    laddr="[::]${laddr_raw}"
  else
    laddr="$laddr_raw"
  fi

  [ -z "$base" ] && base="forward-$(date +%s)"
  local name_tcp="${base}-tcp"
  local name_udp="${base}-udp"

  # metadata 固定配置（自动启用统计）
  local enable_stats=true
  local observer_period="5s"
  local observer_reset=false


  # build payloads（注意：listener.metadata for udp includes requested fields）
  local payload_tcp payload_udp
  payload_tcp=$(cat <<JSON
{
  "name": "${name_tcp}",
  "addr": "${laddr}",
  "handler": { "type": "tcp" },
  "listener": { "type": "tcp" },
  "forwarder": { "nodes": [ { "addr": "${raddr}", "network": "tcp" } ] },
  "metadata": {
    "enableStats": ${enable_stats},
    "observer.period": "${observer_period}",
    "observer.resetTraffic": ${observer_reset}
  }
}
JSON
)

  payload_udp=$(cat <<JSON
{
  "name": "${name_udp}",
  "addr": "${laddr}",
  "handler": { "type": "udp" },
  "listener": {
    "type": "udp",
    "metadata": {
      "backlog": "128",
      "keepalive": true,
      "readBufferSize": "212992",
      "readQueueSize": "1000",
      "ttl": "30s",
      "relay": "udp"
    }
  },
  "forwarder": { "nodes": [ { "addr": "${raddr}", "network": "udp" } ] },
  "metadata": {
    "enableStats": ${enable_stats},
    "observer.period": "${observer_period}",
    "observer.resetTraffic": ${observer_reset}
  }
}
JSON
)

  echo
  echo "创建 TCP 转发: ${name_tcp} -> ${laddr} -> ${raddr}"

  local resp_tcp body_tcp code_tcp
  resp_tcp=$(api_post_raw "/config/services" "${payload_tcp}")
  body_tcp=$(echo "${resp_tcp}" | sed '$d')
  code_tcp=$(echo "${resp_tcp}" | tail -n1)

  echo "创建 UDP 转发: ${name_udp} -> ${laddr} -> ${raddr}"

  local resp_udp body_udp code_udp
  resp_udp=$(api_post_raw "/config/services" "${payload_udp}")
  body_udp=$(echo "${resp_udp}" | sed '$d')
  code_udp=$(echo "${resp_udp}" | tail -n1)

  # 提取 msg（如果需要判断）
  _extract_msg() {
    local body="$1"
    if command -v jq >/dev/null 2>&1; then
      echo "$body" | jq -r '.msg // empty' 2>/dev/null || echo ""
    else
      echo "$body" | sed -n 's/.*"msg"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || echo ""
    fi
  }
  msg_tcp=$(_extract_msg "$body_tcp")
  msg_udp=$(_extract_msg "$body_udp")

  # ======= 更鲁棒的成功判定与回滚逻辑 =======
  _is_success() {
    local code="$1"; local body="$2"

    # 如果有 2xx 状态码，先认为成功（多数情况下足够）
    if [ -n "$code" ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
      # 如果安装了 jq，优先用它检查返回体中明确的错误/成功字段
      if command -v jq >/dev/null 2>&1; then
        # 当 body 是合法 json 时，若存在 "code" 且不为 0 则视为失败；若 msg == "OK" 或 code == 0 则视为成功
        if echo "$body" | jq -e '(.code? // 0) == 0 or (.msg? == "OK")' >/dev/null 2>&1; then
          return 0
        else
          # 否则仍把 2xx 当作成功（兼容一些返回格式），但保留可能的失败判定
          return 0
        fi
      else
        # 无 jq 时做简单的文本判断：如果包含 "msg":"OK" 且不包含明显的 error/code 非0，则认为成功
        if echo "$body" | grep -qi '"msg"[[:space:]]*:[[:space:]]*"OK"' && ! echo "$body" | grep -qiE '"code"[[:space:]]*:[[:space:]]*[1-9]'; then
          return 0
        fi
        # 无法确认时，仍把 2xx 当作成功
        return 0
      fi
    fi

    # 非 2xx 一律视为失败（可以根据需要进一步解析 body 获取更详细错误）
    return 1
  }

  # 使用上面的判断函数设置标志
  tcp_ok=1; udp_ok=1
  if _is_success "$code_tcp" "$body_tcp"; then tcp_ok=0; else tcp_ok=1; fi
  if _is_success "$code_udp" "$body_udp"; then udp_ok=0; else udp_ok=1; fi

  # 自动回滚：如果一方成功另一方失败，则删除已成功的一方（quiet），并给出简短提示
  if [ "$tcp_ok" -eq 0 ] && [ "$udp_ok" -ne 0 ]; then
    echo "注意：TCP 已创建，但 UDP 创建失败，正在回滚 TCP 服务 (${name_tcp}) ..."
    api_delete_raw "/config/services/${name_tcp}" >/dev/null 2>&1 || true
    echo "已回滚 TCP 服务：${name_tcp}。请检查端口或目标并重试。"
    pause
    return
  fi

  if [ "$udp_ok" -eq 0 ] && [ "$tcp_ok" -ne 0 ]; then
    echo "注意：UDP 已创建，但 TCP 创建失败，正在回滚 UDP 服务 (${name_udp}) ..."
    api_delete_raw "/config/services/${name_udp}" >/dev/null 2>&1 || true
    echo "已回滚 UDP 服务：${name_udp}。请检查端口或目标并重试。"
    pause
    return
  fi


  if [ "$tcp_ok" -eq 0 ] && [ "$udp_ok" -eq 0 ]; then
    echo "转发创建完成。"
    # 保存配置
    if save_config_to_file; then
      echo "配置已持久化到 ${CONFIG_FILE}"
    else
      echo "警告：配置保存失败，重启后转发可能丢失"
    fi
    pause
    return
  fi

  echo "创建结果："
  printf "  TCP -> HTTP: %s, msg: %s\n" "$code_tcp" "${msg_tcp:-<no msg>}"
  printf "  UDP -> HTTP: %s, msg: %s\n" "$code_udp" "${msg_udp:-<no msg>}"

  # 回滚逻辑（若一方成功另一方失败）
  if [ "$tcp_ok" -eq 0 ] && [ "$udp_ok" -ne 0 ]; then
    echo "注意：TCP 创建成功但 UDP 创建失败，正在回滚 TCP (${name_tcp}) ..."
    api_delete_raw "/config/services/${name_tcp}" >/dev/null
    echo "已回滚 TCP 服务。请检查端口设置后重试。"
    pause
    return
  fi
  if [ "$udp_ok" -eq 0 ] && [ "$tcp_ok" -ne 0 ]; then
    echo "注意：UDP 创建成功但 TCP 创建失败，正在回滚 UDP (${name_udp}) ..."
    api_delete_raw "/config/services/${name_udp}" >/dev/null
    echo "已回滚 UDP 服务。请检查端口设置后重试。"
    pause
    return
  fi

  echo "创建失败：TCP/UDP 均未成功创建。请检查返回信息并重试。"
  pause
}


add_relay_forward() {
  echo "创建 relay_forward 服务（同时创建 TCP & UDP service，并创建 chain）"
  while true; do
    read -rp "本地转发端口 (例: 44111 / :44111 / 0.0.0.0:44111) : " laddr_raw
    if [ -n "$laddr_raw" ]; then
      break
    else
      echo "❌ 转发端口不能为空，请重新输入。"
    fi
  done

  while true; do
    read -rp "转发目标(落地)地址与端口（例如 192.168.1.1:44111）: " target_addr
    if [ -n "$target_addr" ]; then
      break
    else
      echo "❌ 目标地址不能为空，请重新输入。"
    fi
  done

  while true; do
    read -rp "Relay服务地址与端口 (例如 192.168.100.1:12345): " relay_addr
    if [ -n "$relay_addr" ]; then
      break
    else
      echo "❌ 中转机地址与端口不能为空，请重新输入。"
    fi
  done

  echo
  echo "请选择中转机的加密方式（dialer 传输类型）:"
  echo " 1) tcp   （不加密，默认）"
  echo " 2) tls   （TCP + TLS）"
  echo " 3) ws    （WebSocket）"
  echo " 4) wss   （加密 WebSocket）"
  echo " 5) kcp   （基于 UDP 的快速传输）"
  read -rp "输入选项 [1-5] (默认 1): " dial_opt
  case "$dial_opt" in
    2) DIAL_TYPE="tcp"; DIAL_TLS="yes"  ;;
    3) DIAL_TYPE="ws";  DIAL_TLS="no"   ;;
    4) DIAL_TYPE="ws";  DIAL_TLS="yes"  ;;
    5) DIAL_TYPE="kcp"; DIAL_TLS="no"   ;;
    *) DIAL_TYPE="tcp"; DIAL_TLS="no"   ;;
  esac

  # ===== 中转 auth（username/password） =====
  # 默认生成 uuid（如果系统有 uuidgen 使用它，否则用 openssl/sha1 fallback）
  gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
      uuidgen
    elif command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 16
    else
      echo "$(date +%s)-$RANDOM" | sha1sum | awk '{print $1}'
    fi
  }

  default_auth=$(gen_uuid)

  echo
  read -rp "中转机是否启用了认证？(Y/n): " yn_auth
  yn_auth=${yn_auth:-Y}
  if [[ "$yn_auth" =~ ^[Yy]$ ]]; then
    auth_enabled="yes"
    echo
    echo "中转认证 (connector.auth)：请输入中转机使用的用户名/密码。"
    while true; do
      read -rp "中转认证用户名: " auth_user
      if [ -n "$auth_user" ]; then
        break
      else
        echo "❌ 中转认证用户名不能为空，请重新输入。"
      fi
    done

    read -rp "中转认证密码 (回车与用户名相同): " auth_pass
    if [ -z "$auth_pass" ]; then
      auth_pass="$auth_user"
    fi
  else
    echo "已选择：中转机未启用认证，将不生成 connector.auth 字段。"
    auth_enabled="no"
    auth_user=""
    auth_pass=""
  fi


  # 规范本地监听 addr（如果只给端口则加冒号）
  _norm_addr_simple() {
    local x="$1"
    x="$(echo -n "$x" | tr -d ' \t\r\n')"
    if [ -z "$x" ]; then
      printf ""
      return
    fi
    if echo "$x" | grep -Eq '^[0-9]+$'; then
      printf "[::]:%s" "$x"
    else
      printf "%s" "$x"
    fi
  }
  laddr=$(_norm_addr_simple "$laddr_raw")

  # 基础名称与 chain/node 命名
  ts=$(date +%s)
  svc_base_default="relay_forward_${ts}"
  read -rp "基础服务名称 (默认 ${svc_base_default}): " svc_base
  svc_base=${svc_base:-$svc_base_default}
  svc_tcp="${svc_base}-tcp"
  svc_udp="${svc_base}-udp"
  chain_name="${svc_base}-chain-${ts}"
  hop_name="${svc_base}-hop-0"
  node_name="${svc_base}-node-0"

  # 解析 relay_addr（去掉 query，处理 path）
  addr_with_possible_path="$(echo "${relay_addr}" | sed -E 's/\?.*//')"
  if [ "$DIAL_TYPE" = "ws" ]; then
    addr_part="${addr_with_possible_path}"
  else
    addr_part="$(echo "${addr_with_possible_path}" | sed -E 's#/.*$##')"
  fi
  addr_part="$(echo -n "${addr_part}" | sed -E 's/^[[:space:]]+//' | sed -E 's/[[:space:]]+$//' | sed -E 's#^/*##')"

  if [ -z "$addr_part" ]; then
    echo "无法解析中转地址（addr）。请检查输入：${relay_addr}"
    pause
    return
  fi

  host_only="$(echo "${addr_part}" | sed -E 's/:.*$//')"

  # ===== 构造 connector.auth 块 =====
  connector_auth_json=$(cat <<JSON
{
  "auth": {
    "username": "${auth_user}",
    "password": "${auth_pass}"
  }
}
JSON
)

  # 构造 node json（connector + dialer），将 connector 包含 auth
  if [ "$DIAL_TYPE" = "kcp" ]; then
    node_json=$(cat <<JSON
{
  "name": "${node_name}",
  "addr": "${addr_part}",
  "connector": { "type": "relay", "auth": { "username": "${auth_user}", "password": "${auth_pass}" } },
  "dialer": { "type": "kcp" }
}
JSON
)
  elif [ "$DIAL_TYPE" = "ws" ]; then
    if [ "$DIAL_TLS" = "yes" ]; then
      node_json=$(cat <<JSON
{
  "name": "${node_name}",
  "addr": "${addr_part}",
  "connector": { "type": "relay", "auth": { "username": "${auth_user}", "password": "${auth_pass}" } },
  "dialer": { "type": "ws", "tls": { "serverName": "${host_only}", "secure": true } }
}
JSON
)
    else
      node_json=$(cat <<JSON
{
  "name": "${node_name}",
  "addr": "${addr_part}",
  "connector": { "type": "relay", "auth": { "username": "${auth_user}", "password": "${auth_pass}" } },
  "dialer": { "type": "ws" }
}
JSON
)
    fi
  else
    # tcp (可能带 tls)
    if [ "$DIAL_TLS" = "yes" ]; then
      node_json=$(cat <<JSON
{
  "name": "${node_name}",
  "addr": "${addr_part}",
  "connector": { "type": "relay", "auth": { "username": "${auth_user}", "password": "${auth_pass}" } },
  "dialer": { "type": "tcp", "tls": { "serverName": "${host_only}", "secure": true } }
}
JSON
)
    else
      node_json=$(cat <<JSON
{
  "name": "${node_name}",
  "addr": "${addr_part}",
  "connector": { "type": "relay", "auth": { "username": "${auth_user}", "password": "${auth_pass}" } },
  "dialer": { "type": "tcp" }
}
JSON
)
    fi
  fi

  # chain payload (single hop single node)
  chain_payload=$(cat <<JSON
{
  "name": "${chain_name}",
  "hops": [
    {
      "name": "${hop_name}",
      "nodes": [
        ${node_json}
      ]
    }
  ]
}
JSON
)

  # service payloads (tcp + udp) — 包含 metadata enableStats 等
  metadata_block=$(cat <<JSON
{
  "enableStats": true,
  "observer.period": "5s",
  "observer.resetTraffic": false
}
JSON
)

  payload_tcp=$(cat <<JSON
{
  "name": "${svc_tcp}",
  "addr": "${laddr}",
  "handler": {
    "type": "tcp",
    "chain": "${chain_name}"
  },
  "listener": {
    "type": "tcp"
  },
  "forwarder": {
    "nodes": [
      {
        "name": "target-0",
        "addr": "${target_addr}"
      }
    ]
  },
  "metadata": ${metadata_block}
}
JSON
)

  payload_udp=$(cat <<JSON
{
  "name": "${svc_udp}",
  "addr": "${laddr}",
  "handler": {
    "type": "udp",
    "chain": "${chain_name}"
  },
  "listener": {
    "type": "udp",
    "metadata": {
      "backlog": "128",
      "keepalive": true,
      "readBufferSize": "212992",
      "readQueueSize": "1000",
      "ttl": "30s",
      "relay": "udp"
    }
  },
  "forwarder": {
    "nodes": [
      {
        "name": "target-0",
        "addr": "${target_addr}",
        "network": "udp"
      }
    ]
  },
  "metadata": ${metadata_block}
}
JSON
)

  echo
  echo "准备创建 chain (${chain_name}) 并引用到 service (${svc_tcp} & ${svc_udp}) ..."
  # 1) POST chain
  resp_chain=$(api_post_raw "/config/chains" "${chain_payload}")
  body_chain=$(echo "${resp_chain}" | sed '$d')
  code_chain=$(echo "${resp_chain}" | tail -n1)

  # fallback merge function (requires jq)
  _merge_into_config_and_put() {
    if ! command -v jq >/dev/null 2>&1; then
      echo "错误：fallback 合并需要 jq，但系统未安装 jq。无法合并。"
      return 1
    fi
    cfg=$(api_get_raw "/config")
    if [ -z "$(echo -n "${cfg}" | tr -d ' \t\r\n')" ]; then
      echo "错误：读取 /config 失败或为空，无法合并。"
      return 2
    fi
    tmp=$(mktemp) || tmp="/tmp/gost_config_tmp.$$"
    tmp2=$(mktemp) || tmp2="/tmp/gost_config_tmp2.$$"
    echo "${cfg}" | jq --argjson chain "${chain_payload}" '
      if has("chains") then
        .chains |= (if . == null then [ $chain ] else (. + [ $chain ]) end)
      else
        . + { "chains": [ $chain ] }
      end
    ' >"${tmp}" 2>/dev/null || { rm -f "${tmp}"; echo "jq 合并 chain 失败"; return 3; }
    echo "$(cat "${tmp}")" | jq --argjson svc "${payload_tcp}" '
      if has("services") then
        .services |= (if . == null then [ $svc ] else (. + [ $svc ]) end)
      else
        . + { "services": [ $svc ] }
      end
    ' >"${tmp2}" 2>/dev/null || { rm -f "${tmp}" "${tmp2}"; echo "jq 合并 tcp service 失败"; return 4; }

    # append udp as well
    mv "${tmp2}" "${tmp}"
    echo "$(cat "${tmp}")" | jq --argjson svc "${payload_udp}" '
      if has("services") then
        .services |= (if . == null then [ $svc ] else (. + [ $svc ]) end)
      else
        . + { "services": [ $svc ] }
      end
    ' >"${tmp2}" 2>/dev/null || { rm -f "${tmp}" "${tmp2}"; echo "jq 合并 udp service 失败"; return 4; }

    put_resp=$(api_put_raw "/config" "$(cat "${tmp2}")")
    put_body=$(echo "${put_resp}" | sed '$d' 2>/dev/null)
    put_code=$(echo "${put_resp}" | tail -n1 2>/dev/null)
    rm -f "${tmp}" "${tmp2}"
    if echo "${put_code}" | grep -Eq '^[0-9]+$' && [ "${put_code}" -ge 200 ] 2>/dev/null && [ "${put_code}" -lt 300 ] 2>/dev/null; then
      return 0
    else
      echo "PUT /config 返回 ${put_code}"
      echo "${put_body}" | _pp
      return 5
    fi
  }

  # Check chain creation success
  if echo "${code_chain}" | grep -Eq '^[0-9]+$' && [ "${code_chain}" -ge 200 ] 2>/dev/null && [ "${code_chain}" -lt 300 ] 2>/dev/null; then
    echo "chain 创建成功 (POST /config/chains). 继续创建 TCP & UDP service..."

    # create TCP
    resp_tcp=$(api_post_raw "/config/services" "${payload_tcp}")
    body_tcp=$(echo "${resp_tcp}" | sed '$d')
    code_tcp=$(echo "${resp_tcp}" | tail -n1)

    # create UDP
    resp_udp=$(api_post_raw "/config/services" "${payload_udp}")
    body_udp=$(echo "${resp_udp}" | sed '$d')
    code_udp=$(echo "${resp_udp}" | tail -n1)

    # helper check
    _is_ok_code() { local c=$1; if echo "$c" | grep -Eq '^[0-9]+$' && [ "$c" -ge 200 ] 2>/dev/null && [ "$c" -lt 300 ] 2>/dev/null; then return 0; fi; return 1; }

    _is_ok_code "$code_tcp" && tcp_ok=1 || tcp_ok=0
    _is_ok_code "$code_udp" && udp_ok=1 || udp_ok=0

    if [ "$tcp_ok" -eq 1 ] && [ "$udp_ok" -eq 1 ]; then
      echo "✅ 已同时创建 ${svc_tcp} 与 ${svc_udp}."
      echo "中转认证 (username/password):"
      printf "  %s\n" "${auth_user}"
      printf "  %s\n" "${auth_pass}"
      # save config silently if function exists
      if declare -f save_config_to_file >/dev/null 2>&1; then
        save_config_to_file >/dev/null 2>&1 || true
      fi
      pause
      return 0
    fi

    # rollback logic
    if [ "$tcp_ok" -eq 1 ] && [ "$udp_ok" -eq 0 ]; then
      echo "注意：TCP 创建成功但 UDP 创建失败 -> 回滚 TCP (${svc_tcp}) ..."
      api_delete_raw "/config/services/${svc_tcp}" >/dev/null 2>&1 || true
      echo "请检查 UDP 错误信息:"
      echo "HTTP ${code_udp}"
      echo "${body_udp}" | _pp
      # 尝试删除 chain（若由我们新建且未被其它服务引用，尽力删除）
      api_delete_raw "/config/chains/${chain_name}" >/dev/null 2>&1 || true
      pause
      return 2
    fi

    if [ "$udp_ok" -eq 1 ] && [ "$tcp_ok" -eq 0 ]; then
      echo "注意：UDP 创建成功但 TCP 创建失败 -> 回滚 UDP (${svc_udp}) ..."
      api_delete_raw "/config/services/${svc_udp}" >/dev/null 2>&1 || true
      echo "请检查 TCP 错误信息:"
      echo "HTTP ${code_tcp}"
      echo "${body_tcp}" | _pp
      api_delete_raw "/config/chains/${chain_name}" >/dev/null 2>&1 || true
      pause
      return 2
    fi

    # both failed
    echo "创建失败：TCP/UDP 均未成功创建。"
    echo "TCP 返回: HTTP ${code_tcp}"
    echo "${body_tcp}" | _pp
    echo "UDP 返回: HTTP ${code_udp}"
    echo "${body_udp}" | _pp
    api_delete_raw "/config/chains/${chain_name}" >/dev/null 2>&1 || true
    pause
    return 3

  else
    # fallback: merge into /config using jq
    echo "POST /config/chains 返回 ${code_chain}, 尝试通过 PUT /config 合并 chain + services（需要 jq）..."
    if _merge_into_config_and_put; then
      echo "✅ 通过 PUT /config 合并 chain + service 成功。"
      if declare -f save_config_to_file >/dev/null 2>&1; then
        save_config_to_file >/dev/null 2>&1 || true
      fi
      pause
      return 0
    else
      echo "❌ 合并失败。POST /config/chains 返回："
      echo "HTTP ${code_chain}"
      echo "${body_chain}" | _pp
      pause
      return 4
    fi
  fi
}

add_relay_listen() {
  echo "创建 Relay 监听服务"
  read -rp "本地监听端口或地址 (12345 / :12345 / 127.0.0.1:12345) 默认 12345: " laddr_raw
  laddr_raw=${laddr_raw:-12345}

  ts=$(date +%s)
  relay_listen_base="relay_listen_${ts}"

  read -rp "基础服务名称 (默认 ${relay_listen_base}): " base
  base=${svc_base:-$relay_listen_base}

  echo
  echo "请选择加密类型:"
  echo "  1) tls   （推荐）"
  echo "  2) ws    （WebSocket）"
  echo "  3) wss   （加密 WebSocket）"
  echo "  4) kcp   （基于 UDP 的快速传输）"
  echo "  5) tcp   （不加密，不推荐）"  
  read -rp "输入选项 [1-5] (默认 1): " opt
  case "$opt" in
    2) LISTENER_TYPE="ws" ;;
    3) LISTENER_TYPE="wss" ;;
    4) LISTENER_TYPE="kcp" ;;
    5) LISTENER_TYPE="tcp" ;;
    *) LISTENER_TYPE="tls" ;;
  esac

  # ---- 规范化本地地址 ----
  _normalize_local_addr_for_input() {
    local input="$1"
    input="$(echo -n "$input" | tr -d ' \t\r\n')"
    if [ -z "$input" ]; then
      echo ""
      return
    fi
    if echo "$input" | grep -Eq '^[0-9]+$'; then
      echo "[::]:${input}"
    else
      echo "$input"
    fi
  }
  laddr=$(_normalize_local_addr_for_input "$laddr_raw")
  
  # ---- 生成 UUID（user 与 password 相同）----
  gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
      uuidgen
    elif [ -r /proc/sys/kernel/random/uuid ]; then
      cat /proc/sys/kernel/random/uuid
    elif command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 8
    else
      echo "$(date +%s)-$$"
    fi
  }
  UUID_VAL=$(gen_uuid)
  USERNAME="${UUID_VAL}"
  PASSWORD="${UUID_VAL}"

  # ---- 构造 payload ----
  NAME="${base}"
  ADDR="${laddr}"

  payload=$(cat <<JSON
{
  "name": "${NAME}",
  "addr": "${ADDR}",
  "handler": {
    "type": "relay",
    "auth": {
      "username": "${USERNAME}",
      "password": "${PASSWORD}"
    }
  },
  "listener": {
    "type": "${LISTENER_TYPE}"
  }
}
JSON
)

  echo
  echo "创建监听服务：relay+${LISTENER_TYPE}://${ADDR} ..."
  resp=$(api_post_raw "/config/services" "${payload}")
  body=$(echo "${resp}" | sed '$d')
  code=$(echo "${resp}" | tail -n1)

  if echo "$code" | grep -Eq '^[0-9]+$'; then
    code_num=$code
  else
    code_num=0
  fi

  if [ "$code_num" -ge 200 ] 2>/dev/null && [ "$code_num" -lt 300 ] 2>/dev/null; then
    echo "✅ 创建成功: ${NAME}"
    echo "认证信息："
    echo "  用户名 / 密码: ${UUID_VAL}"
    echo "  监听类型: ${LISTENER_TYPE}"
    echo "请保存好上述 UUID，用于客户端认证连接。"

    if declare -f save_config_to_file >/dev/null 2>&1; then
      if save_config_to_file >/dev/null 2>&1; then
        echo "配置已保存到 ${CONFIG_FILE}"
      else
        echo "⚠️ 保存配置失败，请手动保存配置。"
      fi
    fi
  else
    echo "❌ 创建失败 (HTTP ${code_num}):"
    echo "${body}" | _pp
  fi

  pause
}





# ========== 显示可用的基础转发名（去掉 -tcp/-udp） ==========
show_available_bases() {
  # 从 /config/services 获取所有 name，去掉 -tcp/-udp 后缀并去重
  local raw names
  raw=$(api_get_raw "/config/services")
  if [ -z "$(echo "$raw" | tr -d ' \n\r')" ]; then
    echo "无转发（空）"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "未安装 jq，无法列出基础名。原始 names:"
    echo "$raw" | _pp
    return
  fi

  # 尝试各种封装形式
  names=$(echo "$raw" | jq -r '
    if type=="object" then
      if has("data") and (.data|has("list")) then .data.list else (if has("list") then .list else [.] end) end
    else .
    end
    | .[]?.name // empty
    | sub("\\-tcp$";"")
    | sub("\\-udp$";"")
  ' 2>/dev/null | sort -u)

  if [ -z "$(echo "$names" | tr -d ' \n\r')" ]; then
    echo "未在 response 中找到服务名称。"
    return
  fi

  echo "当前可用的基础转发名:"
  echo "$names" | nl -w2 -s'. ' 
}
# ========== 删除转发（支持删除与基础名相关的所有 services & 关联 chains，包括 relay_forward / relay_listen） ==========
delete_forward() {
  # 从 API 获取服务数据（兼容 data.list 为 null）
  local raw
  raw=$(api_get_raw "/config/services" 2>/dev/null)

  if [ -z "$(echo -n "$raw" | tr -d ' \t\r\n')" ]; then
    echo "未能从 API 获取服务列表或当前无服务。"
    pause
    return
  fi

  # 提取去重的基础名列表（把 -tcp/-udp 后缀去掉）
  local names_list
  names_list=$(echo "$raw" | jq -r '
    if type=="object" then
      if has("data") and (.data|has("list")) then .data.list
      elif has("list") then .list
      else [.] end
    else .
    end
    | .[]?.name // empty
    | sub("\\-tcp$";"")
    | sub("\\-udp$";"")
  ' 2>/dev/null | sort -u | awk "NF")

  # 读取到数组
  local -a BASES=()
  while IFS= read -r line; do
    [ -n "$line" ] && BASES+=("$line")
  done <<< "$names_list"

  if [ "${#BASES[@]}" -eq 0 ]; then
    echo "当前没有可删除的转发（或 API 返回格式异常）。"
    pause
    return
  fi

  # 列出可删除的基础名并让用户选择（编号或直接输入）
  echo "可删除的基础转发名："
  local i
  for i in "${!BASES[@]}"; do
    printf "  %2d) %s\n" "$((i+1))" "${BASES[$i]}"
  done
  echo
  read -e -rp "输入编号 或 直接输入基础名 / 完整 service 名称 (回车取消): " choice
  if [ -z "$choice" ]; then
    echo "已取消。"
    pause
    return
  fi

  local svc_base=""
  if echo "$choice" | grep -Eq '^[0-9]+$'; then
    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#BASES[@]}" ] 2>/dev/null; then
      svc_base="${BASES[$((choice-1))]}"
    else
      echo "编号超出范围"
      pause
      return
    fi
  else
    svc_base="$choice"
  fi

  # 从 /config/services 再次拉取所有服务名，找出包含 svc_base 的那些服务（更宽松匹配）
  local all_services
  all_services=$(echo "$raw" | jq -r '
    if type=="object" then
      if has("data") and (.data|has("list")) then .data.list
      elif has("list") then .list
      else [.] end
    else .
    end
    | .[]?.name // empty
  ' 2>/dev/null)

  # 过滤出要删除的服务：包含基础名或等于 base-tcp/base-udp
  local -a to_delete=()
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    if [ "$s" = "${svc_base}-tcp" ] || [ "$s" = "${svc_base}-udp" ] || echo "$s" | grep -Fq "$svc_base"; then
      to_delete+=("$s")
    fi
  done <<< "$all_services"

  # 如果用户输入了完整 service 名称（包含 -tcp/-udp）且上面没匹配到，直接尝试删除该名称
  if [ "${#to_delete[@]}" -eq 0 ]; then
    if echo "$svc_base" | grep -Eq '\-tcp$|\-udp$'; then
      to_delete+=("$svc_base")
    fi
  fi

  if [ "${#to_delete[@]}" -eq 0 ]; then
    echo "未找到与 '${svc_base}' 匹配的任何 service。"
    pause
    return
  fi

  # 显示将删除的服务（简洁）
  echo
  echo "将删除以下 service（直接执行，无需二次确认）："
  for s in "${to_delete[@]}"; do
    echo "  - $s"
  done
  echo

  # 执行删除并汇总结果（静默输出 API body，但不交互）
  local -a deleted=() failed=() notfound=()
  for s in "${to_delete[@]}"; do
    resp=$(api_delete_raw "/config/services/${s}" 2>/dev/null)
    body=$(echo "${resp}" | sed '$d' 2>/dev/null)
    code=$(echo "${resp}" | tail -n1 2>/dev/null)

    if echo "$code" | grep -Eq '^[0-9]+$' && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
      deleted+=("$s")
    else
      # 判定 404 / not found
      if [ "$code" = "404" ] || echo "$body" | grep -qi 'not found\|404'; then
        notfound+=("$s")
      else
        failed+=("${s}|${code}|${body}")
      fi
    fi
  done

  # 尝试删除可能关联的 chains：获取 /config/chains（兼容性处理）
  local chain_raw chains
  chain_raw=$(api_get_raw "/config/chains" 2>/dev/null || true)
  if [ -n "$(echo -n "$chain_raw" | tr -d ' \t\r\n')" ]; then
    chains=$(echo "$chain_raw" | jq -r '
      if type=="object" then
        if has("data") and (.data|has("list")) then .data.list
        elif has("list") then .list
        else [.] end
      else .
      end
      | .[]?.name // empty
    ' 2>/dev/null)
  else
    chains=""
  fi

  # 找到包含 svc_base 的 chain 名称并删除
  local -a deleted_chains=() failed_chains=() notfound_chains=()
  if [ -n "$(echo -n "$chains" | tr -d ' \t\r\n')" ]; then
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      if echo "$cname" | grep -Fq "$svc_base"; then
        respc=$(api_delete_raw "/config/chains/${cname}" 2>/dev/null)
        bodyc=$(echo "${respc}" | sed '$d' 2>/dev/null)
        codec=$(echo "${respc}" | tail -n1 2>/dev/null)
        if echo "$codec" | grep -Eq '^[0-9]+$' && [ "$codec" -ge 200 ] 2>/dev/null && [ "$codec" -lt 300 ] 2>/dev/null; then
          deleted_chains+=("$cname")
        else
          if [ "$codec" = "404" ] || echo "$bodyc" | grep -qi 'not found\|404'; then
            notfound_chains+=("$cname")
          else
            failed_chains+=("${cname}|${codec}|${bodyc}")
          fi
        fi
      fi
    done <<< "$chains"
  fi

  # 最后尝试持久化配置（静默）
  save_config_to_file >/dev/null 2>&1 || true

  # 输出简洁汇总
  echo
  echo "删除操作完成："
  if [ "${#deleted[@]}" -gt 0 ]; then
    echo " 已删除 services (${#deleted[@]}):"
    for x in "${deleted[@]}"; do echo "  - $x"; done
  fi
  if [ "${#notfound[@]}" -gt 0 ]; then
    echo " 未找到/已不存在 (${#notfound[@]}):"
    for x in "${notfound[@]}"; do echo "  - $x"; done
  fi
  if [ "${#failed[@]}" -gt 0 ]; then
    echo " 删除失败 (${#failed[@]}):"
    for x in "${failed[@]}"; do
      svc="${x%%|*}"; rest="${x#*|}"
      code="${rest%%|*}"; body="${rest#*|}"
      echo "  - ${svc} (HTTP ${code})"
      echo "    返回: $(echo "$body" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    done
  fi

  if [ "${#deleted_chains[@]}" -gt 0 ]; then
    echo " 已删除 chains (${#deleted_chains[@]}):"
    for x in "${deleted_chains[@]}"; do echo "  - $x"; done
  fi
  if [ "${#notfound_chains[@]}" -gt 0 ]; then
    echo " chains 未找到/已不存在 (${#notfound_chains[@]}):"
    for x in "${notfound_chains[@]}"; do echo "  - $x"; done
  fi
  if [ "${#failed_chains[@]}" -gt 0 ]; then
    echo " chains 删除失败 (${#failed_chains[@]}):"
    for x in "${failed_chains[@]}"; do
      cname="${x%%|*}"; rest="${x#*|}"; code="${rest%%|*}"; body="${rest#*|}"
      echo "  - ${cname} (HTTP ${code})"
      echo "    返回: $(echo "$body" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    done
  fi

  echo
  pause
}



# ========== fetch_stats: 从 /config 读取并显示 stats（更可靠） ==========
# usage: fetch_stats [SERVICE_NAME]
fetch_stats() {
  local api="${API_URL}"
  local name="${1:-}"

  # Ensure jq exists for pretty output
  if ! command -v jq >/dev/null 2>&1; then
    echo "请先安装 jq：apt install -y jq"
    return 1
  fi

  # Trigger a full config fetch to encourage gost to refresh/aggregate runtime status
  curl -s "${api}/config" >/dev/null

  if [ -n "${name}" ]; then
    # single service: print stats only (JSON)
    curl -s "${api}/config" \
      | jq -r --arg NAME "${name}" '.services[]? | select(.name==$NAME) | .status.stats // .stats // {}'
    return
  fi

  # no name: list all services' stats as a readable table
  curl -s "${api}/config" \
    | jq -r '.services[]? | {name: .name, stats: (.status.stats // .stats // null)}' \
    | jq -s '.' \
    | jq -r '
      (["NAME","TOTAL","CUR","IN","OUT"] | @tsv),
      (.[] | [
        .name,
        ((.stats.totalConns // 0) | tostring),
        ((.stats.currentConns // 0) | tostring),
        ((.stats.inputBytes // 0) | tostring),
        ((.stats.outputBytes // 0) | tostring)
      ] | @tsv)
    ' | awk -F'\t' '
      BEGIN {
        printf "%-30s %8s %8s %12s %12s\n", "NAME", "TOTAL", "CUR", "IN", "OUT"
        print "----------------------------------------------------------------------------------------"
      }
      function human(bytes,   v) {
        v = bytes + 0
        if (v >= 1073741824) return sprintf("%.2fG", v/1073741824)
        if (v >= 1048576) return sprintf("%.2fM", v/1048576)
        if (v >= 1024) return sprintf("%.2fK", v/1024)
        return sprintf("%dB", v)
      }
      {
        name=$1
        total=$2
        cur=$3
        inb=$4
        outb=$5
        printf "%-30s %8s %8s %12s %12s\n", name, total, cur, human(inb), human(outb)
      }'
}


# ===== reload_config: 热重载 /config/reload（兼容返回格式） =====
reload_config() {
  echo "正在热重载 GOST 配置 (/config/reload) ..."
  local resp code msg

  resp=$(curl -s -X POST "${API_URL}/config/reload")
  # 尝试用 jq 提取更友好
  if command -v jq >/dev/null 2>&1; then
    code=$(echo "$resp" | jq -r '.code // empty' 2>/dev/null || echo "")
    msg=$(echo "$resp" | jq -r '.msg // empty' 2>/dev/null || echo "")
  else
    code=""
    msg=$(echo "$resp" | sed -n '1p')
  fi

  if [ "$code" = "0" ] || [ "$msg" = "OK" ] || [ "$msg" = "reload success" ] || [ -z "$resp" ]; then
    echo "✅ 配置已成功重载。"
  else
    echo "⚠️ 重载可能失败，返回："
    echo "$resp"
  fi
  pause
}
# ===== restart_service_single_v2: 使用脚本的 API helper (DELETE -> POST) 重启单个 service =====
restart_service_single_v2() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "服务名不能为空"
    return 1
  fi

  local resp tmp payload create_resp code msg

  # 1) 获取当前服务配置（优先 .data）
  resp=$(api_get_raw "/config/services/${name}")
  if [ -z "$(echo -n "$resp" | tr -d ' \t\r\n')" ]; then
    echo "⚠️ 无法获取 ${name} 的配置（空响应），请检查服务名是否正确。"
    return 2
  fi

  # 2) 提取 payload（.data 或 整体），并写入临时文件/变量
  if command -v jq >/dev/null 2>&1; then
    payload=$(echo "$resp" | jq -c '.data // .' 2>/dev/null) || payload=""
  else
    # 无 jq 时尽量从 resp 中去掉外层 {"data":...}，退回原文
    if echo "$resp" | grep -q '"data"'; then
      payload=$(echo "$resp" | sed -n 's/^[[:space:]]*{[[:space:]]*"data"[[:space:]]*:[[:space:]]*//;p' | sed '$s/}$//')
      payload="{${payload}}"
    else
      payload="$resp"
    fi
  fi

  # 3) payload 非空校验
  if [ -z "$(echo -n "$payload" | tr -d ' \t\r\n')" ]; then
    echo "⚠️ 无法从 GET /config/services/${name} 提取到有效 payload，取消重启。"
    return 3
  fi

  # 4) 确保 payload 中包含 name 字段（避免 40001）
  if command -v jq >/dev/null 2>&1; then
    if ! echo "$payload" | jq -e '.name' >/dev/null 2>&1; then
      payload=$(echo "$payload" | jq --arg n "$name" '.name = $n')
    fi
  else
    if ! echo "$payload" | grep -q '"name"'; then
      # 在对象开头注入 name（谨慎处理）
      payload=$(echo "$payload" | sed "s/^{/{\"name\":\"${name}\",/")
    fi
  fi

  # 5) 调用 DELETE（静默），然后短等
  api_delete_raw "/config/services/${name}" >/dev/null 2>&1 || true
  sleep 0.35

  # 6) 重新创建（使用脚本提供的 api_post_raw 函数，它会返回 body + http_code）
  create_resp=$(api_post_raw "/config/services" "${payload}")
  # api_post_raw 返回结构：...body...\nHTTPCODE
  code=$(echo "${create_resp}" | tail -n1)
  msg=$(echo "${create_resp}" | sed '$d' | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # 7) 判断创建结果（优先使用 jq 判断）
  if command -v jq >/dev/null 2>&1; then
    # 解析 body JSON（可能为空），并判断 .code==0 或 .msg=="OK" 或 http code 2xx
    body_json=$(echo "${create_resp}" | sed '$d')
    ok=1
    if [ -n "$code" ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
      ok=0
    fi
    # 进一步检查 body 中明确的错误/成功字段
    if [ "$ok" -ne 0 ]; then
      if echo "$body_json" | jq -e '(.code? // 0) == 0 or (.msg? == "OK")' >/dev/null 2>&1; then
        ok=0
      fi
    fi

    if [ "$ok" -eq 0 ]; then
      echo "✅ ${name} 重启成功。"
      return 0
    else
      echo "❌ ${name} 重启失败（POST 返回 http ${code}），服务器响应："
      echo "$body_json" | _pp
      return 4
    fi
  else
    # 无 jq：用 http code 做粗略判断，若不是 2xx 则打印返回体
    if [ -n "$code" ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
      echo "✅ ${name} 重启成功（基于 HTTP 状态判断）。"
      return 0
    else
      echo "❌ ${name} 重启失败（HTTP ${code}），服务器返回："
      echo "${msg}"
      return 4
    fi
  fi
}
# ===== restart_forward_v3: 支持按序号或按名称重启（同时重启 base-tcp 与 base-udp） =====
restart_forward_v3() {
  # 从 API 拉出所有 service name，去掉 -tcp/-udp 后缀并保持首次出现顺序
  local raw names name_list
  raw=$(api_get_raw "/config/services")
  if [ -z "$(echo -n "$raw" | tr -d ' \t\r\n')" ]; then
    echo "⚠️ 无法获取服务列表（API 返回为空）"
    return 1
  fi

  # 解析出基础名列表（优先使用 jq；没有 jq 则降级）
  if command -v jq >/dev/null 2>&1; then
    # 保持首次出现顺序并去重（awk seen）
    name_list=$(echo "$raw" \
      | jq -r '
          if type=="object" then
            if has("data") and (.data|has("list")) then .data.list
            elif has("list") then .list
            else [.] end
          else
            .
          end
        | .[]?.name // empty
        | sub("-tcp$";"")
        | sub("-udp$";"")
      ' 2>/dev/null | awk '!seen[$0]++')
  else
    # 无 jq：用 grep/sed 尽量提取 name 字段（不保证完美）
    name_list=$(echo "$raw" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/-tcp$//' | sed 's/-udp$//' | awk '!seen[$0]++')
  fi

  # 检查是否有可用基础名
  if [ -z "$(echo -n "$name_list" | tr -d ' \t\r\n')" ]; then
    echo "当前没有可用的基础转发名。"
    return 2
  fi

  # 打印带编号的列表
  echo "可重启的基础转发名："
  local i=1
  # 将 name_list 读到数组以便通过索引取值
  IFS=$'\n' read -rd '' -a bases <<<"$name_list" || true
  for name in "${bases[@]}"; do
    printf "  %2d) %s\n" "$i" "$name"
    i=$((i+1))
  done

  echo
  read -rp "请输入序号 或 基础名 / 完整 service 名称 (回车取消): " sel
  if [ -z "$sel" ]; then
    echo "已取消。"
    return 0
  fi

  # 判断是数字序号还是名称
  if echo "$sel" | grep -Eq '^[0-9]+$'; then
    local idx=$((sel)) # 1-based
    if [ "$idx" -le 0 ] || [ "$idx" -gt "${#bases[@]}" ]; then
      echo "无效序号：${sel}"
      return 3
    fi
    # 选中对应基础名
    local base="${bases[$((idx-1))]}"
    echo "已选择：#${idx} -> ${base}"
    # 依次重启 base-tcp 和 base-udp（如果存在）
    restart_service_single_v2 "${base}-tcp" || echo "⚠️ ${base}-tcp 重启失败或不存在"
    restart_service_single_v2 "${base}-udp" || echo "⚠️ ${base}-udp 重启失败或不存在"
    echo "操作完成：已尝试重启 ${base} 的 tcp/udp 服务。"
    return 0
  fi

  # 如果用户输入包含 -tcp 或 -udp，则视为完整 service 名称，仅重启该项
  if echo "$sel" | grep -Eq '\-tcp$|\-udp$'; then
    restart_service_single_v2 "$sel"
    return $?
  fi

  # 否则当作基础名处理：尝试重启 base-tcp 与 base-udp
  local base="$sel"
  echo "开始重启：${base}-tcp 与 ${base}-udp ..."
  restart_service_single_v2 "${base}-tcp" || echo "⚠️ ${base}-tcp 重启失败或不存在"
  restart_service_single_v2 "${base}-udp" || echo "⚠️ ${base}-udp 重启失败或不存在"
  echo "操作完成：已尝试重启 ${base} 的 tcp/udp 服务。"
  return 0
}


# ===== reload_or_restart_menu: 子菜单入口 =====
reload_or_restart_menu() {
  while true; do
    cat <<EOF

----------------------------
1) 热重载 GOST 配置（重启所有服务，POST /config/reload）
2) 重启单个转发（按序号或按名称重启同名 tcp & udp）
0) 返回主菜单
----------------------------
EOF
    read -rp "选择 (0-2): " opt
    case "$opt" in
      1)
        # 提示是否先保存配置到文件，避免 reload 丢失 API 临时改动
        read -rp "是否先保存当前配置到 ${CONFIG_FILE} 以避免 reload 丢失 API 临时配置？ (Y/n): " yn
        if [ -z "$yn" ] || [[ "$yn" =~ ^[Yy] ]]; then
          if save_config_to_file; then
            echo "已保存配置文件。"
          else
            echo "警告：保存配置失败，reload 会按当前 GOST 内存/文件行为执行。"
          fi
        fi
        reload_config
        ;;
      2)
        # 进入重启列表逻辑
        restart_forward_v3
        pause
        ;;
      0) break ;;
      *)
        echo "无效选择"
        ;;
    esac
  done
}

# ===== 卸载 gost（简洁版：stop -> 删除 service -> 删除文件与目录） =====
uninstall_gost() {
  echo "🚨 开始卸载 gost ..."

  # 停止并禁用 systemd 服务
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop gost.service >/dev/null 2>&1 || true
    systemctl disable gost.service >/dev/null 2>&1 || true
  fi

  # 删除 systemd unit 文件
  rm -f /etc/systemd/system/gost.service /lib/systemd/system/gost.service >/dev/null 2>&1
  systemctl daemon-reload >/dev/null 2>&1 || true

  # 删除 gost 可执行文件
  rm -f /usr/local/bin/gost >/dev/null 2>&1 || true

  # 删除配置文件夹
  rm -rf /etc/gost >/dev/null 2>&1 || true

  echo "✅ gost 已成功卸载。"
  echo "已执行：停止服务 + 删除服务文件 + 删除 /usr/local/bin/gost 与 /etc/gost"
  exit 0
}


# ========== 添加转发 子菜单（普通 / 加密） ==========
add_forward_menu() {
  while true; do
    cat <<EOF

----------------------------
  添加转发（子菜单）
----------------------------
 1) 普通转发（同时创建 TCP + UDP）
 2) Relay转发（前置+中转机）
 0) 返回上级菜单
----------------------------
EOF
    read -rp "请选择 (0-2): " subch
    case "$subch" in
      1)
        add_forward_combined
        break
        ;;
      2)
        relay_menu
        break
        ;;
      0)
        return 0
        ;;
      *)
        echo "无效选择，请输入 0-2。"
        ;;
    esac
  done
}

relay_menu() {
  while true; do
    cat <<EOF

Relay 转发（前置 + 中转机）
 1) 配置-F relay 入口机 
 2) 配置-L relay 中转机
 3) 检查/列出已配置的 Relay 转发
 0) 返回
EOF
    read -rp "请选择: " rch
    case "$rch" in
      1)
        add_relay_forward  # 你可以实现该函数（我可以直接写）
        ;;
      2)
        add_relay_listen
        ;;
      3)
        # list_transfers_table 或自定义过滤 .handler.type == "relay"
        echo "列出所有 handler.type == relay 的服务:"
        api_get "/config/services" | jq '.data.services[]? | select(.handler.type=="relay") | {name,addr,listener,handler,forwarder}'
        pause
        ;;
      0) break ;;
      *) echo "无效选择" ;;
    esac
  done
}




# ========== 主菜单 ==========
while true; do
  API_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${API_URL}/config" 2>/dev/null || echo "000")
  case "$API_CODE" in
    200) API_STATUS_TXT="✅ GOST API 已开放 (200)";;
    401) API_STATUS_TXT="⚠️ 需要认证 (401)";;
    404) API_STATUS_TXT="⚠️ 返回 404（接口路径可能不同）";;
    000) API_STATUS_TXT="❌ 无法连接到 GOST API";;
    *)   API_STATUS_TXT="❌ 无法访问 GOST API (code=${API_CODE})";;
  esac

  cat <<EOF

══════════════════════════════════════════════════════════
           GOST API 管理工具 V1.1 2025/11/7
仓库地址：https://github.com/lengmo23/Gostapi_forward
══════════════════════════════════════════════════════════
$(get_gost_status)

$(check_gost_api_status)
API: ${API_URL}
认证: $( [ -n "${API_AUTH}" ] && echo "已设置" || echo "未设置" )
══════════════════════════════════════════════════════════
1) 安装 GOST
2) 卸载 GOST
══════════════════════════════════════════════════════════
3) 添加转发
4) 列出所有转发
5) 删除转发服务
6) 重载服务
══════════════════════════════════════════════════════════
7) 手动保存配置到文件
8) 获取完整配置
9) 查看实时流量统计
══════════════════════════════════════════════════════════
0) 退出脚本
EOF
  read -e -rp "请选择: " ch
  case "$ch" in
    1) install_gost_and_setup ;;
    2) uninstall_gost ;; 
    3) add_forward_menu ;;
    4) list_transfers_table ;;
    5) delete_forward ;;
    6) reload_or_restart_menu ;;
    7) save_config_to_file; pause ;;
    8) echo "GET /config"; api_get "/config"; pause ;;
    9) fetch_stats ;;
    0) echo "退出"; exit 0 ;;
    *) echo "无效选择";;
  esac
done
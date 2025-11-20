#!/usr/bin/env bash 
# gost-api-cli.sh — GOST API 管理脚本
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
      read -e -rp "是否使用镜像下载二进制以加速? (Y/n) " yn
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
          read -e -rp "(y/N) " yn2
          if [[ "${yn2}" =~ ^[Yy]$ ]]; then
            DOWNLOAD_PREFIX="${PROXIES[0]}"
          fi
        fi
      else
        DOWNLOAD_PREFIX=""
        echo "将不使用镜像，直接从 GitHub 下载（可能较慢/失败）。"
      fi
    else
      # 非中国大陆，直接跳过，无需询问（按你的要求）
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
    if declare -f check_gost_api_status >/dev/null 2>&1; then
      check_gost_api_status
    else
      echo "API 状态：✅ GOST API 已开放 (200)"
    fi
    echo "检测到 GOST API 已可用，跳过安装。"
    return 0
  fi

  echo "开始安装 GOST（因 API 当前不可用）..."
  # 2) 安装缺失依赖（仅安装缺失项），保证 curl/jq 可用后再检测 IP
  ensure_dependencies "$SUDO" || true

  # 2.5) 立即决定是否使用镜像（如果在 CN 会提示并设置 DOWNLOAD_PREFIX）
  decide_github_proxy_for_cn

  # 3) 查找 GitHub Release 的 asset（latest）
  local UNAME_M ARCH_LABEL latest_json api_url asset_url tag_name try_api_url
  UNAME_M=$(uname -m 2>/dev/null || echo "x86_64")
  case "$UNAME_M" in
    x86_64|amd64) ARCH_LABEL="linux_amd64" ;;
    aarch64|arm64) ARCH_LABEL="linux_arm64" ;;
    armv7*|armv6*) ARCH_LABEL="linux_armv7" ;;
    *) ARCH_LABEL="linux_amd64" ;;
  esac

  api_url="https://api.github.com/repos/go-gost/gost/releases/latest"

  # 如果已选用 DOWNLOAD_PREFIX，则优先尝试通过镜像去请求 release JSON（部分镜像支持）
  latest_json=""
  if [ -n "${DOWNLOAD_PREFIX:-}" ]; then
    try_api_url="${DOWNLOAD_PREFIX}api.github.com/repos/go-gost/gost/releases/latest"
    latest_json=$(curl -fsSL "${try_api_url}" 2>/dev/null || echo "")
    if [ -n "$latest_json" ]; then
      echo "已通过镜像获取 release 信息（${try_api_url}）"
    else
      # 回退到官方 API
      latest_json=$(curl -fsSL "${api_url}" 2>/dev/null || echo "")
      echo "镜像获取 release 失败，回退到官方 API 获取 release 信息。"
    fi
  else
    latest_json=$(curl -fsSL "${api_url}" 2>/dev/null || echo "")
  fi

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

  # 5) 下载：优先使用 DOWNLOAD_PREFIX（若为空则直接下载 asset_url）
  local tmpdir gost_candidate dest cfg download_url direct_url
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
  direct_url="${asset_url}"

  echo "下载中（尝试）: ${download_url}"
  if ! curl -fsSL -o gost_release.tar.gz "${download_url}"; then
    echo "警告：使用首选方式下载失败： ${download_url}"
    # 如果使用了代理，回退到直连尝试一次
    if [ -n "${DOWNLOAD_PREFIX:-}" ]; then
      echo "回退到直连下载（不使用镜像）: ${direct_url}"
      if ! curl -fsSL -o gost_release.tar.gz "${direct_url}"; then
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
    $SUDO systemctl restart gost.service >/dev/null 2>&1 || $SUDO service gost restart >/dev/null 2>&1 || true

    sleep 2

    local api_code
    api_code=$(_get_api_code)
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




# ========== 列表展示函数 (修复版V3：强制显示所有分类) ==========
list_transfers_table() {
  # 固定列宽
  local WIDTH_IDX=5
  local WIDTH_LOCAL=25
  local WIDTH_REMOTE=40
  local WIDTH_NAME=25
  local sep_len=$((WIDTH_IDX + WIDTH_LOCAL + WIDTH_REMOTE + WIDTH_NAME + 9))

  _trim() { echo -n "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
  _print_line() { printf '%*s\n' "$sep_len" '' | tr ' ' '-'; }
  
  echo
  echo "                    当前 GOST 服务列表                    "
  _print_line

  # 拉取 JSON
  local raw list_json
  raw=$(api_get_raw "/config/services" 2>/dev/null)

  # 预处理 JSON 数据
  if [ -z "$(echo -n "$raw" | tr -d ' \t\r\n')" ]; then
    list_json="[]"
  elif ! command -v jq >/dev/null 2>&1; then
    echo "未检测到 jq，无法解析表格。"
    return
  else
    # 兼容处理各种 API 返回格式
    if echo "$raw" | jq -e 'has("data") and (.data|has("list"))' >/dev/null 2>&1; then
      list_json=$(echo "$raw" | jq -c '.data.list' 2>/dev/null)
    elif echo "$raw" | jq -e 'has("list")' >/dev/null 2>&1; then
      list_json=$(echo "$raw" | jq -c '.list' 2>/dev/null)
    else
      local typ
      typ=$(echo "$raw" | jq -r 'type' 2>/dev/null || echo "invalid")
      if [ "$typ" = "array" ]; then list_json="$raw"; elif [ "$typ" = "object" ]; then list_json="[$raw]"; else list_json="[]"; fi
    fi
  fi

  # 解析并生成 TSV (Name, Local, Remote, Chain, HType)
  local tsv
  tsv=$(echo "$list_json" | jq -r '
    .[]? |
    (
      (.name // "") as $name |
      (.addr // "-") as $local |
      (if .forwarder and .forwarder.nodes and (.forwarder.nodes|length > 0) then .forwarder.nodes[0].addr else "" end) as $remote |
      (if .handler and .handler.chain then .handler.chain else "" end) as $chain |
      (if .handler and .handler.type then .handler.type else "tcp" end) as $htype |
      [$name, $local, ($remote//"-"), $chain, $htype] | @tsv
    )
  ' 2>/dev/null)

  # 如果没有任何服务
  if [ -z "$(echo -n "$tsv" | tr -d ' \t\r\n')" ]; then
    tsv=""
  fi

  # 使用 awk 处理分类，不直接打印，而是给每行加前缀 N|, R|, L|
  local merged
  merged=$(echo "$tsv" | awk -F'\t' '
  {
    full=$1; local=$2; remote=$3; chain=$4; htype=$5
    # 基础名合并 (去掉 -tcp/-udp)
    base=full; sub(/-tcp$/, "", base); sub(/-udp$/, "", base)
    
    if (!(base in seen)) {
      seen[base]=1
      order[++n]=base
      locals[base]=local
      remotes[base]=remote
      
      # === 分类判定 ===
      # L: Relay 监听 (Type=relay, 无 chain)
      if (htype == "relay" && chain == "") {
         types[base]="L"
         remotes[base]="(本机接收)" 
      } 
      # R: Relay 转发 (有 chain)
      else if (chain != "") {
         types[base]="R"
         if (remote == "-" || remote == "") remotes[base] = "Chain->" chain
      } 
      # N: 普通转发
      else {
         types[base]="N"
      }
    } else {
       # 修正: 如果同组中发现有 Chain，升级为 R
       if (chain != "" && types[base] == "N") types[base]="R"
    }
  }
  END {
    for (i=1;i<=n;i++) {
      b=order[i]
      printf("%s|%d|%s|%s|%s\n", types[b], i, b, locals[b], remotes[b])
    }
  }
  ')

  # 内部函数：打印表头
  _print_header() {
    local title="$1"
    echo
    printf "  %s\n" "$title"
    printf "%-5s| %-25s| %-40s| %-25s\n" "序号" "本地地址:端口" "目标地址:端口" "服务名称"
    _print_line
  }

  # 内部函数：打印空行
  _print_empty() {
    printf "%-4s| %-21s| %-34s| %-25s\n" " -" " (暂无)" " -" " -"
  }

  # === 1. 普通转发 (N) ===
  _print_header "1. 普通转发 (Port -> IP)"
  local count_n=0
  while IFS='|' read -r typ idx base local remote; do
    if [ "$typ" = "N" ]; then
      base="$(_trim "$base")"; local="$(_trim "$local")"; remote="$(_trim "$remote")"; idx="$(_trim "$idx")"
      printf "%-4s| %-19s| %-34s| %-25s\n" " $idx" "$local" "$remote" "$base"
      count_n=$((count_n+1))
    fi
  done <<<"$merged"
  [ "$count_n" -eq 0 ] && _print_empty

  # === 2. Relay 转发 (R) ===
  _print_header "2. Relay 转发 (Client -> Chain)"
  local count_r=0
  while IFS='|' read -r typ idx base local remote; do
    if [ "$typ" = "R" ]; then
      base="$(_trim "$base")"; local="$(_trim "$local")"; remote="$(_trim "$remote")"; idx="$(_trim "$idx")"
      printf "%-4s| %-19s| %-34s| %-25s\n" " $idx" "$local" "$remote" "$base"
      count_r=$((count_r+1))
    fi
  done <<<"$merged"
  [ "$count_r" -eq 0 ] && _print_empty

  # === 3. Relay 监听 (L) ===
  _print_header "3. Relay 监听 (服务端 -L)"
  local count_l=0
  while IFS='|' read -r typ idx base local remote; do
    if [ "$typ" = "L" ]; then
      base="$(_trim "$base")"; local="$(_trim "$local")"; remote="$(_trim "$remote")"; idx="$(_trim "$idx")"
      printf "%-4s| %-19s| %-38s| %-25s\n" " $idx" "$local" "$remote" "$base"
      count_l=$((count_l+1))
    fi
  done <<<"$merged"
  [ "$count_l" -eq 0 ] && _print_empty

  _print_line
  local total
  total=$(echo "$merged" | grep -cE "^[NRL]\|" || echo 0)
  echo
  echo "总计: ${total} 个服务组"
  echo
  read -n1 -r -s -p "按任意键返回主菜单..." && echo
}
# ========== 添加转发（TCP+UDP），并带上 metadata (带 LeastPing 跳转) ==========
add_forward() {
  echo "添加转发（同时创建 TCP + UDP）"
  read -e -rp "本地监听端口 (PORT / :PORT / 127.0.0.1:PORT): " laddr_raw
  read -e -rp "目标地址 (IP:PORT): " raddr

  if [ -z "$laddr_raw" ] || [ -z "$raddr" ]; then
    echo "输入不能为空"
    pause
    return
  fi

  # 1. 生成默认名称
  local default_base="forward-$(date +%s)"

  # 2. 询问名称（带默认值）
  read -e -rp "转发名称 (默认: ${default_base}): " base
  base=${base:-$default_base}

  # 3. 地址规范化 (GOST 需要的格式)
  local laddr
  if echo "$laddr_raw" | grep -Eq '^[0-9]+$'; then
    laddr="[::]:${laddr_raw}"
  elif echo "$laddr_raw" | grep -Eq '^:[0-9]+$'; then
    laddr="[::]${laddr_raw}"
  else
    laddr="$laddr_raw"
  fi

  # 4. 提取纯端口号 (LeastPing 需要的格式)
  local pure_port
  if echo "$laddr_raw" | grep -Eq '^[0-9]+$'; then
      pure_port="$laddr_raw"
  else
      pure_port="${laddr_raw##*:}"
  fi

  local name_tcp="${base}-tcp"
  local name_udp="${base}-udp"
  local enable_stats=true
  local observer_period="5s"
  local observer_reset=false

  # 构造 JSON payload
  local payload_tcp=$(cat <<JSON
{
  "name": "${name_tcp}",
  "addr": "${laddr}",
  "handler": { "type": "tcp" },
  "listener": { "type": "tcp" },
  "forwarder": { "nodes": [ { "addr": "${raddr}", "network": "tcp" } ] },
  "metadata": { "enableStats": ${enable_stats}, "observer.period": "${observer_period}", "observer.resetTraffic": ${observer_reset} }
}
JSON
)

  local payload_udp=$(cat <<JSON
{
  "name": "${name_udp}",
  "addr": "${laddr}",
  "handler": { "type": "udp" },
  "listener": {
    "type": "udp",
    "metadata": { "backlog": "128", "keepalive": true, "readBufferSize": "212992", "readQueueSize": "1000", "ttl": "30s", "relay": "udp" }
  },
  "forwarder": { "nodes": [ { "addr": "${raddr}", "network": "udp" } ] },
  "metadata": { "enableStats": ${enable_stats}, "observer.period": "${observer_period}", "observer.resetTraffic": ${observer_reset} }
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

  # 成功判定逻辑
  _is_success() {
    local code="$1"; local body="$2"
    if [ -n "$code" ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
       return 0
    fi
    return 1
  }

  tcp_ok=1; udp_ok=1
  if _is_success "$code_tcp" "$body_tcp"; then tcp_ok=0; fi
  if _is_success "$code_udp" "$body_udp"; then udp_ok=0; fi

  # 结果处理与回滚
  if [ "$tcp_ok" -eq 0 ] && [ "$udp_ok" -eq 0 ]; then
    echo "✅ 转发创建完成。"
    if save_config_to_file; then
      echo "配置已持久化到 ${CONFIG_FILE}"
    else
      echo "警告：配置保存失败"
    fi

    # === LeastPing 快捷入口 ===
    echo
    echo "----------------------------------------------------------------"
    read -e -rp "是否为此服务配置 LeastPing (自动切换最低延迟落地)? (y/N): " yn_lp
    if [[ "$yn_lp" =~ ^[Yy]$ ]]; then
       # 直接带参跳转，不再 pause
       least_ping_auto "$pure_port" "$raddr"
       return
    fi

    pause
    return
  fi

  # 处理失败情况
  echo "创建结果：TCP HTTP $code_tcp / UDP HTTP $code_udp"
  if [ "$tcp_ok" -eq 0 ] && [ "$udp_ok" -ne 0 ]; then
    echo "回滚 TCP..."
    api_delete_raw "/config/services/${name_tcp}" >/dev/null
  fi
  if [ "$udp_ok" -eq 0 ] && [ "$tcp_ok" -ne 0 ]; then
    echo "回滚 UDP..."
    api_delete_raw "/config/services/${name_udp}" >/dev/null
  fi
  echo "❌ 创建失败，已回滚。"
  pause
}

# ========== 创建 Relay Forward ==========
add_relay_forward() {
  echo "创建 Relay Forward (将本地流量转发给中转机)"
  echo "------------------------------------------------"

  # 1. 输入本地监听端口
  read -e -rp "本地监听端口或地址 (例: 44111 / :44111): " laddr_raw
  if [ -z "$laddr_raw" ]; then echo "端口不能为空"; pause; return; fi

  # 2. 输入最终落地目标
  read -e -rp "转发目标(落地)地址 (例: 1.1.1.1:80): " target_addr
  if [ -z "$target_addr" ]; then echo "目标不能为空"; pause; return; fi

  # 3. 检查并询问是否复用现有的 Chain
  local reuse_chain="false"
  local chain_name=""
  
  # 获取完整配置
  local raw_config
  raw_config=$(api_get_raw "/config" 2>/dev/null)
  
  # 解析 Chain 列表
  local chain_list
  if command -v jq >/dev/null 2>&1; then
      chain_list=$(echo "$raw_config" | jq -r '
        (.chains // .data.chains // []) | .[]? | 
        "\(.name)|\(.hops[0].nodes[0].addr // "unknown")"
      ' 2>/dev/null)
  else
      chain_list=""
  fi

  if [ -n "$(echo -n "$chain_list" | tr -d ' \t\r\n')" ]; then
      echo
      echo "🔍 发现已存在的转发链 (Relay Chains):"
      local i=1
      local -a chain_names
      local -a chain_addrs
      
      while IFS='|' read -r cname caddr; do
          if [ -n "$cname" ]; then
              echo -e "  $i) 名称: \033[32m${cname}\033[0m (中转机: ${caddr})"
              chain_names[$i]=$cname
              chain_addrs[$i]=$caddr
              i=$((i+1))
          fi
      done <<< "$chain_list"
      
      echo "  0) 不复用，创建新的中转配置"
      echo
      read -e -rp "是否复用已有链? 请输入序号 (默认 0): " ch_idx
      ch_idx=${ch_idx:-0}
      
      if [[ "$ch_idx" =~ ^[0-9]+$ ]] && [ "$ch_idx" -ge 1 ] && [ "$ch_idx" -lt "$i" ]; then
          chain_name="${chain_names[$ch_idx]}"
          echo "✅ 已选择复用链: ${chain_name}"
          reuse_chain="true"
      else
          echo "👉 选择创建新的中转配置。"
          reuse_chain="false"
      fi
  else
      echo "ℹ️  未发现可用的转发链，进入新建流程。"
      reuse_chain="false"
  fi

  # ==========================================
  # 分支 A: 创建新 Chain
  # ==========================================
  if [ "$reuse_chain" == "false" ]; then
      while true; do
        read -e -rp "Relay中转机地址 (例: 192.168.100.1:12345): " relay_addr
        if [ -n "$relay_addr" ]; then break; else echo "地址不能为空"; fi
      done

      echo
      echo "请选择中转机的加密方式:"
      echo " 1) tls    （默认）"
      echo " 2) ws     （WebSocket）"
      echo " 3) wss    （加密 WebSocket）"
      echo " 4) kcp    （UDP）"
      echo " 5) tcp    （无加密）"
      read -e -rp "输入选项 [1-5] (默认 1): " dial_opt
      case "$dial_opt" in
        2) DIAL_TYPE="ws";  DIAL_TLS="no"   ;;
        3) DIAL_TYPE="ws";  DIAL_TLS="yes"  ;;
        4) DIAL_TYPE="kcp"; DIAL_TLS="no"   ;;
        5) DIAL_TYPE="tcp"; DIAL_TLS="no"   ;;
        *) DIAL_TYPE="tls"; DIAL_TLS="yes"  ;;
      esac

      echo
      read -e -rp "中转机是否开启了认证? (Y/n): " yn_auth
      auth_enabled="false"
      auth_user=""
      auth_pass=""
      if [[ "${yn_auth:-Y}" =~ ^[Yy]$ ]]; then
        auth_enabled="true"
        read -e -rp "认证用户名: " auth_user
        read -e -rp "认证密码: " auth_pass
      fi

      ts=$(date +%s)
      svc_base_default="relay_forward_${ts}"
      
      # 1. 询问服务名
      read -e -rp "基础服务名称 (默认 ${svc_base_default}): " svc_base
      svc_base=${svc_base:-$svc_base_default}
      
      # 2. 自动生成 Chain 名
      chain_name="chain-${ts}"
      hop_name="hop-${ts}"
      node_name="node-${ts}"

      addr_with_possible_path="$(echo "${relay_addr}" | sed -E 's/\?.*//')"
      if [ "$DIAL_TYPE" = "ws" ] || [ "$DIAL_TYPE" = "wss" ]; then
        addr_part="${addr_with_possible_path}"
      else
        addr_part="$(echo "${addr_with_possible_path}" | sed -E 's#/.*$##')"
      fi
      host_only="$(echo "${addr_part}" | sed -E 's/:.*$//')"

      auth_part=""
      if [ "$auth_enabled" == "true" ]; then
          auth_part=", \"auth\": { \"username\": \"${auth_user}\", \"password\": \"${auth_pass}\" }"
      fi

      if [ "$DIAL_TYPE" = "tls" ]; then
          dialer_part=", \"dialer\": { \"type\": \"tls\", \"tls\": {\"serverName\": \"${host_only}\"} }"
      elif [ "$DIAL_TYPE" = "wss" ]; then
          dialer_part=", \"dialer\": { \"type\": \"ws\", \"tls\": {\"serverName\": \"${host_only}\"} }"
      elif [ "$DIAL_TYPE" = "ws" ]; then
          dialer_part=", \"dialer\": { \"type\": \"ws\" }"
      elif [ "$DIAL_TYPE" = "kcp" ]; then
          dialer_part=", \"dialer\": { \"type\": \"kcp\" }"
      else
          dialer_part=", \"dialer\": { \"type\": \"tcp\" }"
      fi

      node_json=$(cat <<JSON
{
  "name": "${node_name}",
  "addr": "${addr_part}",
  "connector": { "type": "relay" ${auth_part} }
  ${dialer_part}
}
JSON
)
      chain_payload=$(cat <<JSON
{
  "name": "${chain_name}",
  "hops": [ { "name": "${hop_name}", "nodes": [ ${node_json} ] } ]
}
JSON
)
      echo "正在创建新链: ${chain_name} ..."
      resp_chain=$(api_post_raw "/config/chains" "${chain_payload}")
      code_chain=$(echo "${resp_chain}" | tail -n1)
      
      if ! [[ "$code_chain" =~ 2[0-9][0-9] ]]; then
          echo "❌ 创建 Chain 失败 (HTTP $code_chain)"
          echo "${resp_chain}" | sed '$d'
          pause; return
      fi
      echo "✅ 链创建成功。"

  else
      # ==========================================
      # 分支 B: 复用 Chain
      # ==========================================
      ts=$(date +%s)
      svc_base_default="relay_forward_${ts}"
      
      # [关键修改] 这里也询问服务名称，并使用相同的默认前缀
      echo
      read -e -rp "基础服务名称 (默认 ${svc_base_default}): " svc_base
      svc_base=${svc_base:-$svc_base_default}
  fi

  # ==========================================
  # 通用部分: 创建 Service
  # ==========================================
  
  if echo "$laddr_raw" | grep -Eq '^[0-9]+$'; then laddr="[::]:${laddr_raw}"; else laddr="$laddr_raw"; fi
  
  svc_tcp="${svc_base}-tcp"
  svc_udp="${svc_base}-udp"
  metadata_block='{ "enableStats": true, "observer.period": "5s" }'

  payload_tcp=$(cat <<JSON
{
  "name": "${svc_tcp}",
  "addr": "${laddr}",
  "handler": { "type": "tcp", "chain": "${chain_name}" },
  "listener": { "type": "tcp" },
  "forwarder": { "nodes": [ { "name": "target", "addr": "${target_addr}" } ] },
  "metadata": ${metadata_block}
}
JSON
)
  payload_udp=$(cat <<JSON
{
  "name": "${svc_udp}",
  "addr": "${laddr}",
  "handler": { "type": "udp", "chain": "${chain_name}" },
  "listener": { "type": "udp", "metadata": { "ttl": "30s", "relay": "udp" } },
  "forwarder": { "nodes": [ { "addr": "${target_addr}", "network": "udp" } ] },
  "metadata": ${metadata_block}
}
JSON
)

  echo "正在创建服务 (绑定链: ${chain_name})..."
  
  resp_tcp=$(api_post_raw "/config/services" "${payload_tcp}")
  code_tcp=$(echo "${resp_tcp}" | tail -n1)
  
  resp_udp=$(api_post_raw "/config/services" "${payload_udp}")
  code_udp=$(echo "${resp_udp}" | tail -n1)

  tcp_ok=0; udp_ok=0
  if [[ "$code_tcp" =~ 2[0-9][0-9] ]]; then tcp_ok=1; fi
  if [[ "$code_udp" =~ 2[0-9][0-9] ]]; then udp_ok=1; fi

  if [ "$tcp_ok" -eq 1 ] && [ "$udp_ok" -eq 1 ]; then
      echo "✅ 服务创建成功！"
      echo "   TCP: ${svc_tcp} -> Chain: ${chain_name} -> ${target_addr}"
      echo "   UDP: ${svc_udp} -> Chain: ${chain_name} -> ${target_addr}"
      if declare -f save_config_to_file >/dev/null 2>&1; then
          save_config_to_file >/dev/null 2>&1
          echo "配置已保存。"
      fi
  else
      echo "❌ 创建部分失败: TCP=$code_tcp, UDP=$code_udp"
      if [ "$tcp_ok" -eq 1 ]; then api_delete_raw "/config/services/${svc_tcp}" >/dev/null; fi
      if [ "$udp_ok" -eq 1 ]; then api_delete_raw "/config/services/${svc_udp}" >/dev/null; fi
      echo "已尝试回滚服务。"
  fi

  pause
}

# ========== 创建 Relay 监听服务 (支持自定义认证) ==========
add_relay_listen() {
  echo "创建 Relay 监听服务 (服务端)"
  
  # 1. 输入端口
  read -e -rp "本地监听端口或地址 (12345 / :12345 / 127.0.0.1:12345) 默认 12345: " laddr_raw
  laddr_raw=${laddr_raw:-12345}

  ts=$(date +%s)
  relay_listen_base="relay_listen_${ts}"

  # 2. 输入服务名
  read -e -rp "基础服务名称 (默认 ${relay_listen_base}): " base
  base=${base:-$relay_listen_base}

  # 3. 选择加密类型
  echo
  echo "请选择加密类型:"
  echo "  1) tls    （推荐，默认）"
  echo "  2) ws     （WebSocket）"
  echo "  3) wss    （加密 WebSocket）"
  echo "  4) kcp    （基于 UDP 的快速传输）"
  echo "  5) tcp    （不加密，不推荐）"  
  read -e -rp "输入选项 [1-5] (默认 1): " opt
  case "$opt" in
    2) LISTENER_TYPE="ws" ;;
    3) LISTENER_TYPE="wss" ;;
    4) LISTENER_TYPE="kcp" ;;
    5) LISTENER_TYPE="tcp" ;;
    *) LISTENER_TYPE="tls" ;;
  esac

  # 4. 地址规范化
  _normalize_local_addr_for_input() {
    local input="$1"
    input="$(echo -n "$input" | tr -d ' \t\r\n')"
    if [ -z "$input" ]; then echo ""; return; fi
    if echo "$input" | grep -Eq '^[0-9]+$'; then echo "[::]:${input}"; else echo "$input"; fi
  }
  laddr=$(_normalize_local_addr_for_input "$laddr_raw")
  
  # 5. 认证配置 (交互部分)
  # 生成一个候选 UUID
  gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then uuidgen
    elif [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
    elif command -v openssl >/dev/null 2>&1; then openssl rand -hex 8
    else echo "$(date +%s)-$$"; fi
  }
  
  default_uuid=$(gen_uuid)
  auth_enabled="false"
  final_user=""
  final_pass=""
  auth_json_part=""

  echo
  read -e -rp "是否开启认证? (Y/n): " yn_auth
  if [[ "${yn_auth:-Y}" =~ ^[Yy]$ ]]; then
      auth_enabled="true"
      
      # 询问用户名
      read -e -rp "请输入认证用户名 [默认: ${default_uuid}]: " input_user
      final_user="${input_user:-$default_uuid}"
      
      # 询问密码
      read -e -rp "请输入认证密码 [默认: 与用户名相同]: " input_pass
      final_pass="${input_pass:-$final_user}"
      
      # 构造 JSON 片段 (注意前面的逗号，用于插入到 handler 对象中)
      auth_json_part=", \"auth\": { \"username\": \"${final_user}\", \"password\": \"${final_pass}\" }"
  else
      echo "已选择：无认证模式 (公开连接)。"
  fi

  # 6. 构造 Payload
  NAME="${base}"
  ADDR="${laddr}"

  # 注意：这里利用 shell 变量拼接 json，auth_json_part 如果为空则不带 auth 字段
  payload=$(cat <<JSON
{
  "name": "${NAME}",
  "addr": "${ADDR}",
  "handler": {
    "type": "relay"
    ${auth_json_part}
  },
  "listener": {
    "type": "${LISTENER_TYPE}"
  }
}
JSON
)

  echo
  echo "正在创建服务: relay+${LISTENER_TYPE}://${ADDR} ..."
  
  # 发送请求
  resp=$(api_post_raw "/config/services" "${payload}")
  body=$(echo "${resp}" | sed '$d')
  code=$(echo "${resp}" | tail -n1)

  if echo "$code" | grep -Eq '^[0-9]+$'; then code_num=$code; else code_num=0; fi

  if [ "$code_num" -ge 200 ] 2>/dev/null && [ "$code_num" -lt 300 ] 2>/dev/null; then
    echo "✅ 创建成功: ${NAME}"
    if [ "$auth_enabled" == "true" ]; then
        echo "   认证信息: [ 用户名: ${final_user} / 密码: ${final_pass} ]"
    else
        echo "   认证信息: [ 无认证 ]"
    fi
    echo "   监听类型: ${LISTENER_TYPE}"

    if declare -f save_config_to_file >/dev/null 2>&1; then
      if save_config_to_file >/dev/null 2>&1; then
        echo "✅ 配置已保存。"
      else
        echo "⚠️ 保存配置失败。"
      fi
    fi
  else
    echo "❌ 创建失败 (HTTP ${code_num}):"
    echo "${body}" | (command -v jq >/dev/null 2>&1 && jq . || cat)
  fi

  pause
}

# ========== 10) 智能最低延迟切换 (LeastPing + 优雅切换) ==========
least_ping_auto() {
  # 支持传参: least_ping_auto [PORT] [TARGET_A]
  local arg_port="${1:-}"
  local arg_target_a="${2:-}"

  echo "══════════════════════════════════════════════════════════"
  echo "           智能最低延迟切换"
  echo "----------------------------------------------------------"
  
  # 0. 环境检查
  if ! command -v python3 >/dev/null 2>&1; then echo "❌ 错误: 需要 python3"; pause; return; fi
  if ! command -v jq >/dev/null 2>&1; then echo "❌ 错误: 需要 jq"; pause; return; fi

  local current_api="${API_URL}"
  local current_auth="${API_AUTH:-}" 
  local LISTEN_PORT
  local TARGET_1

  # 1. 确定端口
  if [ -n "$arg_port" ]; then
      LISTEN_PORT="$arg_port"
      echo "📌 使用指定端口: ${LISTEN_PORT}"
  else
      read -e -rp "请输入监听端口 (PORT): " LISTEN_PORT
      if [ -z "$LISTEN_PORT" ]; then echo "监听端口不能为空"; pause; return; fi
  fi

  # 2. 确定落地 A
  if [ -n "$arg_target_a" ]; then
      TARGET_1="$arg_target_a"
      echo "📌 使用指定落地 A: ${TARGET_1}"
  else
      echo "正在查询端口信息..."
      local raw
      raw=$(api_get_raw "/config" 2>/dev/null)
      local current_target
      current_target=$(echo "$raw" | jq -r --arg port "$LISTEN_PORT" 'first(.services[]? | select(.addr | endswith(":" + $port)) | .forwarder.nodes[0].addr // empty)')

      if [ -z "$current_target" ]; then
          echo "❌ 错误：未找到监听端口 $LISTEN_PORT 的转发服务。"
          pause; return
      fi
      echo "✅ 发现当前转发目标(落地): ${current_target}"
      read -e -rp "请输入备选落地 A [默认: ${current_target}]: " input_t1
      TARGET_1="${input_t1:-$current_target}"
  fi

  # 3. 输入落地 B
  local TARGET_2
  while true; do
      read -e -rp "请输入备选落地 B (IP:PORT): " TARGET_2
      if [ -z "$TARGET_2" ]; then echo "不能为空"; elif [ "$TARGET_2" == "$TARGET_1" ]; then echo "不能相同"; else break; fi
  done

  # 4. 测速函数
  _get_latency_py() {
      local target=$1
      python3 -c "
import socket, time
target = '$target'
timeout = 2.0
try:
    if ':' in target: ip, port = target.split(':'); port = int(port)
    else: print('99999'); exit()
    succ=0; total=0
    for _ in range(3):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(timeout); start = time.time()
        try: s.connect((ip, port)); total += (time.time() - start) * 1000; succ += 1; s.close()
        except: pass
        time.sleep(0.2)
    print(f'{total/succ:.2f}' if succ > 0 else '99999')
except: print('99999')
"
  }

  echo "----------------------------------------------------------"
  echo -n "正在测试 落地 A ($TARGET_1) ... "; PING_1=$(_get_latency_py "$TARGET_1")
  if [ "$PING_1" == "99999" ]; then echo "[失败]"; else echo "${PING_1} ms"; fi
  echo -n "正在测试 落地 B ($TARGET_2) ... "; PING_2=$(_get_latency_py "$TARGET_2")
  if [ "$PING_2" == "99999" ]; then echo "[失败]"; else echo "${PING_2} ms"; fi
  echo "----------------------------------------------------------"

  local winner=""
  if [ "$PING_1" == "99999" ] && [ "$PING_2" == "99999" ]; then
      echo "❌ 两个落地均无法连接，本次不进行切换。"
  else
      IS_1_BETTER=$(awk "BEGIN {print ($PING_1 < $PING_2) ? 1 : 0}")
      if [ "$IS_1_BETTER" -eq 1 ]; then winner="$TARGET_1"; echo "✅ 决策: 落地 A 胜出"; else winner="$TARGET_2"; echo "✅ 决策: 落地 B 胜出"; fi

      # === 1. 获取当前正在使用的 IP (Check Active Target) ===
      local raw_check; raw_check=$(api_get_raw "/config" 2>/dev/null)
      local active_now
      active_now=$(echo "$raw_check" | jq -r --arg port "$LISTEN_PORT" 'first(.services[]? | select(.addr | endswith(":" + $port)) | .forwarder.nodes[0].addr // empty)')

      # === 2. 判断是否需要切换 ===
      if [ "$winner" == "$active_now" ]; then
          echo
          echo "🎉 当前配置已是最佳节点 ($winner)，无需切换。"
          echo "   (A: ${PING_1}ms vs B: ${PING_2}ms)"
      else
          # 需要切换 -> 检查活跃连接
          local active_conns
          active_conns=$(echo "$raw_check" | jq -r --arg port "$LISTEN_PORT" '[ .services[]? | select(.addr | endswith(":" + $port)) | (.status.stats.currentConns // 0) ] | add // 0')

          local do_update=1
          if [ "$active_conns" -gt 0 ]; then
              echo
              echo -e "⚠️  警告: 当前端口有 \033[31m${active_conns}\033[0m 个活跃用户连接！"
              read -e -rp "是否强制切换? (y/N): " yn_force
              if [[ ! "$yn_force" =~ ^[Yy]$ ]]; then echo "已取消切换。"; do_update=0; else echo ">>> 用户选择强制切换。"; fi
          fi

          if [ "$do_update" -eq 1 ]; then
              echo -n "正在更新 GOST 配置... "
              local service_names; service_names=$(echo "$raw_check" | jq -r --arg port "$LISTEN_PORT" 'if .services then .services[] else empty end | select(.addr | endswith(":" + $port)) | .name')
              local update_cnt=0
              for name in $service_names; do
                  local svc_json; svc_json=$(echo "$raw_check" | jq --arg n "$name" '.services[] | select(.name == $n)')
                  if echo "$svc_json" | jq -e '.forwarder.nodes' >/dev/null 2>&1; then
                      local new_svc_json; new_svc_json=$(echo "$svc_json" | jq --arg target "$winner" '.forwarder.nodes[0].addr = $target')
                      api_put_raw "/config/services/$name" "$new_svc_json" >/dev/null 2>&1
                      update_cnt=$((update_cnt+1))
                  fi
              done
              echo "已更新 $update_cnt 个服务。"
              if declare -f save_config_to_file >/dev/null 2>&1; then save_config_to_file >/dev/null 2>&1; echo "✅ 配置已自动持久化保存。"; fi
          fi
      fi
  fi

  # 7. 创建 Crontab
  echo; echo "【后台监测服务设置】"
  read -e -rp "是否为此端口创建定时监测任务? (y/N): " yn_cron
  if [[ ! "$yn_cron" =~ ^[Yy]$ ]]; then echo "已取消。"; pause; return; fi
  
  echo; echo "🤔 当监测到更优节点但有用户连接时："
  echo "   Y = 强制切换 (可能会断开用户)"; echo "   N = 优雅等待 (跳过本次切换)"
  read -e -rp "是否强制切换? (Y/n): " cron_force_yn
  local FORCE_MODE="false"; if [[ "$cron_force_yn" =~ ^[Yy]$ ]]; then FORCE_MODE="true"; fi
  
  read -e -rp "监测频率 (分钟，默认 5): " cron_min
  if ! [[ "$cron_min" =~ ^[0-9]+$ ]]; then cron_min=5; fi

  local task_dir="/etc/gost/tasks"; mkdir -p "$task_dir"
  local task_script="${task_dir}/monitor_${LISTEN_PORT}.sh"
  local log_file="/var/log/gost_monitor_${LISTEN_PORT}.log"

  echo "正在生成监测脚本..."
  cat > "$task_script" <<EOF
#!/bin/bash
# Auto-generated by Gost-API-CLI
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
API_URL="${current_api}"; API_AUTH="${current_auth}"
LISTEN_PORT="${LISTEN_PORT}"; TARGET_1="${TARGET_1}"; TARGET_2="${TARGET_2}"
FORCE_MODE="${FORCE_MODE}"
log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1"; }
get_ping() {
    local tgt=\$1
    python3 -c "
import socket, time
target = '\$tgt'; timeout = 2.0
try:
    if ':' in target: ip, port = target.split(':'); port = int(port)
    else: print('99999'); exit()
    succ=0; total=0
    for _ in range(3):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(timeout); start = time.time()
        try: s.connect((ip, port)); total += (time.time() - start) * 1000; succ += 1; s.close()
        except: pass
        time.sleep(0.2)
    print(f'{total/succ:.2f}' if succ > 0 else '99999')
except: print('99999')
"
}
p1=\$(get_ping "\$TARGET_1"); p2=\$(get_ping "\$TARGET_2")
if [ "\$p1" == "99999" ] && [ "\$p2" == "99999" ]; then log "ALL FAIL"; exit 1; fi
better=\$(awk "BEGIN {print (\$p1 < \$p2) ? 1 : 0}")
if [ "\$better" -eq 1 ]; then WINNER="\$TARGET_1"; else WINNER="\$TARGET_2"; fi

H=""; if [ -n "\$API_AUTH" ]; then H="-u \$API_AUTH"; fi
RAW=\$(curl -s \$H "\${API_URL}/config")
CUR=\$(echo "\$RAW" | jq -r --arg p "\$LISTEN_PORT" 'first(.services[]? | select(.addr | endswith(":" + \$p)) | .forwarder.nodes[0].addr // empty)')
if [ "\$CUR" == "\$WINNER" ]; then exit 0; fi

if [ "\$FORCE_MODE" == "false" ]; then
    ACT=\$(echo "\$RAW" | jq -r --arg p "\$LISTEN_PORT" '[ .services[]? | select(.addr | endswith(":" + \$p)) | (.status.stats.currentConns // 0) ] | add // 0')
    if [ "\$ACT" -gt 0 ]; then log "SKIP: Busy (Conns: \$ACT)."; exit 0; fi
fi

log "Switching: \$CUR -> \$WINNER"
NS=\$(echo "\$RAW" | jq -r --arg p "\$LISTEN_PORT" '.services[]? | select(.addr | endswith(":" + \$p)) | .name')
for N in \$NS; do
    J=\$(echo "\$RAW" | jq --arg n "\$N" '.services[] | select(.name == \$n)')
    NJ=\$(echo "\$J" | jq --arg t "\$WINNER" '.forwarder.nodes[0].addr = \$t')
    curl -s \$H -X PUT -H "Content-Type: application/json" -d "\$NJ" "\${API_URL}/config/services/\$N" >/dev/null
done
D=\$(curl -s \$H "\${API_URL}/config"); if echo "\$D" | jq empty >/dev/null 2>&1; then echo "\$D" | jq '.' > /etc/gost/config.json 2>/dev/null; fi
log "Done."
EOF
  chmod +x "$task_script"
  (crontab -l 2>/dev/null | grep -v "$task_script") | crontab -
  (crontab -l 2>/dev/null; echo "*/${cron_min} * * * * /bin/bash ${task_script} >> ${log_file} 2>&1") | crontab -
  echo "✅ Crontab 任务已添加！"; pause
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

# ========== 删除转发  ==========
delete_forward() {
  # 1. 获取所有服务数据
  local raw
  raw=$(api_get_raw "/config/services" 2>/dev/null)

  if [ -z "$(echo -n "$raw" | tr -d ' \t\r\n')" ]; then
    echo "未能从 API 获取服务列表或当前无服务。"
    pause; return
  fi

  # 2. 提取基础名供用户选择
  local names_list
  names_list=$(echo "$raw" | jq -r '
    (if type=="object" then (if has("data") and (.data|has("list")) then .data.list elif has("list") then .list else [.] end) else . end)
    | .[]?.name // empty
    | sub("\\-tcp$";"")
    | sub("\\-udp$";"")
  ' 2>/dev/null | sort -u | awk "NF")

  local -a BASES=()
  while IFS= read -r line; do [ -n "$line" ] && BASES+=("$line"); done <<< "$names_list"

  if [ "${#BASES[@]}" -eq 0 ]; then
    echo "当前没有可删除的转发。"
    pause; return
  fi

  echo "可删除的基础转发名："
  local i
  for i in "${!BASES[@]}"; do printf "  %2d) %s\n" "$((i+1))" "${BASES[$i]}"; done
  echo
  read -e -rp "输入编号 或 完整名称 (回车取消): " choice
  if [ -z "$choice" ]; then echo "已取消。"; pause; return; fi

  local svc_base=""
  if echo "$choice" | grep -Eq '^[0-9]+$'; then
    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#BASES[@]}" ] 2>/dev/null; then
      svc_base="${BASES[$((choice-1))]}"
    else
      echo "编号超出范围"; pause; return
    fi
  else
    svc_base="$choice"
  fi

  # 3. 找出要删除的具体 Service 及其 Chain
  local all_services_json
  all_services_json=$(echo "$raw" | jq -c '
    (if type=="object" then (if has("data") and (.data|has("list")) then .data.list elif has("list") then .list else [.] end) else . end)
  ' 2>/dev/null)

  local -a to_delete=()
  local -a related_chains=()

  while IFS=$'\t' read -r s_name s_chain; do
    if [ -z "$s_name" ] || [ "$s_name" == "null" ]; then continue; fi
    
    if [ "$s_name" = "${svc_base}-tcp" ] || [ "$s_name" = "${svc_base}-udp" ] || echo "$s_name" | grep -Fq "$svc_base"; then
        to_delete+=("$s_name")
        if [ -n "$s_chain" ] && [ "$s_chain" != "null" ]; then
            if [[ ! " ${related_chains[*]} " =~ " ${s_chain} " ]]; then
                related_chains+=("$s_chain")
            fi
        fi
    fi
  done < <(echo "$all_services_json" | jq -r '.[] | "\(.name)\t\(.handler.chain // "")"')

  if [ "${#to_delete[@]}" -eq 0 ]; then
    if echo "$svc_base" | grep -Eq '\-tcp$|\-udp$'; then to_delete+=("$svc_base"); fi
  fi

  if [ "${#to_delete[@]}" -eq 0 ]; then
    echo "未找到与 '${svc_base}' 匹配的 Service。"; pause; return
  fi

  # === 4. 执行删除 Services ===
  echo
  echo "正在删除 Service..."
  for s in "${to_delete[@]}"; do
    resp=$(api_delete_raw "/config/services/${s}" 2>/dev/null)
    code=$(echo "${resp}" | tail -n1 2>/dev/null)
    if [[ "$code" =~ 2[0-9][0-9] ]]; then
      echo "  ✅ 已删除: $s"
    else
      echo "  ❌ 删除失败: $s (HTTP $code)"
    fi
  done

  # === 5. 智能检测 Chain 依赖 (逻辑更新) ===
  if [ "${#related_chains[@]}" -gt 0 ]; then
    echo
    echo "正在检查 Chain 依赖关系..."
    # 等待 API 状态刷新
    sleep 0.5
    local fresh_raw
    fresh_raw=$(api_get_raw "/config/services" 2>/dev/null)
    
    for c in "${related_chains[@]}"; do
        # 查找谁还在用这个 chain
        local users
        users=$(echo "$fresh_raw" | jq -r --arg c "$c" '
          (if type=="object" then (if has("data") and (.data|has("list")) then .data.list elif has("list") then .list else [.] end) else . end)
          | .[]? | select(.handler.chain == $c) | .name
        ')

        local users_str
        users_str=$(echo "$users" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

        echo "------------------------------------------------"
        echo -e "检测 Chain: \033[33m$c\033[0m"

        if [ -n "$users_str" ]; then
            # === 情况 A: 仍被占用 -> 直接跳过 ===
            echo -e "⚠️  \033[31m此 Chain 仍被以下服务占用，自动跳过删除:\033[0m"
            echo -e "   -> \033[36m${users_str}\033[0m"
            echo "   🛡️  已保留以保障其他服务。"
        else
            # === 情况 B: 无人使用 -> 绿色提示，默认 N ===
            echo -e "ℹ️  状态: \033[32m空闲 (无服务引用)\033[0m"
            read -e -rp "   是否清理此无用 Chain? (y/N) [默认N]: " yn_del
            # 默认 N
            yn_del=${yn_del:-N}
            
            if [[ "$yn_del" =~ ^[Yy]$ ]]; then
                respc=$(api_delete_raw "/config/chains/${c}" 2>/dev/null)
                codec=$(echo "${respc}" | tail -n1 2>/dev/null)
                if [[ "$codec" =~ 2[0-9][0-9] ]]; then 
                    echo "   🗑️  已删除: $c"
                else 
                    echo "   ❌ 删除失败: $c (HTTP $codec)"
                fi
            else
                echo "   👉 已保留。"
            fi
        fi
    done
  fi

  # 持久化
  save_config_to_file >/dev/null 2>&1 || true

  echo
  echo "操作结束。"
  pause
}


# ========== fetch_stats: 从 /config 读取并显示 stats ==========
# usage: fetch_stats [SERVICE_NAME]
fetch_stats() {
  local api="${API_URL}"
  local name="${1:-}"

  if ! command -v jq >/dev/null 2>&1; then
    echo "请先安装 jq：apt install -y jq"
    read -n1 -r -s -p "按任意键返回主菜单..." && echo
    return 1
  fi

  # 触发一次完整 /config 拉取，促使 gost 汇总最新状态
  curl -s "${api}/config" >/dev/null

  # jq 输出每一行：name \t totalConns \t currentConns \t inputBytes \t outputBytes
  _jq_rows_all() {
    curl -s "${api}/config" \
      | jq -r '
        .services[]? |
        [
          (.name // "-"),
          ((.status.stats.totalConns // .stats.totalConns) // 0),
          ((.status.stats.currentConns // .stats.currentConns) // 0),
          ((.status.stats.inputBytes // .stats.inputBytes) // 0),
          ((.status.stats.outputBytes // .stats.outputBytes) // 0)
        ] | @tsv
      '
  }

  _jq_row_single() {
    local svc="$1"
    curl -s "${api}/config" \
      | jq -r --arg NAME "$svc" '
        .services[]? | select(.name==$NAME) |
        [
          (.name // "-"),
          ((.status.stats.totalConns // .stats.totalConns) // 0),
          ((.status.stats.currentConns // .stats.currentConns) // 0),
          ((.status.stats.inputBytes // .stats.inputBytes) // 0),
          ((.status.stats.outputBytes // .stats.outputBytes) // 0)
        ] | @tsv
      '
  }

  # awk 表格打印（中文表头 + 人类可读字节）
  _print_table_from_rows() {
    awk -F'\t' '
      BEGIN {
        printf "%-36s %18s %15s %10s %14s\n", "名称", "累计连接", "当前连接", "接收", "发送"
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
        name = $1
        total = ($2+0)
        cur = ($3+0)
        inb = ($4+0)
        outb = ($5+0)
        printf "%-36s %10d %10d %12s %12s\n", name, total, cur, human(inb), human(outb)
      }
    '
  }

  # ---------- 全部服务表格模式 ----------
  echo
  echo "                                 当前服务统计信息（实时）                   "
  echo "========================================================================================"
  rows=$(_jq_rows_all)
  if [ -z "$(echo -n "$rows" | tr -d ' \t\r\n')" ]; then
    echo "未找到任何服务或无统计数据。"
    echo
    read -n1 -r -s -p "按任意键返回主菜单..." && echo
    return
  fi

  # 打印表格（jq 只输出数据行，awk 打印表头）
  printf "%s\n" "$rows" | _print_table_from_rows
  echo "----------------------------------------------------------------------------------------"
  echo
  read -n1 -r -s -p "按 r 开始每 5 秒自动刷新（按任意键退出），或按任意键直接返回: " key
  echo
  if [ "$key" != "r" ]; then
    return
  fi

  # 自动刷新表格模式
  while true; do
    clear
    echo "                            当前服务统计信息（5s刷新）                   "
    echo "========================================================================================"
    rows=$(_jq_rows_all)
    if [ -z "$(echo -n "$rows" | tr -d ' \t\r\n')" ]; then
      echo "未找到任何服务或无统计数据。"
    else
      printf "%s\n" "$rows" | _print_table_from_rows
    fi
    echo "----------------------------------------------------------------------------------------"
    # 如果在 5 秒内检测到任意键，则退出循环
    if read -t 5 -n1 -r -s -p "" stop; then
      echo
      break
    fi
  done

  return
}

# ========== 查看端口连接详情 ==========
check_active_connections() {
  echo "══════════════════════════════════════════════════════════"
  echo "           端口实时连接来源 (Live Sources) "
  echo "----------------------------------------------------------"
  
  if ! command -v jq >/dev/null 2>&1; then echo "❌ 错误: 需要 jq"; pause; return; fi

  # 1. 获取服务列表
  echo "正在获取服务..."
  local raw; raw=$(api_get_raw "/config" 2>/dev/null)
  local svc_list
  svc_list=$(echo "$raw" | jq -r '.services[]? | select(.handler.type=="tcp" or .handler.type=="relay" or .handler.type=="http" or .handler.type=="socks5" or .handler.type=="udp") | "\(.name)|\(.addr | split(":") | last)|\(.handler.type)"')

  if [ -z "$svc_list" ]; then echo "⚠️  无相关服务运行。"; pause; return; fi

  echo "正在扫描连接..."
  echo

  local IFS=$'\n'
  for line in $svc_list; do
      local name="${line%%|*}"; local rest="${line#*|}"; local port="${rest%%|*}"; local type="${rest#*|}"
      if ! [[ "$port" =~ ^[0-9]+$ ]]; then continue; fi

      echo -e "🔵 服务: \033[36m$name\033[0m (Port: $port)"
      echo "   -------------------------------------------"
      echo "   远程来源 (Remote IP:Port)"

      local conns=""
      
      # 清洗函数: 去掉 ::ffff: 前缀，去掉方括号 [] (针对 IPv6 格式)
      # 统一输出格式为: IP:PORT
      
      if [ "$type" == "udp" ]; then
          if command -v ss >/dev/null 2>&1; then
             # ss UDP: $4 is Peer (Remote) in unconn state? No, ss -u usually: State Recv Send Local Peer ($5)
             # ss -un output: State Recv-Q Send-Q Local Address:Port Peer Address:Port
             conns=$(ss -un "sport = :$port" | awk 'NR>1 {print $5}')
          else
             # netstat UDP: $5 is Foreign
             conns=$(netstat -un | grep ":$port " | grep -v "0.0.0.0:\*" | awk '{print $5}')
          fi
      else
          # TCP
          if command -v ss >/dev/null 2>&1; then
              # ss TCP (state established): Recv-Q($1) Send-Q($2) Local($3) Remote($4)
              conns=$(ss -tn state established "sport = :$port" | awk 'NR>1 {print $4}')
          else
              # netstat TCP: Proto Recv Send Local Foreign($5) State
              conns=$(netstat -tn | grep ":$port " | grep "ESTABLISHED" | awk '{print $5}')
          fi
      fi

      # 统一清洗处理
      if [ -z "$conns" ]; then
          echo "   (暂无连接)"
      else
          # sed 处理: 
          # 1. s/::ffff://g  -> 去掉 IPv4 映射前缀
          # 2. s/^\[//       -> 去掉开头的 [
          # 3. s/\]:/:/      -> 把 ]: 变成 : (处理 [IPv6]:Port)
          echo "$conns" | sed 's/::ffff://g' | sed 's/^\[//' | sed 's/\]:/:/' | sed 's/^/   /'
          
          # 统计
          echo "   ---"
          echo "   📊 Top 3 来源:"
          # 统计时去掉端口号 (从最后一个冒号切分)
          echo "$conns" | sed 's/::ffff://g' | sed 's/^\[//' | sed 's/\]:/:/' | sed -E 's/:[0-9]+$//' | sort | uniq -c | sort -nr | head -n 3 | awk '{print "      " $1 " 个来自: " $2}'
      fi
      echo
  done
  unset IFS
  echo "══════════════════════════════════════════════════════════"
  pause
}


# ===== reload_config: 热重载 /config/reload =====
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
  read -e -rp "请输入序号 或 基础名 / 完整 service 名称 (回车取消): " sel
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
    read -e -rp "选择 (0-2): " opt
    case "$opt" in
      1)
        # 提示是否先保存配置到文件，避免 reload 丢失 API 临时改动
        read -e -rp "是否先保存当前配置到 ${CONFIG_FILE} 以避免 reload 丢失 API 临时配置？ (Y/n): " yn
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
    read -e -rp "请选择 (0-2): " subch
    case "$subch" in
      1)
        add_forward
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
 0) 返回
EOF
    read -e -rp "请选择: " rch
    case "$rch" in
      1)
        add_relay_forward
        ;;
      2)
        add_relay_listen
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
           GOST API 管理工具 V1.3.2 2025/11/19
仓库地址：https://github.com/lengmo23/Gostapi_forward
V1.3.2 Leastping均衡,转发Relay链复用

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
4) 查看转发
5) 删除转发
6) 重载服务
7) Leastping均衡
══════════════════════════════════════════════════════════
8) 保存配置到文件
9) 获取完整API配置
10) 查看实时流量统计
11) 查看端口连接详情
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
    7) least_ping_auto ;;
    8) save_config_to_file; pause ;;
    9) echo "GET /config"; api_get "/config"; pause ;;
    10) fetch_stats ;;
    11) check_active_connections ;;
    0) echo "退出"; exit 0 ;;
    *) echo "无效选择";;
  esac
done

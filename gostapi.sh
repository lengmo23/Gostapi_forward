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
      "https://ghfast.top/"
      "https://ghproxy.org/"
      "https://download.fastgit.org/"
      "https://ghproxy.cn/"
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
          else
            DOWNLOAD_PREFIX=""
          fi
        fi
      else
        DOWNLOAD_PREFIX=""
        echo "将不使用镜像，直接从 GitHub 下载（可能较慢/失败）。"
      fi
    else
      # 非中国，默认不使用镜像，可让用户强制选择
      echo "检测到 country=${country:-unknown}，默认不使用镜像。"
      read -rp "若要强制使用镜像以加速下载，请输入 y （否则回车跳过）: " usem
      if [[ "${usem}" =~ ^[Yy]$ ]]; then
        # pick first reachable proxy
        for p in "${PROXIES[@]}"; do
          if curl -s --head --max-time 4 "${p}raw.githubusercontent.com/" >/dev/null 2>&1; then
            DOWNLOAD_PREFIX="$p"; break
          fi
        done
        [ -n "$DOWNLOAD_PREFIX" ] && echo "选用镜像: ${DOWNLOAD_PREFIX}" || echo "未找到可用镜像，继续使用直连。"
      fi
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
    printf "%-4s| %-19s| %-34s| %-25s\n" "$idx" "$local" "$remote" "$name"
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
# ========== 删除转发（修复 data.list 为 null 的情况） ==========
delete_forward() {
  # 从 API 获取服务数据
  local raw
  raw=$(api_get_raw "/config/services" 2>/dev/null)

  # 如果无返回
  if [ -z "$(echo "$raw" | tr -d ' \n\r')" ]; then
    echo "未能从 API 获取服务列表或当前无服务。"
    pause
    return
  fi

  # 检查 count 或 list 是否为 null / 空数组
  local count
  count=$(echo "$raw" | jq -r 'try (.data.count // (if type=="array" then length else 0 end)) catch 0' 2>/dev/null || echo 0)
  local is_null_list
  is_null_list=$(echo "$raw" | jq -r 'try (.data.list == null) catch false' 2>/dev/null || echo "false")

  if [ "$count" -eq 0 ] || [ "$is_null_list" = "true" ]; then
    echo "当前没有可删除的转发。"
    pause
    return
  fi

  # 生成去重基础名列表
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

  # 读入数组
  local -a BASES=()
  while IFS= read -r line; do
    [ -n "$line" ] && BASES+=("$line")
  done <<< "$names_list"

  if [ "${#BASES[@]}" -eq 0 ]; then
    echo "当前没有可删除的转发。"
    pause
    return
  fi

  # 显示编号列表
  echo "可删除的基础转发名："
  local i
  for i in "${!BASES[@]}"; do
    printf "  %2d) %s\n" "$((i+1))" "${BASES[$i]}"
  done
  echo

  # 用户输入编号或名称
  read -e -rp "输入编号或直接输入服务名称 (直接回车返回上级菜单): " choice
  if [ -z "$choice" ]; then
    echo "已取消。"
    pause
    return
  fi

  local svc_name=""
  if echo "$choice" | grep -Eq '^[0-9]+$'; then
    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#BASES[@]}" ] 2>/dev/null; then
      svc_name="${BASES[$((choice-1))]}"
    else
      echo "编号超出范围"
      pause
      return
    fi
  else
    svc_name="$choice"
  fi

  # 构建删除列表（只删 -tcp / -udp）
  declare -a to_delete
  if echo "$svc_name" | grep -Eq '\-tcp$|\-udp$'; then
    to_delete+=("$svc_name")
  else
    to_delete+=("${svc_name}-tcp")
    to_delete+=("${svc_name}-udp")
  fi

  # 静默删除
  for s in "${to_delete[@]}"; do
    api_delete_raw "/config/services/${s}" >/dev/null 2>&1 || true
  done

  # 静默保存配置
  save_config_to_file >/dev/null 2>&1 || true

  echo "删除转发服务完成"
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
3) 添加转发（TCP+UDP）
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
    3) add_forward_combined ;;
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
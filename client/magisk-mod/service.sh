#!/system/bin/sh
# Sleepy Project - Android Magisk Module Service
# 监控前台应用及媒体状态，上报至 Sleepy 服务器

# ========== 配置加载 ==========
SCRIPT_DIR="${0%/*}"
CONFIG_FILE="${SCRIPT_DIR}/config.cfg"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERROR] 配置文件不存在: $CONFIG_FILE" >&2
  exit 1
fi

. "$CONFIG_FILE"

# 清理变量中的回车符
SECRET=$(printf '%s' "$SECRET" | tr -d '\r\n')
DEVICE_ID=$(printf '%s' "$DEVICE_ID" | tr -d '\r\n')
URL=$(printf '%s' "$URL" | tr -d '\r\n')
LOG_NAME=$(printf '%s' "$LOG_NAME" | tr -d '\r\n')
DEVICE_NAME=$(printf '%s' "$DEVICE_NAME" | tr -d '\r\n')
CACHE=$(printf '%s' "$CACHE" | tr -d '\r\n')
MEDIA_SWITCH=$(printf '%s' "$MEDIA" | tr -d '\r\n')
MEDIA_DEVICE_ID=$(printf '%s' "$MEDIA_DEVICE_ID" | tr -d '\r\n')
MEDIA_DEVICE_SHOW_NAME=$(printf '%s' "$MEDIA_DEVICE_SHOW_NAME" | tr -d '\r\n')

# 缓存文件路径（优先使用 config.cfg 中的 CACHE，否则默认在模块目录下）
CACHE_FILE="${CACHE:-${SCRIPT_DIR}/cache.txt}"

# ========== 日志系统 ==========
LOG_PATH="${SCRIPT_DIR}/${LOG_NAME:-monitor.log}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH"
}

# ========== 工具函数 ==========

# 判断当前包名是否为游戏，执行对应时长的等待
is_game() {
  pkg="$1"
  for game in $GAME_PACKAGES; do
    if [ "$game" = "$pkg" ]; then
      log "游戏模式: $pkg，等待 600 秒后再次检测"
      sleep 600
      return 0
    fi
  done
  sleep 30
  return 1
}

# 获取应用显示名称（不依赖应用商店）
# 优先级: 缓存 > dumpsys package > 包名
get_app_name() {
  package_name="$1"

  # 特殊情况：锁屏
  if [ "$package_name" = "NotificationShade" ]; then
    echo "锁屏"
    return
  fi

  # 1. 优先查缓存（含手动录入和自动解析结果）
  cached_name=$(awk -F '=' -v pkg="$package_name" '$1 == pkg {print $2; exit}' "$CACHE_FILE" 2>/dev/null)
  if [ -n "$cached_name" ]; then
    log "缓存命中: $package_name -> $cached_name"
    echo "$cached_name"
    return
  fi

  # 2. 尝试通过 dumpsys package 获取应用标签
  raw_label=$(dumpsys package "$package_name" 2>/dev/null \
    | grep -m1 "label=" \
    | sed "s/.*label='\([^']*\)'.*/\1/")

  # 过滤掉资源 ID 格式（如 0x7f100041）
  if [ -n "$raw_label" ] && ! printf '%s' "$raw_label" | grep -qE '^0x[0-9a-fA-F]+$'; then
    log "dumpsys 解析应用名称: $package_name -> $raw_label"
    printf '%s=%s\n' "$package_name" "$raw_label" >> "$CACHE_FILE"
    echo "$raw_label"
    return
  fi

  # 3. 回退：使用包名
  log "应用名称解析失败，使用包名: $package_name"
  echo "$package_name"
}

# 获取电池状态，返回格式如 "85%⚡" 或 "85%🔋"
get_battery_info() {
  battery_level=$(dumpsys battery 2>/dev/null | sed -n 's/.*level: \([0-9]*\).*/\1/p')
  is_charging=$(dumpsys deviceidle get charging 2>/dev/null)
  if [ "$is_charging" = "true" ]; then
    printf '%s%%⚡' "${battery_level:-?}"
  else
    printf '%s%%🔋' "${battery_level:-?}"
  fi
}

# 获取当前媒体播放信息
# 播放中返回 "标题<TAB>歌手"，否则返回空字符串
get_media_info() {
  dump=$(dumpsys media_session 2>/dev/null)
  # PlaybackState.STATE_PLAYING = 3
  if printf '%s' "$dump" | grep -qE "PlaybackState \{state=3[,}]|,state=3,"; then
    printf '%s' "$dump" \
      | grep -m1 "description=" \
      | sed -nr 's/.*description=([^,]+), ?([^,]+).*/\1\t\2/p'
  fi
}

# ========== 状态上报 ==========

# 上报设备前台应用状态
# 参数: $1=包名  $2=using值(true/false)
send_device_status() {
  pkg="$1"
  d_using="$2"

  app_name=$(get_app_name "$pkg")
  battery=$(get_battery_info)
  display_str="${app_name}[${battery}]"

  log "→ 设备上报: using=${d_using}, app=${display_str}"

  http_code=$(curl -s --connect-timeout 35 --max-time 100 \
    -w "%{http_code}" -o "${SCRIPT_DIR}/.curl_resp" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"secret\":\"${SECRET}\",\"id\":\"${DEVICE_ID}\",\"show_name\":\"${device_model}\",\"using\":${d_using},\"app_name\":\"${display_str}\"}" \
    "$URL")

  log "← 设备上报响应: HTTP ${http_code}"
  if [ "$http_code" != "200" ]; then
    log "  !! 设备上报失败，响应: $(cat "${SCRIPT_DIR}/.curl_resp" 2>/dev/null)"
  fi
}

# 上报媒体播放状态
# 参数: $1=using值(true/false)  $2=媒体内容描述字符串
send_media_status() {
  m_using="$1"
  m_content="$2"

  log "→ 媒体上报: using=${m_using}, content=${m_content}"

  http_code=$(curl -s --connect-timeout 35 --max-time 100 \
    -w "%{http_code}" -o "${SCRIPT_DIR}/.curl_media_resp" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"secret\":\"${SECRET}\",\"id\":\"${MEDIA_DEVICE_ID}\",\"show_name\":\"${MEDIA_DEVICE_SHOW_NAME}\",\"using\":${m_using},\"app_name\":\"${m_content}\"}" \
    "$URL")

  log "← 媒体上报响应: HTTP ${http_code}"
  if [ "$http_code" != "200" ]; then
    log "  !! 媒体上报失败，响应: $(cat "${SCRIPT_DIR}/.curl_media_resp" 2>/dev/null)"
  fi
}

# ========== 主流程 ==========

# 初始化日志（每次启动覆盖旧日志）
> "$LOG_PATH"
log "===== Sleepy 服务启动 ====="

# 获取设备信息
device_model=$(getprop ro.product.model)
android_version=$(getprop ro.build.version.release)
log "设备: ${device_model} | Android ${android_version}"

# 若配置了自定义设备显示名，覆盖 device_model
if [ -n "${DEVICE_NAME}" ]; then
  device_model="${DEVICE_NAME}"
  log "已使用自定义设备名: ${device_model}"
fi

log "等待系统完全启动 (60s)..."
sleep 60
log "开始监控"

# ========== 状态追踪变量 ==========
LAST_DEVICE_STATE=""   # 格式: "<包名>:<device_using>"，用于检测设备状态变化
LAST_MEDIA=""          # 最近一次上报的媒体内容字符串
lock_counter=0
device_using="true"
media_using="false"
PACKAGE_NAME=""

# ========== 主监控循环 ==========
while true; do

  # --- 屏幕/锁屏状态检测 ---
  isLock=$(dumpsys window policy 2>/dev/null | sed -n 's/.*showing=\([a-z]*\).*/\1/p')

  if [ "$isLock" = "true" ]; then
    lock_counter=$((lock_counter + 1))
    PACKAGE_NAME="NotificationShade"

    if [ "$lock_counter" -ge 60 ] && [ "$device_using" = "true" ]; then
      # 持续锁屏累计 60 次（约 30 分钟），标记设备为未使用
      device_using="false"
      log "持续锁屏 ${lock_counter} 次，判定设备未使用"
    else
      device_using="true"
    fi
  else
    # 屏幕亮起/解锁
    if [ "$lock_counter" -gt 0 ]; then
      log "设备解锁 (之前锁屏计数: ${lock_counter})"
      lock_counter=0
    fi
    device_using="true"
    CURRENT_FOCUS=$(dumpsys activity activities 2>/dev/null | grep -m1 'ResumedActivity')
    new_pkg=$(printf '%s' "$CURRENT_FOCUS" | sed -E 's/.*u0 ([^/]+).*/\1/')
    if [ -n "$new_pkg" ]; then
      PACKAGE_NAME="$new_pkg"
    fi
  fi

  # --- 设备状态变化检测 ---
  current_device_state="${PACKAGE_NAME}:${device_using}"
  if [ -n "$PACKAGE_NAME" ] && [ "$current_device_state" != "$LAST_DEVICE_STATE" ]; then
    log "设备状态变化: [${LAST_DEVICE_STATE:-无}] -> [${current_device_state}]"
    send_device_status "$PACKAGE_NAME" "$device_using"
    LAST_DEVICE_STATE="$current_device_state"
  fi

  # --- 媒体状态变化检测（独立于设备状态）---
  if [ "$MEDIA_SWITCH" = "true" ]; then
    media_raw=$(get_media_info)
    if [ -n "$media_raw" ]; then
      m_title=$(printf '%s' "$media_raw" | cut -f1)
      m_artist=$(printf '%s' "$media_raw" | cut -f2)
      current_media="♪${m_title} - ${m_artist}"
      media_using="true"
    else
      current_media="未在播放"
      media_using="false"
    fi

    if [ "$current_media" != "$LAST_MEDIA" ]; then
      log "媒体状态变化: [${LAST_MEDIA:-无}] -> [${current_media}]"
      send_media_status "$media_using" "$current_media"
      LAST_MEDIA="$current_media"
    fi
  fi

  is_game "$PACKAGE_NAME"
done
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
# 监控模式: sleep（默认，每30秒轮询）或 logcat（基于活动事件，轮询间隔5秒）
MONITOR_MODE=$(printf '%s' "${MONITOR_MODE:-sleep}" | tr -d '\r\n')
# 日志文件最大大小（KB），超出后保留最后500行，默认1024KB
LOG_MAX_KB=$(printf '%s' "${LOG_MAX_KB:-1024}" | tr -d '\r\n')
# 持续锁屏超过此秒数后标记为未使用，默认1800秒（30分钟）
SLEEP_TIMEOUT=$(printf '%s' "${SLEEP_TIMEOUT:-1800}" | tr -d '\r\n')

# 缓存文件路径（优先使用 config.cfg 中的 CACHE，否则默认在模块目录下）
CACHE_FILE="${CACHE:-${SCRIPT_DIR}/cache.txt}"

# ========== 日志系统 ==========
LOG_PATH="${SCRIPT_DIR}/${LOG_NAME:-monitor.log}"
# 日志最大字节数
LOG_MAX_BYTES=$((LOG_MAX_KB * 1024))
# logcat 模式用于传递最新包名的临时文件
LOGCAT_PKG_FILE="${SCRIPT_DIR}/.logcat_pkg"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH"
}

# 检查并轮转日志（超过 LOG_MAX_BYTES 则保留最后500行）
# 在主循环每次迭代结束时调用，避免每次 log() 都触发 wc
log_rotate_check() {
  local fsize
  fsize=$(wc -c < "$LOG_PATH" 2>/dev/null || echo 0)
  if [ "$fsize" -gt "$LOG_MAX_BYTES" ]; then
    tail -n 500 "$LOG_PATH" > "${LOG_PATH}.tmp" 2>/dev/null \
      && mv "${LOG_PATH}.tmp" "$LOG_PATH" 2>/dev/null
    log "日志已轮转（超过 ${LOG_MAX_KB}KB）"
  fi
}

# ========== 工具函数 ==========

# 判断当前包名是否为游戏，执行对应时长的等待
# logcat 模式使用更短的等待间隔（非游戏5s / 游戏60s）
is_game() {
  local pkg="$1"
  local game
  for game in $GAME_PACKAGES; do
    if [ "$game" = "$pkg" ]; then
      if [ "$MONITOR_MODE" = "logcat" ]; then
        log "游戏模式 (logcat): $pkg，等待 60 秒"
        sleep 60
      else
        log "游戏模式: $pkg，等待 600 秒后再次检测"
        sleep 600
      fi
      return 0
    fi
  done
  if [ "$MONITOR_MODE" = "logcat" ]; then
    sleep 5
  else
    sleep 30
  fi
  return 1
}

# 获取应用显示名称（不依赖应用商店）
# 优先级: 缓存 > dumpsys package > 包名
get_app_name() {
  local package_name="$1"
  local cached_name raw_label

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

# 获取电池状态
# 优先读取 sysfs 内核节点（无 Binder 调用开销），回退到 dumpsys battery
# 返回格式如 "85%⚡" 或 "85%🔋"
get_battery_info() {
  local battery_level charging_status dumpsys_out status_code

  # 优先读取 sysfs 内核节点
  battery_level=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  charging_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)

  # 若 sysfs 节点不可用，回退到 dumpsys battery
  if [ -z "$battery_level" ]; then
    dumpsys_out=$(dumpsys battery 2>/dev/null)
    battery_level=$(printf '%s' "$dumpsys_out" | sed -n 's/.*level: \([0-9]*\).*/\1/p')
    status_code=$(printf '%s' "$dumpsys_out" | sed -n 's/.*status: \([0-9]*\).*/\1/p')
    # dumpsys status: 2=Charging, 5=Full
    case "$status_code" in
      2|5) charging_status="Charging" ;;
      *)   charging_status="Discharging" ;;
    esac
  fi

  if [ "$charging_status" = "Charging" ] || [ "$charging_status" = "Full" ]; then
    printf '%s%%⚡' "${battery_level:-?}"
  else
    printf '%s%%🔋' "${battery_level:-?}"
  fi
}

# 获取当前媒体播放信息
# 播放中返回 "标题<TAB>歌手"，否则返回空字符串
get_media_info() {
  local dump
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
  local pkg="$1"
  local d_using="$2"
  local app_name battery display_str http_code

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
    log "  !! 设备上报失败，响应: $(head -c 200 "${SCRIPT_DIR}/.curl_resp" 2>/dev/null)"
  fi
}

# 上报媒体播放状态
# 参数: $1=using值(true/false)  $2=媒体内容描述字符串
send_media_status() {
  local m_using="$1"
  local m_content="$2"
  local http_code

  log "→ 媒体上报: using=${m_using}, content=${m_content}"

  http_code=$(curl -s --connect-timeout 35 --max-time 100 \
    -w "%{http_code}" -o "${SCRIPT_DIR}/.curl_media_resp" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"secret\":\"${SECRET}\",\"id\":\"${MEDIA_DEVICE_ID}\",\"show_name\":\"${MEDIA_DEVICE_SHOW_NAME}\",\"using\":${m_using},\"app_name\":\"${m_content}\"}" \
    "$URL")

  log "← 媒体上报响应: HTTP ${http_code}"
  if [ "$http_code" != "200" ]; then
    log "  !! 媒体上报失败，响应: $(head -c 200 "${SCRIPT_DIR}/.curl_media_resp" 2>/dev/null)"
  fi
}

# ========== logcat 模式 ==========

# 启动后台 logcat 监听进程
# am_activity_launch 事件格式: [..., com.pkg.name/.ActivityName, ...]
# 每次检测到新包名时写入 LOGCAT_PKG_FILE（主循环读取后删除）
start_logcat_watcher() {
  rm -f "$LOGCAT_PKG_FILE"
  (
    logcat -b events -s am_activity_launch 2>/dev/null | while IFS= read -r line; do
      pkg=$(printf '%s' "$line" \
        | sed -n 's/.*\[[^,]*,[^,]*,[^,]*,\([^/]*\)\/.*/\1/p')
      if [ -n "$pkg" ]; then
        printf '%s\n' "$pkg" > "$LOGCAT_PKG_FILE"
      fi
    done
  ) &
  LOGCAT_BG_PID=$!
  log "logcat 监听进程已启动 (PID: $LOGCAT_BG_PID)"
}

# 清理后台进程和临时文件
cleanup() {
  if [ -n "${LOGCAT_BG_PID:-}" ]; then
    kill "$LOGCAT_BG_PID" 2>/dev/null
    log "logcat 监听进程已停止 (PID: $LOGCAT_BG_PID)"
  fi
  rm -f "$LOGCAT_PKG_FILE" \
        "${SCRIPT_DIR}/.curl_resp" \
        "${SCRIPT_DIR}/.curl_media_resp"
}
trap cleanup EXIT INT TERM

# ========== 主流程 ==========

# 初始化日志（每次启动覆盖旧日志）
> "$LOG_PATH"
log "===== Sleepy 服务启动 (模式: ${MONITOR_MODE}) ====="

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

# 启动 logcat 监听（仅 logcat 模式）
LOGCAT_BG_PID=""
if [ "$MONITOR_MODE" = "logcat" ]; then
  start_logcat_watcher
fi

# ========== 状态追踪变量 ==========
LAST_DEVICE_STATE=""   # 格式: "<包名>:<device_using>"，用于检测设备状态变化
LAST_MEDIA=""          # 最近一次上报的媒体内容字符串
lock_start_ts=0        # 锁屏起始时间戳（0=未锁屏或超时已上报）
device_using="true"
media_using="false"
PACKAGE_NAME=""

# ========== 主监控循环 ==========
while true; do

  # --- 屏幕/锁屏状态检测 ---
  isLock=$(dumpsys window policy 2>/dev/null | sed -n 's/.*showing=\([a-z]*\).*/\1/p')

  if [ "$isLock" = "true" ]; then
    # 首次进入锁屏，记录时间戳
    if [ "$lock_start_ts" -eq 0 ]; then
      lock_start_ts=$(date +%s)
      log "设备锁屏，开始计时"
    fi
    PACKAGE_NAME="NotificationShade"

    # 基于真实时间戳判断是否超过 SLEEP_TIMEOUT（不受 Doze 模式影响）
    current_ts=$(date +%s)
    elapsed=$((current_ts - lock_start_ts))
    if [ "$elapsed" -ge "$SLEEP_TIMEOUT" ] && [ "$device_using" = "true" ]; then
      device_using="false"
      log "持续锁屏 ${elapsed} 秒（≥ ${SLEEP_TIMEOUT}s），判定设备未使用"
    fi
  else
    # 屏幕亮起/解锁
    if [ "$lock_start_ts" -gt 0 ]; then
      current_ts=$(date +%s)
      log "设备解锁（锁屏持续 $((current_ts - lock_start_ts)) 秒）"
      lock_start_ts=0
    fi
    device_using="true"

    new_pkg=""
    if [ "$MONITOR_MODE" = "logcat" ] && [ -f "$LOGCAT_PKG_FILE" ]; then
      # logcat 模式：读取后台监听写入的最新包名
      new_pkg=$(cat "$LOGCAT_PKG_FILE" 2>/dev/null)
      rm -f "$LOGCAT_PKG_FILE"
    fi
    # sleep 模式，或 logcat 模式下无新事件且尚未初始化包名时，通过 dumpsys 获取前台应用
    if [ -z "$new_pkg" ] && { [ "$MONITOR_MODE" != "logcat" ] || [ -z "$PACKAGE_NAME" ]; }; then
      CURRENT_FOCUS=$(dumpsys activity activities 2>/dev/null | grep -m1 'ResumedActivity')
      new_pkg=$(printf '%s' "$CURRENT_FOCUS" | sed -E 's/.*u0 ([^/]+).*/\1/')
    fi
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

  log_rotate_check
  is_game "$PACKAGE_NAME"
done
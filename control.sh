#!/bin/zsh
# 自定义触控板手势监听 · 统一控制入口
# 在当前桌面会话直接启动，使权限检查与实际监听使用相同的权限上下文。
set -eu

ROOT="${0:A:h}"
BIN="$ROOT/bin/TrackpadGestures"
LEGACY_JOB="gui/$(id -u)/local.native-trackpad"
LEGACY_PLIST="$ROOT/LaunchAgents/local.native-trackpad.plist"
LOG_DIR="$ROOT/logs"
PID_FILE="$LOG_DIR/TrackpadGestures.pid"
OUT_LOG="$LOG_DIR/stdout.log"
ERR_LOG="$LOG_DIR/stderr.log"

log() { print -r -- "$1"; }

require_binary() {
  if [[ ! -x "$BIN" ]]; then
    log "错误：缺少可执行文件 $BIN"
    log "请在项目根目录执行：swift build -c release --disable-sandbox --scratch-path /tmp/native-trackpad-build"
    log "然后把 /tmp/native-trackpad-build/release/TrackpadGestures 复制到 bin/"
    exit 1
  fi
}

check_accessibility() {
  local output
  output="$("$BIN" check 2>&1)" || { log "错误：设备检查失败"; log "$output"; exit 1; }
  if [[ "$output" != *"辅助功能权限：已授予"* ]]; then
    log "错误：辅助功能权限未授予"
    log "请在 系统设置 → 隐私与安全性 → 辅助功能 中允许运行手势程序的桌面应用（如终端或 Kimi Code）。"
    exit 2
  fi
}

running_pids() { pgrep -f "$BIN" 2>/dev/null || true; }

do_stop() {
  local quiet="${1:-}"
  if launchctl print "$LEGACY_JOB" >/dev/null 2>&1; then
    launchctl bootout "$LEGACY_JOB" >/dev/null 2>&1 || true
  fi
  local pids
  pids="$(running_pids)"
  if [[ -n "$pids" ]]; then
    print -r -- "$pids" | while read -r pid; do
      kill -TERM "$pid" 2>/dev/null || true
    done
  fi
  local i=0
  while (( i < 25 )); do
    if [[ -z "$(running_pids)" ]]; then break; fi
    sleep 0.2
    i=$(( i + 1 ))
  done
  if [[ -n "$(running_pids)" ]]; then
    log "错误：仍残留进程 $(running_pids)"
    exit 1
  fi
  rm -f "$PID_FILE" "$LEGACY_PLIST"
  if [[ -z "$quiet" ]]; then
    log "已停止：手势监听进程已退出，旧 launchd 注册已清理，未设置登录自启"
  fi
}

do_start() {
  require_binary
  check_accessibility
  do_stop quiet
  mkdir -p "$LOG_DIR"
  touch "$OUT_LOG" "$ERR_LOG"

  local log_offset
  log_offset="$(stat -f%z "$ERR_LOG")"
  nohup "$BIN" run --no-prompt </dev/null >>"$OUT_LOG" 2>>"$ERR_LOG" &
  local pid=$!
  print -r -- "$pid" > "$PID_FILE"

  local ready=false
  local i=0
  while (( i < 40 )); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    if tail -c "+$(( log_offset + 1 ))" "$ERR_LOG" 2>/dev/null | grep -Fq "手势监听已启动"; then
      ready=true
      break
    fi
    sleep 0.25
    i=$(( i + 1 ))
  done

  if [[ "$ready" != true ]]; then
    log "错误：监听未就绪，最近日志如下："
    tail -5 "$ERR_LOG"
    do_stop quiet
    exit 1
  fi

  log "已启动：手势监听（当前桌面会话直接运行，未设置登录自启）"
  log "PID：$pid"
  log "日志：$OUT_LOG"
  log "      $ERR_LOG"
}

do_status() {
  local pids
  pids="$(running_pids)"
  if [[ -n "$pids" ]]; then
    log "进程：运行中 (PID $(print -r -- "$pids" | tr '\n' ' '))"
  else
    log "进程：未运行"
  fi
  if launchctl print "$LEGACY_JOB" >/dev/null 2>&1; then
    log "旧 launchd 注册：仍存在，可执行 ./control.sh stop 清理"
  fi
  log "运行方式：当前桌面会话直接运行（无 launchd，无登录自启）"
  log "日志目录：$LOG_DIR"
  if [[ -x "$BIN" ]]; then
    log "--- 设备与权限 ---"
    "$BIN" check 2>&1 | tail -5
  else
    log "二进制：缺失 ($BIN)"
  fi
}

case "${1:-status}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop quiet; do_start ;;
  status)  do_status ;;
  *)       log "用法：control.sh start|stop|restart|status"; exit 64 ;;
esac

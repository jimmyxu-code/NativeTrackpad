#!/bin/zsh
set -eu

ROOT="${0:A:h}"
BIN="$ROOT/bin/TrackpadGestures"
SUPPORT="$HOME/Library/Application Support/NativeTrackpad"
LABEL="local.native-trackpad"
JOB="gui/$(id -u)/$LABEL"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="$ROOT/LaunchAgents/$LABEL.plist"
LOG_DIR="$SUPPORT/logs"
PID_FILE="$LOG_DIR/TrackpadGestures.pid"
OUT_LOG="$LOG_DIR/stdout.log"
ERR_LOG="$LOG_DIR/stderr.log"

log() { print -r -- "$1"; }

require_binary() {
  if [[ ! -x "$BIN" || ! -x "$ROOT/TrackpadGestures.app/Contents/MacOS/TrackpadGestures" ]]; then
    log "错误：缺少可执行文件或应用包"
    log "请先执行 release 构建并同步 bin/ 与 TrackpadGestures.app/"
    exit 1
  fi
}

check_accessibility() {
  local output
  output="$("$BIN" check 2>&1)" || { log "错误：设备检查失败"; log "$output"; exit 1; }
  if [[ "$output" != *"辅助功能权限：已授予"* ]]; then
    log "错误：辅助功能权限未授予"
    log "请在 系统设置 → 隐私与安全性 → 辅助功能 中允许 $BIN"
    exit 2
  fi
}

running_pids() { pgrep -x "TrackpadGestures" 2>/dev/null || true; }

do_stop() {
  local quiet="${1:-}"
  if launchctl print "$JOB" >/dev/null 2>&1; then
    launchctl bootout "$JOB" >/dev/null 2>&1 || true
  fi
  rm -f "$DEST"
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
  rm -f "$PID_FILE"
  if [[ -z "$quiet" ]]; then
    log "已停止：进程已退出，登录自启注册已移除"
  fi
}

do_start() {
  require_binary
  check_accessibility
  do_stop quiet
  mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
  cp -R "$ROOT/TrackpadGestures.app" "$SUPPORT/"
  codesign --force --sign - "$SUPPORT/TrackpadGestures.app" >/dev/null
  touch "$OUT_LOG" "$ERR_LOG"
  local log_offset
  log_offset="$(stat -f%z "$ERR_LOG")"
  cp "$TEMPLATE" "$DEST"
  launchctl bootstrap "gui/$(id -u)" "$DEST"
  launchctl enable "$JOB"
  launchctl kickstart -k "$JOB"

  local ready=false
  local i=0
  while (( i < 120 )); do
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
  local pids
  pids="$(running_pids)"
  print -r -- "$pids" > "$PID_FILE"
  log "已启动：手势监听运行中，并已设置用户登录自启"
  log "PID：$pids"
  log "LaunchAgent：$DEST"
}

do_status() {
  local pids
  pids="$(running_pids)"
  if [[ -n "$pids" ]]; then
    log "进程：运行中 (PID $(print -r -- "$pids" | tr '\n' ' '))"
  else
    log "进程：未运行"
  fi
  if launchctl print "$JOB" >/dev/null 2>&1; then
    log "登录自启：已注册 ($JOB)"
  elif [[ -f "$DEST" ]]; then
    log "登录自启：plist 已安装但未注册"
  else
    log "登录自启：未注册"
  fi
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
  restart) do_start ;;
  status)  do_status ;;
  *)       log "用法：control.sh start|stop|restart|status"; exit 64 ;;
esac

#!/system/bin/sh
# 显示器端「HDR/SDR 精密控光记忆」守护脚本。
#
# 背景：这台 Redmi G Pro 27U 的固件在收到 HDR 信号时会自己切画面模式
# （实测 HDR10：picture_mode 70 -> 22，固件日志 SCC_VID_HDR_EVNT set picture mode:22），
# 但**不会**跟着切「精密控光」—— 精密控光在固件里是全局值（实测：在模式 22 里写 2，
# 切回模式 70 仍是 2；而同一次切换里背光/色温/色域/色调映射都按模式各自恢复了）。
# 所以记忆这件事必须由外部补：本脚本常驻显示器内部盯 picture_mode，
# 在 HDR/SDR 之间来回切时把记忆值写回去。
#
# 写入通道与桌面端一致：TvService 的 runSystemCommand -> app_process -> MtkDirectTool
# 读回用 logcat（MtkDirectTool 会把结果打进 logcat）。
#
# 由 install.sh 部署，配置见同目录 README。

DIR=/sdcard/Download/Mimonitor_Toolbox
CONF="$DIR/dimming_memory.conf"
STATE="$DIR/dimming_memory.state"
LOG="$DIR/dimming_memory.log"
STOP="$DIR/dimming_memory.stop"
PIDFILE="$DIR/dimming_memory.pid"
JAR=/data/data/mitv.service/cache/MtkDirectTool.jar
CACHE_DIR=/data/data/mitv.service/cache
# 由 TvService 通道启动时进程是 system_app，`settings put` 会被
# AppOps 的 checkPackage NPE 拒掉（实测）；那时只写 JNI，键保持不动。
CAN_WRITE_SETTINGS=1

# 默认值（可被 CONF 覆盖）
SDR_LEVEL=0
HDR_LEVEL=3
HDR_MODES="11 12 13 15 16 17 18 19 22 23 29 30 31 32 33 39 40 41 42 43 44"
POLL_SECONDS=1
LEARN=1
SYNC_EVERY=30

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
  # 只留最近 400 行，别把 sdcard 写满
  tail -n 400 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

# ── 配置 / 记忆 ────────────────────────────────────────────────
[ -f "$CONF" ] && . "$CONF"
# 学习到的值优先（state 由本脚本自己维护，conf 只提供出厂默认）
[ -f "$STATE" ] && . "$STATE"

save_state() {
  {
    echo "SDR_LEVEL=$SDR_LEVEL"
    echo "HDR_LEVEL=$HDR_LEVEL"
  } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

in_hdr_modes() {
  for m in $HDR_MODES; do
    [ "$m" = "$1" ] && return 0
  done
  return 1
}

state_name() {
  [ "$1" = hdr ] && echo HDR || echo SDR
}

# ── 读全局 settings ─────────────────────────────────────────────
# `settings` 是个 sh 包装脚本，每次调用都要起一个 app_process（实测 ~45ms）；
# `cmd settings list global` 是原生二进制（~29ms）且一次拿回全部键，
# 比“逐键 get”省 3 倍开销；老固件没有 cmd 时退回 settings get。
HAVE_CMD=0
command -v cmd >/dev/null 2>&1 && HAVE_CMD=1

read_settings() {
  if [ "$HAVE_CMD" = 1 ]; then
    cmd settings list global 2>/dev/null
  else
    settings list global 2>/dev/null
  fi
}

# 一次拿到 picture_mode / picture_local_dimming / tv_picture_video_local_dimming。
# 注意：mksh（Android 的 sh）在 ${var%%pat} 里把 | 当模式分支，
# 所以不能用 | 分隔 —— 用空格，空值补 - 占位，保证字段不错位。
read_triple() {
  read_settings | awk -F= '
    $1 == "picture_mode" { m = $2 }
    $1 == "picture_local_dimming" { d = $2 }
    $1 == "tv_picture_video_local_dimming" { v = $2 }
    END { printf "%s %s %s\n", (m == "" ? "-" : m), (d == "" ? "-" : d), (v == "" ? "-" : v) }'
}

# ── MTK 寄存器读写 ─────────────────────────────────────────────
jni_get() {
  logcat -c 2>/dev/null
  service call TvService 3 s16 "sh -c eval\${IFS}CLASSPATH=$JAR\${IFS}/system/bin/app_process\${IFS}$CACHE_DIR\${IFS}MtkDirectTool\${IFS}get\${IFS}$1" >/dev/null 2>&1
  i=0
  while [ $i -lt 10 ]; do
    v=$(logcat -d -s MtkDirectTool 2>/dev/null | sed -n "s/.*GET $1 = //p" | tail -n 1)
    [ -n "$v" ] && { echo "$v"; return; }
    sleep 0.15
    i=$((i + 1))
  done
  echo ""
}

jni_set() {
  service call TvService 3 s16 "sh -c eval\${IFS}CLASSPATH=$JAR\${IFS}/system/bin/app_process\${IFS}$CACHE_DIR\${IFS}MtkDirectTool\${IFS}set\${IFS}$1\${IFS}$2\${IFS}3" >/dev/null 2>&1
}

apply_level() {
  # 与桌面端写入顺序一致：先 JNI（立即落到硬件），再两个 settings 键
  # （OSD 与其它组件看的是 settings；实测 tv_picture_video_local_dimming 会驱动硬件）
  level=$1
  jni_set g_video__vid_local_dimming "$level"
  if [ "$CAN_WRITE_SETTINGS" = 1 ]; then
    if settings put global tv_picture_video_local_dimming "$level" 2>/dev/null \
       && settings put global picture_local_dimming "$level" 2>/dev/null; then
      log "写入精密控光=$level（JNI + settings）"
    else
      CAN_WRITE_SETTINGS=0
      log "写入精密控光=$level（JNI）；本进程写不了 settings（非 shell uid），后续只写 JNI"
    fi
  else
    log "写入精密控光=$level（JNI）"
  fi
  # 自己写的值不算用户操作：记下来，供下一轮区分
  written_val=$level
  written_bucket=$bucket
  written_at=$(date +%s)
}

learn() {
  value=$1
  source=$2
  target_bucket=$3
  now=$(date +%s)
  # 固件会把 OSD 的写入镜像到另一个键（实测延迟约 5s）。同一个动作学一次就行，
  # 否则镜像会被当成第二次用户操作、记进错误的一侧。
  if [ "$value" = "$last_learned_val" ] && [ $(( now - last_learned_at )) -le 20 ]; then
    return
  fi
  if [ "$target_bucket" = hdr ]; then
    [ "$HDR_LEVEL" = "$value" ] && return
    HDR_LEVEL=$value
  else
    [ "$SDR_LEVEL" = "$value" ] && return
    SDR_LEVEL=$value
  fi
  last_learned_val=$value
  last_learned_at=$now
  save_state
  log "学习：$(state_name "$target_bucket") 记忆更新为 ${value}（来源 ${source}）"
}

# 这个变化是不是我们自己刚写下去的
is_own_write() {
  value=$1
  [ "$value" = "$written_val" ] || return 1
  [ "$bucket" = "$written_bucket" ] || return 1
  [ $(( $(date +%s) - written_at )) -le 8 ]
}

echo $$ > "$PIDFILE"
log "uid=$(id 2>/dev/null | cut -d' ' -f1) 守护启动：SDR=$SDR_LEVEL HDR=$HDR_LEVEL 轮询=${POLL_SECONDS}s 学习=$LEARN HDR_MODES=[$HDR_MODES]"

bucket=""
written_val=""
written_bucket=""
written_at=0
last_learned_val=""
last_learned_at=0
prev_dim=""
prev_vdim=""
tick=0

while true; do
  if [ -f "$STOP" ]; then
    log "收到停止标记，守护退出"
    break
  fi
  set -- $(read_triple)
  mode=$1
  dim=$2
  vdim=$3
  [ "$mode" = - ] && mode=""
  [ "$dim" = - ] && dim=""
  [ "$vdim" = - ] && vdim=""
  case "$mode" in
    ''|null|0|*[!0-9]*) bucket_now=unknown ;;
    *)
      if in_hdr_modes "$mode"; then bucket_now=hdr; else bucket_now=sdr; fi
      ;;
  esac

  # ── 学习：settings 值被别人（OSD / 遥控器 / 桌面端）改了 ──
  # 用 $bucket（变化发生时的状态），不用 bucket_now：切模式的同一拍里到达的
  # 延迟镜像属于上一个状态，归到新年份会把记忆学歪。
  if [ "$LEARN" = 1 ] && [ "$bucket" != "" ] && [ "$bucket" != unknown ]; then
    if [ -n "$prev_dim" ] && [ "$dim" != "$prev_dim" ] && [ "$dim" != null ]; then
      is_own_write "$dim" || learn "$dim" picture_local_dimming "$bucket"
    elif [ -n "$prev_vdim" ] && [ "$vdim" != "$prev_vdim" ] && [ "$vdim" != null ]; then
      is_own_write "$vdim" || learn "$vdim" tv_picture_video_local_dimming "$bucket"
    fi
  fi
  prev_dim=$dim
  prev_vdim=$vdim

  # ── 联动：HDR/SDR 状态变了就写回记忆值 ──
  if [ "$bucket_now" != unknown ] && [ "$bucket_now" != "$bucket" ]; then
    if [ "$bucket_now" = hdr ]; then want=$HDR_LEVEL; else want=$SDR_LEVEL; fi
    was_synced=$bucket
    bucket=$bucket_now          # 先落状态：apply_level / is_own_write 都按新状态记账
    hw=$(jni_get g_video__vid_local_dimming)
    if [ "$hw" = "$want" ]; then
      [ -n "$was_synced" ] && log "状态切换 -> $(state_name "$bucket_now")（picture_mode ${mode}）：硬件已是 ${want}，无需写入"
    else
      if [ -n "$was_synced" ]; then
        log "状态切换 -> $(state_name "$bucket_now")（picture_mode ${mode}）：硬件是 ${hw}，写回 ${want}（记忆 SDR=${SDR_LEVEL} HDR=${HDR_LEVEL}）"
      else
        log "首次同步 -> $(state_name "$bucket_now")（picture_mode ${mode}）：硬件是 ${hw}，写回 ${want}（记忆 SDR=${SDR_LEVEL} HDR=${HDR_LEVEL}）"
      fi
      apply_level "$want"
      prev_dim=$want
      prev_vdim=$want
    fi
  fi

  # ── 周期校正：只在「硬件」与「settings 键」不一致时修（不覆盖用户刚改的值）──
  tick=$((tick + 1))
  if [ "$bucket" != "" ] && [ "$bucket" != unknown ] && [ $((tick % SYNC_EVERY)) -eq 0 ]; then
    ref=$vdim
    [ -z "$ref" ] || [ "$ref" = null ] && ref=$dim
    if [ -n "$ref" ] && [ "$ref" != null ]; then
      hw=$(jni_get g_video__vid_local_dimming)
      if [ -n "$hw" ] && [ "$hw" != "$ref" ]; then
        log "校正：硬件 ${hw} 与 settings ${ref} 不一致，按 settings 回写"
        jni_set g_video__vid_local_dimming "$ref"
      fi
    fi
  fi

  sleep "$POLL_SECONDS"
done

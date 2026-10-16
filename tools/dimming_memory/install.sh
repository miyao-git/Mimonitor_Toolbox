#!/usr/bin/env bash
# 显示器端「HDR/SDR 精密控光记忆」守护脚本：部署 / 启动 / 查看 / 停止。
#
#   ./install.sh deploy [ip:port]     # 推送脚本 + 首次生成配置（默认端口 5555）
#   ./install.sh start  [ip:port]     # 默认走 adb 启动（shell uid，能写 settings 键）
#   ./install.sh start --tunnel [ip]  # 走 TvService 通道启动（完全脱离主机，但只写 JNI）
#   ./install.sh stop   [ip:port]
#   ./install.sh status [ip:port]
#   ./install.sh log    [ip:port]
#
# 两种启动方式说明：
#   adb（默认）：进程是 shell uid（2000），settings put 正常，能同时更新
#       picture_local_dimming / tv_picture_video_local_dimming；缺点是启动动作要主机在场。
#   --tunnel：经 `service call TvService ... app_process` 起，进程是 system_app，
#       主机拔掉也活着；但该上下文 `settings put` 会被 AppOps 拒（实测 NPE），
#       只写 MTK 寄存器（画面是对的，OSD 里显示的键值可能滞后）。
#
# adb 依次取 $ADB、PATH、/opt/homebrew/bin/adb。
set -u

DIR=/sdcard/Download/Mimonitor_Toolbox
REMOTE_SH="$DIR/dimming_memory.sh"
TMP_SH=/data/local/tmp/dimming_memory.sh
CONF="$DIR/dimming_memory.conf"
STATE="$DIR/dimming_memory.state"
STOP="$DIR/dimming_memory.stop"
PIDFILE="$DIR/dimming_memory.pid"
LOG="$DIR/dimming_memory.log"
JAR_CACHE=/data/data/mitv.service/cache/MtkDirectTool.jar
HERE="$(cd "$(dirname "$0")" && pwd)"

ADB="${ADB:-$(command -v adb || true)}"
[ -z "$ADB" ] && [ -x /opt/homebrew/bin/adb ] && ADB=/opt/homebrew/bin/adb
if [ -z "$ADB" ]; then
  echo "找不到 adb：装 android-platform-tools，或用 ADB=/path/to/adb $0 ..." >&2
  exit 1
fi

cmd="${1:-status}"
serial="192.168.31.15:5555"
tunnel=0
for arg in "${@:2}"; do
  case "$arg" in
    --tunnel) tunnel=1 ;;
    *) serial="$arg" ;;
  esac
done

sh_dev() { "$ADB" -s "$serial" shell "$@" </dev/null; }

ensure_connected() {
  local state
  state=$("$ADB" devices | awk -v s="$serial" '$1 == s {print $2}')
  if [ "$state" != "device" ]; then
    "$ADB" connect "$serial" >/dev/null 2>&1 || true
    sleep 1
    state=$("$ADB" devices | awk -v s="$serial" '$1 == s {print $2}')
  fi
  if [ "$state" != "device" ]; then
    echo "连不上 ${serial}（先在 app 里确认显示器 IP / 无线 ADB 已打开）" >&2
    exit 1
  fi
}

# 经 TvService 通道执行一条 shell 命令（与桌面端写寄存器同一条路）
# 注意：命令体里的空白必须传字面量 ${IFS}（TvService 用 Runtime.exec(String)，
# 不经过 shell，是 eval 再重新解析的），所以这里要拼出 `\${IFS}` 给设备端 shell。
tunnel_sh() {
  local parts="" p
  for p in "$@"; do parts="$parts\\\${IFS}$p"; done
  sh_dev "service call TvService 3 s16 \"sh -c eval$parts\"" >/dev/null 2>&1
}

status_pid() {
  sh_dev 'p=$(cat '"$PIDFILE"' 2>/dev/null); if [ -n "$p" ] && [ -d /proc/$p ]; then echo $p; fi' \
    | tr -d '\r' | head -n 1
}

deploy() {
  ensure_connected
  "$ADB" -s "$serial" push "$HERE/dimming_memory.sh" "$REMOTE_SH" >/dev/null || exit 1
  "$ADB" -s "$serial" push "$HERE/dimming_memory.sh" "$TMP_SH" >/dev/null || exit 1
  sh_dev "chmod 755 $REMOTE_SH $TMP_SH; mkdir -p $DIR"
  if ! sh_dev "test -f $CONF && echo yes" | grep -q yes; then
    # 用本地临时文件 + push：sh_dev 固定了 </dev/null，没法直接喂 heredoc
    tmp_conf=$(mktemp -t dimming_memory_conf)
    cat > "$tmp_conf" <<'CONF'
# 精密控光记忆配置。改完执行 ./install.sh restart 生效。
# 值：0=关 1=低 2=中 3=高
SDR_LEVEL=0
HDR_LEVEL=3
# 固件自动切过去的 HDR 画面模式（HDR10/DV/HDR 游戏…）。实测本机 HDR10 会切到 22。
HDR_MODES="11 12 13 15 16 17 18 19 22 23 29 30 31 32 33 39 40 41 42 43 44"
POLL_SECONDS=1
# 1 = 用户在 OSD/桌面端改控光时，自动记进当前 HDR/SDR 记忆
LEARN=1
# 每多少秒核对一次硬件寄存器（防止 OSD 改了 settings 键没同步）
SYNC_EVERY=30
CONF
    "$ADB" -s "$serial" push "$tmp_conf" "$CONF" >/dev/null || exit 1
    find "$tmp_conf" -delete 2>/dev/null
    echo "已生成配置 ${CONF}（默认 SDR=0 / HDR=3）"
  else
    echo "配置已存在，未覆盖：${CONF}"
  fi
  # 功能性探测：能不能经 TvService 读到寄存器（比 stat jar 可靠，adb shell 进不去 cache 目录）
  probe=$(sh_dev "logcat -c; service call TvService 3 s16 \"sh -c eval\\\${IFS}CLASSPATH=$JAR_CACHE\\\${IFS}/system/bin/app_process\\\${IFS}/data/data/mitv.service/cache\\\${IFS}MtkDirectTool\\\${IFS}get\\\${IFS}g_video__vid_local_dimming\" >/dev/null; sleep 1; logcat -d -s MtkDirectTool | tail -n 1" | tr -d '\r')
  case "$probe" in
    *'GET g_video__vid_local_dimming'*) : ;;
    *) echo "警告：经 TvService 读不到寄存器，先用桌面端连接一次（会自动部署 MtkDirectTool.jar）" >&2 ;;
  esac
  echo "部署完成：${REMOTE_SH}"
}

start() {
  ensure_connected
  if [ -n "$(status_pid)" ]; then echo "已在运行（pid $(status_pid)）"; return; fi
  sh_dev "find $DIR -maxdepth 1 -name dimming_memory.stop -delete"
  if [ "$tunnel" = 1 ]; then
    tunnel_sh sh "$REMOTE_SH"
    sleep 3
  else
    # adb 方式：后台起进程后本端 adb 客户端会一直挂在管道上，
    # 所以先确认 pid 文件出现，再把这个本地客户端杀掉（远端已 nohup 脱离）。
    "$ADB" -s "$serial" shell "cd $DIR && nohup sh $REMOTE_SH >/dev/null 2>&1 & echo started" \
      >/dev/null 2>&1 </dev/null &
    local_adb=$!
    for _ in $(seq 1 20); do
      sleep 0.5
      [ -n "$(status_pid)" ] && break
    done
    kill "$local_adb" 2>/dev/null || true
    wait "$local_adb" 2>/dev/null || true
  fi
  pid=$(status_pid)
  if [ -n "$pid" ]; then
    echo "已启动（pid ${pid}$([ "$tunnel" = 1 ] && echo ', TvService 通道' || echo ', adb/shell uid')）"
  else
    echo "启动失败，看 ./install.sh log" >&2
  fi
}

stop() {
  ensure_connected
  pid=$(status_pid)
  if [ -z "$pid" ]; then echo "未在运行"; return; fi
  sh_dev "echo stop > $STOP" >/dev/null 2>&1 || true
  for _ in $(seq 1 12); do
    sleep 0.5
    [ -z "$(status_pid)" ] && break
  done
  if [ -n "$(status_pid)" ]; then          # 兜底：让它自己 kill 自己（system 上下文能杀它）
    tunnel_sh sh -c "kill $(status_pid)"
    sleep 1
  fi
  if [ -z "$(status_pid)" ]; then
    sh_dev "find $DIR -maxdepth 1 -name dimming_memory.stop -delete" >/dev/null 2>&1 || true
    echo "已停止（原 pid ${pid}）"
  else
    echo "停止失败，pid ${pid} 还在" >&2
  fi
}

case "$cmd" in
  deploy) deploy ;;
  start)  start ;;
  stop)   stop ;;
  restart) stop; sleep 1; start ;;
  status)
    ensure_connected
    pid=$(status_pid)
    echo "进程: ${pid:-未运行}"
    sh_dev "settings get global picture_mode; settings get global picture_local_dimming; settings get global tv_picture_video_local_dimming" \
      | tr -d '\r' | paste -d' ' - - - 2>/dev/null | sed 's/^/当前 picture_mode \/ 主键 \/ 别名键: /'
    sh_dev "cat $STATE 2>/dev/null" | tr -d '\r' | sed 's/^/记忆: /'
    sh_dev "tail -n 8 $LOG 2>/dev/null" | tr -d '\r'
    ;;
  log)    ensure_connected; sh_dev "tail -n 40 $LOG 2>/dev/null" | tr -d '\r' ;;
  *)      sed -n '2,20p' "$0" ;;
esac

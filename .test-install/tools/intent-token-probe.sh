#!/data/data/com.termux/files/usr/bin/bash
# intent-token-probe.sh — 查明带 ?token= 的 URL 在 Android intent 链里会不会被截断,
# 以及**同端口第二次打开时浏览器是否复用旧标签页**(那会让人误以为 token 丢了)。
#
# 用法:
#   bash .test-install/tools/intent-token-probe.sh [端口]           # 单发: 只验 intent 链
#   bash .test-install/tools/intent-token-probe.sh [端口] --twice    # 双发: 同端口两个不同 token
#
# 双发的读法 —— 第二枪决定一切:
#   收到 token2  -> 浏览器每次都真的重新加载, 标签复用不成立
#   收到 token1  -> 复用了旧标签, 地址栏还是上一次的 URL (正是「只有端口号没有 token」的成因)
#   什么都没收到 -> 浏览器只是切回已有标签、根本没再发请求 (同样是复用, 最常见)
# 会在手机上弹浏览器 (双发弹两次)。
set -uo pipefail
PORT="${1:-3150}"
MODE="${2:-}"
LOG="$PWD/.intent-probe.log"; : > "$LOG"

python3 - "$PORT" "$LOG" <<'PY' &
import sys, http.server, socketserver
port, log = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/favicon.ico":
            with open(log, "a") as f:
                f.write(self.requestline + "\n")
        self.send_response(200); self.end_headers()
        self.wfile.write(b"probe ok - you can close this tab")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", port), H).serve_forever()
PY
SRV=$!
trap 'kill "$SRV" 2>/dev/null' EXIT
sleep 2

fire() { # $1=token 标签  $2=等待秒数
  local url="http://127.0.0.1:${PORT}/?token=$1"
  echo "==> 交出: $url"
  termux-open-url "$url"
  local n=0
  while [ "$n" -lt "$2" ]; do
    grep -q "token=$1" "$LOG" 2>/dev/null && { echo "    收到了 token=$1"; return 0; }
    sleep 1; n=$((n+1))
  done
  echo "    $2s 内没收到 token=$1 的请求"
  return 1
}

T1="ONE$(date +%s)"
fire "$T1" 20 || true

if [ "$MODE" = "--twice" ]; then
  echo
  echo "--- 第二枪: 同端口 $PORT, 换一个 token (请**不要**手动关掉刚才的标签页) ---"
  sleep 3
  T2="TWO$(date +%s)"
  fire "$T2" 20 || true
fi

kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
echo
echo "=== 监听器收到的全部请求 ==="
cat "$LOG" 2>/dev/null || echo "  (无)"
echo
if [ "$MODE" = "--twice" ]; then
  if grep -q "token=${T2:-__none__}" "$LOG" 2>/dev/null; then
    echo "结论: 第二枪也真的重新加载了 —— **标签复用不成立**, 得另找原因"
  elif grep -q "token=$T1" "$LOG" 2>/dev/null; then
    echo "结论: 只看到第一枪 —— **浏览器复用了旧标签页**, 这就是「地址栏只有端口号」的成因"
  else
    echo "结论: 一枪都没收到, 本次不成立 (换端口重试)"
  fi
elif grep -q "token=" "$LOG" 2>/dev/null; then
  echo "结论: intent 链**保留**了 token —— 问题不在 Android 这一层"
else
  echo "结论: 没收到请求, 本次不成立"
fi
rm -f "$LOG"

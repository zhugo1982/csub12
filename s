#!/bin/bash
# ============================================================
#  Hugo sing-box 12 协议一键脚本（重制版）
#  - 服务端配置: /etc/sing-box/config.json
#  - 订阅文件:   /etc/hugo-sub/   (不能放进 /etc/sing-box，见下方说明)
#
#  注意: 官方 sing-box 服务以 "-C /etc/sing-box" 启动，会把该目录下
#  所有 *.json 合并成服务端配置。所以任何客户端 JSON 都不能放在那里。
# ============================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本！(例如: sudo bash ...)"
  exit 1
fi

SB_DIR="/etc/sing-box"
SUB_DIR="/etc/hugo-sub"
NODE_FILE="$SUB_DIR/nodes.txt"
B64_FILE="$SUB_DIR/sub_b64.txt"
SBOX_FILE="$SUB_DIR/singbox.json"
SBOX_CN_FILE="$SUB_DIR/singbox-cn.json"
CLASH_FILE="$SUB_DIR/clash.yaml"
TOKEN_FILE="$SUB_DIR/token"
IP_FILE="$SUB_DIR/ip"
SUB_PORT=2082
# 脚本升级地址（改成你自己的 GitHub 原始文件地址）
SCRIPT_URL="https://raw.githubusercontent.com/zhugo1982/sub-9/refs/heads/main/grok"

TCP_PORTS="443 444 8881 3443 10000 7443 6443 6555 5443 4443 $SUB_PORT"
UDP_PORTS="8443 9443 6443 6555"

LINE="============================================================"

# ---------- 工具函数 ----------

get_ip() {
    local ip u
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
        ip=$(curl -s4 -m 6 "$u" | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
}

b64() { echo -n "$1" | base64 -w0; }
b64url() { echo -n "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }

install_deps() {
    local need=""
    for c in curl openssl jq python3; do
        command -v "$c" >/dev/null 2>&1 || need="$need $c"
    done
    [ -z "$need" ] && return 0
    echo "==> 安装依赖:$need"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y $need ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $need ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $need ca-certificates
    fi
}

install_singbox() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo "==> 未检测到 sing-box，正在安装..."
        if command -v apt-get >/dev/null 2>&1; then
            bash <(curl -fsSL https://sing-box.app/deb-install.sh)
        else
            bash <(curl -fsSL https://sing-box.app/install.sh)
        fi
    fi
    if ! command -v sing-box >/dev/null 2>&1; then
        echo "❌ sing-box 安装失败，请检查网络后重试。"
        exit 1
    fi

    # 版本检查（AnyTLS 需要 1.12+）
    local ver maj rest min
    ver=$(sing-box version 2>/dev/null | awk 'NR==1{print $3}')
    maj=${ver%%.*}
    rest=${ver#*.}
    min=${rest%%.*}
    if [ "${maj:-0}" -lt 1 ] 2>/dev/null || { [ "${maj:-0}" -eq 1 ] && [ "${min:-0}" -lt 12 ]; }; then
        echo "❌ 当前 sing-box 版本为 $ver，低于 1.12，不支持 AnyTLS 等新特性。"
        echo "   请先升级: bash <(curl -fsSL https://sing-box.app/deb-install.sh)"
        exit 1
    fi
    echo "✅ sing-box 版本: $ver"
}

check_ports() {
    local p
    for p in $TCP_PORTS; do
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"; then
            echo "⚠️  TCP 端口 $p 已被其他程序占用，对应节点可能无法启动！"
        fi
    done
}

open_firewall() {
    local p
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "==> 检测到 ufw，自动放行端口..."
        for p in $TCP_PORTS; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
        for p in $UDP_PORTS; do ufw allow "${p}/udp" >/dev/null 2>&1; done
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        echo "==> 检测到 firewalld，自动放行端口..."
        for p in $TCP_PORTS; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1; done
        for p in $UDP_PORTS; do firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1; done
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# ---------- 订阅 HTTP 服务 ----------

setup_sub_service() {
    echo "==> 配置 HTTP 订阅服务 (端口: $SUB_PORT)..."

    cat > "$SUB_DIR/server.py" << 'PYEOF'
import http.server
import socketserver

BASE = "/etc/hugo-sub"
PORT = 2082


def read_token():
    try:
        with open(BASE + "/token") as f:
            return f.read().strip()
    except Exception:
        return ""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        t = read_token()
        routes = {
            "/%s/sub" % t: ("sub_b64.txt", "text/plain; charset=utf-8"),
            "/%s/singbox" % t: ("singbox.json", "application/json; charset=utf-8"),
            "/%s/singbox-cn" % t: ("singbox-cn.json", "application/json; charset=utf-8"),
            "/%s/clash" % t: ("clash.yaml", "text/yaml; charset=utf-8"),
        }
        item = routes.get(self.path.split("?")[0]) if t else None
        if not item:
            self.send_error(404, "Not Found")
            return
        try:
            with open(BASE + "/" + item[0], "rb") as f:
                data = f.read()
        except Exception:
            self.send_error(404, "Not Found")
            return
        self.send_response(200)
        self.send_header("Content-Type", item[1])
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    Server(("", PORT), Handler).serve_forever()
PYEOF

    cat > /etc/systemd/system/hugo-sub.service << SERVICEOF
[Unit]
Description=Hugo Sub HTTP Service
After=network.target

[Service]
Type=simple
ExecStart=$(command -v python3) $SUB_DIR/server.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SERVICEOF

    systemctl daemon-reload
    systemctl enable hugo-sub >/dev/null 2>&1
    systemctl restart hugo-sub
    sleep 1
    if systemctl is-active --quiet hugo-sub; then
        echo "✅ 订阅服务已启动"
    else
        echo "❌ 订阅服务启动失败，请查看: journalctl -u hugo-sub -n 30 --no-pager"
    fi
}

# ---------- 显示节点 ----------

show_nodes() {
    if [ ! -f "$NODE_FILE" ]; then
        echo "❌ 未找到已保存的节点信息！请先选择「全新部署」。"
        return
    fi
    local ip token
    ip=$(cat "$IP_FILE" 2>/dev/null)
    token=$(cat "$TOKEN_FILE" 2>/dev/null)

    echo "$LINE"
    echo "✨ 当前服务器的 12 大协议节点："
    echo "$LINE"
    cat "$NODE_FILE"
    echo ""
    echo "$LINE"
    echo "🔗 通用订阅 (V2rayN / Shadowrocket / v2rayNG / NekoBox):"
    echo "   http://$ip:$SUB_PORT/$token/sub"
    echo ""
    echo "📱 苹果 sing-box App 订阅 (Profiles → New → Remote):"
    echo "   全局代理:     http://$ip:$SUB_PORT/$token/singbox"
    echo "   大陆直连分流: http://$ip:$SUB_PORT/$token/singbox-cn"
    echo ""
    echo "🐱 Clash Meta / Mihomo 订阅 (Clash Verge / FlClash / Stash / ClashX Meta):"
    echo "   http://$ip:$SUB_PORT/$token/clash"
    echo "$LINE"
    echo "⚠️  订阅链接里含全部节点密码，请勿公开分享。"
    echo "⚠️  云服务器还需在控制台安全组放行:"
    echo "   TCP: $TCP_PORTS"
    echo "   UDP: $UDP_PORTS"
    echo "$LINE"
}

# ---------- 状态检测 ----------

check_status() {
    echo "$LINE"
    echo "🔍 sing-box 服务状态:"
    systemctl status sing-box --no-pager 2>&1 | head -12
    echo ""
    echo "🔍 订阅服务状态:"
    systemctl status hugo-sub --no-pager 2>&1 | head -8
    echo ""
    echo "🔍 服务端配置检查:"
    if sing-box check -C "$SB_DIR" 2>&1; then
        echo "✅ 配置语法正常"
    fi
    echo ""
    echo "🔍 监听端口:"
    ss -lntup 2>/dev/null | grep -E "sing-box|python3" | awk '{print $1, $5}'
    echo ""
    local token
    token=$(cat "$TOKEN_FILE" 2>/dev/null)
    echo "🔍 本机订阅访问测试:"
    echo -n "   /sub      -> HTTP "; curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:$SUB_PORT/$token/sub"
    echo -n "   /singbox  -> HTTP "; curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:$SUB_PORT/$token/singbox"
    echo ""
    echo "🔍 最近 15 行日志:"
    journalctl -u sing-box -n 15 --no-pager 2>&1
    echo "$LINE"
}

# ---------- 卸载 ----------

uninstall_nodes() {
    echo "$LINE"
    echo "⚠️  警告：此操作将彻底卸载 sing-box、订阅服务并删除所有节点配置！"
    read -p "确定要彻底卸载吗？(y/N): " CONFIRM
    case "$CONFIRM" in
        [yY][eE][sS]|[yY])
            echo "==> 1. 停止并禁用服务..."
            systemctl stop sing-box 2>/dev/null
            systemctl disable sing-box 2>/dev/null
            systemctl stop hugo-sub 2>/dev/null
            systemctl disable hugo-sub 2>/dev/null

            echo "==> 2. 清理配置文件..."
            rm -rf "$SB_DIR" "$SUB_DIR"
            rm -f /etc/systemd/system/hugo-sub.service
            systemctl daemon-reload

            echo "==> 3. 卸载 sing-box 软件包..."
            if command -v apt-get >/dev/null 2>&1; then
                apt-get purge -y sing-box 2>/dev/null
                apt-get autoremove -y 2>/dev/null
            elif command -v dnf >/dev/null 2>&1; then
                dnf remove -y sing-box 2>/dev/null
            elif command -v yum >/dev/null 2>&1; then
                yum remove -y sing-box 2>/dev/null
            fi

            echo "==> 4. 清理 sub 快捷命令..."
            rm -f /usr/local/bin/sub

            echo "$LINE"
            echo "✅ 卸载完成！"
            echo "$LINE"
            exit 0
            ;;
        *)
            echo "❌ 操作已取消。"
            ;;
    esac
}

# ---------- 生成分流订阅 / 不重置节点的刷新 ----------

# 注意: 1.14 起 download_detour 已弃用(1.16 移除)，改用 http_clients + default_http_client，需客户端 1.14+
build_cn_profile() {
    jq '
      del(.http_clients, .route.default_http_client, .route.rule_set, .dns.rules)
      | .route.rules |= map(select(.rule_set == null))
      | .http_clients = [ { "tag": "proxy-http", "detour": "proxy" } ]
      | .route.default_http_client = "proxy-http"
      | .route.rule_set = [
        { "tag": "geoip-cn", "type": "remote", "format": "binary",
          "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" },
        { "tag": "geosite-cn", "type": "remote", "format": "binary",
          "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" }
      ]
      | .route.rules += [ { "rule_set": [ "geosite-cn", "geoip-cn" ], "action": "route", "outbound": "direct" } ]
      | .dns.rules = [ { "rule_set": "geosite-cn", "action": "route", "server": "dns-local" } ]
    ' "$SBOX_FILE" > "$SBOX_CN_FILE.tmp" && mv "$SBOX_CN_FILE.tmp" "$SBOX_CN_FILE"
}

# 从已生成的 sing-box 客户端配置里读取凭证，生成 Clash Meta (Mihomo) 订阅
build_clash() {
    local cv_ssp cv_stp cv_st_proxy cv_st_group cv_ip cv_uuid cv_pub cv_sid cv_sni cv_vmess cv_any cv_hy2 cv_tuic cv_ss22 cv_ssc cv_trj cv_pu cv_pp
    clash_val() { jq -r ".outbounds[] | select(.tag==\"$1\") | $2" "$SBOX_FILE"; }

    cv_ip=$(clash_val Hugo-Reality-TCP .server)
    cv_uuid=$(clash_val Hugo-Reality-TCP .uuid)
    cv_pub=$(clash_val Hugo-Reality-TCP .tls.reality.public_key)
    cv_sid=$(clash_val Hugo-Reality-TCP .tls.reality.short_id)
    cv_sni=$(clash_val Hugo-Reality-TCP .tls.server_name)
    cv_vmess=$(clash_val Hugo-VMess .uuid)
    cv_any=$(clash_val Hugo-AnyTLS .password)
    cv_hy2=$(clash_val Hugo-Hysteria2 .password)
    cv_tuic=$(clash_val Hugo-TuicV5 .password)
    cv_ss22=$(clash_val Hugo-Shadowsocks-2022 .password)
    cv_ssc=$(clash_val Hugo-Shadowsocks-Classic .password)
    cv_trj=$(clash_val Hugo-Trojan .password)
    cv_pu=$(clash_val Hugo-Socks5-Mixed .username)
    cv_pp=$(clash_val Hugo-Socks5-Mixed .password)
    cv_ssp=$(clash_val Hugo-ShadowTLS .password)
    cv_stp=$(clash_val Hugo-ShadowTLS-out .password)

    # ShadowTLS (若已启用)
    cv_st_proxy=""
    cv_st_group=""
    if [ -n "$cv_stp" ] && [ "$cv_stp" != "null" ]; then
        cv_st_proxy=$(cat << STEOF

  - name: "Hugo-ShadowTLS"
    type: ss
    server: $cv_ip
    port: 4443
    cipher: 2022-blake3-aes-128-gcm
    password: "$cv_ssp"
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: $cv_sni
      password: "$cv_stp"
      version: 3
STEOF
)
        cv_st_group='      - "Hugo-ShadowTLS"'
    fi

    if [ -z "$cv_ip" ] || [ -z "$cv_uuid" ] || [ -z "$cv_pub" ]; then
        echo "❌ 读取节点凭证失败，无法生成 Clash 订阅。"
        return 1
    fi

    cat > "$CLASH_FILE.tmp" << CLASHEOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query

proxies:
  - name: "Hugo-Reality-TCP"
    type: vless
    server: $cv_ip
    port: 443
    uuid: "$cv_uuid"
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $cv_sni
    client-fingerprint: chrome
    reality-opts:
      public-key: "$cv_pub"
      short-id: "$cv_sid"

  - name: "Hugo-Reality-gRPC"
    type: vless
    server: $cv_ip
    port: 444
    uuid: "$cv_uuid"
    network: grpc
    udp: true
    tls: true
    servername: $cv_sni
    client-fingerprint: chrome
    grpc-opts:
      grpc-service-name: hugogrpc
    reality-opts:
      public-key: "$cv_pub"
      short-id: "$cv_sid"

  - name: "Hugo-XTLS-Reality-8881"
    type: vless
    server: $cv_ip
    port: 8881
    uuid: "$cv_uuid"
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $cv_sni
    client-fingerprint: chrome
    reality-opts:
      public-key: "$cv_pub"
      short-id: "$cv_sid"

  - name: "Hugo-VMess"
    type: vmess
    server: $cv_ip
    port: 3443
    uuid: "$cv_vmess"
    alterId: 0
    cipher: auto
    udp: true

  - name: "Hugo-AnyTLS"
    type: anytls
    server: $cv_ip
    port: 10000
    password: "$cv_any"
    udp: true
    sni: bing.com
    skip-cert-verify: true

  - name: "Hugo-Hysteria2"
    type: hysteria2
    server: $cv_ip
    port: 8443
    password: "$cv_hy2"
    sni: bing.com
    skip-cert-verify: true
    alpn:
      - h3

  - name: "Hugo-TuicV5"
    type: tuic
    server: $cv_ip
    port: 9443
    uuid: "$cv_uuid"
    password: "$cv_tuic"
    alpn:
      - h3
    congestion-controller: bbr
    udp-relay-mode: native
    sni: bing.com
    skip-cert-verify: true

  - name: "Hugo-Shadowsocks-2022"
    type: ss
    server: $cv_ip
    port: 6443
    cipher: 2022-blake3-aes-128-gcm
    password: "$cv_ss22"
    udp: true

  - name: "Hugo-Shadowsocks-Classic"
    type: ss
    server: $cv_ip
    port: 6555
    cipher: aes-256-gcm
    password: "$cv_ssc"
    udp: true

  - name: "Hugo-Trojan"
    type: trojan
    server: $cv_ip
    port: 7443
    password: "$cv_trj"
    sni: bing.com
    skip-cert-verify: true
    udp: true

  - name: "Hugo-Socks5-Mixed"
    type: socks5
    server: $cv_ip
    port: 5443
    username: "$cv_pu"
    password: "$cv_pp"
    udp: true
$cv_st_proxy

proxy-groups:
  - name: "节点选择"
    type: select
    proxies:
      - "自动选择"
      - "Hugo-Reality-TCP"
      - "Hugo-Reality-gRPC"
      - "Hugo-XTLS-Reality-8881"
      - "Hugo-VMess"
      - "Hugo-AnyTLS"
      - "Hugo-Hysteria2"
      - "Hugo-TuicV5"
      - "Hugo-Shadowsocks-2022"
      - "Hugo-Shadowsocks-Classic"
      - "Hugo-Trojan"
      - "Hugo-Socks5-Mixed"
$cv_st_group
      - DIRECT

  - name: "自动选择"
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
      - "Hugo-Reality-TCP"
      - "Hugo-Reality-gRPC"
      - "Hugo-XTLS-Reality-8881"
      - "Hugo-AnyTLS"
      - "Hugo-Hysteria2"
      - "Hugo-TuicV5"
      - "Hugo-Trojan"
      - "Hugo-Shadowsocks-2022"

rules:
  - AND,((IP-CIDR,$cv_ip/32),(DST-PORT,$SUB_PORT)),DIRECT
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
CLASHEOF
    mv "$CLASH_FILE.tmp" "$CLASH_FILE"
}

# ---------- ShadowTLS v3 (第 12 个协议) ----------

# 服务端: 往 config.json 追加 shadowtls 入站 + 内部 shadowsocks 入站（凭证随机生成）
st_patch_server() {
    local sni="$1" stp ssp
    stp=$(openssl rand -hex 8)
    ssp=$(openssl rand -base64 16)
    jq --arg sni "$sni" --arg stp "$stp" --arg ssp "$ssp" '
      .inbounds += [
        { "type": "shadowtls", "tag": "shadowtls-in", "listen": "0.0.0.0", "listen_port": 4443, "version": 3,
          "users": [ { "name": "hugo-shadowtls", "password": $stp } ],
          "handshake": { "server": $sni, "server_port": 443 },
          "detour": "shadowsocks-st-in" },
        { "type": "shadowsocks", "tag": "shadowsocks-st-in", "listen": "127.0.0.1", "network": "tcp",
          "method": "2022-blake3-aes-128-gcm", "password": $ssp }
      ]
    ' "$SB_DIR/config.json" > "$SUB_DIR/config.tmp" && mv "$SUB_DIR/config.tmp" "$SB_DIR/config.json"
}

st_server_has() {
    jq -e '.inbounds[] | select(.type == "shadowtls")' "$SB_DIR/config.json" >/dev/null 2>&1
}

# 从服务端配置读取 ShadowTLS 凭证
st_read() {
    ST_PASS=$(jq -r '.inbounds[] | select(.type == "shadowtls") | .users[0].password' "$SB_DIR/config.json")
    ST_SS_PASS=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-st-in") | .password' "$SB_DIR/config.json")
}

# 客户端: 往 sing-box 客户端订阅追加 ShadowTLS 节点（可重复执行）
st_patch_client() {
    local ip sni
    st_read
    if [ -z "$ST_PASS" ] || [ "$ST_PASS" = "null" ]; then
        echo "❌ 读取 ShadowTLS 凭证失败。"
        return 1
    fi
    ip=$(cat "$IP_FILE" 2>/dev/null)
    sni=$(jq -r '.outbounds[] | select(.tag == "Hugo-Reality-TCP") | .tls.server_name' "$SBOX_FILE")
    jq --arg ip "$ip" --arg sni "$sni" --arg stp "$ST_PASS" --arg ssp "$ST_SS_PASS" '
      .outbounds |= map(select(.tag != "Hugo-ShadowTLS" and .tag != "Hugo-ShadowTLS-out"))
      | .outbounds += [
          { "type": "shadowsocks", "tag": "Hugo-ShadowTLS", "server": $ip, "server_port": 4443,
            "method": "2022-blake3-aes-128-gcm", "password": $ssp, "detour": "Hugo-ShadowTLS-out" },
          { "type": "shadowtls", "tag": "Hugo-ShadowTLS-out", "server": $ip, "server_port": 4443, "version": 3,
            "password": $stp,
            "tls": { "enabled": true, "server_name": $sni, "utls": { "enabled": true, "fingerprint": "chrome" } } }
        ]
      | (.outbounds[] | select(.tag == "proxy") | .outbounds) |= ((. - ["Hugo-ShadowTLS"]) + ["Hugo-ShadowTLS"])
    ' "$SBOX_FILE" > "$SBOX_FILE.tmp" && mv "$SBOX_FILE.tmp" "$SBOX_FILE"
}

# 节点信息文件追加第 12 项
st_patch_nodefile() {
    [ -f "$NODE_FILE" ] || return 0
    grep -q '^\[12\]' "$NODE_FILE" && return 0
    st_read
    local ip sni
    ip=$(cat "$IP_FILE" 2>/dev/null)
    sni=$(jq -r '.inbounds[] | select(.type == "shadowtls") | .handshake.server' "$SB_DIR/config.json")
    {
        echo "------------------------------------------------------------"
        echo "[12] ShadowTLS v3 + SS2022 (4443)  ※ 仅 sing-box / Clash 订阅支持:"
        echo "     服务器: $ip   端口: 4443"
        echo "     SS 加密: 2022-blake3-aes-128-gcm   SS 密码: $ST_SS_PASS"
        echo "     ShadowTLS 版本: 3   ShadowTLS 密码: $ST_PASS   伪装域名: $sni"
    } >> "$NODE_FILE"
}

# ---------- 服务端加固: 禁止代理访问内网/本机，屏蔽 BT ----------

server_hardened() {
    jq -e '(.route.rules // []) | map(select(.protocol == "bittorrent")) | length > 0' "$SB_DIR/config.json" >/dev/null 2>&1
}

harden_server() {
    # 若已有自定义 route 配置则不覆盖
    if jq -e '.route' "$SB_DIR/config.json" >/dev/null 2>&1; then
        return 0
    fi
    jq '.route = {
          "rules": [
            { "action": "sniff" },
            { "protocol": "bittorrent", "action": "reject" },
            { "ip_is_private": true, "action": "reject" }
          ],
          "final": "direct"
        }' "$SB_DIR/config.json" > "$SUB_DIR/config.tmp" && mv "$SUB_DIR/config.tmp" "$SB_DIR/config.json"
}

# 已部署的服务器: 不重置节点，追加 ShadowTLS / 安全规则（失败自动回滚）
refresh_server() {
    local need_st=0 need_hd=0 sni
    st_server_has || need_st=1
    server_hardened || need_hd=1
    if [ "$need_st" -eq 0 ] && [ "$need_hd" -eq 0 ]; then
        return 0
    fi

    echo "==> 更新服务端配置 (节点凭证保持不变)..."
    sni=$(jq -r '.outbounds[] | select(.tag == "Hugo-Reality-TCP") | .tls.server_name' "$SBOX_FILE")
    cp "$SB_DIR/config.json" "$SUB_DIR/config.json.bak"

    if [ "$need_st" -eq 1 ]; then
        if ! st_patch_server "$sni"; then
            cp "$SUB_DIR/config.json.bak" "$SB_DIR/config.json"
            echo "❌ 追加 ShadowTLS 失败，已回滚。"
            return 1
        fi
    fi
    if [ "$need_hd" -eq 1 ]; then
        if ! harden_server; then
            cp "$SUB_DIR/config.json.bak" "$SB_DIR/config.json"
            echo "❌ 追加安全规则失败，已回滚。"
            return 1
        fi
    fi
    if ! sing-box check -C "$SB_DIR"; then
        echo "❌ 配置检查未通过，已回滚到原配置。"
        cp "$SUB_DIR/config.json.bak" "$SB_DIR/config.json"
        return 1
    fi
    systemctl restart sing-box
    sleep 2
    if ! systemctl is-active --quiet sing-box; then
        echo "❌ sing-box 重启失败，已回滚到原配置。日志:"
        journalctl -u sing-box -n 20 --no-pager
        cp "$SUB_DIR/config.json.bak" "$SB_DIR/config.json"
        systemctl restart sing-box
        return 1
    fi
    [ "$need_st" -eq 1 ] && { open_firewall; echo "✅ ShadowTLS 已启用 (TCP 4443，记得在云安全组放行)"; }
    [ "$need_hd" -eq 1 ] && echo "✅ 已启用服务端安全规则 (禁止访问内网/本机地址，屏蔽 BT)"
    return 0
}

# 更新脚本相关文件（订阅服务、分流订阅），不改动节点凭证
refresh_sub() {
    if [ ! -f "$SBOX_FILE" ] || [ ! -f "$TOKEN_FILE" ]; then
        echo "❌ 未找到已部署的订阅文件，请先选择「全新部署」。"
        return 1
    fi
    install_deps
    echo "==> 重新生成订阅 (节点凭证保持不变)..."
    # 订阅端口直连: 更新订阅时请求不走代理，避免 VPN 开启时更新失败
    local SUBIP
    SUBIP=$(cat "$IP_FILE" 2>/dev/null)
    if [ -n "$SUBIP" ]; then
        jq --arg ip "$SUBIP/32" --argjson port "$SUB_PORT" '
          .route.rules = [ .route.rules[] | select((.port // []) != [$port]) ]
          | .route.rules = (.route.rules[0:2]
              + [ { "ip_cidr": [ $ip ], "port": [ $port ], "action": "route", "outbound": "direct" } ]
              + .route.rules[2:])
        ' "$SBOX_FILE" > "$SBOX_FILE.tmp" && mv "$SBOX_FILE.tmp" "$SBOX_FILE"
    fi
    refresh_server || return 1
    st_patch_client || return 1
    st_patch_nodefile
    if ! build_cn_profile; then
        echo "❌ 分流订阅生成失败。"
        return 1
    fi
    build_clash || return 1
    chmod 600 "$SUB_DIR"/* 2>/dev/null
    setup_sub_service
    echo "✅ 更新完成，请在手机 sing-box 里更新订阅配置。"
    echo ""
    show_nodes
}

# ---------- 全新部署 ----------

install_nodes() {
    install_deps
    install_singbox

    echo "==> 1. 停止旧服务并清理旧版残留..."
    systemctl stop sing-box 2>/dev/null
    systemctl stop hugo-sub 2>/dev/null
    mkdir -p "$SB_DIR" "$SUB_DIR"
    # 旧版脚本把 json/订阅放在 /etc/sing-box 里，会被 sing-box 当服务端配置合并，必须清掉
    rm -f "$SB_DIR/sub_singbox.json" "$SB_DIR/sub_b64.txt" "$SB_DIR/sub_links.txt" "$SB_DIR/sub_server.py"
    check_ports

    echo "==> 2. 生成凭证..."
    local KEYPAIR PRIV_KEY PUB_KEY
    KEYPAIR=$(sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUB_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then
        echo "❌ Reality 密钥生成失败！"
        exit 1
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    VMESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    ANYTLS_PASS=$(openssl rand -hex 12)
    HY2_PASS=$(openssl rand -hex 8)
    TUIC_PASS=$(openssl rand -hex 8)
    SS_PASS=$(openssl rand -base64 16)
    SS_CLASSIC_PASS=$(openssl rand -base64 16)
    TROJAN_PASS=$(openssl rand -hex 8)
    PROXY_USER="hugo"
    PROXY_PASS=$(openssl rand -hex 6)
    SHORT_ID=$(openssl rand -hex 8)
    SNI="gateway.icloud.com"
    # 订阅 token 重复部署时保持不变，手机上的订阅链接不用重新添加
    TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
    [ -z "$TOKEN" ] && TOKEN=$(openssl rand -hex 8)

    IP=$(get_ip)
    if [ -z "$IP" ]; then
        read -p "❌ 自动获取公网 IP 失败，请手动输入服务器公网 IP: " IP
    fi
    echo "$IP" > "$IP_FILE"
    echo "$TOKEN" > "$TOKEN_FILE"

    echo "==> 3. 生成自签名证书..."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$SB_DIR/hy2.key" -out "$SB_DIR/hy2.crt" \
        -days 3650 -subj "/CN=bing.com" \
        -addext "subjectAltName=DNS:bing.com" 2>/dev/null
    chmod 600 "$SB_DIR/hy2.key"
    chmod 644 "$SB_DIR/hy2.crt"
    if id sing-box >/dev/null 2>&1; then
        chown sing-box:sing-box "$SB_DIR/hy2.key" "$SB_DIR/hy2.crt" 2>/dev/null
    fi

    echo "==> 4. 写入服务端配置 (12 个协议入站)..."
    cat > "$SB_DIR/config.json" << CONFIG
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-tcp",
      "listen": "0.0.0.0", "listen_port": 443,
      "users": [ { "name": "hugo-tcp", "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$PRIV_KEY",
          "short_id": [ "$SHORT_ID" ]
        }
      }
    },
    {
      "type": "vless", "tag": "vless-grpc",
      "listen": "0.0.0.0", "listen_port": 444,
      "users": [ { "name": "hugo-grpc", "uuid": "$UUID" } ],
      "tls": {
        "enabled": true, "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$PRIV_KEY",
          "short_id": [ "$SHORT_ID" ]
        }
      },
      "transport": { "type": "grpc", "service_name": "hugogrpc" }
    },
    {
      "type": "vless", "tag": "xtls-reality-extra",
      "listen": "0.0.0.0", "listen_port": 8881,
      "users": [ { "name": "hugo-xtls-8881", "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$PRIV_KEY",
          "short_id": [ "$SHORT_ID" ]
        }
      }
    },
    {
      "type": "vmess", "tag": "vmess-in",
      "listen": "0.0.0.0", "listen_port": 3443,
      "users": [ { "name": "hugo-vmess", "uuid": "$VMESS_UUID", "alterId": 0 } ]
    },
    {
      "type": "anytls", "tag": "anytls-in",
      "listen": "0.0.0.0", "listen_port": 10000,
      "users": [ { "name": "hugo-anytls", "password": "$ANYTLS_PASS" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/hy2.crt",
        "key_path": "$SB_DIR/hy2.key"
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in",
      "listen": "0.0.0.0", "listen_port": 8443,
      "users": [ { "password": "$HY2_PASS" } ],
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true, "alpn": [ "h3" ],
        "certificate_path": "$SB_DIR/hy2.crt",
        "key_path": "$SB_DIR/hy2.key"
      }
    },
    {
      "type": "tuic", "tag": "tuic-in",
      "listen": "0.0.0.0", "listen_port": 9443,
      "users": [ { "uuid": "$UUID", "password": "$TUIC_PASS" } ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true, "alpn": [ "h3" ],
        "certificate_path": "$SB_DIR/hy2.crt",
        "key_path": "$SB_DIR/hy2.key"
      }
    },
    {
      "type": "shadowsocks", "tag": "ss-2022-in",
      "listen": "0.0.0.0", "listen_port": 6443,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASS"
    },
    {
      "type": "shadowsocks", "tag": "ss-classic-in",
      "listen": "0.0.0.0", "listen_port": 6555,
      "method": "aes-256-gcm",
      "password": "$SS_CLASSIC_PASS"
    },
    {
      "type": "trojan", "tag": "trojan-in",
      "listen": "0.0.0.0", "listen_port": 7443,
      "users": [ { "name": "hugo-trojan", "password": "$TROJAN_PASS" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/hy2.crt",
        "key_path": "$SB_DIR/hy2.key"
      }
    },
    {
      "type": "mixed", "tag": "mixed-in",
      "listen": "0.0.0.0", "listen_port": 5443,
      "users": [ { "username": "$PROXY_USER", "password": "$PROXY_PASS" } ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
CONFIG

    # 第 12 个协议: ShadowTLS v3
    if ! st_patch_server "$SNI"; then
        echo "❌ 写入 ShadowTLS 配置失败！"
        exit 1
    fi

    # 服务端安全规则: 禁止访问内网/本机地址，屏蔽 BT
    if ! harden_server; then
        echo "❌ 写入安全规则失败！"
        exit 1
    fi

    echo "==> 5. 检查配置并启动 sing-box..."
    if ! sing-box check -C "$SB_DIR"; then
        echo "❌ 服务端配置检查未通过，已中止（上面是具体报错）。"
        exit 1
    fi
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    sleep 2
    if ! systemctl is-active --quiet sing-box; then
        echo "❌ sing-box 启动失败，最近日志："
        journalctl -u sing-box -n 30 --no-pager
        exit 1
    fi
    echo "✅ sing-box 已正常运行"

    echo "==> 6. 生成节点链接..."
    VLESS_TCP="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&type=tcp&headerType=none#Hugo-Reality-TCP"
    VLESS_GP="vless://$UUID@$IP:444?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&type=grpc&serviceName=hugogrpc&mode=gun#Hugo-Reality-gRPC"
    XTLS_EXTRA="vless://$UUID@$IP:8881?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&type=tcp&headerType=none#Hugo-XTLS-Reality-8881"

    VMESS_JSON="{\"v\":\"2\",\"ps\":\"Hugo-VMess\",\"add\":\"$IP\",\"port\":\"3443\",\"id\":\"$VMESS_UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\"}"
    VMESS_LINK="vmess://$(b64 "$VMESS_JSON")"

    ANYTLS_LINK="anytls://$ANYTLS_PASS@$IP:10000?insecure=1&sni=bing.com#Hugo-AnyTLS"
    HY2_LINK="hysteria2://$HY2_PASS@$IP:8443?insecure=1&sni=bing.com#Hugo-Hysteria2"
    TUIC_LINK="tuic://$UUID:$TUIC_PASS@$IP:9443?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=bing.com&udp_relay_mode=native#Hugo-TuicV5"
    SS_LINK="ss://$(b64url "2022-blake3-aes-128-gcm:$SS_PASS")@$IP:6443#Hugo-Shadowsocks-2022"
    SS_CLASSIC_LINK="ss://$(b64url "aes-256-gcm:$SS_CLASSIC_PASS")@$IP:6555#Hugo-Shadowsocks-Classic"
    TROJAN_LINK="trojan://$TROJAN_PASS@$IP:7443?security=tls&allowInsecure=1&sni=bing.com#Hugo-Trojan"
    SOCKS_LINK="socks://$(b64url "$PROXY_USER:$PROXY_PASS")@$IP:5443#Hugo-Socks5-Mixed"

    cat > "$NODE_FILE" << LINKS
[1] VLESS-Reality-TCP (443):
$VLESS_TCP
------------------------------------------------------------
[2] VLESS-Reality-gRPC (444):
$VLESS_GP
------------------------------------------------------------
[3] XTLS-Reality-Extra (8881):
$XTLS_EXTRA
------------------------------------------------------------
[4] VMess (3443):
$VMESS_LINK
------------------------------------------------------------
[5] AnyTLS (10000):
$ANYTLS_LINK
------------------------------------------------------------
[6] Hysteria 2 (8443/udp):
$HY2_LINK
------------------------------------------------------------
[7] TUIC v5 (9443/udp):
$TUIC_LINK
------------------------------------------------------------
[8] Shadowsocks 2022 (6443):
$SS_LINK
------------------------------------------------------------
[9] Shadowsocks Classic (6555):
$SS_CLASSIC_LINK
------------------------------------------------------------
[10] Trojan (7443):
$TROJAN_LINK
------------------------------------------------------------
[11] SOCKS5/HTTP Mixed (5443):
$SOCKS_LINK
LINKS

    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
        "$VLESS_TCP" "$VLESS_GP" "$XTLS_EXTRA" "$VMESS_LINK" "$ANYTLS_LINK" \
        "$HY2_LINK" "$TUIC_LINK" "$SS_LINK" "$SS_CLASSIC_LINK" "$TROJAN_LINK" "$SOCKS_LINK" \
        | base64 -w0 > "$B64_FILE"

    st_patch_nodefile

    echo "==> 7. 生成 sing-box 客户端订阅 (iOS/macOS，需 App 1.12+)..."
    cat > "$SBOX_FILE" << SBCONFIG
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [
      { "type": "https", "tag": "dns-remote", "server": "1.1.1.1", "detour": "proxy" },
      { "type": "udp", "tag": "dns-local", "server": "223.5.5.5" }
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": [ "172.19.0.1/30" ],
      "auto_route": true
    }
  ],
  "outbounds": [
    {
      "type": "selector", "tag": "proxy",
      "outbounds": [ "auto", "Hugo-Reality-TCP", "Hugo-Reality-gRPC", "Hugo-XTLS-Reality-8881", "Hugo-VMess", "Hugo-AnyTLS", "Hugo-Hysteria2", "Hugo-TuicV5", "Hugo-Shadowsocks-2022", "Hugo-Shadowsocks-Classic", "Hugo-Trojan", "Hugo-Socks5-Mixed" ],
      "default": "auto"
    },
    {
      "type": "urltest", "tag": "auto",
      "outbounds": [ "Hugo-Reality-TCP", "Hugo-Reality-gRPC", "Hugo-XTLS-Reality-8881", "Hugo-AnyTLS", "Hugo-Hysteria2", "Hugo-TuicV5", "Hugo-Trojan", "Hugo-Shadowsocks-2022" ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "5m"
    },
    {
      "type": "vless", "tag": "Hugo-Reality-TCP",
      "server": "$IP", "server_port": 443,
      "uuid": "$UUID", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "$SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$PUB_KEY", "short_id": "$SHORT_ID" }
      }
    },
    {
      "type": "vless", "tag": "Hugo-Reality-gRPC",
      "server": "$IP", "server_port": 444,
      "uuid": "$UUID",
      "tls": {
        "enabled": true, "server_name": "$SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$PUB_KEY", "short_id": "$SHORT_ID" }
      },
      "transport": { "type": "grpc", "service_name": "hugogrpc" }
    },
    {
      "type": "vless", "tag": "Hugo-XTLS-Reality-8881",
      "server": "$IP", "server_port": 8881,
      "uuid": "$UUID", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "$SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$PUB_KEY", "short_id": "$SHORT_ID" }
      }
    },
    {
      "type": "vmess", "tag": "Hugo-VMess",
      "server": "$IP", "server_port": 3443,
      "uuid": "$VMESS_UUID", "security": "auto", "alter_id": 0
    },
    {
      "type": "anytls", "tag": "Hugo-AnyTLS",
      "server": "$IP", "server_port": 10000,
      "password": "$ANYTLS_PASS",
      "tls": { "enabled": true, "insecure": true, "server_name": "bing.com" }
    },
    {
      "type": "hysteria2", "tag": "Hugo-Hysteria2",
      "server": "$IP", "server_port": 8443,
      "password": "$HY2_PASS",
      "tls": { "enabled": true, "insecure": true, "server_name": "bing.com", "alpn": [ "h3" ] }
    },
    {
      "type": "tuic", "tag": "Hugo-TuicV5",
      "server": "$IP", "server_port": 9443,
      "uuid": "$UUID", "password": "$TUIC_PASS",
      "congestion_control": "bbr",
      "tls": { "enabled": true, "insecure": true, "server_name": "bing.com", "alpn": [ "h3" ] }
    },
    {
      "type": "shadowsocks", "tag": "Hugo-Shadowsocks-2022",
      "server": "$IP", "server_port": 6443,
      "method": "2022-blake3-aes-128-gcm", "password": "$SS_PASS"
    },
    {
      "type": "shadowsocks", "tag": "Hugo-Shadowsocks-Classic",
      "server": "$IP", "server_port": 6555,
      "method": "aes-256-gcm", "password": "$SS_CLASSIC_PASS"
    },
    {
      "type": "trojan", "tag": "Hugo-Trojan",
      "server": "$IP", "server_port": 7443,
      "password": "$TROJAN_PASS",
      "tls": { "enabled": true, "insecure": true, "server_name": "bing.com" }
    },
    {
      "type": "socks", "tag": "Hugo-Socks5-Mixed",
      "server": "$IP", "server_port": 5443,
      "username": "$PROXY_USER", "password": "$PROXY_PASS"
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_cidr": [ "$IP/32" ], "port": [ $SUB_PORT ], "action": "route", "outbound": "direct" },
      { "ip_is_private": true, "action": "route", "outbound": "direct" }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local"
  }
}
SBCONFIG

    if ! jq empty "$SBOX_FILE" 2>/dev/null; then
        echo "❌ 客户端 JSON 格式错误！"
        exit 1
    fi

    # 追加 ShadowTLS 客户端节点
    st_patch_client || exit 1

    # 大陆直连分流版本（在全局版基础上追加规则集）
    build_cn_profile

    # Clash Meta (Mihomo) 订阅
    build_clash

    # 校验客户端配置语法（仅提示，不影响部署）
    if ! sing-box check -c "$SBOX_FILE" >/dev/null 2>&1; then
        echo "⚠️  客户端配置未通过本机 sing-box 语法检查，详情:"
        sing-box check -c "$SBOX_FILE" 2>&1 | head -5
    fi

    chmod 600 "$SUB_DIR"/* 2>/dev/null
    chmod 644 "$SUB_DIR/server.py" 2>/dev/null

    open_firewall
    setup_sub_service

    echo ""
    echo "✅ 部署完成！"
    echo ""
    show_nodes
}

# ---------- 订阅二维码 ----------

urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

install_pkg() {
    local pkg="$1"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1; apt-get install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg"
    fi
}

show_qr() {
    if [ ! -f "$TOKEN_FILE" ]; then
        echo "❌ 未找到订阅信息，请先选择「全新部署」。"
        return 1
    fi
    if ! command -v qrencode >/dev/null 2>&1; then
        echo "==> 安装二维码工具 qrencode..."
        install_pkg qrencode
    fi
    if ! command -v qrencode >/dev/null 2>&1; then
        echo "❌ qrencode 安装失败，无法显示二维码。"
        return 1
    fi

    local ip token base choice url
    ip=$(cat "$IP_FILE" 2>/dev/null)
    token=$(cat "$TOKEN_FILE" 2>/dev/null)
    base="http://$ip:$SUB_PORT/$token"

    choice="$1"
    if [ -z "$choice" ]; then
        echo "$LINE"
        echo "  1. 通用订阅 (小火箭 / V2rayN / v2rayNG 扫码)"
        echo "  2. sing-box 苹果端 - 全局代理"
        echo "  3. sing-box 苹果端 - 大陆直连分流"
        echo "  4. Clash Meta 订阅"
        echo "$LINE"
        read -p "请选择要显示二维码的订阅 [1-4]: " choice
    fi
    case "$choice" in
        1) url="$base/sub" ;;
        2) url="sing-box://import-remote-profile?url=$(urlenc "$base/singbox")#Hugo-Global" ;;
        3) url="sing-box://import-remote-profile?url=$(urlenc "$base/singbox-cn")#Hugo-CN" ;;
        4) url="$base/clash" ;;
        *) echo "❌ 无效选择。"; return 1 ;;
    esac
    echo ""
    echo "$url"
    echo ""
    qrencode -t ANSIUTF8 "$url"
    echo ""
    echo "💡 若扫码后 App 没有自动导入，请直接复制上面的链接手动添加。"
}

# ---------- BBR 加速 ----------

enable_bbr() {
    local cur
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$cur" = "bbr" ]; then
        echo "✅ BBR 已经开启，无需重复设置。"
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo "❌ 当前内核不支持 BBR (需要 Linux 4.9 及以上)。"
        return 1
    fi
    echo "tcp_bbr" > /etc/modules-load.d/hugo-bbr.conf
    cat > /etc/sysctl.d/99-hugo-bbr.conf << 'BBREOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBREOF
    sysctl -p /etc/sysctl.d/99-hugo-bbr.conf >/dev/null 2>&1
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$cur" = "bbr" ]; then
        echo "✅ BBR 已开启，重启后依然生效。"
    else
        echo "❌ BBR 开启失败，当前拥塞算法: $cur"
        return 1
    fi
}

# ---------- 流量统计 ----------

show_traffic() {
    local iface fresh=0
    if ! command -v vnstat >/dev/null 2>&1; then
        echo "==> 安装流量统计工具 vnstat..."
        install_pkg vnstat
        fresh=1
    fi
    if ! command -v vnstat >/dev/null 2>&1; then
        echo "❌ vnstat 安装失败。"
        return 1
    fi
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$iface" ]; then
        echo "❌ 未能识别默认网卡。"
        return 1
    fi
    vnstat --add -i "$iface" >/dev/null 2>&1
    systemctl enable --now vnstat >/dev/null 2>&1
    echo "$LINE"
    echo "📊 网卡: $iface   (tx = 出站流量，云服务器通常按出站计费)"
    echo "$LINE"
    if [ "$fresh" -eq 1 ]; then
        echo "ℹ️  vnstat 刚安装，需要运行一段时间才会有数据，请稍后再查看。"
    fi
    vnstat -i "$iface" -d 7 2>&1
    echo ""
    vnstat -i "$iface" -m 2>&1
    echo "$LINE"
}

# ---------- 升级 ----------

upgrade_singbox() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo "❌ 未安装 sing-box。"
        return 1
    fi
    local old new
    old=$(sing-box version 2>/dev/null | awk 'NR==1{print $3}')
    echo "当前 sing-box 版本: $old"
    read -p "确定升级到最新版吗？(y/N): " CONFIRM
    case "$CONFIRM" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "❌ 已取消。"; return 0 ;;
    esac

    mkdir -p "$SUB_DIR"
    cp "$SB_DIR/config.json" "$SUB_DIR/config.json.upgrade.bak" 2>/dev/null

    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        bash <(curl -fsSL https://sing-box.app/deb-install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi

    # 升级过程不应改动我们的配置，若被改动则还原
    if [ -f "$SUB_DIR/config.json.upgrade.bak" ] && ! cmp -s "$SUB_DIR/config.json.upgrade.bak" "$SB_DIR/config.json"; then
        cp "$SUB_DIR/config.json.upgrade.bak" "$SB_DIR/config.json"
    fi

    new=$(sing-box version 2>/dev/null | awk 'NR==1{print $3}')
    echo "升级后版本: $new"
    if ! sing-box check -C "$SB_DIR"; then
        echo "⚠️  新版本对现有配置的检查未通过（上面是具体报错），暂未重启服务，仍在运行旧进程。"
        return 1
    fi
    systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
        echo "✅ 升级完成: $old -> $new"
    else
        echo "❌ 升级后 sing-box 启动失败，日志:"
        journalctl -u sing-box -n 20 --no-pager
        return 1
    fi
}

upgrade_script() {
    echo "==> 下载最新脚本..."
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL "$SCRIPT_URL" -o "$tmp" || [ ! -s "$tmp" ]; then
        echo "❌ 下载失败: $SCRIPT_URL"
        rm -f "$tmp"
        return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        echo "❌ 下载的脚本语法检查未通过，已放弃更新。"
        rm -f "$tmp"
        return 1
    fi
    install -m 755 "$tmp" /usr/local/bin/sub
    rm -f "$tmp"
    echo "✅ 脚本已更新，正在用新版本更新订阅与服务端配置 (不重置节点)..."
    exec /usr/local/bin/sub refresh
}

# ---------- 入口 ----------

case "$1" in
    install)   install_nodes;   exit 0 ;;
    uninstall) uninstall_nodes; exit 0 ;;
    status)    check_status;    exit 0 ;;
    show)      show_nodes;      exit 0 ;;
    refresh)   refresh_sub;     exit 0 ;;
    qr)        show_qr "$2";   exit 0 ;;
    bbr)       enable_bbr;      exit 0 ;;
    traffic)   show_traffic;    exit 0 ;;
    upgrade-core) upgrade_singbox; exit 0 ;;
    upgrade)   upgrade_script;  exit 0 ;;
esac

echo "$LINE"
echo "          Hugo sing-box 12 协议一键管理脚本（重制版）        "
echo "$LINE"
echo "  1. 查看当前节点信息及订阅链接"
echo "  2. 全新部署 / 重置 12 大协议节点（生成新凭证及订阅）"
echo "  3. 状态检测（排查不通问题）"
echo "  4. 彻底卸载 sing-box 及清除所有服务"
echo "  5. 更新订阅 / 追加新功能（不重置节点）"
echo "  6. 订阅二维码"
echo "  7. 开启 BBR 加速"
echo "  8. 流量统计"
echo "  9. 升级 sing-box 内核"
echo " 10. 升级本脚本（并自动更新，不重置节点）"
echo "  0. 退出"
echo "$LINE"
read -p "请输入数字选择 [0-10]: " CHOICE

case "$CHOICE" in
    1) show_nodes ;;
    2) install_nodes ;;
    3) check_status ;;
    4) uninstall_nodes ;;
    5) refresh_sub ;;
    6) show_qr ;;
    7) enable_bbr ;;
    8) show_traffic ;;
    9) upgrade_singbox ;;
    10) upgrade_script ;;
    0) exit 0 ;;
    *) echo "❌ 无效输入，脚本已退出。"; exit 1 ;;
esac

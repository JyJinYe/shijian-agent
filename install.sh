#!/usr/bin/env bash
# Shijian Agent installer v1. Configuration is read only from stdin.
set -euo pipefail
set +x
umask 077
step='检查安装参数'
work=''
locked=0
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$work" ]; then rm -rf -- "$work"; fi
  if [ "$locked" = 1 ]; then rmdir /run/shijian-probe-install.lock 2>/dev/null || true; fi
  if [ "$status" != 0 ]; then
    printf '安装失败：%s。已有配置和状态不会被自动删除；请排查后重试，已有安装请使用升级流程。\n' "$step" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf '%s\n' "$1" >&2; exit 1; }
platform='' version='' digest='' image_id=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || fail '安装参数缺少值'
  case "$1" in
    --platform) platform=$2;;
    --version) version=$2;;
    --sha256) digest=$2;;
    --image-id) image_id=$2;;
    *) fail '未知安装参数';;
  esac
  shift 2
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || fail '版本无效'
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail '安装包摘要无效'
case "$platform" in
  linux-amd64) filename="shijian-probe-$version-linux-amd64.tar.gz";;
  docker-amd64)
    filename="shijian-probe-$version-docker-amd64.tar.gz"
    [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Docker 镜像 ID 无效';;
  *) fail '此安装脚本仅支持 Linux amd64/systemd 和 Docker amd64';;
esac
step='检查目标系统与依赖'
[ "$(id -u)" = 0 ] || fail '请以 root 执行安装命令'
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail '当前固定包仅支持 Linux amd64'
for tool in curl sha256sum mktemp install cat head wc rm rmdir mkdir; do
  command -v "$tool" >/dev/null 2>&1 || fail "缺少依赖：$tool，请先安装后重试"
done
if [ "$platform" = linux-amd64 ]; then
  for tool in tar gzip systemctl; do
    command -v "$tool" >/dev/null 2>&1 || fail "缺少依赖：$tool，请先安装后重试"
  done
  [ -d /run/systemd/system ] || fail '当前系统未运行 systemd'
else
  command -v docker >/dev/null 2>&1 || fail '请先安装并启动 rootful Docker Engine'
  command -v gzip >/dev/null 2>&1 || fail '缺少依赖：gzip'
  kernel=$(uname -r)
  [[ "$kernel" =~ ^([0-9]+)\.([0-9]+) ]] || fail '无法识别 Linux 内核版本'
  major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
  (( major > 5 || (major == 5 && minor >= 12) )) || fail 'Docker 宿主机安装需要 Linux 5.12 或以上'
  docker info >/dev/null 2>&1 || fail 'Docker Engine 无法访问，请检查服务状态'
  security=$(docker info --format '{{json .SecurityOptions}}')
  [[ "$security" != *rootless* ]] || fail '当前安装不支持 rootless Docker'
  operating_system=$(docker info --format '{{.OperatingSystem}}')
  [[ "$operating_system" != *'Docker Desktop'* ]] || fail '当前安装不支持 Docker Desktop'
fi
step='检查已有安装'
mkdir /run/shijian-probe-install.lock 2>/dev/null || fail '另一个安装正在运行，或上次中断留下安装锁，请先检查 /run/shijian-probe-install.lock'
locked=1
for path in /etc/shijian-probe /var/lib/shijian-probe /etc/systemd/system/shijian-probe.service /usr/local/bin/shijian-probe; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || fail '检测到已有安装，请使用升级/回滚流程'
done
# A Docker installation must also block an attempted native installation.
if command -v docker >/dev/null 2>&1; then
  if docker container inspect shijian-probe >/dev/null 2>&1; then
    fail '检测到已有 Docker 安装，请使用升级/回滚流程'
  fi
fi
step='读取安装配置'
work=$(mktemp -d /tmp/shijian-install.XXXXXXXX)
# The UI supplies JSON. Agent validates its schema before starting collection.
# Limit input size without printing its contents or passing it as a process argument.
head -c 65537 > "$work/config.json"
config_size=$(wc -c < "$work/config.json")
[ "$config_size" -gt 0 ] && [ "$config_size" -le 65536 ] || fail '安装配置为空或超过 64 KiB'
step='从 GitHub 下载固定版本包'
printf '正在下载 Agent %s (%s)…\n' "$version" "$platform"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 \
  "https://github.com/JyJinYe/shijian-agent/releases/download/agent-$version/$filename" \
  --output "$work/$filename"
step='校验安装包 SHA256'
(cd "$work" && printf '%s  %s\n' "$digest" "$filename" | sha256sum -c -)
if [ "$platform" = linux-amd64 ]; then
  step='解压并检查程序'
  mkdir "$work/unpacked"
  # Extract only the expected executable from the checksum-verified package.
  tar -xzf "$work/$filename" -C "$work/unpacked" -- shijian-probe
  [ -f "$work/unpacked/shijian-probe" ] && [ ! -L "$work/unpacked/shijian-probe" ] || fail '包内程序无效'
  [ "$("$work/unpacked/shijian-probe" -version)" = "$version" ] || fail '包内程序版本不符'
else
  step='加载并检查固定 Docker 镜像'
  gzip -dc "$work/$filename" | docker load
  docker image inspect "$image_id" >/dev/null
fi
step='安装配置与创建状态目录'
install -d -m 700 /etc/shijian-probe /var/lib/shijian-probe
install -m 600 "$work/config.json" /etc/shijian-probe/config.json
if [ "$platform" = linux-amd64 ]; then
  step='安装程序与 systemd 服务'
  install -m 755 "$work/unpacked/shijian-probe" /usr/local/bin/shijian-probe
  cat > "$work/shijian-probe.service" <<'UNIT'
[Unit]
Description=Shijian native host probe
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/shijian-probe -config /etc/shijian-probe/config.json
Restart=on-failure
RestartSec=15
User=root
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/shijian-probe
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
[Install]
WantedBy=multi-user.target
UNIT
  install -m 644 "$work/shijian-probe.service" /etc/systemd/system/shijian-probe.service
  step='启动 systemd 服务'
  systemctl daemon-reload
  systemctl enable --now shijian-probe
  systemctl is-active --quiet shijian-probe
  printf 'Agent 服务已启动。查看状态：systemctl status --no-pager shijian-probe\n'
else
  step='启动 Docker 容器'
  docker run -d --name shijian-probe --restart unless-stopped \
    --network host --pid host --read-only --cap-drop ALL --cap-add NET_RAW \
    --security-opt no-new-privileges \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    --mount type=bind,src=/,dst=/host,readonly,bind-propagation=rslave \
    --mount type=bind,src=/etc/shijian-probe/config.json,dst=/etc/shijian-probe/config.json,readonly \
    --mount type=bind,src=/var/lib/shijian-probe,dst=/var/lib/shijian-probe \
    "$image_id"
  [ "$(docker inspect --format '{{.State.Running}}' shijian-probe)" = true ] || fail '容器未进入运行状态'
  printf 'Agent 容器已启动。查看状态：docker inspect shijian-probe\n'
fi
printf '请返回主站确认收到上报；服务启动不代表主站已经接收数据。\n'

#!/usr/bin/env bash
# Shijian Agent installer v6. Keep all setup and operation instructions here.
set +x
# Keep execution inside one function so a truncated curl response cannot run a partial install.
shijian_install_main() {
set -euo pipefail
umask 077
step='检查安装参数'
work=''
locked=0
state_lock_fd=''
config_tmp=''
binary_tmp=''
installed=''
backup=''
upgrade_started=0
upgrade_complete=0
old_running=0
container_renamed=0
rollback_container=''
rebind=0
state_archive=''
new_native_files=0
release_state_lock() {
  if [ -n "$state_lock_fd" ]; then
    flock -u "$state_lock_fd" || true
    exec {state_lock_fd}>&-
    state_lock_fd=''
  fi
}
cleanup() {
  local status=$?
  trap - EXIT
  release_state_lock
  if [ "$status" != 0 ] && [ "$upgrade_started" = 1 ] && [ "$upgrade_complete" = 0 ]; then
    set +e
    rollback_ok=1
    if [ "$installed" = docker-amd64 ] && [ -n "$rollback_container" ] && docker container inspect "$rollback_container" >/dev/null 2>&1; then container_renamed=1; fi
    printf '安装未完成，正在恢复原部署；同节点保留最新队列，重新绑定时分别保留新旧节点状态。\n' >&2
    if [ "$installed" = linux-amd64 ]; then
      systemctl stop shijian-probe || rollback_ok=0
      binary_tmp=$(mktemp /usr/local/bin/.shijian-probe.XXXXXXXX)
      if install -m 755 "$backup/shijian-probe" "$binary_tmp"; then
        mv -f -- "$binary_tmp" /usr/local/bin/shijian-probe || rollback_ok=0
      else rollback_ok=0; fi
      binary_tmp=''
    elif [ "$container_renamed" = 1 ]; then
      if docker container inspect shijian-probe >/dev/null 2>&1; then docker rm -f shijian-probe >/dev/null || rollback_ok=0; fi
    fi
    if [ -z "$installed" ]; then
      if [ "$platform" = linux-amd64 ] && [ "$new_native_files" = 1 ]; then
        systemctl stop shijian-probe 2>/dev/null || true
        rm -f /usr/local/bin/shijian-probe /etc/systemd/system/shijian-probe.service || rollback_ok=0
        systemctl daemon-reload || rollback_ok=0
      elif [ "$platform" = docker-amd64 ] && docker container inspect shijian-probe >/dev/null 2>&1; then
        docker rm -f shijian-probe >/dev/null || rollback_ok=0
      fi
    fi
    # A different identity must never inherit the previous node's outbox.
    # Move complete directories on the same filesystem; do not overwrite either
    # node's latest state with a copied snapshot during rollback.
    if [ -n "$state_archive" ] && [ -d "$state_archive/previous" ]; then
      if [ -e /var/lib/shijian-probe ]; then
        mv -- /var/lib/shijian-probe "$state_archive/failed-new-state" || rollback_ok=0
      fi
      if [ ! -e /var/lib/shijian-probe ]; then
        mv -- "$state_archive/previous" /var/lib/shijian-probe || rollback_ok=0
      else rollback_ok=0; fi
    fi
    if [ -f "$backup/config.json" ]; then
      config_tmp=$(mktemp /etc/shijian-probe/.config.XXXXXXXX)
      if install -m 600 "$backup/config.json" "$config_tmp"; then
        mv -f -- "$config_tmp" /etc/shijian-probe/config.json || rollback_ok=0
      else rollback_ok=0; fi
      config_tmp=''
    fi
    if [ "$installed" = linux-amd64 ]; then
      if [ "$old_running" = 1 ]; then systemctl start shijian-probe || rollback_ok=0; fi
    elif [ "$installed" = docker-amd64 ]; then
      if [ "$container_renamed" = 1 ]; then docker rename "$rollback_container" shijian-probe || rollback_ok=0; fi
      if [ "$old_running" = 1 ]; then docker start shijian-probe >/dev/null || rollback_ok=0; fi
    fi
    if [ "$rollback_ok" = 1 ]; then printf '原程序/容器及配置已恢复，备份位于 %s。\n' "$backup" >&2
    else printf '自动恢复未全部成功，请按备份 %s 检查原部署；最新状态未被旧备份覆盖。\n' "$backup" >&2; fi
  fi
  if [ -n "$binary_tmp" ]; then rm -f -- "$binary_tmp"; fi
  if [ -n "$config_tmp" ]; then rm -f -- "$config_tmp"; fi
  if [ -n "$work" ]; then rm -rf -- "$work"; fi
  if [ "$locked" = 1 ]; then rmdir /run/shijian-probe-install.lock 2>/dev/null || true; fi
  if [ "$status" != 0 ]; then
    printf '安装失败：%s。已有配置和状态不会被自动删除；请根据上方原因排查后重试。\n' "$step" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf '%s\n' "$1" >&2; exit 1; }
printf '时见 Agent 安装：需要 root 和 Linux amd64；原生安装需要 systemd，Docker 安装需要 Linux >=5.12 与 rootful Docker。\n'
printf '安装包按固定版本校验 SHA256；同一部署方式可直接覆盖；同节点保留队列，新节点先隔离旧状态再重新绑定，先验包再停机并备份，失败恢复原部署；保留最新状态重装，自动更新关闭。命令包含长期节点凭据，请勿公开或分享。\n'
platform='linux-amd64' version='' digest='' image_id=''
endpoint='' server_id='' token='' interfaces='' github_proxy=''
interfaces_set=0
package_file='' config_file=''
usage() { printf '用法：安装命令 --endpoint HTTPS主站 --server-id 节点ID --token 上报令牌 [--interfaces eth0,eth1] [--docker] [--github-proxy https://gh-proxy.org/]\n'; }
if [ "$#" = 0 ]; then usage; fail '缺少安装配置'; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help) usage; exit 0;;
    --docker) platform='docker-amd64'; shift; continue;;
  esac
  [ "$#" -ge 2 ] || fail '安装参数缺少值'
  case "$1" in
    --package-file) package_file=$2;;
    --config-file) config_file=$2;;
    --github-proxy) github_proxy=$2;;
    --endpoint) endpoint=$2;;
    --server-id) server_id=$2;;
    --token) token=$2;;
    --interfaces) interfaces=$2; interfaces_set=1;;
    --platform) platform=$2;;
    --version) version=$2;;
    --sha256) digest=$2;;
    --image-id) image_id=$2;;
    *) fail '未知安装参数';;
  esac
  shift 2
done
case "$github_proxy" in
  ''|'https://gh-proxy.org/') ;;
  *) fail '不支持的 GitHub 下载代理';;
esac
# BEGIN FROZEN RELEASE
release_version='0.3.0-preview.12'
native_sha256='ed5309269a0ca46694d29d55f5643aa92786cc10fb6b5090dd2164de1f63c92d'
docker_sha256='65d2bc6e5791eb9d8520fae1432ece53117b597d88e19dd5dad3dbace9b26f20'
docker_image_id='sha256:c4e9ca927bd724179417fc7337d36288df1337af5b950f9be3c30fc3391b7d86'
# END FROZEN RELEASE
version=${version:-$release_version}
case "$platform" in
  linux-amd64) digest=${digest:-$native_sha256};;
  docker-amd64) digest=${digest:-$docker_sha256}; image_id=${image_id:-$docker_image_id};;
esac
config_from_args=0
if [ -n "$endpoint$server_id$token$interfaces" ]; then
  config_from_args=1
  [[ "$endpoint" =~ ^https://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?/?$ ]] || fail '需要可信 HTTPS 主站地址，不允许路径、查询参数或用户信息'
  [[ "$server_id" =~ ^[A-Za-z0-9_-]{1,80}$ ]] || fail '节点 ID 无效'
  [[ "$token" =~ ^ms_[a-f0-9]{8}_[A-Za-z0-9_-]{32}$ ]] || fail '上报令牌格式无效'
  if [ -n "$interfaces" ]; then
    [[ "$interfaces" =~ ^[A-Za-z0-9_.:-]{1,80}(,[A-Za-z0-9_.:-]{1,80})*$ ]] && [ "${#interfaces}" -le 8000 ] || fail '统计接口名无效'
  fi
fi
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
for tool in curl sha256sum mktemp install cat head wc stat mv rm rmdir mkdir cp grep sleep; do
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
for path in /usr/lib/systemd/system/shijian-probe.service /lib/systemd/system/shijian-probe.service; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || fail '检测到非标准服务安装，请人工迁移，未停止原服务'
done
native_present=0
for path in /etc/systemd/system/shijian-probe.service /usr/local/bin/shijian-probe; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    native_present=1
    [ ! -L "$path" ] && [ -f "$path" ] && [ "$(stat -c %u "$path")" = 0 ] || fail '已有程序或服务不是 root 所有的普通文件，拒绝覆盖'
  fi
done
if [ "$native_present" = 1 ]; then
  [ -f /etc/systemd/system/shijian-probe.service ] && [ -x /usr/local/bin/shijian-probe ] || fail '已有安装不完整，缺少标准程序或服务，请人工检查'
  grep -Fxq 'ExecStart=/usr/local/bin/shijian-probe -config /etc/shijian-probe/config.json' /etc/systemd/system/shijian-probe.service || fail '已有服务使用非标准启动参数，请人工迁移'
  installed=linux-amd64
elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet shijian-probe; then
  fail 'Agent 服务仍在运行但没有标准安装文件，拒绝覆盖'
fi
for path in /etc/shijian-probe /var/lib/shijian-probe; do
  [ ! -L "$path" ] || fail '保留目录不能是符号链接，请人工检查，未改动配置与状态'
  if [ -e "$path" ]; then
    [ -d "$path" ] || fail '保留目录路径被其他文件占用，请人工检查'
    [ "$(stat -c %u "$path")" = 0 ] || fail '保留目录必须属于 root，请人工检查'
  fi
done
for path in /etc/shijian-probe/config.json /etc/shijian-probe/OPERATIONS.txt /var/lib/shijian-probe/state.json /var/lib/shijian-probe/state.json.lock /var/lib/shijian-probe/state.json.tmp; do
  [ ! -L "$path" ] || fail '保留配置或状态不能是符号链接，请人工检查'
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(stat -c %u "$path")" = 0 ] || fail '保留配置或状态不是 root 所有的普通文件，请人工检查'
  fi
done
# A Docker installation must also block an attempted native installation.
if command -v docker >/dev/null 2>&1; then
  if docker container inspect shijian-probe >/dev/null 2>&1; then
    [ -z "$installed" ] || fail '同时检测到原生服务和 Docker 容器，请人工检查，未停止原部署'
    installed=docker-amd64
  fi
fi
if [ -n "$installed" ]; then
  [ "$installed" = "$platform" ] || fail '已有安装的部署方式不同，拒绝跨部署方式覆盖，请先人工迁移'
  [ -f /etc/shijian-probe/config.json ] || fail '已有安装缺少原 config.json，无法确认节点身份，未停止原部署'
  command -v flock >/dev/null 2>&1 || fail '覆盖升级需要 flock（util-linux），请安装后重试'
  if [ "$installed" = docker-amd64 ]; then
    mounts=$(docker inspect --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' shijian-probe)
    printf '%s\n' "$mounts" | grep -Fxq '/etc/shijian-probe/config.json -> /etc/shijian-probe/config.json' || fail '已有 Docker 容器使用不同配置挂载，请人工迁移'
    printf '%s\n' "$mounts" | grep -Fxq '/var/lib/shijian-probe -> /var/lib/shijian-probe' || fail '已有 Docker 容器使用不同状态挂载，请人工迁移'
    [ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' shijian-probe)" = host ] && [ "$(docker inspect --format '{{.HostConfig.PidMode}}' shijian-probe)" = host ] || fail '已有 Docker 容器不是标准宿主机部署，请人工迁移'
    restart_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' shijian-probe)
    case "$restart_policy" in always|unless-stopped|no) ;; *) fail '已有容器使用非标准重启策略，请人工迁移';; esac
  fi
fi
step='读取安装配置'
work=$(mktemp -d /tmp/shijian-install.XXXXXXXX)
if [ "$config_from_args" = 1 ]; then
  # Every value is restricted above to JSON-safe characters; never evaluate arguments as shell code.
  printf '{"endpoint":"%s","server_id":"%s","token":"%s","interfaces":"%s","state_file":"/var/lib/shijian-probe/state.json"}\n' \
    "$endpoint" "$server_id" "$token" "$interfaces" > "$work/config.json"
else
  # Compatibility for commands that pass an explicit package checksum and JSON via stdin.
  if [ -n "$config_file" ]; then head -c 65537 -- "$config_file" > "$work/config.json"
  else head -c 65537 > "$work/config.json"; fi
fi
config_size=$(wc -c < "$work/config.json")
[ "$config_size" -gt 0 ] && [ "$config_size" -le 65536 ] || fail '安装配置为空或超过 64 KiB'
# Parse only the flat string configuration format emitted by the installation UI.
# Escaped strings, duplicate/unknown keys and malformed JSON require manual review.
read_identity() {
  local json key value prefix
  local -A fields=()
  json=$(cat -- "$1")
  [[ "$json" =~ ^[[:space:]]*\{ ]] || return 1
  json=${json:${#BASH_REMATCH[0]}}
  local entry='^[[:space:]]*"([^"\\[:cntrl:]]+)"[[:space:]]*:[[:space:]]*"([^"\\[:cntrl:]]*)"[[:space:]]*'
  while :; do
    [[ "$json" =~ $entry ]] || return 1
    prefix=${BASH_REMATCH[0]} key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    case "$key" in endpoint|server_id|token|interfaces|state_file) ;; *) return 1;; esac
    [[ ! -v 'fields[$key]' ]] || return 1
    fields[$key]=$value
    json=${json:${#prefix}}
    if [[ "$json" =~ ^\}[[:space:]]*$ ]]; then break; fi
    [[ "$json" = ,* ]] || return 1
    json=${json:1}
  done
  [ -n "${fields[endpoint]:-}" ] && [ -n "${fields[server_id]:-}" ] && [ -n "${fields[state_file]:-}" ] || return 1
  config_endpoint=${fields[endpoint]%/}
  config_server_id=${fields[server_id]}
  config_state_file=${fields[state_file]}
  config_interfaces=${fields[interfaces]:-}
  config_token=${fields[token]:-}
}
step='检查保留配置与状态的归属'
recover=0
state_present=0
for path in /var/lib/shijian-probe/* /var/lib/shijian-probe/.[!.]* /var/lib/shijian-probe/..?*; do
  if [ -e "$path" ] || [ -L "$path" ]; then state_present=1; break; fi
done
if [ -f /etc/shijian-probe/config.json ]; then
  [ "$(wc -c < /etc/shijian-probe/config.json)" -le 65536 ] || fail '保留配置过大，请人工检查，未改动原配置与状态'
  read_identity /etc/shijian-probe/config.json || fail '无法可靠读取保留配置的节点身份；仅自动恢复标准字符串配置，请人工检查，未改动原配置与状态'
  old_endpoint=$config_endpoint old_server_id=$config_server_id old_state_file=$config_state_file old_interfaces=$config_interfaces
  read_identity "$work/config.json" || fail '无法读取本次配置的节点身份，未改动原配置与状态'
  if [ "$old_endpoint" != "$config_endpoint" ] || [ "$old_server_id" != "$config_server_id" ]; then
    rebind=1
  fi
  [ "$old_state_file" = /var/lib/shijian-probe/state.json ] && [ "$config_state_file" = "$old_state_file" ] || fail '保留配置使用了不同的状态路径，请人工迁移，未改动原配置与状态'
  recover=1
  if [ "$rebind" = 0 ] && [ "$interfaces_set" = 0 ] && [ -z "$config_interfaces" ]; then
    # An omitted/empty initial interface selection keeps the local selection.
    [[ "$old_interfaces" != *'"'* ]] || fail '原统计接口配置无效'
    printf '{"endpoint":"%s","server_id":"%s","token":"%s","interfaces":"%s","state_file":"/var/lib/shijian-probe/state.json"}\n' "$config_endpoint" "$config_server_id" "$config_token" "$old_interfaces" > "$work/config.json"
  fi
elif [ "$state_present" = 1 ]; then
  fail '检测到保留状态但缺少原 config.json，无法确认所属节点；请恢复原配置后重装，未删除状态'
fi
if [ "$recover" = 1 ]; then
  if command -v docker >/dev/null 2>&1; then
    docker info >/dev/null 2>&1 || fail '存在保留配置但 Docker 无法访问，无法确认旧容器已卸载，请先检查 Docker'
  fi
  if [ "$state_present" = 1 ] && [ -z "$installed" ]; then
    command -v flock >/dev/null 2>&1 || fail '恢复保留状态需要 flock（util-linux），请安装后重试'
    exec {state_lock_fd}<> /var/lib/shijian-probe/state.json.lock
    flock -n "$state_lock_fd" || fail '保留状态仍被 Agent 进程占用，请先停止原进程；未改动配置与状态'
  fi
  if [ "$rebind" = 1 ]; then
    printf '检测到节点或主站变更：将备份旧配置并隔离完整旧状态，新节点使用独立会话和队列；不会将旧数据补报到新节点。\n'
  else
    printf '检测到同一节点的保留配置，重装将保留最新状态与补报队列，并备份旧配置后更新本次凭据。\n'
  fi
fi
if [ -n "$package_file" ]; then
  step='读取本地固定版本包'
  [ -f "$package_file" ] && [ ! -L "$package_file" ] || fail '本地安装包必须是普通文件'
  cp -- "$package_file" "$work/$filename"
else
  step='从 GitHub 下载固定版本包'
  printf '正在下载 Agent %s (%s)…\n' "$version" "$platform"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 \
    "${github_proxy}https://github.com/JyJinYe/shijian-agent/releases/download/agent-$version/$filename" \
    --output "$work/$filename"
fi
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
# Downloads and integrity/version checks above never interrupt the old process.
if [ -n "$installed" ] || [ "$rebind" = 1 ]; then
  step='备份并停止旧 Agent'
  install -d -m 700 /var/lib/shijian-probe
  backup=$(mktemp -d /etc/shijian-probe/upgrade-backup.XXXXXXXX)
  install -m 600 /etc/shijian-probe/config.json "$backup/config.json"
  install -m 600 "$work/config.json" "$backup/requested-config.json"
  if [ -f /etc/shijian-probe/OPERATIONS.txt ]; then install -m 600 /etc/shijian-probe/OPERATIONS.txt "$backup/OPERATIONS.txt"; fi
  if [ "$installed" = linux-amd64 ]; then
    install -m 700 /usr/local/bin/shijian-probe "$backup/shijian-probe"
    install -m 600 /etc/systemd/system/shijian-probe.service "$backup/shijian-probe.service"
    if systemctl is-active --quiet shijian-probe; then old_running=1; fi
  elif [ "$installed" = docker-amd64 ]; then
    docker container inspect shijian-probe > "$backup/container.json"
    if [ "$(docker inspect --format '{{.State.Running}}' shijian-probe)" = true ]; then old_running=1; fi
    rollback_container="shijian-probe-backup-${backup##*.}"
  fi
  upgrade_started=1
  if [ "$installed" = linux-amd64 ]; then systemctl stop shijian-probe
  elif [ "$installed" = docker-amd64 ]; then
    docker stop --time 25 shijian-probe >/dev/null
    docker rename shijian-probe "$rollback_container"
    container_renamed=1
  fi
  step='锁定并备份最新状态'
  if [ -z "$state_lock_fd" ]; then
    exec {state_lock_fd}<> /var/lib/shijian-probe/state.json.lock
    flock -n "$state_lock_fd" || fail '旧进程停止后状态仍被占用，拒绝替换程序'
  fi
  if [ -f /var/lib/shijian-probe/state.json ]; then install -m 600 /var/lib/shijian-probe/state.json "$backup/state.json"; fi
  if [ "$rebind" = 1 ]; then
    step='隔离旧节点状态'
    state_archive=$(mktemp -d /var/lib/shijian-probe-rebind.XXXXXXXX)
    printf '%s\n' "$state_archive" > "$backup/STATE_ARCHIVE"
    mv -- /var/lib/shijian-probe "$state_archive/previous"
    install -d -m 700 /var/lib/shijian-probe
    release_state_lock
    exec {state_lock_fd}<> /var/lib/shijian-probe/state.json.lock
    flock -n "$state_lock_fd" || fail '新状态目录已被其他进程占用，拒绝继续重新绑定'
    printf '旧节点状态已隔离至 %s/previous；新节点将使用独立状态，失败时恢复旧绑定并保留新队列。\n' "$state_archive"
  fi
  printf '旧部署和最新状态已备份至 %s。\n' "$backup"
fi
step='安装配置与创建状态目录'
install -d -m 700 /etc/shijian-probe /var/lib/shijian-probe
if [ "$recover" = 1 ] && [ -z "$installed" ] && [ "$rebind" = 0 ]; then
  backup=$(mktemp -d /etc/shijian-probe/reinstall-backup.XXXXXXXX)
  install -m 600 /etc/shijian-probe/config.json "$backup/config.json"
  printf '原配置已备份至 %s/config.json；状态目录保持原位。\n' "$backup"
fi
config_tmp=$(mktemp /etc/shijian-probe/.config.XXXXXXXX)
install -m 600 "$work/config.json" "$config_tmp"
mv -f -- "$config_tmp" /etc/shijian-probe/config.json
config_tmp=''
if [ "$platform" = linux-amd64 ]; then
  step='安装程序与 systemd 服务'
  new_native_files=1
  binary_tmp=$(mktemp /usr/local/bin/.shijian-probe.XXXXXXXX)
  install -m 755 "$work/unpacked/shijian-probe" "$binary_tmp"
  mv -f -- "$binary_tmp" /usr/local/bin/shijian-probe
  binary_tmp=''
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
  if [ -z "$installed" ]; then install -m 644 "$work/shijian-probe.service" /etc/systemd/system/shijian-probe.service; fi
  step='启动 systemd 服务'
  systemctl daemon-reload
  release_state_lock
  if [ -n "$installed" ]; then systemctl start shijian-probe; else systemctl enable --now shijian-probe; fi
  sleep 2
  systemctl is-active --quiet shijian-probe
  printf 'Agent 服务已启动。查看状态：systemctl status --no-pager shijian-probe\n'
else
  step='启动 Docker 容器'
  release_state_lock
  docker run -d --name shijian-probe --restart "${restart_policy:-unless-stopped}" \
    --network host --pid host --read-only --cap-drop ALL --cap-add NET_RAW \
    --security-opt no-new-privileges \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    --mount type=bind,src=/,dst=/host,readonly,bind-propagation=rslave \
    --mount type=bind,src=/etc/shijian-probe/config.json,dst=/etc/shijian-probe/config.json,readonly \
    --mount type=bind,src=/var/lib/shijian-probe,dst=/var/lib/shijian-probe \
    "$image_id"
  sleep 2
  [ "$(docker inspect --format '{{.State.Running}} {{.State.Restarting}} {{.RestartCount}}' shijian-probe)" = 'true false 0' ] || fail '新容器未稳定运行或已进入重启循环'
  printf 'Agent 容器已启动。查看状态：docker inspect shijian-probe\n'
fi
upgrade_complete=1
if [ "$container_renamed" = 1 ]; then
  docker rm "$rollback_container" >/dev/null || printf '新容器已启动，旧容器 %s 未能清理，可确认运行后手动删除。\n' "$rollback_container" >&2
fi
printf '请返回主站确认收到上报；服务启动不代表主站已经接收数据。\n'

step='保存日常操作说明'
if [ "$platform" = linux-amd64 ]; then
  cat > /etc/shijian-probe/OPERATIONS.txt <<'OPERATIONS'
以下命令按需单独执行，不要整段运行。

查看状态：
  systemctl status --no-pager shijian-probe
查看日志：
  journalctl -u shijian-probe -n 50 --no-pager
临时暂停（重启机器后仍会自动启动）：
  systemctl stop shijian-probe
恢复运行：
  systemctl start shijian-probe
重启 Agent：
  systemctl restart shijian-probe
暂停并取消开机启动：
  systemctl disable --now shijian-probe
恢复并启用开机启动：
  systemctl enable --now shijian-probe
卸载程序（保留配置和状态）：
  systemctl disable --now shijian-probe && rm -f /etc/systemd/system/shijian-probe.service /usr/local/bin/shijian-probe && systemctl daemon-reload
OPERATIONS
else
  cat > /etc/shijian-probe/OPERATIONS.txt <<'OPERATIONS'
以下命令按需单独执行，不要整段运行。

查看状态：
  docker inspect shijian-probe
查看日志：
  docker logs --tail 50 shijian-probe
临时暂停：
  docker stop --time 25 shijian-probe
恢复运行：
  docker start shijian-probe
重启 Agent：
  docker restart --time 25 shijian-probe
暂停并取消自动启动：
  docker update --restart=no shijian-probe && docker stop --time 25 shijian-probe
恢复运行并启用自动启动：
  docker update --restart=unless-stopped shijian-probe && docker start shijian-probe
卸载容器（保留配置和状态）：
  docker stop --time 25 shijian-probe && docker rm shijian-probe
OPERATIONS
fi
cat >> /etc/shijian-probe/OPERATIONS.txt <<'OPERATIONS'

暂停后停止采集与上报，已有补报状态保留。
卸载默认保留 /etc/shijian-probe 和 /var/lib/shijian-probe；重新复制新版安装命令即可覆盖升级；同节点保留队列，节点或主站变化时先隔离旧状态再重新绑定。
覆盖升级先校验新包，再停止旧服务/容器并备份程序、配置与最新状态；启动失败自动恢复原部署，不用旧状态覆盖最新队列。
升级沿用同一部署方式，保留原生服务定义及 Docker 自动重启策略；同节点未指定 --interfaces 时保留原统计接口，重新绑定按新配置选择；配置更新为本次凭据。更换节点或主站时，新旧身份分别使用独立队列；旧配置和状态保存在输出的备份目录。跨部署方式或文件异常时会拒绝。
卸载后请在主站「令牌管理」撤销该节点凭据；本机卸载不会自动撤销主站令牌。
再次查看本说明：cat /etc/shijian-probe/OPERATIONS.txt
OPERATIONS
cat /etc/shijian-probe/OPERATIONS.txt
}
shijian_install_main "$@"

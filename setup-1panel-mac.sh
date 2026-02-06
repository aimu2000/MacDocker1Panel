#!/bin/zsh

# macOS 1Panel 一体化部署脚本（含安全升级）
# 支持：安装 / 卸载 / 强制重装 / 升级 / 控制
# 仓库：https://github.com/aimu2000/MacDocker1panel
# 原仓库: https://github.com/purainity/docker-1panel-v2

set -e

# === 配置 ===
SCRIPT_URL="https://raw.githubusercontent.com/aimu2000/MacDocker1panel/main/setup-1panel-mac.sh"
DEFAULT_GITHUB_REPO="aimu2000/MacDocker1panel"
DEFAULT_PANEL_USER="aimu2000"
DEFAULT_PANEL_PORT=168
DEFAULT_PANEL_ENTRANCE="aimu2000"
DEFAULT_DATA_DIR="$HOME/1panel-data"
CONTROL_SCRIPT="$HOME/1panel-control.sh"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/local.1panel.start.plist"

# === 颜色 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

if [[ "$OSTYPE" != "darwin"* ]]; then
  error "此脚本仅支持 macOS"
  exit 1
fi

# === 升级流程（交互式，默认全 N）===
run_upgrade() {
  log "开始升级检查..."
  echo
  echo "=== 升级选项（默认 N，仅 Y 执行）==="

  # 1. 升级脚本自身
  read -r "?是否更新本脚本？(y/N): " upgrade_script
  if [[ "$upgrade_script" =~ ^[Yy]$ ]]; then
    local temp_script="/tmp/setup-1panel-new.sh"
    if curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then
      chmod +x "$temp_script"
      mv "$temp_script" "$0"
      log "✅ 脚本已更新，正在重启..."
      exec "$0" "$@"
    else
      warn "无法下载新脚本，跳过"
    fi
  fi

  # 2. 更新 Homebrew
  read -r "?是否更新 Homebrew？(y/N): " upgrade_brew
  if [[ "$upgrade_brew" =~ ^[Yy]$ ]]; then
    log "更新 Homebrew..."
    brew update
  fi

  # 3. 升级 Docker CLI 和 Colima
  read -r "?是否升级 Docker CLI 和 Colima？(y/N): " upgrade_deps
  if [[ "$upgrade_deps" =~ ^[Yy]$ ]]; then
    log "升级依赖..."
    brew upgrade docker colima
  fi

  # 4. 重新构建镜像（可选）
  read -r "?是否重新构建 1Panel 镜像？(y/N): " rebuild_image
  if [[ "$rebuild_image" =~ ^[Yy]$ ]]; then
    read -r "?请输入 GitHub 仓库（格式: owner/repo，默认 $DEFAULT_GITHUB_REPO）: " github_repo
    github_repo="${github_repo:-$DEFAULT_GITHUB_REPO}"
    log "正在重建镜像（仓库: $github_repo）..."
    cd ~
    rm -rf tmp-1panel-build
    git clone "https://github.com/$github_repo.git" tmp-1panel-build
    cd tmp-1panel-build
    docker build -t "docker-1panel-v2" .
    rm -rf tmp-1panel-build
    log "✅ 镜像重建完成"
  fi

  log "✅ 升级流程结束"
}

# === 安装依赖（如未安装）===
install_deps() {
  if ! command -v brew &> /dev/null; then
    log "安装 Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  if ! command -v docker &> /dev/null; then
    log "安装 Docker CLI..."
    brew install docker
  fi
  if ! command -v colima &> /dev/null; then
    log "安装 Colima..."
    brew install colima
  fi
}

# === 配置镜像加速器 ===
setup_mirror() {
  local config="$HOME/.colima/default/docker/daemon.json"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<EOF
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com"
  ]
}
EOF
  log "已配置国内镜像加速器"
}

# === 构建镜像 ===
build_image() {
  local repo="$1"
  log "克隆并构建镜像（仓库: $repo）..."
  cd ~
  rm -rf tmp-1panel-build
  git clone "https://github.com/$repo.git" tmp-1panel-build
  cd tmp-1panel-build
  docker build -t "docker-1panel-v2" .
  rm -rf tmp-1panel-build
  log "✅ 镜像构建完成"
}

# === 创建控制脚本 ===
create_control_script() {
  local data_dir="$1" port="$2" entrance="$3" user="$4"
  cat > "$CONTROL_SCRIPT" <<EOF
#!/bin/zsh
CONTAINER_NAME="1panel"
DATA_DIR="$data_dir"
IMAGE_NAME="docker-1panel-v2"
PORT="$port"
ENTRANCE="$entrance"
USER="$user"

log() { echo "[\$(date +'%H:%M:%S')] \$1"; }

start() {
  colima start
  while ! docker info >/dev/null 2>&1; do sleep 2; done
  if ! docker ps -a --format '{{.Names}}' | grep -q "^\${CONTAINER_NAME}\$"; then
    docker run -d --name "\$CONTAINER_NAME" --network host --restart unless-stopped \\
      -v /var/run/docker.sock:/var/run/docker.sock \\
      -v "\$DATA_DIR:\$DATA_DIR" \\
      -e TZ=Asia/Shanghai -e LANGUAGE=zh \\
      -e PANEL_BASE_DIR="\$DATA_DIR" \\
      -e PANEL_PORT="\$PORT" \\
      -e PANEL_ENTRANCE="\$ENTRANCE" \\
      -e PANEL_USERNAME="\$USER" \\
      -e PANEL_PASSWORD='YourStrongPass!2026' \\
      "\$IMAGE_NAME"
  elif ! docker ps --format '{{.Names}}' | grep -q "^\${CONTAINER_NAME}\$"; then
    docker start "\$CONTAINER_NAME"
  fi
}

case "\$1" in
  start) start ;;
  stop) docker stop "\$CONTAINER_NAME" 2>/dev/null || true; colima stop ;;
  restart) "\$0" stop && sleep 3 && "\$0" start ;;
  status)
    if colima status --json 2>/dev/null | jq -r '.running // "false"' | grep -q "true"; then
      echo "Colima: 运行中"
      if docker ps --format '{{.Names}}' | grep -q "^\${CONTAINER_NAME}\$"; then
        echo "1Panel: 运行中 (http://localhost:\$PORT/\$ENTRANCE)"
      else
        echo "1Panel: 容器未运行"
      fi
    else
      echo "Colima: 未运行"
    fi
    ;;
  *) echo "用法: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
  chmod +x "$CONTROL_SCRIPT"
}

# === 设置开机自启 ===
setup_autostart() {
  cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.1panel.start</string>
    <key>ProgramArguments</key>
    <array>
        <string>$CONTROL_SCRIPT</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/1panel.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/1panel.err</string>
</dict>
</plist>
EOF
  launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
  launchctl load "$LAUNCH_AGENT"
  log "✅ 开机自启已配置"
}

# === 启动并等待就绪 ===
start_and_wait() {
  "$CONTROL_SCRIPT" start
  log "正在等待 1Panel 初始化完成（约 1-3 分钟）..."
  while true; do
    if docker logs 1panel 2>/dev/null | grep -q "\[INFO\] listen at http://0.0.0.0:$DEFAULT_PANEL_PORT \[tcp4\]"; then
      break
    fi
    sleep 10
  done
  log "🎉 1Panel 已就绪！"
  echo
  echo "🌐 访问地址: http://localhost:$DEFAULT_PANEL_PORT/$DEFAULT_PANEL_ENTRANCE"
  echo "👤 用户名: $DEFAULT_PANEL_USER"
  echo "🔑 密码: YourStrongPass!2026（请登录后立即修改！）"
  echo
}

# === 彻底清理 ===
full_cleanup() {
  echo
  echo "=== 强制重装前清理选项（默认全选 Y）==="
  read -r "?停止并删除容器？(Y/n): " clean_container
  clean_container="${clean_container:-Y}"
  read -r "?删除 1Panel 数据目录？(Y/n): " clean_data
  clean_-Y}"
  read -r "?删除 docker-1panel-v2 镜像？(Y/n): " clean_image
  clean_image="${clean_image:-Y}"
  read -r "?卸载 Colima？(y/N): " uninstall_colima
  uninstall_colima="${uninstall_colima:-N}"
  read -r "?卸载 Docker CLI？(y/N): " uninstall_docker
  uninstall_docker="${uninstall_docker:-N}"
  read -r "?删除控制脚本和开机自启？(Y/n): " clean_scripts
  clean_scripts="${clean_scripts:-Y}"

  if [[ "$clean_container" =~ ^[Yy]$ ]]; then
    docker stop 1panel 2>/dev/null || true
    docker rm 1panel 2>/dev/null || true
  fi
  if [[ "$clean_data" =~ ^[Yy]$ ]] && [ -d "$DEFAULT_DATA_DIR" ]; then
    rm -rf "$DEFAULT_DATA_DIR"
  fi
  if [[ "$clean_image" =~ ^[Yy]$ ]]; then
    docker rmi docker-1panel-v2 2>/dev/null || true
  fi
  if [[ "$uninstall_colima" =~ ^[Yy]$ ]]; then
    brew uninstall colima
    colima delete 2>/dev/null || true
  fi
  if [[ "$uninstall_docker" =~ ^[Yy]$ ]]; then
    brew uninstall docker
  fi
  if [[ "$clean_scripts" =~ ^[Yy]$ ]]; then
    rm -f "$CONTROL_SCRIPT" "$LAUNCH_AGENT"
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
  fi
  log "✅ 清理完成"
}

# === 安装流程 ===
run_install() {
  echo
  read -r "?请输入 GitHub 仓库（格式: owner/repo，默认 $DEFAULT_GITHUB_REPO）: " github_repo
  github_repo="${github_repo:-$DEFAULT_GITHUB_REPO}"

  echo
  read -r "?是否配置国内镜像加速？(Y/n，默认 Y): " use_mirror
  use_mirror="${use_mirror:-Y}"
  [[ "$use_mirror" =~ ^[Yy]$ ]] && setup_mirror

  echo
  read -r "?是否克隆并构建镜像？(Y/n，默认 Y): " build_img
  build_img="${build_img:-Y}"
  [[ "$build_img" =~ ^[Yy]$ ]] && build_image "$github_repo"

  echo
  read -r "?是否设置开机自启？(Y/n，默认 Y): " autostart
  autostart="${autostart:-Y}"

  install_deps
  colima start
  create_control_script "$DEFAULT_DATA_DIR" "$DEFAULT_PANEL_PORT" "$DEFAULT_PANEL_ENTRANCE" "$DEFAULT_PANEL_USER"
  [[ "$autostart" =~ ^[Yy]$ ]] && setup_autostart
  start_and_wait
}

# === 主菜单 ===
echo "=================================="
echo " 1Panel macOS 一体化部署脚本"
echo "=================================="
echo "1) 安装"
echo "2) 卸载"
echo "3) 强制重装（彻底清理后全新安装）"
echo "4) 升级（交互式，默认不更新）"
echo "5) 控制（启动/停止/重启/状态）"
echo "6) 退出"
echo -n "请选择 [1-6]: "
read -r choice

case $choice in
  1)
    run_install
    ;;
  2)
    if [ -f "$CONTROL_SCRIPT" ]; then
      "$CONTROL_SCRIPT" stop
      echo -n "是否保留数据 ($DEFAULT_DATA_DIR)? [y/N]: "
      read -r keep
      [[ ! "$keep" =~ ^[Yy]$ ]] && rm -rf "$DEFAULT_DATA_DIR"
      docker rmi docker-1panel-v2 2>/dev/null || true
      rm -f "$CONTROL_SCRIPT" "$LAUNCH_AGENT"
      launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
      log "卸载完成"
    else
      error "未安装"
    fi
    ;;
  3)
    log "开始强制重装..."
    full_cleanup
    run_install
    ;;
  4)
    run_upgrade
    ;;
  5)
    if [ -f "$CONTROL_SCRIPT" ]; then
      echo "子命令: start | stop | restart | status"
      read -r cmd
      "$CONTROL_SCRIPT" "$cmd"
    else
      error "请先安装"
    fi
    ;;
  6)
    exit 0
    ;;
  *)
    error "无效选项"
    ;;
esac
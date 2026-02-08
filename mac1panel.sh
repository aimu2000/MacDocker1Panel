#!/bin/zsh

# =======================================================
# macOS 1Panel 一体化部署脚本
# 版本: 20260206V2.1
# 最后更新: 2026-02-06 BY aimu2000
# 仓库: https://github.com/aimu2000/MacDocker1panel
# =======================================================
# 
# 使用方法:
# 
# 1. 安装模式 (交互式安装)
#    ./mac1panel.sh
# 
# 2. 直接命令模式 (快速操作)
#    ./mac1panel.sh start       # 启动 1Panel
#    ./mac1panel.sh stop        # 停止 1Panel
#    ./mac1panel.sh restart     # 重启 1Panel
#    ./mac1panel.sh status      # 查看状态
#    ./mac1panel.sh update      # 检查脚本更新
#    ./mac1panel.sh version     # 显示版本信息
#    ./mac1panel.sh stopAll     # 停止所有服务（Colima+Docker）
#    ./mac1panel.sh startAll   # 启动所有服务（Colima+Docker）
# 
# 3. 交互菜单模式
#    ./mac1panel.sh             # 显示主菜单选择安装/卸载/升级等
# 
# 主菜单选项:
#    1) 安装 - 交互式安装 1Panel 和依赖
#    2) 卸载 - 选择交互式或强制卸载
#    3) 强制重装 - 彻底清理后全新安装
#    4) 升级 - 交互式升级组件
#    5) 控制 - 启动/停止/重启/状态查看
#    6) 退出
# 
# 强制卸载选项: 删除所有相关文件包括:
#   - 1Panel 容器、镜像和数据目录
#   - 控制脚本和开机自启配置
#   - Colima 和 Docker CLI 及配置目录
# =======================================================

set -e

# === 配置 ===
SCRIPT_NAME="mac1panel.sh"
SCRIPT_URL="https://raw.githubusercontent.com/aimu2000/MacDocker1panel/main/mac1panel.sh"
DEFAULT_GITHUB_REPO="aimu2000/MacDocker1panel"
DEFAULT_PANEL_USER="aimu2000"
DEFAULT_PANEL_PORT=168
DEFAULT_PANEL_ENTRANCE="aimu2000"
DEFAULT_DATA_DIR="$HOME/1panel-data"
DOCKER_DATA_DIR="$DEFAULT_DATA_DIR/1panel"
CONTROL_SCRIPT="$HOME/.1panel-control.sh"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/local.1panel.start.plist"

# === 脚本版本信息 ===
CURRENT_VERSION="20260206V2.1"

# === 颜色定义 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# === 日志函数 ===
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# === 环境检查 ===
if [[ "$OSTYPE" != "darwin"* ]]; then
  error "此脚本仅支持 macOS"
  exit 1
fi

# === 版本检查函数 ===
check_script_update() {
    log "检查脚本更新..."
    
    # 直接下载远程脚本文件并提取版本信息
    local remote_content=$(curl --connect-timeout 5 --max-time 10 -fsSL "$SCRIPT_URL" 2>/dev/null || echo "")
    
    if [[ -n "$remote_content" ]]; then
        # 从远程脚本内容中提取版本信息
        local remote_version=$(echo "$remote_content" | grep -E "^CURRENT_VERSION=\"[^\"]*\"" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d ' ')
        
        # 如果直接提取失败，尝试从注释中提取
        if [[ -z "$remote_version" ]]; then
            remote_version=$(echo "$remote_content" | grep -E "版本[:：]" | head -1 | grep -oE "[0-9]{8}V[0-9]+\.[0-9]+" | head -1)
        fi
        
        if [[ -n "$remote_version" ]]; then
            info "本地版本: $CURRENT_VERSION"
            info "远程版本: $remote_version"
            
            # 版本比较（基于简单的字符串比较）
            if [[ "$remote_version" != "$CURRENT_VERSION" ]]; then
                echo
                warn "发现新版本: $remote_version"
                echo -n "是否更新脚本？(Y/n): "
                read -r update_choice
                update_choice="${update_choice:-Y}"
                
                if [[ "$update_choice" =~ ^[Yy]$ ]]; then
                    update_script
                else
                    log "已跳过更新"
                fi
            else
                log "当前已是最新版本"
            fi
        else
            warn "无法从远程脚本解析版本信息"
        fi
    else
        warn "无法连接到GitHub检查更新"
    fi
}

# === 脚本更新函数 ===
update_script() {
    log "开始更新脚本..."
    local temp_script="/tmp/mac1panel-new.sh"
    
    # 备份当前脚本
    local backup_file="$HOME/1panel-script-backup-$(date +%Y%m%d%H%M%S).sh"
    cp "$0" "$backup_file"
    log "当前脚本已备份至: $backup_file"
    
    # 下载新脚本
    if curl --connect-timeout 5 --max-time 10 -fsSL "$SCRIPT_URL" -o "$temp_script"; then
        # 验证新脚本的基本语法
        if bash -n "$temp_script" 2>/dev/null; then
            chmod +x "$temp_script"
            
            # 替换当前脚本
            mv "$temp_script" "$0"
            log "✅ 脚本更新成功！"
            log "正在重启脚本..."
            exec "$0" "$@"
        else
            error "下载的脚本语法错误，更新中止"
            rm -f "$temp_script"
            return 1
        fi
    else
        error "无法下载新脚本"
        rm -f "$temp_script"
        return 1
    fi
}

# === 全部停止函数 ===
stop_all_services() {
    log "停止所有服务..."
    
    # 停止 1Panel 容器
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^1panel$"; then
        docker stop 1panel 2>/dev/null && log "✅ 1Panel 容器已停止"
    fi
    
    # 停止 Colima
    if colima status 2>/dev/null | grep -q "running"; then
        colima stop 2>/dev/null && log "✅ Colima 已停止"
    fi
    
    log "🎉 所有服务已停止"
}

# === 全部启动函数 ===
start_all_services() {
    log "启动所有服务..."
    
    # 启动 Colima
    if ! colima status 2>/dev/null | grep -q "running"; then
        colima start 2>/dev/null && log "✅ Colima 已启动"
    fi
    
    # 启动 1Panel
    if [ -f "$CONTROL_SCRIPT" ]; then
        "$CONTROL_SCRIPT" start && log "✅ 1Panel 已启动"
    else
        warn "控制脚本不存在，无法启动 1Panel"
    fi
    
    log "🎉 所有服务已启动"
}

# === 直接控制功能 ===
direct_control() {
    case "$1" in
        "start")
            if [ -f "$CONTROL_SCRIPT" ]; then
                "$CONTROL_SCRIPT" start
            else
                error "控制脚本不存在，请先安装 1Panel"
                exit 1
            fi
            ;;
        "stop")
            if [ -f "$CONTROL_SCRIPT" ]; then
                "$CONTROL_SCRIPT" stop
            else
                error "控制脚本不存在，请先安装 1Panel"
                exit 1
            fi
            ;;
        "restart")
            if [ -f "$CONTROL_SCRIPT" ]; then
                "$CONTROL_SCRIPT" restart
            else
                error "控制脚本不存在，请先安装 1Panel"
                exit 1
            fi
            ;;
        "status")
            if [ -f "$CONTROL_SCRIPT" ]; then
                "$CONTROL_SCRIPT" status
            else
                error "控制脚本不存在，请先安装 1Panel"
                exit 1
            fi
            ;;
        "stopAll")
            stop_all_services
            exit 0
            ;;
        "startAll")
            start_all_services
            exit 0
            ;;
        "version")
            show_version
            exit 0
            ;;
        "update")
            check_script_update
            exit 0
            ;;
        *)
            error "无效命令，可用命令: start | stop | restart | status | stopAll | startAll | version | update"
            echo "使用方法: $0 {start|stop|restart|status|stopAll|startAll|version|update}"
            exit 1
            ;;
    esac
    exit 0
}

# === 显示版本信息 ===
show_version() {
    echo "======================================================="
    echo "            macOS 1Panel 一体化部署脚本"
    echo "======================================================="
    echo "脚本名称: $SCRIPT_NAME"
    echo "版本: $CURRENT_VERSION"
    echo "仓库: $DEFAULT_GITHUB_REPO"
    echo "默认端口: $DEFAULT_PANEL_PORT"
    echo "默认入口: $DEFAULT_PANEL_ENTRANCE"
    echo "默认用户: $DEFAULT_PANEL_USER"
    echo "数据目录: $DEFAULT_DATA_DIR"
    echo "控制脚本: $CONTROL_SCRIPT"
    echo "======================================================="
}

# === 检查安装状态 ===
check_installation() {
    local installed=false
    
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^1panel$"; then
        installed=true
    fi
    
    if docker images --format '{{.Repository}}' 2>/dev/null | grep -q "^docker-1panel-v2$"; then
        installed=true
    fi
    
    if [ -f "$CONTROL_SCRIPT" ]; then
        installed=true
    fi
    
    if [ -f "$LAUNCH_AGENT" ]; then
        installed=true
    fi
    
    if [ -d "$DEFAULT_DATA_DIR" ]; then
        installed=true
    fi
    
    if $installed; then
        return 0
    else
        return 1
    fi
}

# === 安装依赖 ===
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
    cd ~
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
    if colima status 2>/dev/null | grep -q "running"; then
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
    mkdir -p "$(dirname "$LAUNCH_AGENT")"
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

# === 卸载函数 ===
run_uninstall() {
    echo "选择卸载方式:"
    echo "1) 交互式卸载（推荐）"
    echo "2) 强制卸载（删除所有相关文件）"
    echo "3) 取消"
    echo -n "请选择 [1-3]: "
    read -r choice
    
    case $choice in
        1)
            log "开始交互式卸载..."
            # 停止服务
            if [ -f "$CONTROL_SCRIPT" ]; then
                "$CONTROL_SCRIPT" stop
            fi
            
            # 删除容器
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^1panel$"; then
                docker rm 1panel 2>/dev/null && log "✅ 1Panel 容器已删除"
            fi
            
            # 删除镜像
            if docker images --format '{{.Repository}}' 2>/dev/null | grep -q "^docker-1panel-v2$"; then
                docker rmi docker-1panel-v2 2>/dev/null && log "✅ 1Panel 镜像已删除"
            fi
            
            # 删除控制脚本
            if [ -f "$CONTROL_SCRIPT" ]; then
                rm -f "$CONTROL_SCRIPT" && log "✅ 控制脚本已删除"
            fi
            
            # 删除开机自启
            if [ -f "$LAUNCH_AGENT" ]; then
                launchctl unload "$LAUNCH_AGENT" 2>/dev/null
                rm -f "$LAUNCH_AGENT" && log "✅ 开机自启配置已删除"
            fi
            
            # 询问是否删除数据目录
            echo -n "是否删除数据目录 $DEFAULT_DATA_DIR？(y/N): "
            read -r delete_data
            if [[ "$delete_data" =~ ^[Yy]$ ]]; then
                rm -rf "$DEFAULT_DATA_DIR" && log "✅ 数据目录已删除"
            else
                log "数据目录保留: $DEFAULT_DATA_DIR"
            fi
            
            log "✅ 卸载完成"
            ;;
        2)
            log "开始强制卸载..."
            stop_all_services
            
            # 强制删除所有相关文件
            docker rm -f 1panel 2>/dev/null || true
            docker rmi -f docker-1panel-v2 2>/dev/null || true
            rm -f "$CONTROL_SCRIPT" 2>/dev/null || true
            launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
            rm -f "$LAUNCH_AGENT" 2>/dev/null || true
            rm -rf "$DEFAULT_DATA_DIR" 2>/dev/null || true
            
            log "✅ 强制卸载完成"
            ;;
        3)
            log "取消卸载"
            ;;
        *)
            error "无效选项"
            ;;
    esac
}

# === 强制重装函数 ===
run_force_reinstall() {
    log "开始强制重装..."
    run_uninstall
    sleep 2
    run_install
}

# === 升级函数 ===
run_upgrade() {
    echo "选择升级组件:"
    echo "1) 升级脚本本身"
    echo "2) 升级 1Panel 镜像"
    echo "3) 升级所有依赖（Homebrew/Docker/Colima）"
    echo "4) 取消"
    echo -n "请选择 [1-4]: "
    read -r choice
    
    case $choice in
        1) check_script_update ;;
        2)
            if check_installation; then
                log "重新构建 1Panel 镜像..."
                build_image "$DEFAULT_GITHUB_REPO"
                "$CONTROL_SCRIPT" restart
            else
                error "1Panel 未安装，请先安装"
            fi
            ;;
        3)
            log "升级所有依赖..."
            install_deps
            ;;
        4) log "取消升级" ;;
        *) error "无效选项" ;;
    esac
}

# === 控制函数 ===
run_control() {
    echo "选择控制操作:"
    echo "1) 启动 1Panel"
    echo "2) 停止 1Panel"
    echo "3) 重启 1Panel"
    echo "4) 查看状态"
    echo "5) 启动所有服务（Colima+1Panel）"
    echo "6) 停止所有服务（Colima+1Panel）"
    echo "7) 取消"
    echo -n "请选择 [1-7]: "
    read -r choice
    
    case $choice in
        1) "$CONTROL_SCRIPT" start ;;
        2) "$CONTROL_SCRIPT" stop ;;
        3) "$CONTROL_SCRIPT" restart ;;
        4) "$CONTROL_SCRIPT" status ;;
        5) start_all_services ;;
        6) stop_all_services ;;
        7) log "取消操作" ;;
        *) error "无效选项" ;;
    esac
}

# === 安装流程 ===
run_install() {
    echo -n "请输入 GitHub 仓库（格式: owner/repo，默认 $DEFAULT_GITHUB_REPO）: "
    read -r github_repo
    github_repo="${github_repo:-$DEFAULT_GITHUB_REPO}"

    # 依赖安装确认
    echo -n "是否安装/更新所需依赖（Homebrew/Docker/Colima）? (Y/n，默认 Y): "
    read -r install_deps_choice
    install_deps_choice="${install_deps_choice:-Y}"
    
    # 镜像加速配置
    echo -n "是否配置国内镜像加速？(Y/n，默认 Y): "
    read -r use_mirror
    use_mirror="${use_mirror:-Y}"
    if [[ "$use_mirror" =~ ^[Yy]$ ]]; then
        setup_mirror
    fi

    # 依赖安装
    if [[ "$install_deps_choice" =~ ^[Yy]$ ]]; then
        install_deps
    else
        log "跳过依赖安装，请确保已安装：Homebrew、Docker CLI、Colima"
    fi

    # Colima 启动确认
    echo -n "是否启动 Colima (Docker 环境)? (Y/n，默认 Y): "
    read -r start_colima
    start_colima="${start_colima:-Y}"
    if [[ "$start_colima" =~ ^[Yy]$ ]]; then
        colima start
    else
        log "跳过 Colima 启动，请确保 Docker 环境已就绪"
    fi

    # 镜像构建
    echo -n "是否克隆并构建镜像？(Y/n，默认 Y): "
    read -r build_img
    build_img="${build_img:-Y}"
    if [[ "$build_img" =~ ^[Yy]$ ]]; then
        build_image "$github_repo"
    else
        log "跳过镜像构建，使用现有镜像（如存在）"
    fi

    # 开机自启
    echo -n "是否设置开机自启？(Y/n，默认 Y): "
    read -r autostart
    autostart="${autostart:-Y}"

    # 创建控制脚本
    create_control_script "$DEFAULT_DATA_DIR" "$DEFAULT_PANEL_PORT" "$DEFAULT_PANEL_ENTRANCE" "$DEFAULT_PANEL_USER"
    
    # 配置自启
    if [[ "$autostart" =~ ^[Yy]$ ]]; then
        setup_autostart
    fi
    
    # 启动并等待
    start_and_wait
}

# === 主函数 ===
main() {
    # 检查命令行参数
    if [[ $# -gt 0 ]]; then
        direct_control "$1"
    fi
    
    # 显示版本信息
    show_version
    
    # 检查更新（非强制）
    
    # 主菜单
    echo
    echo "请选择操作:"
    echo "1) 安装"
    echo "2) 卸载" 
    echo "3) 强制重装（彻底清理后全新安装）"
    echo "4) 升级（交互式，默认不更新）"
    echo "5) 控制（启动/停止/重启/状态）"
    echo "6) 退出"
    echo -n "请选择 [1-6]: "
    read -r choice

    case $choice in
        1) run_install ;;
        2) run_uninstall ;;
        3) run_force_reinstall ;;
        4) run_upgrade ;;
        5) run_control ;;
        6) exit 0 ;;
        *) error "无效选项" ;;
    esac
}

# === 脚本入口 ===
if [[ "${(%):-%x}" == "${0}" ]]; then
    main "$@"
fi
# 临时跳过自动检查更新

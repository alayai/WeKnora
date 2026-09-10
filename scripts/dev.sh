#!/bin/bash
# 开发环境启动脚本 - 只启动基础设施，app 和 frontend 需要手动在本地运行

# 设置颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 获取项目根目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# 日志函数
log_info() {
    printf "%b\n" "${BLUE}[INFO]${NC} $1"
}

log_success() {
    printf "%b\n" "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    printf "%b\n" "${RED}[ERROR]${NC} $1"
}

log_warning() {
    printf "%b\n" "${YELLOW}[WARNING]${NC} $1"
}

# 选择可用的 Docker Compose 命令
DOCKER_COMPOSE_BIN=""
DOCKER_COMPOSE_SUBCMD=""

detect_compose_cmd() {
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_BIN="docker"
        DOCKER_COMPOSE_SUBCMD="compose"
        return 0
    fi
    if command -v docker-compose &> /dev/null; then
        if docker-compose version &> /dev/null; then
            DOCKER_COMPOSE_BIN="docker-compose"
            DOCKER_COMPOSE_SUBCMD=""
            return 0
        fi
    fi
    return 1
}

# 显示帮助信息
show_help() {
    printf "%b\n" "${GREEN}WeKnora 开发环境脚本${NC}"
    echo "用法: $0 [命令] [选项]"
    echo ""
    echo "命令:"
    echo "  start      启动基础设施服务（postgres, redis, docreader, langfuse）"
    echo "  stop       停止所有服务"
    echo "  restart    重启所有服务"
    echo "  logs       查看服务日志"
    echo "  status     查看服务状态"
    echo "  app        启动后端应用（本地 go run / air）"
    echo "  host-infra 现有 compose 栈上切到「宿主机 app」：停掉容器 app，并把 DB/Redis/DocReader 端口映射出来"
    echo "  frontend   启动前端开发服务器（本地运行）"
    echo "  frontend   启动前端开发服务器（本地运行）"
    echo "  help       显示此帮助信息"
    echo ""
    echo "可选 Profile（用于 start 命令）:"
    echo "  --minio       启动 MinIO 对象存储"
    echo "  --qdrant      启动 Qdrant 向量数据库"
    echo "  --neo4j       启动 Neo4j 图数据库"
    echo "  --dex         启动 Dex（OIDC 身份认证）"
    echo "  --langfuse    启动 Langfuse（默认已开启）"
    echo "  --no-langfuse 不启动 Langfuse"
    echo "  --odl-hybrid  启动 OpenDataLoader hybrid（Docling，镜像较大，按需启用）"
    echo "  --full        启动所有可选服务（不含 odl-hybrid，需另加 --odl-hybrid）"
    echo ""
    echo "示例："
    echo "  $0 start                    # 启动基础服务"
    echo "  $0 start --qdrant           # 启动基础服务 + Qdrant"
    echo "  $0 start --dex             # 启动基础服务 + Dex"
    echo "  $0 start --odl-hybrid       # 启动基础服务 + OpenDataLoader hybrid"
    echo "  $0 start --full             # 启动所有服务"
    echo "  make dev-start DEV_ARGS=--odl-hybrid   # 同上（Makefile 传参）"
    echo "  $0 app                      # 在另一个终端启动后端"
    echo "  $0 frontend                 # 在另一个终端启动前端"
}

# 加载 .env 与可选的 .env.local（后者覆盖前者）
# 读取时去掉行尾 \r，兼容 Windows 风格(CRLF)换行符，
# 否则 bash source 会把残留的 \r 当成命令导致 "...: $'\r': command not found"。
# 注意：不能用 source <(sed ...)——macOS 自带 Bash 3.2 对 process substitution
# 的 source 不会把变量导入当前 shell；必须落到可 seek 的临时文件再 source。
_source_env_file() {
    local src="$1"
    local tmp
    tmp="$(mktemp)" || return 1
    sed -e 's/\r$//' "$src" > "$tmp"
    set -a
    # shellcheck source=/dev/null
    source "$tmp"
    set +a
    rm -f "$tmp"
}

load_env_files() {
    if [ -f ".env" ]; then
        _source_env_file .env || return 1
    else
        return 1
    fi

    if [ -f ".env.local" ]; then
        log_info "加载 .env.local 覆盖配置..."
        _source_env_file .env.local || return 1
    fi
    return 0
}

# 检查 Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "未安装Docker，请先安装Docker"
        return 1
    fi
    
    if ! detect_compose_cmd; then
        log_error "未检测到 Docker Compose"
        return 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker服务未运行"
        return 1
    fi
    
    return 0
}

# 检查 .env 是否启用了 hybrid 模式（用于 --odl-hybrid 启动后重建 docreader）
_should_enable_odl_hybrid_from_env() {
    local hybrid="${DOCREADER_ODL_HYBRID:-off}"
    hybrid=$(printf '%s' "$hybrid" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$hybrid" in
        off|"") return 1 ;;
        *) return 0 ;;
    esac
}

_enable_odl_hybrid_profile() {
    PROFILES="$PROFILES --profile odl-hybrid"
    ENABLED_SERVICES="$ENABLED_SERVICES odl-hybrid"
}

# 等待 odl-hybrid HTTP 健康检查通过（compose 启动后服务可能仍在拉依赖）
_wait_odl_hybrid_ready() {
    local port="${ODL_HYBRID_PORT:-5002}"
    local max_wait="${ODL_HYBRID_STARTUP_WAIT_SEC:-180}"
    local waited=0
    local interval=5

    if ! command -v curl &> /dev/null; then
        log_warning "未安装 curl，跳过 odl-hybrid 就绪等待；请手动检查 http://localhost:${port}/health"
        return 0
    fi

    log_info "等待 odl-hybrid 就绪（最多 ${max_wait}s，首次需构建镜像: docker compose ... build odl-hybrid）..."
    while [ "$waited" -lt "$max_wait" ]; do
        if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            log_success "odl-hybrid 已就绪 (http://localhost:${port}/health)"
            return 0
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
    log_warning "odl-hybrid 在 ${max_wait}s 内未就绪，请查看: docker logs WeKnora-odl-hybrid"
    return 1
}

# 启动基础设施服务
start_services() {
    log_info "启动开发环境基础设施服务..."
    
    check_docker
    if [ $? -ne 0 ]; then
        return 1
    fi

    cd "$PROJECT_ROOT"
    
    # 检查 .env 文件
    if [ ! -f ".env" ]; then
        log_error ".env 文件不存在，请先创建"
        return 1
    fi

    load_env_files
    if [ $? -ne 0 ]; then
        log_error ".env 文件不存在，请先创建"
        return 1
    fi

    if [ -n "${DEV_REMOTE_HOST:-}" ]; then
        log_warning "已配置 DEV_REMOTE_HOST=${DEV_REMOTE_HOST}，跳过本地 Docker 基础设施启动"
        log_info "远程服务: PostgreSQL/Redis/DocReader/Langfuse → ${DEV_REMOTE_HOST}"
        log_info "接下来: make dev-app（本地后端）或 make dev-frontend（前端）"
        return 0
    fi
    
    # 解析 profile 参数
    shift  # 移除 "start" 命令本身
    # 默认启动基础设施（postgres / redis / docreader）+ langfuse，
    # 其余可选服务通过 --minio / --qdrant / --neo4j / --dex / --full 按需开启。
    PROFILES="--profile langfuse"
    ENABLED_SERVICES="langfuse"
    while [ $# -gt 0 ]; do
        case "$1" in
            --minio)
                PROFILES="$PROFILES --profile minio"
                ENABLED_SERVICES="$ENABLED_SERVICES minio"
                ;;
            --qdrant)
                PROFILES="$PROFILES --profile qdrant"
                ENABLED_SERVICES="$ENABLED_SERVICES qdrant"
                ;;
            --neo4j)
                PROFILES="$PROFILES --profile neo4j"
                ENABLED_SERVICES="$ENABLED_SERVICES neo4j"
                ;;
            --dex)
                PROFILES="$PROFILES --profile dex"
                ENABLED_SERVICES="$ENABLED_SERVICES dex"
                ;;
            --langfuse)
                PROFILES="$PROFILES --profile langfuse"
                ENABLED_SERVICES="$ENABLED_SERVICES langfuse"
                ;;
            --no-langfuse)
                PROFILES="${PROFILES//--profile langfuse/}"
                ENABLED_SERVICES="${ENABLED_SERVICES//langfuse/}"
                ;;
            --odl-hybrid)
                if [[ "$ENABLED_SERVICES" != *"odl-hybrid"* ]]; then
                    _enable_odl_hybrid_profile
                fi
                ;;
            --full)
                PROFILES="--profile full"
                ENABLED_SERVICES="minio qdrant neo4j dex"
                break
                ;;
            *)
                log_warning "未知参数: $1"
                ;;
        esac
        shift
    done

    # 启动服务（odl-hybrid 单独 --build，避免每次重建 docreader）
    "$DOCKER_COMPOSE_BIN" $DOCKER_COMPOSE_SUBCMD -f docker-compose.dev.yml $PROFILES up -d
    local compose_rc=$?
    if [ "$compose_rc" -eq 0 ] && [[ "$ENABLED_SERVICES" == *"odl-hybrid"* ]]; then
        log_info "构建/更新 odl-hybrid 镜像..."
        "$DOCKER_COMPOSE_BIN" $DOCKER_COMPOSE_SUBCMD -f docker-compose.dev.yml $PROFILES up -d --build odl-hybrid
        _wait_odl_hybrid_ready || true
        # docreader 需读取 DOCREADER_ODL_HYBRID；若刚改 .env，强制重建以注入环境变量
        if _should_enable_odl_hybrid_from_env; then
            log_info "重建 docreader 以应用 DOCREADER_ODL_HYBRID=${DOCREADER_ODL_HYBRID} ..."
            "$DOCKER_COMPOSE_BIN" $DOCKER_COMPOSE_SUBCMD -f docker-compose.dev.yml up -d --force-recreate docreader
        fi
    fi

    if [ "$compose_rc" -eq 0 ]; then
        log_success "基础设施服务已启动"
        echo ""
        log_info "服务访问地址:"
        echo "  - PostgreSQL:    localhost:5432"
        echo "  - Redis:         localhost:6379"
        echo "  - DocReader:     localhost:50051"
        
        # 根据启用的 profile 显示额外服务
        if [[ "$ENABLED_SERVICES" == *"minio"* ]]; then
            echo "  - MinIO:         localhost:9000 (Console: localhost:9001)"
        fi
        if [[ "$ENABLED_SERVICES" == *"qdrant"* ]]; then
            echo "  - Qdrant:        localhost:6333 (gRPC: localhost:6334)"
        fi
        if [[ "$ENABLED_SERVICES" == *"neo4j"* ]]; then
            echo "  - Neo4j:         localhost:7474 (Bolt: localhost:7687)"
        fi
        if [[ "$ENABLED_SERVICES" == *"dex"* ]]; then
            echo "  - Dex:           localhost:5556"
        fi
        if [[ "$ENABLED_SERVICES" == *"langfuse"* ]]; then
            echo "  - Langfuse:      http://localhost:${LANGFUSE_WEB_PORT:-3000}"
        fi
        if [[ "$ENABLED_SERVICES" == *"odl-hybrid"* ]]; then
            echo "  - ODL Hybrid:    http://localhost:${ODL_HYBRID_PORT:-5002} (health: /health)"
            echo "                   docreader 需 DOCREADER_ODL_HYBRID=docling-fast"
        fi
        
        echo ""
        log_info "接下来的步骤:"
        printf "%b\n" "${YELLOW}1. 在新终端运行后端:${NC} make dev-app"
        printf "%b\n" "${YELLOW}2. 在新终端运行前端:${NC} make dev-frontend"
        return 0
    else
        log_error "服务启动失败"
        return 1
    fi
}

# 停止服务
stop_services() {
    log_info "停止开发环境服务..."
    
    check_docker
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    cd "$PROJECT_ROOT"
    "$DOCKER_COMPOSE_BIN" $DOCKER_COMPOSE_SUBCMD -f docker-compose.dev.yml down
    
    if [ $? -eq 0 ]; then
        log_success "所有服务已停止"
        return 0
    else
        log_error "服务停止失败"
        return 1
    fi
}

# 重启服务
restart_services() {
    stop_services
    sleep 2
    start_services
}

# 查看日志
show_logs() {
    check_docker
    if [ $? -ne 0 ]; then
        return 1
    fi

    cd "$PROJECT_ROOT"
    "$DOCKER_COMPOSE_BIN" $DOCKER_COMPOSE_SUBCMD -f docker-compose.dev.yml logs -f
}

# 查看状态
show_status() {
    check_docker
    if [ $? -ne 0 ]; then
        return 1
    fi

    cd "$PROJECT_ROOT"
    "$DOCKER_COMPOSE_BIN" $DOCKER_COMPOSE_SUBCMD -f docker-compose.dev.yml ps
}

# WSL2 把端口转到 Windows 时经常只绑 [::1]。Docker Desktop 和浏览器访问
# 127.0.0.1 走 IPv4，会连不上本机 app。在 Windows 上起一个 IPv4→IPv6 中继。
ensure_windows_ipv4_localhost_proxy() {
    local port="${1:-${SERVER_PORT:-${APP_PORT:-18080}}}"
    if ! grep -qi microsoft /proc/version 2>/dev/null; then
        return 0
    fi
    if ! command -v powershell.exe >/dev/null 2>&1; then
        return 0
    fi

    local win_v4
    win_v4=$(powershell.exe -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:${port}/health' -TimeoutSec 2).StatusCode } catch { 'FAIL' }" 2>/dev/null | tr -d '\r')
    if [ "$win_v4" = "200" ]; then
        return 0
    fi

    local script_win
    script_win=$(wslpath -w "$PROJECT_ROOT/scripts/wsl-ipv4-proxy.ps1" 2>/dev/null || true)
    if [ -z "$script_win" ] || [ ! -f "$PROJECT_ROOT/scripts/wsl-ipv4-proxy.ps1" ]; then
        log_warning "无法把 ${port} 发布到 Windows 的 127.0.0.1，请改用 http://localhost:${port}/health"
        return 0
    fi

    log_info "WSL 仅转发了 IPv6 localhost，正在补 Windows IPv4 127.0.0.1:${port} ..."
    cmd.exe /c start "" /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script_win" -Port "$port" >/dev/null 2>&1
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        win_v4=$(powershell.exe -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:${port}/health' -TimeoutSec 2).StatusCode } catch { 'FAIL' }" 2>/dev/null | tr -d '\r')
        if [ "$win_v4" = "200" ]; then
            log_success "Windows 已可通过 http://127.0.0.1:${port}/health 访问"
            return 0
        fi
        sleep 0.5
    done
    log_warning "Windows 127.0.0.1:${port} 仍不可达。请用 http://localhost:${port}/health（IPv6）"
    return 0
}

# Docker Desktop/WSL 刚起来时，127.0.0.1 已 LISTEN，但 docker-proxy 会对
# 首包 RST。nc -z 仍会成功，Go redis.Ping / gorm.Open 则 panic。
probe_tcp_payload() {
    local host="$1" port="$2" hex_payload="$3"
    if ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    python3 - "$host" "$port" "$hex_payload" <<'PY'
import socket, sys
host, port, payload_hex = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    s = socket.create_connection((host, port), 2)
    s.settimeout(2)
    s.sendall(bytes.fromhex(payload_hex))
    data = s.recv(128)
    s.close()
except Exception:
    sys.exit(1)
sys.exit(0 if data else 1)
PY
}

WEKNORA_HOST_PROXY_CONTAINERS=(
    WeKnora-postgres
    WeKnora-redis
    WeKnora-docreader
    WeKnora-neo4j
    WeKnora-qdrant
    WeKnora-frontend
    WeKnora-mcp
    WeKnora-searxng
)

refresh_weknora_docker_proxies() {
    if [ "${WEKNORA_PROXIES_REFRESHED:-0}" = 1 ]; then
        return 0
    fi
    WEKNORA_PROXIES_REFRESHED=1
    log_warning "Docker Desktop/WSL 端口转发异常，正在重启 WeKnora 基础设施容器..."
    docker restart "${WEKNORA_HOST_PROXY_CONTAINERS[@]}" >/dev/null 2>&1 || true
    sleep 4
}

ensure_docker_port_ready() {
    local name="$1" host="$2" port="$3" container="$4" payload="$5"
    if probe_tcp_payload "$host" "$port" "$payload"; then
        return 0
    fi
    refresh_weknora_docker_proxies
    if probe_tcp_payload "$host" "$port" "$payload"; then
        log_success "${name} 端口转发已恢复"
        return 0
    fi
    log_warning "${name} 仍失败，尝试单独重启 ${container}..."
    if docker restart "$container" >/dev/null 2>&1; then
        sleep 2
        if probe_tcp_payload "$host" "$port" "$payload"; then
            log_success "${container} 已恢复"
            return 0
        fi
    fi
    return 1
}

ensure_host_redis_ready() {
    # RESP PING: *1\r\n$4\r\nPING\r\n
    ensure_docker_port_ready "Redis" "$1" "$2" "WeKnora-redis" "2a310d0a24340d0a50494e470d0a"
}

ensure_host_postgres_ready() {
    # PostgreSQL SSLRequest; healthy server replies N or S.
    ensure_docker_port_ready "PostgreSQL" "$1" "$2" "WeKnora-postgres" "0000000804d2162f"
}

ensure_host_neo4j_ready() {
    # Bolt handshake magic + protocol v1.
    ensure_docker_port_ready "Neo4j" "$1" "$2" "WeKnora-neo4j" "6060b01700000001000000000000000000000000"
}

# 宿主机 app 模式：启动前确认 Docker 基础设施已映射到本机端口
check_host_infra_connectivity() {
    case "${DB_HOST:-}" in
        127.0.0.1|localhost) ;;
        *) return 0 ;;
    esac

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker 未运行，本机 app 连不上 Redis/Postgres"
        log_info "请先启动 Docker Desktop，再执行: make host-infra && make dev-app"
        return 1
    fi

    local db_port="${DB_PORT:-5432}"
    local redis_port
    redis_port="${REDIS_ADDR#*:}"
    if [ "$redis_port" = "$REDIS_ADDR" ] || [ -z "$redis_port" ]; then
        redis_port=6379
    fi
    local redis_host="${REDIS_ADDR%%:*}"
    [ -z "$redis_host" ] && redis_host=127.0.0.1

    log_info "检查本机基础设施端口..."
    local failed=0
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "${DB_HOST}" "${db_port}" 2>/dev/null; then
            if ensure_host_postgres_ready "${DB_HOST}" "${db_port}"; then
                log_success "PostgreSQL ${DB_HOST}:${db_port} 可达"
            else
                log_error "PostgreSQL ${DB_HOST}:${db_port} 端口开着，但协议握手失败"
                failed=1
            fi
        else
            log_error "PostgreSQL ${DB_HOST}:${db_port} 不可达"
            failed=1
        fi
        if nc -z -w 3 "${redis_host}" "${redis_port}" 2>/dev/null; then
            if ensure_host_redis_ready "${redis_host}" "${redis_port}"; then
                log_success "Redis ${redis_host}:${redis_port} 可达"
            else
                log_error "Redis ${redis_host}:${redis_port} 端口开着，但协议握手失败"
                failed=1
            fi
        else
            log_error "Redis ${redis_host}:${redis_port} 不可达"
            failed=1
        fi
        if [ "${NEO4J_ENABLE:-}" = "true" ]; then
            local neo4j_host=127.0.0.1
            local neo4j_port=7687
            if [[ "${NEO4J_URI:-}" == *:* ]]; then
                neo4j_port="${NEO4J_URI##*:}"
            fi
            if nc -z -w 3 "${neo4j_host}" "${neo4j_port}" 2>/dev/null; then
                if ensure_host_neo4j_ready "${neo4j_host}" "${neo4j_port}"; then
                    log_success "Neo4j ${neo4j_host}:${neo4j_port} 可达"
                else
                    log_error "Neo4j ${neo4j_host}:${neo4j_port} 端口开着，但协议握手失败"
                    failed=1
                fi
            else
                log_error "Neo4j ${neo4j_host}:${neo4j_port} 不可达"
                failed=1
            fi
        fi
    fi

    if [ "$failed" -ne 0 ]; then
        echo ""
        log_error "基础设施未就绪。先启动 Docker 依赖，再启动本机 app:"
        echo "  make host-infra"
        echo "  make dev-app"
        return 1
    fi
    return 0
}

# 远程开发模式下检查基础设施端口是否可达
check_remote_dev_connectivity() {
    local host="${DEV_REMOTE_HOST:-}"
    if [ -z "$host" ]; then
        return 0
    fi

    local db_port="${DB_PORT:-5432}"
    local redis_port
    redis_port="${REDIS_ADDR#*:}"
    if [ "$redis_port" = "$REDIS_ADDR" ]; then
        redis_port=6379
    fi
    local docreader_port="${DOCREADER_PORT:-50051}"

    log_info "检查远程基础设施连通性 (${host})..."
    local failed=0
    for spec in "PostgreSQL:${host}:${db_port}" "Redis:${host}:${redis_port}" "DocReader:${host}:${docreader_port}"; do
        local name="${spec%%:*}"
        local rest="${spec#*:}"
        local h="${rest%%:*}"
        local p="${rest##*:}"
        if command -v nc &> /dev/null; then
            if nc -z -w 3 "$h" "$p" 2>/dev/null; then
                log_success "${name} ${h}:${p} 可达"
            else
                log_error "${name} ${h}:${p} 不可达 (no route / connection refused)"
                failed=1
            fi
        else
            log_warning "未安装 nc，跳过 ${name} 连通性检查"
        fi
    done

    if [ "$failed" -ne 0 ]; then
        echo ""
        log_error "无法连接远程开发环境 ${host}"
        log_info "排查建议:"
        echo "  1. 确认远程机器 Docker 容器在运行 (postgres/redis/docreader)"
        echo "  2. 确认本机与 ${host} 在同一局域网 (本机: $(ipconfig getifaddr en0 2>/dev/null || echo '未知'))"
        echo "  3. 在远程检查端口映射: docker ps --format 'table {{.Names}}\t{{.Ports}}'"
        echo "  4. 检查远程防火墙是否放行 5432/6379/50051"
        return 1
    fi
    return 0
}

# Host-platform path of the anydoc static archive (built by `make anydoc-lib`).
anydoc_host_archive() {
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) echo "$PROJECT_ROOT/third_party/anydoc-go/lib/darwin_arm64/libanydoc_go.a" ;;
        Darwin-x86_64) echo "$PROJECT_ROOT/third_party/anydoc-go/lib/darwin_amd64/libanydoc_go.a" ;;
        Linux-x86_64)
            if [ -f "$PROJECT_ROOT/third_party/anydoc-go/lib/linux_amd64_gnu/libanydoc_go.a" ]; then
                echo "$PROJECT_ROOT/third_party/anydoc-go/lib/linux_amd64_gnu/libanydoc_go.a"
            else
                echo "$PROJECT_ROOT/third_party/anydoc-go/lib/linux_amd64_musl/libanydoc_go.a"
            fi
            ;;
        Linux-aarch64)
            if [ -f "$PROJECT_ROOT/third_party/anydoc-go/lib/linux_arm64_gnu/libanydoc_go.a" ]; then
                echo "$PROJECT_ROOT/third_party/anydoc-go/lib/linux_arm64_gnu/libanydoc_go.a"
            else
                echo "$PROJECT_ROOT/third_party/anydoc-go/lib/linux_arm64_musl/libanydoc_go.a"
            fi
            ;;
        *) echo "" ;;
    esac
}

# Enable the in-process anydoc engine when the archive is present, unless the
# caller already set GO_BUILD_TAGS (including empty, which opts out).
enable_anydoc_build_tag() {
    if [ -n "${GO_BUILD_TAGS+x}" ]; then
        export GO_BUILD_TAGS
        return
    fi
    local archive
    archive="$(anydoc_host_archive)"
    if [ -n "$archive" ] && [ -f "$archive" ]; then
        export GO_BUILD_TAGS=anydoc
        log_info "检测到 anydoc 静态库，已启用 -tags anydoc"
    else
        log_info "未检测到 anydoc 静态库，解析引擎不可用。需要时先运行: make anydoc-lib"
    fi
}

# 启动后端应用（本地）
start_app() {
    log_info "启动后端应用（本地开发模式）..."
    
    cd "$PROJECT_ROOT"
    
    # 检查 Go 是否安装
    if ! command -v go &> /dev/null; then
        log_error "Go 未安装"
        return 1
    fi
    
    log_info "加载环境配置..."
    if ! load_env_files; then
        log_error ".env 文件不存在，请先创建配置文件"
        return 1
    fi
    
    # 本地 docker-compose.dev 模式：把容器服务名映射到宿主机回环地址
    # 远程开发模式（DEV_REMOTE_HOST 或 .env.local 已设地址）则保留 .env/.env.local 中的值
    if [ -n "${DEV_REMOTE_HOST:-}" ]; then
        log_info "远程开发模式: 基础设施 → ${DEV_REMOTE_HOST}"
        export DB_HOST="${DB_HOST:-$DEV_REMOTE_HOST}"
        export REDIS_ADDR="${REDIS_ADDR:-$DEV_REMOTE_HOST:6379}"
        export DOCREADER_ADDR="${DOCREADER_ADDR:-$DEV_REMOTE_HOST:50051}"
        export MINIO_ENDPOINT="${MINIO_ENDPOINT:-$DEV_REMOTE_HOST:9000}"
        export MILVUS_ADDRESS="${MILVUS_ADDRESS:-$DEV_REMOTE_HOST:19530}"
        export NEO4J_URI="${NEO4J_URI:-bolt://$DEV_REMOTE_HOST:7687}"
        export QDRANT_HOST="${QDRANT_HOST:-$DEV_REMOTE_HOST}"
        if [ -z "${LANGFUSE_HOST:-}" ] || [ "$LANGFUSE_HOST" = "http://langfuse-web:3000" ]; then
            export LANGFUSE_HOST="http://${DEV_REMOTE_HOST}:3000"
        fi
    else
        # Host-side process: rewrite compose DNS names to loopback, keep custom ports.
        case "${DB_HOST:-postgres}" in
            postgres|WeKnora-postgres) export DB_HOST=127.0.0.1 ;;
        esac
        case "${REDIS_ADDR:-redis:6379}" in
            redis:*|WeKnora-redis:*)
                export REDIS_ADDR="127.0.0.1:${REDIS_HOST_PORT:-${REDIS_ADDR##*:}}"
                ;;
        esac
        case "${DOCREADER_ADDR:-docreader:50051}" in
            docreader:*|WeKnora-docreader:*)
                export DOCREADER_ADDR="127.0.0.1:${DOCREADER_ADDR##*:}"
                ;;
        esac
        case "${MINIO_ENDPOINT:-}" in
            minio:*|WeKnora-minio:*)
                export MINIO_ENDPOINT="127.0.0.1:${MINIO_PORT:-${MINIO_ENDPOINT##*:}}"
                ;;
        esac
        case "${QDRANT_HOST:-}" in
            qdrant|WeKnora-qdrant) export QDRANT_HOST=127.0.0.1 ;;
        esac
        case "${NEO4J_URI:-}" in
            bolt://neo4j:*|bolt://WeKnora-neo4j:*)
                export NEO4J_URI="bolt://127.0.0.1:${NEO4J_URI##*:}"
                ;;
        esac
        if [[ "${LANGFUSE_HOST:-}" == *langfuse-web* ]]; then
            export LANGFUSE_HOST="http://127.0.0.1:${LANGFUSE_WEB_PORT:-3000}"
        fi
    fi
    export DOCREADER_TRANSPORT="${DOCREADER_TRANSPORT:-grpc}"

    # Docreader writes into the compose volume at container path /tmp/docreader.
    # Point the same path on the host at that volume so the local app can read images.
    local docreader_vol="/var/lib/docker/volumes/weknora_docreader-tmp/_data"
    if [ -d "$docreader_vol" ] && [ ! -e /tmp/docreader ]; then
        ln -s "$docreader_vol" /tmp/docreader
        log_info "已将 /tmp/docreader 指向 Docker 卷 weknora_docreader-tmp"
    fi

    if ! check_remote_dev_connectivity; then
        return 1
    fi
    if ! check_host_infra_connectivity; then
        return 1
    fi

    # .env.example uses /data/files for the Docker app container, where a
    # volume is mounted at that path. When the backend runs directly on the
    # host via dev-app, /data is often read-only or missing, so use a repo-local
    # writable directory unless the developer explicitly configured another
    # local storage path.
    if [ -z "${LOCAL_STORAGE_BASE_DIR:-}" ] || [ "$LOCAL_STORAGE_BASE_DIR" = "/data/files" ]; then
        export LOCAL_STORAGE_BASE_DIR="$PROJECT_ROOT/.local-data/files"
    fi
    mkdir -p "$LOCAL_STORAGE_BASE_DIR" 2>/dev/null || true
    
    # 确保必要的环境变量已设置
    if [ -z "$DB_DRIVER" ]; then
        log_error "DB_DRIVER 环境变量未设置，请检查 .env 文件"
        return 1
    fi
    
    log_info "环境变量已设置，启动应用..."
    log_info "数据库地址: $DB_HOST:${DB_PORT:-5432}"
    
    export CGO_CFLAGS="-Wno-deprecated-declarations -Wno-gnu-folding-constant"
    if [[ "$(uname)" == "Darwin" ]]; then
      export CGO_LDFLAGS="-Wl,-no_warn_duplicate_libraries"
    fi

    enable_anydoc_build_tag

    (
        publish_port="${SERVER_PORT:-${APP_PORT:-18080}}"
        for i in $(seq 1 90); do
            if curl -sf -m 1 "http://127.0.0.1:${publish_port}/health" >/dev/null 2>&1; then
                ensure_windows_ipv4_localhost_proxy "$publish_port"
                break
            fi
            sleep 1
        done
    ) &

    # 检查是否安装了 Air（热重载工具）
    if command -v air &> /dev/null; then
        log_success "检测到 Air，使用热重载模式启动..."
        log_info "修改 Go 代码后将自动重新编译和重启"
        air
    else
        log_info "未检测到 Air，使用普通模式启动"
        log_warning "提示: 安装 Air 可以实现代码修改后自动重启"
        log_info "安装命令: go install github.com/air-verse/air@latest"
        LDFLAGS="$(./scripts/get_version.sh ldflags) -X 'google.golang.org/protobuf/reflect/protoregistry.conflictPolicy=warn'"
        go run -tags "${GO_BUILD_TAGS:-}" -ldflags="$LDFLAGS" ./cmd/server
    fi
}

# 启动前端（本地）
start_frontend() {
    log_info "启动前端开发服务器..."

    cd "$PROJECT_ROOT"
    if [ -f ".env" ] || [ -f ".env.local" ]; then
        load_env_files >/dev/null 2>&1 || true
    fi
    
    cd "$PROJECT_ROOT/frontend"
    
    # 检查 npm 是否安装
    if ! command -v npm &> /dev/null; then
        log_error "npm 未安装"
        return 1
    fi
    
    # 检查依赖是否已安装
    if [ ! -d "node_modules" ]; then
        log_warning "node_modules 不存在，正在安装依赖..."
        npm install
    fi
    
    log_info "启动 Vite 开发服务器..."
    log_info "前端将运行在 http://localhost:5173"
    log_info "前端 API 代理目标: ${VITE_DEV_PROXY_TARGET:-${FRONTEND_BACKEND_URL:-http://localhost:8080}}"
    
    # 运行开发服务器
    npm run dev
}

# Keep the current compose data volumes; stop the app container so a host
# `go run` can replace it. Frontend Nginx is pointed at host.docker.internal.
start_host_infra() {
    log_info "切换到宿主机 app（保留现有 Docker 数据卷）..."

    check_docker
    if [ $? -ne 0 ]; then
        return 1
    fi

    cd "$PROJECT_ROOT"
    if ! load_env_files; then
        log_error ".env 文件不存在，请先创建"
        return 1
    fi

    log_info "重建 postgres/redis/docreader/frontend 端口与反代..."
    if ! docker compose -f docker-compose.yml -f docker-compose.host-app.yml \
        up -d --force-recreate postgres redis docreader frontend; then
        log_error "覆盖层启动失败"
        return 1
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx 'WeKnora-mcp'; then
        log_info "重配 MCP 指向宿主机 app..."
        docker rm -f WeKnora-mcp >/dev/null 2>&1 || true
        docker compose -f docker-compose.yml -f docker-compose.host-app.yml --profile full up -d mcp
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx 'WeKnora-app'; then
        log_info "停止容器 WeKnora-app，把 ${APP_PORT:-18080} 让给本机进程"
        docker stop WeKnora-app >/dev/null
        docker rm WeKnora-app >/dev/null
    fi

    log_success "基础设施已切到 host-app"
    echo ""
    log_info "宿主机连接:"
    echo "  - PostgreSQL:  127.0.0.1:${DB_HOST_PORT:-15432}"
    echo "  - Redis:       127.0.0.1:${REDIS_HOST_PORT:-16379}"
    echo "  - DocReader:   127.0.0.1:${DOCREADER_HOST_PORT:-15051}"
    echo "  - Frontend:    http://localhost:${FRONTEND_PORT:-80}  →  host app :${SERVER_PORT:-${APP_PORT:-18080}}"
    echo ""
    printf "%b\n" "${YELLOW}接下来在本终端或新终端运行:${NC} make dev-app"
    return 0
}

# 解析命令
CMD="${1:-help}"
case "$CMD" in
    start)
        start_services "$@"
        ;;
    stop)
        stop_services
        ;;
    restart)
        restart_services
        ;;
    logs)
        show_logs
        ;;
    status)
        show_status
        ;;
    app)
        start_app
        ;;
    host-infra)
        start_host_infra
        ;;
    frontend)
        start_frontend
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "未知命令: $CMD"
        show_help
        exit 1
        ;;
esac

exit 0

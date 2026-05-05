#!/usr/bin/env bash
# =============================================================================
# 脚本名称: Nginx-Install.sh
# 功能描述: 从源代码编译、安装、更新和卸载 Nginx 的独立脚本。
#           支持集成最新版 OpenSSL 和可选的 Brotli/Zstd 压缩模块。
#           负责管理 Nginx 的 systemd 服务配置。
# 依赖: bash, curl, wget, git, gcc, make, awk, grep, sed, sort, tr, systemctl, dnf/yum/apt
# 参考: https://github.com/zxcvos/Xray-script/blob/main/service/nginx.sh
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 注册退出时执行的清理函数
trap egress EXIT

# 颜色代码
readonly RED='\033[31m'
readonly YELLOW='\033[33m'
readonly CYAN='\033[36m'
readonly NC='\033[0m'

# 默认路径配置
NGINX_PREFIX="/usr/local/nginx"
readonly NGINX_LOG_PATH="/var/log/nginx"

# 编译选项 (可通过命令行参数覆盖)
JOBS="$(nproc)"
NGINX_VERSION=""      # 空 = 自动获取最新版
OPENSSL_VERSION=""    # 空 = 自动获取最新版
IS_ENABLE_BROTLI=""
IS_ENABLE_ZSTD=""
DRY_RUN=0

# 临时目录
TMPFILE_DIR="$(mktemp -d -t nginx-compile.XXXXXXXX)" || exit 1
readonly TMPFILE_DIR

# 全局变量
declare -a cflags=()

# =============================================================================
# 函数名称: egress
# 功能描述: 脚本退出时执行的清理操作。
# =============================================================================
function egress() {
    [[ -e "${TMPFILE_DIR}/swap" ]] && swapoff "${TMPFILE_DIR}/swap" 2>/dev/null
    rm -rf "${TMPFILE_DIR}"
}

# =============================================================================
# 函数名称: print_info
# 功能描述: 以绿色打印信息级别的提示消息。
# =============================================================================
function print_info() {
    printf "${CYAN}[信息]${NC} %s\n" "$*" >&2
}

# =============================================================================
# 函数名称: print_warn
# 功能描述: 以黄色打印警告级别的提示消息。
# =============================================================================
function print_warn() {
    printf "${YELLOW}[警告]${NC} %s\n" "$*" >&2
}

# =============================================================================
# 函数名称: print_error
# 功能描述: 以红色打印错误级别的提示消息, 并退出脚本。
# =============================================================================
function print_error() {
    printf "${RED}[错误]${NC} %s\n" "$*" >&2
    exit 1
}

# =============================================================================
# 函数名称: cmd_exists
# 功能描述: 检查指定的命令是否存在于系统中。
# =============================================================================
function cmd_exists() {
    local cmd="$1"
    if eval type type >/dev/null 2>&1; then
        eval type "$cmd" >/dev/null 2>&1
    elif command >/dev/null 2>&1; then
        command -v "$cmd" >/dev/null 2>&1
    else
        which "$cmd" >/dev/null 2>&1
    fi
}

# =============================================================================
# 函数名称: _os
# 功能描述: 检测当前操作系统的发行版名称。
# =============================================================================
function _os() {
    local os=""
    if [[ -f "/etc/debian_version" ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release && os="${ID}"
        printf -- "%s" "${os}" && return
    fi
    if [[ -f "/etc/redhat-release" ]]; then
        os="centos"
        printf -- "%s" "${os}" && return
    fi
}

# =============================================================================
# 函数名称: _os_full
# 功能描述: 获取当前操作系统的完整发行版信息。
# =============================================================================
function _os_full() {
    if [[ -f /etc/redhat-release ]]; then
        awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    fi
    if [[ -f /etc/os-release ]]; then
        awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    fi
    if [[ -f /etc/lsb-release ]]; then
        awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
    fi
}

# =============================================================================
# 函数名称: _os_ver
# 功能描述: 获取当前操作系统的主版本号。
# =============================================================================
function _os_ver() {
    local main_ver
    main_ver="$(_os_full | grep -oE "[0-9.]+")"
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: _error_detect
# 功能描述: 执行命令并检查其退出状态, 如果失败则打印错误并退出。
# =============================================================================
function _error_detect() {
    local cmd="$1"
    print_info "正在执行: ${cmd}"
    if ! eval "${cmd}"; then
        print_error "命令执行失败: ${cmd}"
    fi
}

# =============================================================================
# 函数名称: _version_ge
# 功能描述: 比较两个版本号字符串, 判断第一个是否大于等于第二个。
# =============================================================================
function _version_ge() {
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"
}

# =============================================================================
# 函数名称: _install
# 功能描述: 根据操作系统类型安装指定的软件包。
# =============================================================================
function _install() {
    local packages_name="$*"
    local installed_packages=""

    case "$(_os)" in
    centos)
        if cmd_exists "dnf"; then
            packages_name="dnf-plugins-core epel-release epel-next-release ${packages_name}"
            installed_packages="$(dnf list installed 2>/dev/null)"
            if [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 9 ]]; then
                if [[ "${packages_name}" =~ geoip\-devel ]] && ! echo "${installed_packages}" | grep -iwq "geoip-devel"; then
                    dnf update -y
                    _error_detect "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
                    _error_detect "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-9.noarch.rpm"
                    _error_detect "dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm"
                    _error_detect "dnf config-manager --set-enabled remi-modular"
                    _error_detect "dnf update --refresh"
                    dnf update -y
                    _error_detect "dnf --enablerepo=remi install -y GeoIP-devel"
                fi
            elif [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 8 ]]; then
                if ! dnf module list 2>/dev/null | grep container-tools | grep -iwq "\[x\]"; then
                    _error_detect "dnf module disable -y container-tools"
                fi
            fi
            dnf update -y
            for package_name in ${packages_name}; do
                if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                    _error_detect "dnf install -y ${package_name}"
                fi
            done
        else
            packages_name="epel-release yum-utils ${packages_name}"
            installed_packages="$(yum list installed 2>/dev/null)"
            yum update -y
            for package_name in ${packages_name}; do
                if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                    _error_detect "yum install -y ${package_name}"
                fi
            done
        fi
        ;;
    ubuntu | debian)
        apt update -y
        installed_packages="$(apt list --installed 2>/dev/null)"
        for package_name in ${packages_name}; do
            if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                _error_detect "apt install -y ${package_name}"
            fi
        done
        ;;
    esac
}

# =============================================================================
# 函数名称: check_os
# 功能描述: 检查操作系统是否受支持。
# =============================================================================
function check_os() {
    [[ -z "$(_os)" ]] && print_error "不支持的操作系统。"

    case "$(_os)" in
    ubuntu)
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 20 ]] && print_error "不支持的操作系统, 请切换到 Ubuntu 20+ 并重试。"
        ;;
    debian)
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 10 ]] && print_error "不支持的操作系统, 请切换到 Debian 10+ 并重试。"
        ;;
    centos)
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 7 ]] && print_error "不支持的操作系统, 请切换到 CentOS 7+ 并重试。"
        ;;
    *)
        print_error "不支持的操作系统。"
        ;;
    esac
}

# =============================================================================
# 函数名称: swap_on
# 功能描述: 创建并启用临时 swap 空间。
# =============================================================================
function swap_on() {
    local mem=${1}
    if [[ ${mem} -ne '0' ]]; then
        if dd if=/dev/zero of="${TMPFILE_DIR}/swap" bs=1M count="${mem}" 2>&1; then
            chmod 0600 "${TMPFILE_DIR}/swap"
            mkswap "${TMPFILE_DIR}/swap"
            swapon "${TMPFILE_DIR}/swap"
        fi
    fi
}

# =============================================================================
# 函数名称: backup_files
# 功能描述: 备份指定目录下的所有文件。
# =============================================================================
function backup_files() {
    local backup_dir="$1"
    local current_date
    current_date="$(date +%F)"
    for file in "${backup_dir}/"*; do
        if [[ -f "$file" ]]; then
            local file_name
            file_name="$(basename "$file")"
            local backup_file="${backup_dir}/${file_name}_${current_date}"
            mv "$file" "$backup_file"
            print_info "备份文件: ${file} -> ${backup_file}"
        fi
    done
}

# =============================================================================
# 函数名称: compile_dependencies
# 功能描述: 安装编译 Nginx 所需的依赖包。
# =============================================================================
function compile_dependencies() {
    print_info "正在安装编译依赖项..."
    _install ca-certificates curl wget gcc make git openssl tzdata socat
    case "$(_os)" in
    centos)
        _install bind-utils gcc-c++ perl-IPC-Cmd perl-Getopt-Long perl-Data-Dumper perl-Time-Piece
        _install pcre2-devel zlib-devel libxml2-devel libxslt-devel gd-devel geoip-devel perl-ExtUtils-Embed gperftools-devel perl-devel brotli-devel libzstd-devel
        if ! perl -e "use FindBin" &>/dev/null; then
            _install perl-FindBin
        fi
        ;;
    debian | ubuntu)
        _install dnsutils g++ perl-base perl
        _install libpcre2-dev zlib1g-dev libxml2-dev libxslt1-dev libgd-dev libgeoip-dev libgoogle-perftools-dev libperl-dev libbrotli-dev libzstd-dev
        ;;
    esac
}

# =============================================================================
# 函数名称: gen_cflags
# 功能描述: 生成优化的 C 编译器标志 (CFLAGS)。
# =============================================================================
function gen_cflags() {
    cflags=('-g0' '-O3')
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-reuse"; then
        cflags+=('-fstack-reuse=all')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fdwarf2\\-cfi\\-asm"; then
        cflags+=('-fdwarf2-cfi-asm')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fplt"; then
        cflags+=('-fplt')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-ftrapv"; then
        cflags+=('-fno-trapv')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fexceptions"; then
        cflags+=('-fno-exceptions')
    elif gcc -v --help 2>&1 | grep -qw "\\-fhandle\\-exceptions"; then
        cflags+=('-fno-handle-exceptions')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-funwind\\-tables"; then
        cflags+=('-fno-unwind-tables')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fasynchronous\\-unwind\\-tables"; then
        cflags+=('-fno-asynchronous-unwind-tables')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-check"; then
        cflags+=('-fno-stack-check')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-clash\\-protection"; then
        cflags+=('-fno-stack-clash-protection')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-protector"; then
        cflags+=('-fno-stack-protector')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fcf\\-protection="; then
        cflags+=('-fcf-protection=none')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fsplit\\-stack"; then
        cflags+=('-fno-split-stack')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fsanitize"; then
        true >temp.c
        if gcc -E -fno-sanitize=all temp.c >/dev/null 2>&1; then
            cflags+=('-fno-sanitize=all')
        fi
        rm temp.c
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-finstrument\\-functions"; then
        cflags+=('-fno-instrument-functions')
    fi
}

# =============================================================================
# 函数名称: source_compile
# 功能描述: 下载源码并编译 Nginx。
# =============================================================================
function source_compile() {
    cd "${TMPFILE_DIR}" || exit

    # 获取版本
    local nginx_version="${NGINX_VERSION}"
    local openssl_version="${OPENSSL_VERSION}"

    if [[ -z "${nginx_version}" ]]; then
        print_info "正在获取最新 Nginx 版本..."
        nginx_version="$(wget -qO- --no-check-certificate https://api.github.com/repos/nginx/nginx/tags | grep 'name' | cut -d\" -f4 | grep 'release' | head -1 | sed 's/release/nginx/')"
        [[ -z "${nginx_version}" ]] && print_error "获取 Nginx 版本失败, 请检查网络连接或使用 --version 指定版本。"
    fi

    if [[ -z "${openssl_version}" ]]; then
        print_info "正在获取最新 OpenSSL 版本..."
        openssl_version="openssl-$(wget -qO- --no-check-certificate https://api.github.com/repos/openssl/openssl/tags | grep 'name' | cut -d\" -f4 | grep -Eoi '^openssl-([0-9]\.?){3}$' | head -1)"
        [[ -z "${openssl_version}" ]] && print_error "获取 OpenSSL 版本失败, 请检查网络连接或使用 --openssl-version 指定版本。"
    fi

    print_info "Nginx 版本: ${nginx_version}"
    print_info "OpenSSL 版本: ${openssl_version}"

    # 生成编译器优化标志
    gen_cflags

    # Dry-run 模式
    if [[ ${DRY_RUN} -eq 1 ]]; then
        local -a dry_run_args=(
            "--prefix=${NGINX_PREFIX}"
            "--user=nginx"
            "--group=nginx"
            "--with-threads"
            "--with-file-aio"
            "--with-http_ssl_module"
            "--with-http_v2_module"
            "--with-http_v3_module"
            "--with-http_realip_module"
            "--with-http_addition_module"
            "--with-http_xslt_module=dynamic"
            "--with-http_image_filter_module=dynamic"
            "--with-http_geoip_module=dynamic"
            "--with-http_sub_module"
            "--with-http_dav_module"
            "--with-http_flv_module"
            "--with-http_mp4_module"
            "--with-http_gunzip_module"
            "--with-http_gzip_static_module"
            "--with-http_auth_request_module"
            "--with-http_random_index_module"
            "--with-http_secure_link_module"
            "--with-http_degradation_module"
            "--with-http_slice_module"
            "--with-http_stub_status_module"
            "--with-http_perl_module=dynamic"
            "--with-mail=dynamic"
            "--with-mail_ssl_module"
            "--with-stream"
            "--with-stream_ssl_module"
            "--with-stream_realip_module"
            "--with-stream_geoip_module=dynamic"
            "--with-stream_ssl_preread_module"
            "--with-google_perftools_module"
            "--with-compat"
            "--with-cc-opt=${cflags[*]}"
            "--with-openssl=../${openssl_version}"
            "--with-openssl-opt=${cflags[*]}"
        )
        if [[ "${IS_ENABLE_BROTLI}" =~ ^[Yy]$ ]]; then
            dry_run_args+=("--add-module=../ngx_brotli")
        fi
        if [[ "${IS_ENABLE_ZSTD}" =~ ^[Yy]$ ]]; then
            dry_run_args+=("--add-module=../zstd-nginx-module")
        fi

        echo ""
        echo "========== Nginx 编译计划 =========="
        echo "Nginx 版本:    ${nginx_version}"
        echo "OpenSSL 版本:  ${openssl_version}"
        echo "安装路径:      ${NGINX_PREFIX}"
        echo "并行任务数:    ${JOBS}"
        echo "Brotli:        $([[ ${IS_ENABLE_BROTLI} =~ ^[Yy]$ ]] && echo '启用' || echo '禁用')"
        echo "Zstd:          $([[ ${IS_ENABLE_ZSTD} =~ ^[Yy]$ ]] && echo '启用' || echo '禁用')"
        echo "CFLAGS:        ${cflags[*]}"
        echo ""
        echo "配置命令:"
        local total=${#dry_run_args[@]}
        local i=0
        for arg in "${dry_run_args[@]}"; do
            i=$((i + 1))
            if [[ ${i} -eq ${total} ]]; then
                echo "    ${arg}"
            else
                echo "    ${arg} \\"
            fi
        done
        echo "====================================="
        echo ""
        return 0
    fi

    # 下载 Nginx 源码
    print_info "正在下载 Nginx 源码..."
    _error_detect "curl -fsSL -o ${nginx_version}.tar.gz https://nginx.org/download/${nginx_version}.tar.gz"
    tar -zxf "${nginx_version}.tar.gz"

    # 下载 OpenSSL 源码
    print_info "正在下载 OpenSSL 源码..."
    _error_detect "curl -fsSL -o ${openssl_version}.tar.gz https://github.com/openssl/openssl/archive/${openssl_version#*-}.tar.gz"
    tar -zxf "${openssl_version}.tar.gz"

    # 如果启用 Brotli
    if [[ "${IS_ENABLE_BROTLI}" =~ ^[Yy]$ ]]; then
        print_info "正在获取 ngx_brotli 模块..."
        _error_detect "git clone https://github.com/google/ngx_brotli && cd ngx_brotli && git submodule update --init"
        cd "${TMPFILE_DIR}" || exit
    fi

    # 如果启用 Zstd
    if [[ "${IS_ENABLE_ZSTD}" =~ ^[Yy]$ ]]; then
        print_info "正在获取 zstd-nginx-module 模块..."
        _error_detect "git clone https://github.com/tokers/zstd-nginx-module"
        cd "${TMPFILE_DIR}" || exit
    fi

    # 进入 Nginx 源码目录
    cd "${nginx_version}" || exit

    # 源码优化补丁
    sed -i "s/OPTIMIZE[ \\t]*=>[ \\t]*'-O'/OPTIMIZE          => '-O3'/g" src/http/modules/perl/Makefile.PL
    # shellcheck disable=SC2016
    sed -i 's/NGX_PERL_CFLAGS="$CFLAGS `$NGX_PERL -MExtUtils::Embed -e ccopts`"/NGX_PERL_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf
    # shellcheck disable=SC2016
    sed -i 's/NGX_PM_CFLAGS=`$NGX_PERL -MExtUtils::Embed -e ccopts`/NGX_PM_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf

    # 执行 configure
    print_info "正在配置 Nginx 编译选项..."
    local -a configure_args=(
        "--prefix=${NGINX_PREFIX}"
        "--user=nginx"
        "--group=nginx"
        "--with-threads"
        "--with-file-aio"
        "--with-http_ssl_module"
        "--with-http_v2_module"
        "--with-http_v3_module"
        "--with-http_realip_module"
        "--with-http_addition_module"
        "--with-http_xslt_module=dynamic"
        "--with-http_image_filter_module=dynamic"
        "--with-http_geoip_module=dynamic"
        "--with-http_sub_module"
        "--with-http_dav_module"
        "--with-http_flv_module"
        "--with-http_mp4_module"
        "--with-http_gunzip_module"
        "--with-http_gzip_static_module"
        "--with-http_auth_request_module"
        "--with-http_random_index_module"
        "--with-http_secure_link_module"
        "--with-http_degradation_module"
        "--with-http_slice_module"
        "--with-http_stub_status_module"
        "--with-http_perl_module=dynamic"
        "--with-mail=dynamic"
        "--with-mail_ssl_module"
        "--with-stream"
        "--with-stream_ssl_module"
        "--with-stream_realip_module"
        "--with-stream_geoip_module=dynamic"
        "--with-stream_ssl_preread_module"
        "--with-google_perftools_module"
        "--with-compat"
        "--with-cc-opt=${cflags[*]}"
        "--with-openssl=../${openssl_version}"
        "--with-openssl-opt=${cflags[*]}"
    )
    if [[ "${IS_ENABLE_BROTLI}" =~ ^[Yy]$ ]]; then
        configure_args+=("--add-module=../ngx_brotli")
    fi
    if [[ "${IS_ENABLE_ZSTD}" =~ ^[Yy]$ ]]; then
        configure_args+=("--add-module=../zstd-nginx-module")
    fi

    ./configure "${configure_args[@]}"

    print_info "正在申请 512MB 虚拟内存..."
    swap_on 512

    print_info "正在编译 Nginx (并行 ${JOBS} 任务)..."
    _error_detect "make -j${JOBS}"
}

# =============================================================================
# 函数名称: source_install
# 功能描述: 编译并安装 Nginx。
# =============================================================================
function source_install() {
    source_compile
    print_info "正在安装 Nginx..."
    make install
    make clean
    # 清理 make install 生成的不必要文件
    rm -rf "${NGINX_PREFIX}/logs/"
    rm -f "${NGINX_PREFIX}/conf/"*.default "${NGINX_PREFIX}/conf/fastcgi.conf" \
    "${NGINX_PREFIX}/conf/koi-utf" "${NGINX_PREFIX}/conf/koi-win" "${NGINX_PREFIX}/conf/win-utf" \
    "${NGINX_PREFIX}/conf/fastcgi_params" "${NGINX_PREFIX}/conf/scgi_params" "${NGINX_PREFIX}/conf/uwsgi_params"
    mkdir -p "${NGINX_LOG_PATH}"
    chown -R "nginx:adm" "${NGINX_LOG_PATH}"
    ln -sf "${NGINX_PREFIX}/sbin/nginx" /usr/sbin/nginx
}

# =============================================================================
# 函数名称: source_update
# 功能描述: 检查并更新 Nginx。
# =============================================================================
function source_update() {
    print_info "正在获取最新版本..."
    local latest_nginx_version
    latest_nginx_version="$(wget -qO- --no-check-certificate https://api.github.com/repos/nginx/nginx/tags | grep 'name' | cut -d\" -f4 | grep 'release' | head -1 | sed 's/release/nginx/')"
    local latest_openssl_version
    latest_openssl_version="$(wget -qO- --no-check-certificate https://api.github.com/repos/openssl/openssl/tags | grep 'name' | cut -d\" -f4 | grep -Eoi '^openssl-([0-9]\.?){3}$' | head -1)"

    print_info "正在读取当前版本..."
    local current_version_nginx
    current_version_nginx="$(nginx -V 2>&1 | grep "^nginx version:.*" | cut -d / -f 2)"
    local current_version_openssl
    current_version_openssl="$(nginx -V 2>&1 | grep "^built with OpenSSL" | awk '{print $4}')"

    print_info "当前 Nginx: ${current_version_nginx}, 最新 Nginx: ${latest_nginx_version#*-}"
    print_info "当前 OpenSSL: ${current_version_openssl}, 最新 OpenSSL: ${latest_openssl_version#*-}"

    if _version_ge "${latest_nginx_version#*-}" "${current_version_nginx}" || _version_ge "${latest_openssl_version#*-}" "${current_version_openssl}"; then
        print_info "检测到新版本, 开始更新..."

        if [[ ${DRY_RUN} -eq 1 ]]; then
            print_info "Dry-run: 将更新 Nginx 从 ${current_version_nginx} 到 ${latest_nginx_version#*-}"
            return 0
        fi

        source_compile

        print_info "正在执行热升级..."
        # 清理旧备份文件
        rm -f "${NGINX_PREFIX}/sbin/nginx_20"* 2>/dev/null
        rm -f "${NGINX_PREFIX}/modules/"*_20* 2>/dev/null
        mv "${NGINX_PREFIX}/sbin/nginx" "${NGINX_PREFIX}/sbin/nginx_$(date +%F)"
        backup_files "${NGINX_PREFIX}/modules"
        cp objs/nginx "${NGINX_PREFIX}/sbin/"
        cp objs/*.so "${NGINX_PREFIX}/modules/" 2>/dev/null || true
        ln -sf "${NGINX_PREFIX}/sbin/nginx" /usr/sbin/nginx

        if systemctl is-active --quiet nginx; then
            print_info "正在执行平滑升级..."
            kill -USR2 "$(cat /run/nginx.pid)"
            sleep 1
            if [[ -e "/run/nginx.pid.oldbin" ]]; then
                kill -WINCH "$(cat /run/nginx.pid.oldbin)"
                kill -HUP "$(cat /run/nginx.pid.oldbin)"
                sleep 1
                kill -QUIT "$(cat /run/nginx.pid.oldbin)"
            else
                print_info "未检测到旧进程, 跳过平滑升级。"
            fi
        fi
        return 0
    fi
    print_info "Nginx 已是最新版本, 无需更新。"
    return 1
}

# =============================================================================
# 函数名称: purge_nginx
# 功能描述: 完全卸载 Nginx。
# =============================================================================
function purge_nginx() {
    print_info "正在卸载 Nginx..."
    systemctl stop nginx 2>/dev/null || true
    rm -rf "${NGINX_PREFIX}"
    rm -rf /usr/sbin/nginx
    rm -rf /etc/systemd/system/nginx.service
    rm -rf /etc/logrotate.d/nginx
    rm -rf "${NGINX_LOG_PATH}"
    systemctl daemon-reload
    print_info "Nginx 已卸载。"
}

# =============================================================================
# 函数名称: systemctl_config_nginx
# 功能描述: 配置 Nginx 的 systemd 服务文件。
# =============================================================================
function systemctl_config_nginx() {
    print_info "正在配置 systemd 服务..."
    cat >/etc/systemd/system/nginx.service <<'EOF'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/bin/rm -rf /dev/shm/nginx
ExecStartPre=/bin/mkdir /dev/shm/nginx
ExecStartPre=/bin/chmod 711 /dev/shm/nginx
ExecStartPre=/bin/mkdir /dev/shm/nginx/tcmalloc
ExecStartPre=/bin/chmod 0777 /dev/shm/nginx/tcmalloc
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on; pid /run/nginx.pid;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on; pid /run/nginx.pid;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on; pid /run/nginx.pid;' -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
ExecStopPost=/bin/rm -rf /dev/shm/nginx
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    print_info "systemd 服务配置完成。"

    # 配置日志轮转
    print_info "正在配置日志轮转..."
    cat >/etc/logrotate.d/nginx <<EOF
${NGINX_LOG_PATH}/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 nginx adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 \$(cat /run/nginx.pid)
    endscript
}
EOF
    print_info "日志轮转配置完成。"
}

# =============================================================================
# 函数名称: show_help
# 功能描述: 显示脚本使用帮助信息。
# =============================================================================
function show_help() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --install                编译并安装 Nginx
  --update                 检查并更新 Nginx
  --purge                  卸载 Nginx
  --brotli                 启用 Brotli 压缩模块 (与 --install 或 --update 一起使用)
  --zstd                   启用 Zstd 压缩模块 (与 --install 或 --update 一起使用)
  --prefix <路径>          指定安装路径 (默认: /usr/local/nginx)
  --prefix=<路径>          同上
  -j <数量>                指定并行编译任务数 (默认: $(nproc))
  --version <版本>         指定 Nginx 版本 (默认: 自动获取最新版)
  --openssl-version <版本> 指定 OpenSSL 版本 (默认: 自动获取最新版)
  --dry-run                仅显示将要执行的操作, 不实际执行
  --help                   显示此帮助信息

示例:
  $(basename "$0") --install
  $(basename "$0") --install --brotli
  $(basename "$0") --install --brotli --zstd
  $(basename "$0") --install --prefix /opt/nginx
  $(basename "$0") --install --version nginx-1.30.0 --openssl-version openssl-4.0.0
  $(basename "$0") --update
  $(basename "$0") --update --brotli --zstd
  $(basename "$0") --purge
EOF
    exit 0
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
# =============================================================================
function main() {
    # 检查操作系统兼容性
    check_os

    local action=''

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --install | --update | --purge)
            action="${1#--}"
            ;;
        --brotli)
            IS_ENABLE_BROTLI='Y'
            ;;
        --zstd)
            IS_ENABLE_ZSTD='Y'
            ;;
        --prefix)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "--prefix 需要指定路径参数。"
            fi
            NGINX_PREFIX="$2"
            shift
            ;;
        --prefix=*)
            NGINX_PREFIX="${1#*=}"
            ;;
        -j)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "-j 需要指定数值参数。"
            fi
            JOBS="$2"
            shift
            ;;
        --version)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "--version 需要指定版本参数。"
            fi
            NGINX_VERSION="$2"
            shift
            ;;
        --openssl-version)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "--openssl-version 需要指定版本参数。"
            fi
            OPENSSL_VERSION="$2"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --help)
            show_help
            ;;
        *)
            print_error "无效选项: '$1'。使用 '$(basename "$0") --help' 查看用法。"
            ;;
        esac
        shift
    done

    # 检查是否指定了操作
    [[ -z "${action}" ]] && print_error "请指定操作。使用 '$(basename "$0") --help' 查看用法。"

    # 根据操作执行相应功能
    case "${action}" in
    install)
        compile_dependencies
        source_install
        systemctl_config_nginx
        print_info "Nginx 安装完成。使用 'systemctl start nginx' 启动服务。"
        ;;
    update)
        compile_dependencies
        if source_update; then
            print_info "Nginx 更新完成。"
        else
            print_info "Nginx 已是最新版本, 无需更新。"
        fi
        ;;
    purge)
        purge_nginx
        ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"

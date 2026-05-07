#!/usr/bin/env bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:~/.local/bin:~/bin
export PATH

# 脚本退出时执行的清理操作
trap egress EXIT

readonly CYAN=$'\e[1;36m'
readonly YELLOW=$'\e[1;33m'
readonly RED=$'\e[1;31m'
readonly NC=$'\e[0m'
function print_info() {
	printf "${CYAN}[信息]${NC} %s\n" "$*" >&2
}
function print_warn() {
	printf "${YELLOW}[警告]${NC} %s\n" "$*" >&2
}
function print_error() {
	printf "${RED}[错误]${NC} %s\n" "$*" >&2
	exit 1
}

[[ -f "/etc/os-release" ]] && os_id=$(grep -w '^ID' /etc/os-release | cut -d= -f2 | tr -d '"')
[[ -f "/etc/redhat-release" ]] && os_id="centos"
if [[ "$os_id" != "debian" && "$os_id" != "ubuntu" ]]; then
	print_error "此脚本仅支持 Debian 和 Ubuntu, 结束运行"
fi

if [[ "$EUID" -ne 0 ]]; then
	print_error "请以 root 权限运行此脚本, 结束运行"
fi

# 默认路径配置
nginx_prefix="/usr/local/nginx"
nginx_log_path="/usr/local/nginx/logs"

# 临时目录
mkdir -p "$HOME/tmp"
TMPFILE_DIR="$(mktemp -d -p "$HOME/tmp" nginx-compile.XXXXXXXX)" || exit 1
readonly TMPFILE_DIR

# 脚本退出时执行的清理操作
function egress() {
	[[ -e "${TMPFILE_DIR}/swap" ]] && swapoff "${TMPFILE_DIR}/swap" 2>/dev/null
	rm -rf "${TMPFILE_DIR}"
}

# 执行命令并检查其退出状态, 如果失败则打印错误并退出
function _error_detect() {
	local cmd="$1"
	print_info "正在执行: ${cmd}"
	if ! eval "${cmd}"; then
		print_error "执行失败, 结束运行: ${cmd}"
	fi
}

# 安装指定的软件包
function _install() {
	local packages_name="$*"
	local installed_packages

	[[ -z "$(find /var/cache/apt/pkgcache.bin -mmin -1440)" ]] && apt update -y
	installed_packages="$(apt list --installed 2>/dev/null)"
	for package_name in ${packages_name}; do
		if ! echo "${installed_packages}" | grep -iq "^${package_name}/"; then
			_error_detect "apt install -y ${package_name}"
		fi
	done
}

# 创建并启用临时 swap 空间
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

# 安装编译 Nginx 所需的依赖包
function compile_dependencies() {
	print_info "正在安装编译依赖..."
	_install ca-certificates curl wget gcc g++ make git jq libpcre2-dev zlib1g-dev libbrotli-dev libzstd-dev libmaxminddb-dev
}

# 下载源码并编译 Nginx
function source_compile() {
	cd "${TMPFILE_DIR}" || exit

	# 下载 Nginx 源码
	print_info "正在下载 Nginx 源码..."
	nginx_version=$(curl -fsSL https://api.github.com/repos/nginx/nginx/releases/latest | jq -r .tag_name | awk -F'-' '{print $2}')
	[[ -z "${nginx_version}" ]] && print_error "获取 Nginx 版本失败, 请检查网络连接"
	_error_detect "curl -fsSLOJ https://nginx.org/download/nginx-${nginx_version}.tar.gz"
	tar -xf "nginx-${nginx_version}.tar.gz"

	# 下载 OpenSSL 源码
	print_info "正在下载 OpenSSL 源码..."
	openssl_version=$(curl -fsSL https://api.github.com/repos/openssl/openssl/releases/latest | jq -r .tag_name)
	[[ -z "${openssl_version}" ]] && print_error "获取 OpenSSL 版本失败, 请检查网络连接"
	_error_detect "curl -fsSLOJ https://github.com/openssl/openssl/releases/download/${openssl_version}/${openssl_version}.tar.gz"
	tar -xf "$openssl_version.tar.gz"

	# 获取 Brotli 模块
	print_info "正在获取 ngx_brotli 模块..."
	_error_detect "git clone --depth 1 https://github.com/google/ngx_brotli.git"
	_error_detect "git -C ngx_brotli submodule update --init"

	# 获取 Zstd 模块
	print_info "正在获取 zstd-nginx-module 模块..."
	_error_detect "git clone --depth 1 https://github.com/tokers/zstd-nginx-module.git"

	# 进入 Nginx 源码目录
	cd "nginx-${nginx_version}" || exit

	# 执行 configure
	print_info "正在配置 Nginx 编译选项..."
	./configure \
		"--prefix=${nginx_prefix}" \
		"--user=nginx" \
		"--group=nginx" \
		"--with-threads" \
		"--with-file-aio" \
		"--with-http_ssl_module" \
		"--with-http_v2_module" \
		"--with-http_v3_module" \
		"--with-http_realip_module" \
		"--with-http_addition_module" \
		"--with-http_sub_module" \
		"--with-http_dav_module" \
		"--with-http_gunzip_module" \
		"--with-http_gzip_static_module" \
		"--with-http_auth_request_module" \
		"--with-http_random_index_module" \
		"--with-http_secure_link_module" \
		"--with-http_slice_module" \
		"--with-http_stub_status_module" \
		"--with-stream" \
		"--with-stream_ssl_module" \
		"--with-stream_realip_module" \
		"--with-stream_ssl_preread_module" \
		"--with-compat" \
		"--with-openssl=../${openssl_version}" \
		"--add-module=../ngx_brotli" \
		"--add-module=../zstd-nginx-module"

	print_info "正在申请虚拟内存..."
	swap_on 512

	print_info "正在编译 Nginx..."
	_error_detect "make -j$(nproc)"
}

# 编译并安装 Nginx
function source_install() {
	source_compile
	print_info "正在安装 Nginx..."
	make install
	make clean
	# 清理不必要文件
	cd "${nginx_prefix}" || exit
	rm -rf logs/ conf/*.default conf/koi-utf conf/koi-win conf/win-utf
	# 用户 (组), 权限与日志
	id -u nginx &>/dev/null || useradd -M -s /usr/sbin/nologin nginx
	mkdir -p ${nginx_log_path}
	[[ -f "${nginx_log_path}/error.log" ]] || touch ${nginx_log_path}/error.log
	[[ -f "${nginx_log_path}/access.log" ]] || touch ${nginx_log_path}/access.log
	chown -R nginx:adm ${nginx_log_path}
	find ${nginx_log_path} -type d -exec chmod 755 {} +
	find ${nginx_log_path} -type f -exec chmod 640 {} +
	# 为二进制文件添加到可执行路径
	ln -snf "${nginx_prefix}/sbin/nginx" /usr/sbin/nginx
}

# 配置 Nginx 的 systemd 服务文件和日志轮转
function configure_nginx() {
	# 配置 systemd 服务
	cat >/etc/systemd/system/nginx.service <<'EOF'
[Unit]
Description=nginx - high performance web server
Documentation=https://nginx.org/en/docs/
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	print_info "systemd 服务配置完成"

	# 配置日志轮转
	cat >/etc/logrotate.d/nginx <<EOF
${nginx_log_path}/*.log {
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
	print_info "日志轮转配置完成"
}

# 完全卸载 Nginx
function purge_nginx() {
	systemctl stop nginx.service &>/dev/null
	systemctl disable nginx.service &>/dev/null
	killall nginx &>/dev/null

	# 必须在通过 APT 卸载之前执行, 否则可能找不到二进制
	if command -v nginx &>/dev/null; then
		nginx_prefix=$(nginx -V 2>&1 | grep -oP '(?<=--prefix=)[^ ]+' | tr -d '"'\')
	fi

	# 卸载通过 APT 安装的
	if command -v dpkg &>/dev/null; then
		# 检查是否存在状态为 'ii' (已正常安装) 的 nginx 相关包
		nginx_pkgs=$(dpkg -l 'nginx*' 2>/dev/null | grep '^ii' | awk '{print $2}')
		if [[ ! -z $nginx_pkgs ]]; then
			# shellcheck disable=SC2086
			apt-get purge -y $nginx_pkgs &>/dev/null
			apt-get autoremove -y &>/dev/null
		fi
	fi

	# 删除工作目录
	if [[ -n "$nginx_prefix" ]]; then
		# 不允许脚本删除核心系统目录
		if [[ "$nginx_prefix" =~ ^/(usr|etc|var|bin|sbin|lib|root|boot|dev|home)$ ]] || [[ "$nginx_prefix" == "/" ]]; then
			print_error "nginx_prefix 指向核心系统目录, 取消删除"
		else
			rm -rf "$nginx_prefix"
		fi
	fi

	# 删除常见目录
	rm -rf /etc/nginx /var/log/nginx /etc/logrotate.d/nginx "${nginx_log_path}" /var/cache/nginx /var/lib/nginx /usr/local/nginx /opt/nginx

	# 删除二进制文件
	rm -f /usr/sbin/nginx /usr/local/sbin/nginx /usr/bin/nginx /usr/local/bin/nginx

	# 清理 systemd 和 sysvinit 服务文件
	nginx_systemd=$(systemctl show -p FragmentPath --value nginx.service)
	rm -f "$nginx_systemd"
	rm -f /etc/systemd/system/nginx.service
	rm -rf /etc/systemd/system/nginx.service.d
	rm -f /lib/systemd/system/nginx.service
	rm -f /usr/lib/systemd/system/nginx.service
	rm -f /etc/init.d/nginx
	systemctl daemon-reload

	print_info "已卸载 Nginx 并完成清理"
}

# 显示脚本使用帮助信息
function show_help() {
	cat <<EOF
用法: $(basename "$0") [选项]
选项:
  --install    编译并安装 Nginx
  --purge      卸载 Nginx
  --help       显示此帮助信息
EOF
	exit 0
}

# 脚本的主入口函数
function main() {
	local action=''

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--install)
			action='install'
			;;
		--purge)
			action='purge'
			;;
		--help)
			show_help
			;;
		*)
			print_warn "无效选项: '$1'"
			show_help
			;;
		esac
		shift
	done

	[[ -z "${action}" ]] && show_help

	case "${action}" in
	install)
		compile_dependencies
		source_install
		configure_nginx
		print_info "Nginx 已安装完成"
		;;
	purge)
		purge_nginx
		;;
	esac
}

# --- 脚本执行入口 ---
main "$@"

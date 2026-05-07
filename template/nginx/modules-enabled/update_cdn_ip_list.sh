#!/bin/bash

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
}

output="/usr/local/nginx/modules-enabled/cdn_ip_list.conf"

command -v jq &>/dev/null || apt install -y jq

echo "# Cloudflare, Fastly 和 Gcore 的 CDN IP 列表 -- $(date)" >"$output"

print_info "正在处理 Cloudflare IP..."
curl -fsSL https://www.cloudflare.com/ips-v4/ |
	grep -v '^$' | sed 's/^/set_real_ip_from /; s/$/;/' >>"$output"
curl -fsSL https://www.cloudflare.com/ips-v6/ |
	grep -v '^$' | sed 's/^/set_real_ip_from /; s/$/;/' >>"$output"

print_info "正在处理 Fastly IP..."
curl -fsSL https://api.fastly.com/public-ip-list |
	jq -r '(.addresses[], .ipv6_addresses[]) | "set_real_ip_from \( . );"' >>"$output"

print_info "正在处理 Gcore IP..."
curl -fsSL https://api.gcore.com/cdn/public-ip-list |
	jq -r '(.addresses[], .addresses_v6[]) | "set_real_ip_from \( . );"' >>"$output"

if nginx -t &>/dev/null; then
	nginx -s reload
	print_info "更新 $output 成功, 已重载 Nginx"
else
	print_error "Nginx 检查不通过, 请检查 $output"
fi

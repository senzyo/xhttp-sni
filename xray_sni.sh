#!/bin/bash

readonly GREEN=$'\e[1;32m'
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

function _error_detect() {
	local cmd="$1"
	print_info "正在执行: ${cmd}"
	if ! eval "${cmd}"; then
		print_error "执行失败, 结束运行: ${cmd}"
		exit 1
	fi
}

[[ -f "/etc/os-release" ]] && os_id=$(grep -w '^ID' /etc/os-release | cut -d= -f2 | tr -d '"')
[[ -f "/etc/redhat-release" ]] && os_id="centos"
if [[ "$os_id" != "debian" && "$os_id" != "ubuntu" ]]; then
	print_error "此脚本仅支持 Debian 和 Ubuntu, 结束运行"
	exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
	print_error "请以 root 权限运行此脚本, 结束运行"
	exit 1
fi

[[ -z "$(find /var/cache/apt/pkgcache.bin -mmin -1440)" ]] && apt update -y
command -v curl &>/dev/null || apt install -y curl
command -v jq &>/dev/null || apt install -y jq
command -v unzip &>/dev/null || apt install -y unzip

# WORK_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
cd "$HOME" || exit

print_info "正在下载脚本其他部分..."
curl -fsSL --retry 5 --retry-delay 3 "https://github.com/senzyo/xhttp-sni/archive/refs/heads/main.zip" -o xhttp-sni.zip || {
	print_error "多次尝试下载后仍失败, 结束运行"
	exit 1
}
unzip -oq xhttp-sni.zip
rm -f xhttp-sni.zip
cd xhttp-sni-main || exit
rm -rf template_replace
cp -r template template_replace

_error_detect "bash nginx.sh --purge"
_error_detect "bash nginx.sh --install"

xray_systemd="$(systemctl show -p FragmentPath --value xray.service)"
id -u xray &>/dev/null || useradd -M -s /usr/sbin/nologin xray
xray_latest_tag=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
xray_latest_version=${xray_latest_tag#v}
xray_current_version=$(command -v xray &>/dev/null && xray version | head -n 1 | awk '{print $2}')
if [[ "$xray_current_version" == "$xray_latest_version" ]]; then
	print_info "Xray $xray_current_version 已是最新版"
	# 修改运行 Xray 的用户为 xray
	sed -i 's/^User=.*/User=xray/' "$xray_systemd"
	systemctl daemon-reload
else
	curl -fsSLo xray-install.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh
	bash xray-install.sh remove --purge &>/dev/null
	print_info "正在安装 Xray 最新正式版..."
	bash xray-install.sh install -u xray
	print_info "已安装 Xray 最新正式版"
fi

mkdir -p /var/log/xray/
[[ -f "/var/log/xray/error.log" ]] || touch /var/log/xray/error.log
[[ -f "/var/log/xray/access.log" ]] || touch /var/log/xray/access.log
chown -R xray:xray /var/log/xray/
find /var/log/xray/ -type d -exec chmod 755 {} +
find /var/log/xray/ -type f -exec chmod 640 {} +

new_cron="30 2 * * * /usr/bin/curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | /bin/bash -s -- install-geodata &>/dev/null"
if crontab -l 2>/dev/null | grep -q "install-geodata"; then
	print_info "已存在更新 GEO 数据的定时任务"
else
	(
		crontab -l 2>/dev/null
		echo "$new_cron"
	) | crontab -
	print_info "已添加更新 GEO 数据的定时任务"
fi

# 交叉用户组避免权限问题
print_info "交叉用户组:"
gpasswd -a nginx xray
gpasswd -a xray nginx

# 设置存放 Unix Domain Sockets 的内存盘
tmpfile="/etc/tmpfiles.d/xray-nginx.conf"
mkdir -p /etc/tmpfiles.d/
rm -f "$tmpfile"
cat <<'EOF' | tee "$tmpfile" >/dev/null
# 类型  路径            权限  所有者  所属组
d       /dev/shm/nginx  2770  xray    xray    -
EOF
rm -f /dev/shm/nginx/*
systemd-tmpfiles --create "$tmpfile"
print_info "已设置 /dev/shm/nginx/"

XHTTP_UUID=$(xray uuid)
export XHTTP_UUID
print_info "${GREEN}XHTTP_UUID${NC}: $XHTTP_UUID"

domain_regex="^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
while true; do
	read -rp "${CYAN}[信息]${NC} 请输入用于 XHTTP CDN 的伪装站域名: " XHTTP_CDN_Site </dev/tty
	XHTTP_CDN_Site=$(echo "$XHTTP_CDN_Site" | tr -d ' ')
	if [[ "$XHTTP_CDN_Site" =~ $domain_regex ]]; then
		print_info "${GREEN}XHTTP_CDN_Site${NC}: $XHTTP_CDN_Site"
		export XHTTP_CDN_Site
		break
	else
		print_error "域名格式不合法, 请重新输入"
	fi
done

XHTTP_PATH=$(openssl rand -base64 60 | tr -dc 'a-zA-Z0-9' | head -c 40)
export XHTTP_PATH
print_info "${GREEN}XHTTP_PATH${NC}: /$XHTTP_PATH"

Reality_UUID=$(xray uuid)
export Reality_UUID
print_info "${GREEN}Reality_UUID${NC}: $Reality_UUID"

while true; do
	read -rp "${CYAN}[信息]${NC} 请输入用于 Reality 的伪装站域名: " Reality_Site </dev/tty
	Reality_Site=$(echo "$Reality_Site" | tr -d ' ')
	if [[ "$Reality_Site" =~ $domain_regex ]]; then
		print_info "${GREEN}Reality_Site${NC}: $Reality_Site"
		export Reality_Site
		break
	else
		print_error "域名格式不合法, 请重新输入"
	fi
done

X25519_RAW=$(xray x25519)

Reality_privateKey=$(echo "$X25519_RAW" | grep "PrivateKey" | awk -F': ' '{print $2}')
export Reality_privateKey
print_info "${GREEN}Reality_privateKey${NC}: $Reality_privateKey"

Reality_publicKey=$(echo "$X25519_RAW" | grep "Password" | awk -F': ' '{print $2}')
export Reality_publicKey
print_info "${GREEN}Reality_publicKey${NC}: $Reality_publicKey"

Reality_shortId=$(openssl rand -hex 8)
export Reality_shortId
print_info "${GREEN}Reality_shortId${NC}: $Reality_shortId"

VPS_IPv4=$(curl -fsS4 --connect-timeout 10 https://api.ipify.org ||
	curl -fsS4 --connect-timeout 10 https://ifconfig.me ||
	curl -fsS4 --connect-timeout 10 https://icanhazip.com)
export VPS_IPv4
if [[ -z "$VPS_IPv4" ]]; then
	print_error "未获取到公网 IPv4, 结束运行"
	exit 1
else
	print_info "${GREEN}VPS_IPv4${NC}: $VPS_IPv4"
fi

replace_command="s|<XHTTP_UUID>|\$ENV{XHTTP_UUID}|g; "
replace_command+="s|<XHTTP_CDN_Site>|\$ENV{XHTTP_CDN_Site}|g; "
replace_command+="s|<XHTTP_PATH>|\$ENV{XHTTP_PATH}|g; "
replace_command+="s|<Reality_UUID>|\$ENV{Reality_UUID}|g; "
replace_command+="s|<Reality_Site>|\$ENV{Reality_Site}|g; "
replace_command+="s|<Reality_privateKey>|\$ENV{Reality_privateKey}|g; "
replace_command+="s|<Reality_publicKey>|\$ENV{Reality_publicKey}|g; "
replace_command+="s|<Reality_shortId>|\$ENV{Reality_shortId}|g; "
replace_command+="s|<VPS_IPv4>|\$ENV{VPS_IPv4}|g; "

VPS_IPv6=$(curl -fsS6 --connect-timeout 10 https://api6.ipify.org ||
	curl -fsS6 --connect-timeout 10 https://ifconfig.me ||
	curl -fsS6 --connect-timeout 10 https://icanhazip.com)
export VPS_IPv6
if [[ -z "$VPS_IPv6" ]]; then
	print_warn "未获取到公网 IPv6, 跳过使用 IPv6 的模板"
	rm -f 'template_replace/xray/client/UP[xhttp+reality]DL.json'
else
	print_info "${GREEN}VPS_IPv6${NC}: $VPS_IPv6"
	replace_command+="s|<VPS_IPv6>|\$ENV{VPS_IPv6}|g; "
	replace_command+="s|#IPv6_off ||g; "
fi

DOMAIN_LIST=(
	"cfcn-a-proctusa.chinabaidu.pp.ua"
	"1749991941.bilibiliapp.cn"
	"freeyx.cloudflare88.eu.org"
	"cfyx.tencentapp.cn"
	"cf.tencentapp.cn"
	"cf.godns.cc"
	"dnew.cc"
	"cloudflare.182682.xyz"
	"cloudflare-ip.mofashi.ltd"
	"baota.me"
	"mfa.gov.ua"
	"serviceshub.samsclub.com"
)

Cloudflare_1=""
Cloudflare_2=""

for domain in "${DOMAIN_LIST[@]}"; do
	if getent hosts "$domain" &>/dev/null; then
		if [[ -z "$Cloudflare_1" ]]; then
			Cloudflare_1="$domain"
			print_info "${GREEN}优选 Cloudflare_1${NC} 可用: $Cloudflare_1"
			replace_command+="s|<Cloudflare_1>|\$ENV{Cloudflare_1}|g; "
		elif [[ -z "$Cloudflare_2" ]]; then
			Cloudflare_2="$domain"
			print_info "${GREEN}优选 Cloudflare_2${NC} 可用: $Cloudflare_2"
			replace_command+="s|<Cloudflare_2>|\$ENV{Cloudflare_2}|g; "
			break
		fi
	else
		print_warn "$domain 不可用, 检测下一个..."
	fi
done

if [[ -z "$Cloudflare_1" ]]; then
	print_warn "未找到可用的优选域名, 跳过使用 CDN 的模板"
	rm -f 'template_replace/xray/client/ALL[xhttp+tls+cdn].json'
	rm -f 'template_replace/xray/client/UP[xhttp+reality]DL[xhttp+tls+cdn].json'
	rm -f 'template_replace/xray/client/UP[xhttp+tls+cdn]DL.json'
	rm -f 'template_replace/xray/client/UP[xhttp+tls+cdn]DL[xhttp+reality].json'
fi

if [[ -z "$Cloudflare_2" ]] && [[ -n "$Cloudflare_1" ]]; then
	print_warn "只找到一个可用的优选域名, 跳过只使用 CDN 且上下行分离的模板"
	rm -f 'template_replace/xray/client/UP[xhttp+tls+cdn]DL.json'
fi

export Cloudflare_1
export Cloudflare_2

Subs_Site_PATH=$(openssl rand -base64 60 | tr -dc 'a-zA-Z0-9' | head -c 40)
export Subs_Site_PATH
print_info "${GREEN}Subs_Site_PATH${NC}: $Subs_Site_PATH"
replace_command+="s|<Subs_Site_PATH>|\$ENV{Subs_Site_PATH}|g; "

read -rn 1 -p "${CYAN}[信息]${NC} 请确认参数无误, 是否继续 (y/n): " confirm </dev/tty
echo
case "$confirm" in
[yY] | "")
	;;
*)
	print_error "结束运行"
	exit 1
	;;
esac

nginx_prefix=$(nginx -V 2>&1 | grep -oP '(?<=--prefix=)[^ ]+')
export nginx_prefix
if [[ "$nginx_prefix" != "/usr/local/nginx" ]]; then
	replace_command+="s|/usr/local/nginx|\$ENV{nginx_prefix}|g; "
fi

# 替换所有模板文件中对应的字符
find template_replace -type f -not -path '*/.*' -print0 | xargs -0 -r perl -i'' -C -gp -e "$replace_command"

# Nginx 站点的 root 路径
root_Reality_Site=$(grep "root" "template_replace/nginx/sites-enabled/Reality_Site.conf" | awk '{print $2}' | tr -d ';')
root_XHTTP_CDN_Site=$(grep "root" "template_replace/nginx/sites-enabled/XHTTP_CDN_Site.conf" | awk '{print $2}' | tr -d ';')
mkdir -p "$root_Reality_Site"
ln -snf "$root_Reality_Site" "$root_XHTTP_CDN_Site"
mv "template_replace/nginx/index.html" "$root_Reality_Site"

mv "template_replace/nginx/sites-enabled/Reality_Site.conf" "template_replace/nginx/sites-enabled/$Reality_Site.conf"
mv "template_replace/nginx/sites-enabled/XHTTP_CDN_Site.conf" "template_replace/nginx/sites-enabled/$XHTTP_CDN_Site.conf"

rm -rf "$nginx_prefix"/conf/ "$nginx_prefix"/html/
cp -r template_replace/nginx/* "$nginx_prefix"
print_info "已覆盖 Nginx 配置文件"

Xray_Server_Config=$(grep -oP '(?<=-config\s)\S+' "$xray_systemd")
cp template_replace/xray/server.json "$Xray_Server_Config"
print_info "已覆盖 Xray 配置文件"

# 转换换行符
command -v dos2unix &>/dev/null || apt install -y dos2unix
find "$nginx_prefix" -type f -exec dos2unix {} + &>/dev/null
dos2unix "$Xray_Server_Config" &>/dev/null

function urlencode() {
	# 声明局部变量存储输入
	local input
	# 如果没有传入参数, 则从标准输入读取
	if [[ $# -eq 0 ]]; then
		input="$(cat)"
	else
		# 否则使用第一个参数作为输入
		input="$1"
	fi
	# 声明局部变量存储编码后的结果
	local encoded=""
	# 声明循环变量和临时变量
	local i c hex
	# 遍历输入字符串的每个字符
	for ((i = 0; i < ${#input}; i++)); do
		# 获取当前字符
		c="${input:$i:1}"
		# 检查字符是否为不需要编码的安全字符
		case $c in
		[a-zA-Z0-9.~_-])
			# 如果是安全字符, 则直接追加到结果中
			encoded+="$c"
			;;
		*)
			# 如果不是安全字符, 则进行编码
			# printf -v hex 将字符的 ASCII 码转换为两位十六进制数
			printf -v hex "%02X" "'$c"
			# 将 % 和十六进制数追加到结果中
			encoded+="%$hex"
			;;
		esac
	done
	# 输出编码后的字符串
	echo "$encoded"
}

Client_XHTTP_PATH=$(urlencode "/$XHTTP_PATH")
Client_Reality_Site=$(urlencode "$Reality_Site")
Client_XHTTP_CDN_Site=$(urlencode "$XHTTP_CDN_Site")

# No.1 上下行 raw+vision+reality
Client_Node=$(urlencode 'ALL[raw+vision+reality]')
Share_Link_1="vless://$Reality_UUID@$VPS_IPv4:443?security=reality&encryption=none&pbk=$Reality_publicKey&headerType=none&fp=chrome&spx=%2F&type=raw&flow=xtls-rprx-vision&sni=$Client_Reality_Site&sid=$Reality_shortId#$Client_Node"

# No.2 上下行 xhttp+reality
Client_Node=$(urlencode 'ALL[xhttp+reality]')
Share_Link_2="vless://$XHTTP_UUID@$VPS_IPv4:443?mode=auto&path=$Client_XHTTP_PATH&security=reality&encryption=none&pbk=$Reality_publicKey&fp=chrome&spx=%2F&type=xhttp&sni=$Client_Reality_Site&sid=$Reality_shortId#$Client_Node"

# No.3 上下行 xhttp+tls+cdn
if [[ -n $Cloudflare_1 ]]; then
	Client_Node=$(urlencode 'ALL[xhttp+tls+cdn]')
	Share_Link_3="vless://$XHTTP_UUID@$Cloudflare_1:443?mode=auto&path=$Client_XHTTP_PATH&security=tls&alpn=h2&encryption=none&host=$Client_XHTTP_CDN_Site&fp=chrome&type=xhttp&sni=$Client_XHTTP_CDN_Site#$Client_Node"
fi

# No.4 上行 xhttp+reality ipv4 下行 xhttp+reality ipv6
Xray_Client_Config="template_replace/xray/client/UP[xhttp+reality]DL.json"
if [[ -f $Xray_Client_Config ]]; then
	Client_extra=$(jq -c '.outbounds[0].streamSettings.xhttpSettings.extra' "$Xray_Client_Config")
	Client_extra=$(urlencode "$Client_extra")
	Client_Node=$(urlencode 'UP[xhttp+reality]DL')
	Share_Link_4="vless://$XHTTP_UUID@$VPS_IPv4:443?mode=auto&path=$Client_XHTTP_PATH&security=reality&encryption=none&extra=$Client_extra&pbk=$Reality_publicKey&fp=chrome&spx=%2F&type=xhttp&sni=$Client_Reality_Site&sid=$Reality_shortId#$Client_Node"
fi

# No.5 上行 xhttp+reality 下行 xhttp+tls+cdn
Xray_Client_Config="template_replace/xray/client/UP[xhttp+reality]DL[xhttp+tls+cdn].json"
if [[ -f $Xray_Client_Config ]]; then
	Client_extra=$(jq -c '.outbounds[0].streamSettings.xhttpSettings.extra' "$Xray_Client_Config")
	Client_extra=$(urlencode "$Client_extra")
	Client_Node=$(urlencode 'UP[xhttp+reality]DL[xhttp+tls+cdn]')
	Share_Link_5="vless://$XHTTP_UUID@$VPS_IPv4:443?mode=auto&path=$Client_XHTTP_PATH&security=reality&encryption=none&extra=$Client_extra&pbk=$Reality_publicKey&fp=chrome&spx=%2F&type=xhttp&sni=$Client_Reality_Site&sid=$Reality_shortId#$Client_Node"
fi

# No.6 上行 xhttp+tls+cdn 下行 xhttp+tls+cdn
Xray_Client_Config="template_replace/xray/client/UP[xhttp+tls+cdn]DL.json"
if [[ -f $Xray_Client_Config ]]; then
	Client_extra=$(jq -c '.outbounds[0].streamSettings.xhttpSettings.extra' "$Xray_Client_Config")
	Client_extra=$(urlencode "$Client_extra")
	Client_Node=$(urlencode 'UP[xhttp+tls+cdn]DL')
	Share_Link_6="vless://$XHTTP_UUID@$Cloudflare_1:443?mode=auto&path=$Client_XHTTP_PATH&security=tls&alpn=h2&encryption=none&extra=$Client_extra&host=$Client_XHTTP_CDN_Site&fp=chrome&type=xhttp&sni=$Client_XHTTP_CDN_Site#$Client_Node"
fi

# No.7 上行 xhttp+tls+cdn 下行 xhttp+reality
Xray_Client_Config="template_replace/xray/client/UP[xhttp+tls+cdn]DL[xhttp+reality].json"
if [[ -f $Xray_Client_Config ]]; then
	Client_extra=$(jq -c '.outbounds[0].streamSettings.xhttpSettings.extra' "$Xray_Client_Config")
	Client_extra=$(urlencode "$Client_extra")
	Client_Node=$(urlencode 'UP[xhttp+tls+cdn]DL[xhttp+reality]')
	Share_Link_7="vless://$XHTTP_UUID@$Cloudflare_1:443?mode=auto&path=$Client_XHTTP_PATH&security=tls&alpn=h2&encryption=none&extra=$Client_extra&host=$Client_XHTTP_CDN_Site&fp=chrome&type=xhttp&sni=$Client_XHTTP_CDN_Site#$Client_Node"
fi

Share_Link_List=(
	"No.1 上下行 raw+vision+reality|$Share_Link_1"
	"No.2 上下行 xhttp+reality|$Share_Link_2"
	"No.3 上下行 xhttp+tls+cdn|$Share_Link_3"
	"No.4 上行 xhttp+reality ipv4 下行 xhttp+reality ipv6|$Share_Link_4"
	"No.5 上行 xhttp+reality 下行 xhttp+tls+cdn|$Share_Link_5"
	"No.6 上行 xhttp+tls+cdn 下行 xhttp+tls+cdn|$Share_Link_6"
	"No.7 上行 xhttp+tls+cdn 下行 xhttp+reality|$Share_Link_7"
)

: >subs.txt

for item in "${Share_Link_List[@]}"; do
	label="${item%|*}"
	link="${item#*|}"
	if [[ -n "$link" ]]; then
		print_info "${GREEN}$label:${NC}"
		echo "$link" | tee -a subs.txt
	fi
done

mkdir -p /var/www/subscription
mv subs.txt /var/www/subscription

Subs_Link="https://$XHTTP_CDN_Site/$Subs_Site_PATH"
print_info "${GREEN}更新订阅链接:${NC} $Subs_Link"

command -v qrencode &>/dev/null || apt install -y qrencode
echo "$Subs_Link" | qrencode -t ansiutf8

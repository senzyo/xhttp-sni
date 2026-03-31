#!/bin/bash

RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
CYAN=$'\e[1;36m'
NC=$'\e[0m'

if [[ "$EUID" -ne 0 ]]; then
	echo "${RED}[Error]${NC} 请以 root 权限运行此脚本"
	exit 1
fi

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

read -rn 1 -p "${YELLOW}[Warning]${NC} 如有必要, 请先备份你的 Nginx 和 Xray 配置, 是否继续 (y/n):" confirm </dev/tty
case "$confirm" in
[yY] | "")
	echo ""
	;;
*)
	echo "${YELLOW}停止执行${NC}"
	exit 1
	;;
esac

[[ -z "$(find /var/cache/apt/pkgcache.bin -mmin -1440)" ]] && apt update

command -v curl &>/dev/null || apt install -y curl
command -v jq &>/dev/null || apt install -y jq

if nginx -v &>/dev/null; then
	echo "${CYAN}[Notice]${NC} 已安装 Nginx"
else
	OS_ID=$(grep -w '^ID' /etc/os-release | cut -d= -f2 | tr -d '"')
	if [[ "$OS_ID" == "debian" ]]; then
		KEYRING_PKG="debian-archive-keyring"
		REPO_URL="https://nginx.org/packages/mainline/debian"
	elif [[ "$OS_ID" == "ubuntu" ]]; then
		KEYRING_PKG="ubuntu-keyring"
		REPO_URL="https://nginx.org/packages/mainline/ubuntu"
	else
		echo "${RED}[Error]${NC} 此脚本仅支持 Debian 和 Ubuntu"
		exit 1
	fi
	echo "${CYAN}[Notice]${NC} 正在安装 Nginx 官方主线版..."
	apt install -y gnupg2 ca-certificates lsb-release $KEYRING_PKG
	curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg &>/dev/null
	echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] $REPO_URL $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list
	echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | tee /etc/apt/preferences.d/99nginx
	apt update
	apt install -y nginx
	nginx -V
fi

id -u nginx &>/dev/null || useradd -M -s /usr/sbin/nologin nginx

[[ -d "/var/log/nginx/" ]] || mkdir -p /var/log/nginx/
[[ -f "/var/log/nginx/error.log" ]] || touch /var/log/nginx/error.log
[[ -f "/var/log/nginx/access.log" ]] || touch /var/log/nginx/access.log
chown -R nginx:adm /var/log/nginx/
find /var/log/nginx/ -type d -exec chmod 755 {} +
find /var/log/nginx/ -type f -exec chmod 640 {} +

id -u xray &>/dev/null || useradd -M -s /usr/sbin/nologin xray

xray_latest_tag=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
xray_latest_version=${xray_latest_tag#v}
xray_current_version=$(command -v xray &>/dev/null && xray version | head -n 1 | awk '{print $2}')
if [[ "$xray_current_version" == "$xray_latest_version" ]]; then
	echo "${CYAN}[Notice]${NC} Xray $xray_current_version 已是最新版"
	# 修改运行 Xray 的用户为 xray
	sed -i 's/^User=.*/User=xray/' "/etc/systemd/system/xray.service"
	systemctl daemon-reload
else
	bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
	echo "${CYAN}[Notice]${NC} 正在安装 Xray 官方最新稳定版..."
	bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u xray
fi

[[ -d "/var/log/xray/" ]] || mkdir -p /var/log/xray/
[[ -f "/var/log/xray/error.log" ]] || touch /var/log/xray/error.log
[[ -f "/var/log/xray/access.log" ]] || touch /var/log/xray/access.log
chown -R xray:xray /var/log/xray/
find /var/log/xray/ -type d -exec chmod 755 {} +
find /var/log/xray/ -type f -exec chmod 640 {} +

NEW_CRON="30 2 * * * /usr/bin/curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | /bin/bash -s -- install-geodata &>/dev/null"
if crontab -l 2>/dev/null | grep -q "install-geodata"; then
	echo "${CYAN}[Notice]${NC} 更新 GEO 数据的定时任务已存在"
else
	(
		crontab -l 2>/dev/null
		echo "$NEW_CRON"
	) | crontab -
	echo "${GREEN}[Success]${NC} 已添加更新 GEO 数据的定时任务"
fi

# 交叉用户组避免权限问题
echo "${CYAN}[Notice]${NC} 交叉用户组:"
gpasswd -a nginx xray
gpasswd -a xray nginx

# 设置存放 Unix Domain Sockets 的内存盘
TMPFILE="/etc/tmpfiles.d/xray-nginx.conf"
[[ -d "/etc/tmpfiles.d/" ]] || mkdir -p /etc/tmpfiles.d/
[[ -f "$TMPFILE" ]] && rm -f "$TMPFILE"
cat <<'EOF' | tee "$TMPFILE" >/dev/null
# 类型  路径            权限  所有者  所属组
d       /dev/shm/nginx  2770  xray    xray    -
EOF
[[ -d "/dev/shm/nginx" ]] && rm -f /dev/shm/nginx/*
systemd-tmpfiles --create "$TMPFILE"
echo "${GREEN}[Success]${NC} 已设置 /dev/shm/nginx/"

# WORK_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
cd "$HOME" || exit

echo "${CYAN}[Notice]${NC} 正在下载脚本其他部分..."
curl -fsSL --retry 5 --retry-delay 3 "https://github.com/senzyo/xhttp-sni/archive/refs/heads/main.zip" -o xhttp-sni.zip || {
	echo "${RED}[Error]${NC} 多次尝试后下载依然失败"
	exit 1
}
echo "${GREEN}[Success]${NC} 下载成功"

command -v unzip &>/dev/null || apt install -y unzip
unzip -oq xhttp-sni.zip
rm -f xhttp-sni.zip
cd xhttp-sni-main || exit
rm -rf template_replace
cp -r template template_replace

echo "${CYAN}[Notice]${NC} 开始设置各个参数"

XHTTP_UUID=$(xray uuid)
export XHTTP_UUID
echo "${GREEN}[Success] ${YELLOW}XHTTP_UUID${NC}: $XHTTP_UUID"

DOMAIN_REGEX="^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
while true; do
	read -rp "${CYAN}[Notice]${NC} 请输入用于 XHTTP CDN 的伪装站域名:" XHTTP_CDN_Site </dev/tty
	XHTTP_CDN_Site=$(echo "$XHTTP_CDN_Site" | tr -d ' ')
	if [[ "$XHTTP_CDN_Site" =~ $DOMAIN_REGEX ]]; then
		echo "${GREEN}[Success] ${YELLOW}XHTTP_CDN_Site${NC}: $XHTTP_CDN_Site"
		export XHTTP_CDN_Site
		break
	else
		echo "${RED}[Error]${NC} 域名格式不合法, 请重新输入"
	fi
done

XHTTP_PATH=$(openssl rand -base64 60 | tr -dc 'a-zA-Z0-9' | head -c 40)
export XHTTP_PATH
echo "${GREEN}[Success] ${YELLOW}XHTTP_PATH${NC}: /$XHTTP_PATH"

Reality_UUID=$(xray uuid)
export Reality_UUID
echo "${GREEN}[Success] ${YELLOW}Reality_UUID${NC}: $Reality_UUID"

while true; do
	read -rp "${CYAN}[Notice]${NC} 请输入用于 Reality 的伪装站域名:" Reality_Site </dev/tty
	Reality_Site=$(echo "$Reality_Site" | tr -d ' ')
	if [[ "$Reality_Site" =~ $DOMAIN_REGEX ]]; then
		echo "${GREEN}[Success] ${YELLOW}Reality_Site${NC}: $Reality_Site"
		export Reality_Site
		break
	else
		echo "${RED}[Error]${NC} 域名格式不合法, 请重新输入"
	fi
done

X25519_RAW=$(xray x25519)

Reality_privateKey=$(echo "$X25519_RAW" | grep "PrivateKey" | awk '{print $2}')
export Reality_privateKey
echo "${GREEN}[Success] ${YELLOW}Reality_privateKey${NC}: $Reality_privateKey"

Reality_publicKey=$(echo "$X25519_RAW" | grep "Password" | awk '{print $2}')
export Reality_publicKey
echo "${GREEN}[Success] ${YELLOW}Reality_publicKey${NC}: $Reality_publicKey"

Reality_shortId=$(openssl rand -hex 8)
export Reality_shortId
echo "${GREEN}[Success] ${YELLOW}Reality_shortId${NC}: $Reality_shortId"

VPS_IPv4=$(curl -fsS4 --connect-timeout 10 https://api.ipify.org ||
	curl -fsS4 --connect-timeout 10 https://ifconfig.me ||
	curl -fsS4 --connect-timeout 10 https://icanhazip.com)
export VPS_IPv4
if [[ -z "$VPS_IPv4" ]]; then
	echo "${RED}[Error]${NC} 无法获取公网 IPv4"
	exit 1
else
	echo "${GREEN}[Success] ${YELLOW}VPS_IPv4${NC}: $VPS_IPv4"
fi

REPLACE_COMMAND="s|<XHTTP_UUID>|\$ENV{XHTTP_UUID}|g; "
REPLACE_COMMAND+="s|<XHTTP_CDN_Site>|\$ENV{XHTTP_CDN_Site}|g; "
REPLACE_COMMAND+="s|<XHTTP_PATH>|\$ENV{XHTTP_PATH}|g; "
REPLACE_COMMAND+="s|<Reality_UUID>|\$ENV{Reality_UUID}|g; "
REPLACE_COMMAND+="s|<Reality_Site>|\$ENV{Reality_Site}|g; "
REPLACE_COMMAND+="s|<Reality_privateKey>|\$ENV{Reality_privateKey}|g; "
REPLACE_COMMAND+="s|<Reality_publicKey>|\$ENV{Reality_publicKey}|g; "
REPLACE_COMMAND+="s|<Reality_shortId>|\$ENV{Reality_shortId}|g; "
REPLACE_COMMAND+="s|<VPS_IPv4>|\$ENV{VPS_IPv4}|g; "

VPS_IPv6=$(curl -fsS6 --connect-timeout 10 https://api6.ipify.org ||
	curl -fsS6 --connect-timeout 10 https://ifconfig.me ||
	curl -fsS6 --connect-timeout 10 https://icanhazip.com)
export VPS_IPv6
if [[ -z "$VPS_IPv6" ]]; then
	echo "${RED}[Error]${NC} 无法获取公网 IPv6, 将跳过使用 IPv6 的模板"
	rm -f 'template_replace/xray/client/UP[xhttp+reality]DL.json'
else
	echo "${GREEN}[Success] ${YELLOW}VPS_IPv6${NC}: $VPS_IPv6"
	REPLACE_COMMAND+="s|<VPS_IPv6>|\$ENV{VPS_IPv6}|g; "
	REPLACE_COMMAND+="s|#IPv6_off ||g; "
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
			echo "${GREEN}[Success] ${YELLOW}优选 Cloudflare_1${NC} 可用: $Cloudflare_1"
			REPLACE_COMMAND+="s|<Cloudflare_1>|\$ENV{Cloudflare_1}|g; "
		elif [[ -z "$Cloudflare_2" ]]; then
			Cloudflare_2="$domain"
			echo "${GREEN}[Success] ${YELLOW}优选 Cloudflare_2${NC} 可用: $Cloudflare_2"
			REPLACE_COMMAND+="s|<Cloudflare_2>|\$ENV{Cloudflare_2}|g; "
			break
		fi
	else
		echo "${RED}[Error]${NC} $domain 不可用, 检测下一个..."
	fi
done

if [[ -z "$Cloudflare_1" ]]; then
	echo "${RED}[Error]${NC} 未找到可用的优选域名, 将跳过使用 CDN 的模板"
	rm -f 'template_replace/xray/client/ALL[xhttp+tls+cdn].json'
	rm -f 'template_replace/xray/client/UP[xhttp+reality]DL[xhttp+tls+cdn].json'
	rm -f 'template_replace/xray/client/UP[xhttp+tls+cdn]DL.json'
	rm -f 'template_replace/xray/client/UP[xhttp+tls+cdn]DL[xhttp+reality].json'
fi

if [[ -z "$Cloudflare_2" ]] && [[ -n "$Cloudflare_1" ]]; then
	echo "${RED}[Error]${NC} 只找到一个可用的优选域名, 将跳过只使用 CDN 且上下行分离的模板"
	rm -f 'template_replace/xray/client/UP[xhttp+tls+cdn]DL.json'
fi

export Cloudflare_1
export Cloudflare_2

Subs_Site_PATH=$(openssl rand -base64 60 | tr -dc 'a-zA-Z0-9' | head -c 40)
export Subs_Site_PATH
echo "${GREEN}[Success] ${YELLOW}Subs_Site_PATH${NC}: $Subs_Site_PATH"
REPLACE_COMMAND+="s|<Subs_Site_PATH>|\$ENV{Subs_Site_PATH}|g; "

read -rn 1 -p "${CYAN}[Notice]${NC} 请确保参数无误, 是否继续 (y/n):" confirm </dev/tty
case "$confirm" in
[yY] | "")
	echo ""
	;;
*)
	echo "${YELLOW}停止执行${NC}"
	exit 1
	;;
esac

# 替换所有模板文件中对应的字符
find template_replace -type f -not -path '*/.*' -print0 | xargs -0 -r perl -i'' -C -gp -e "$REPLACE_COMMAND"
echo "${GREEN}[Success]${NC} 所有信息已更新"

# Nginx 站点的 root 路径
root_Reality_Site=$(grep "root" "template_replace/nginx/sites-enabled/Reality_Site.conf" | awk '{print $2}' | tr -d ';')
root_XHTTP_CDN_Site=$(grep "root" "template_replace/nginx/sites-enabled/XHTTP_CDN_Site.conf" | awk '{print $2}' | tr -d ';')
[[ -d "$root_Reality_Site" ]] || mkdir -p "$root_Reality_Site"
ln -snf "$root_Reality_Site" "$root_XHTTP_CDN_Site"
mv "template_replace/nginx/index.html" "$root_Reality_Site"

mv "template_replace/nginx/sites-enabled/Reality_Site.conf" "template_replace/nginx/sites-enabled/$Reality_Site.conf"
mv "template_replace/nginx/sites-enabled/XHTTP_CDN_Site.conf" "template_replace/nginx/sites-enabled/$XHTTP_CDN_Site.conf"

NGINX_CONF_PATH=$(nginx -V 2>&1 | grep -oP '(?<=--conf-path=)[^ ]+')
if [[ -n "$NGINX_CONF_PATH" ]]; then
	NGINX_DIR=$(dirname "$NGINX_CONF_PATH")
	export NGINX_DIR
else
	NGINX_DIR="/etc/nginx"
	export NGINX_DIR
fi
if [[ "$NGINX_DIR" != "/etc/nginx" ]]; then
	find template_replace -type f -not -path '*/.*' -print0 | xargs -0 -r perl -i'' -C -gp -e "s|/etc/nginx|\$ENV{NGINX_DIR}|g; "
fi
[[ -d "$NGINX_DIR" ]] || mkdir -p "$NGINX_DIR"
rm -f "$NGINX_DIR"/conf.d/* "$NGINX_DIR"/sites-enabled/* "$NGINX_DIR"/sites-available/*
cp -r template_replace/nginx/* "$NGINX_DIR"
echo "${GREEN}[Success]${NC} 已覆盖 Nginx 配置"

Xray_Server_Config=$(grep -oP '(?<=-config\s)\S+' /etc/systemd/system/xray.service)
cp template_replace/xray/server.json "$Xray_Server_Config"
echo "${GREEN}[Success]${NC} 已覆盖 Xray 配置"

# 转换换行符
command -v dos2unix &>/dev/null || apt install -y dos2unix
find "$NGINX_DIR" -type f -exec dos2unix {} + &>/dev/null
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

for Item in "${Share_Link_List[@]}"; do
	Label="${Item%|*}"
	Link="${Item#*|}"
	if [[ -n "$Link" ]]; then
		echo "${CYAN}[Notice] ${YELLOW}$Label:${NC}"
		echo "$Link" | tee -a subs.txt
	fi
done

[[ -d "/var/www/subscription" ]] || mkdir -p /var/www/subscription
mv subs.txt /var/www/subscription

Subs_Link="https://$XHTTP_CDN_Site/$Subs_Site_PATH"
echo "${CYAN}[Notice] ${YELLOW}更新订阅链接:${NC} $Subs_Link"

command -v qrencode &>/dev/null || apt install -y qrencode
echo "$Subs_Link" | qrencode -t ansiutf8

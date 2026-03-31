<p align="center">
    <img src="https://xtls.github.io/logo-light.svg" width="100px" align="center" />
    <h2 align="center">xhttp-sni</h2>
    <p align="center">
        Nginx SNI 前置分流 <strong>+</strong> Xray 多配置合一的简单方案<br />
    </p>
</p>

> **参考 [zxcvos/Xray-script](https://github.com/zxcvos/Xray-script) 和 [xhttp 五合一配置](https://github.com/XTLS/Xray-core/discussions/4118)**

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/senzyo/xhttp-sni/refs/heads/main/xray_sni.sh)
```

## 注意事项

- 此脚本仅支持 Debian 和 Ubuntu。
- 需要 root 权限。
- 注意防火墙放行 80 和 443 端口。
- 如果要使用双栈网络来上下行分离, 确保服务器和客户端都有可用的 IPv6。
- CDN 站点要在 Cloudflare 打开橙色小云朵。
- 在 Cloudflare 缓存 Cache Rules 里添加 `XHTTP_PATH` 和 `Subs_Site_PATH` 的值。
  - 自定义筛选表达式: 字段 (URI 完整), 运算符 (包含), 值 (`XHTTP_PATH` 的值, 不必带 `/`), 缓存资格 (绕过缓存)。

## 续期证书

acme.sh: https://github.com/acmesh-official/acme.sh/wiki/说明

Cloudflare 生成 `编辑区域 DNS` 的 API 令牌 `CF_Token`: https://dash.cloudflare.com/profile/api-tokens

在 `域` 的概述界面右下角获取区域 ID: `CF_Zone_ID`。

假设 Reality 伪装站是 `www.example.com`, CDN 伪装站是 `cdn.example.com`。

```bash
curl https://get.acme.sh | sh -s email=你的邮箱
export CF_Token="你的 CF_Token"
export CF_Zone_ID="你的 CF_Zone_ID"
bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "www.example.com"
bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "cdn.example.com"
```

> **如果你的 Nginx 工作目录不是 `/etc/nginx`, 记得替换。**

```bash
mkdir -p /etc/nginx/ssl/www.example.com/ /etc/nginx/ssl/cdn.example.com/
```

```bash
bash ~/.acme.sh/acme.sh --install-cert -d www.example.com \
--key-file       /etc/nginx/ssl/www.example.com/private.key \
--ca-file        /etc/nginx/ssl/www.example.com/ca.cer \
--fullchain-file /etc/nginx/ssl/www.example.com/fullchain.cer \
--reloadcmd     "service nginx force-reload"
```

```bash
bash ~/.acme.sh/acme.sh --install-cert -d cdn.example.com \
--key-file       /etc/nginx/ssl/cdn.example.com/private.key \
--ca-file        /etc/nginx/ssl/cdn.example.com/ca.cer \
--fullchain-file /etc/nginx/ssl/cdn.example.com/fullchain.cer \
--reloadcmd     "service nginx force-reload"
```

测试运行 Nginx:

```bash
nginx -t -c /etc/nginx/nginx.conf
```

## Cloudflare优选
### 优选域名

- https://cf.090227.xyz/
- https://vps789.com/cfip/?remarks=domain
- https://www.wetest.vip/page/cloudflare/cname.html

北方三网双程 NTT 到东京, 使用以下优选域名的延迟:

#### 80ms左右

- cf.godns.cc

同一维护者:

- cfcn-a-proctusa.chinabaidu.pp.ua
- 1749991941.bilibiliapp.cn
- freeyx.cloudflare88.eu.org
- cfyx.tencentapp.cn
- cf.tencentapp.cn

#### 150~200ms

同一维护者:

- dnew.cc
- cloudflare.182682.xyz

同一维护者:

- baota.me
- cloudflare-ip.mofashi.ltd

正规网站:

- mfa.gov.ua
- serviceshub.samsclub.com

### 网络不通？

如果使用 CDN, `address` 填入优选域名时, 网络不可用, 填入优选 IP 时正常, 大概率是客户端陷入了 DNS 逻辑陷阱。在 DNS 路由规则中, 设置优选域名使用直连 DNS 解析即可解决。

对于 xray, 类似:

```json
{
  "dns": {
    "servers": [
      {
        "address": "https+local://dns.alidns.com/dns-query",
        "domains": [
          "cf.godns.cc",
          "cf.tencentapp.cn",
          "cfyx.tencentapp.cn",
          "1749991941.bilibiliapp.cn",
          "freeyx.cloudflare88.eu.org",
          "cfcn-a-proctusa.chinabaidu.pp.ua",
          "dnew.cc",
          "cloudflare.182682.xyz",
          "baota.me",
          "cloudflare-ip.mofashi.ltd",
          "mfa.gov.ua",
          "serviceshub.samsclub.com"
        ],
        "skipFallback": true
      }
    ]
  }
}
```

对于 xray 搭配 sing-box 使用的, 在 sing-box 中, 类似:

```json
{
  "dns": {
    "rules": [
      {
        "domain": [
          "cf.godns.cc",
          "cf.tencentapp.cn",
          "cfyx.tencentapp.cn",
          "1749991941.bilibiliapp.cn",
          "freeyx.cloudflare88.eu.org",
          "cfcn-a-proctusa.chinabaidu.pp.ua",
          "dnew.cc",
          "cloudflare.182682.xyz",
          "baota.me",
          "cloudflare-ip.mofashi.ltd",
          "mfa.gov.ua",
          "serviceshub.samsclub.com"
        ],
        "server": "dns-direct"
      }
    ]
  }
}
```

### 优选IP

- https://ip.164746.xyz/ipTop.html
- https://ipdb.api.030101.xyz/?type=bestcf

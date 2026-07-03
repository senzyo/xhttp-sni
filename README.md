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
curl -fsSL https://raw.githubusercontent.com/senzyo/xhttp-sni/refs/heads/main/xray_sni.sh | sudo bash
```

## 注意事项

- 此脚本仅支持 Debian 和 Ubuntu。
- 需要 root 权限。
- 注意防火墙放行 80 和 443 端口。
- 如果要使用双栈网络来上下行分离, 确保服务器和客户端都有可用的 IPv6。

## 续期证书

acme.sh: https://github.com/acmesh-official/acme.sh/wiki/说明

Cloudflare 生成 `编辑区域 DNS` 的 API 令牌 `CF_Token`: https://dash.cloudflare.com/profile/api-tokens

在 `域` 的概述界面右下角获取区域 ID: `CF_Zone_ID`。

假设 Reality 伪装站是 `www.example.com`, CDN 伪装站是 `cloudflare.example.com`, `fastly.example.com`(可选), `gcore.example.com`(可选)。

```bash
curl https://get.acme.sh | sh -s email=你的邮箱
bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
export CF_Token="你的 CF_Token"
export CF_Zone_ID="你的 CF_Zone_ID"
bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "example.com" -d "*.example.com"
```

**如果你的 Nginx 工作目录不是 `/usr/local/nginx`, 记得替换。**

```bash
mkdir -p /usr/local/nginx/ssl/www.example.com/
```

```bash
bash ~/.acme.sh/acme.sh --install-cert -d example.com \
--key-file       /usr/local/nginx/ssl/www.example.com/private.key \
--ca-file        /usr/local/nginx/ssl/www.example.com/ca.cer \
--fullchain-file /usr/local/nginx/ssl/www.example.com/fullchain.cer \
--reloadcmd     "service nginx force-reload"
```

测试运行 Nginx:

```bash
nginx -t -c /usr/local/nginx/conf/nginx.conf
```

## XHTTP PATH 绕过缓存

**记得使用你自己的 PATH, 而不是本文档里的示例 PATH。**

可以使用 `curl -sI "https://cloudflare.example.com/6Lyq6pDS5bSqffPtyhtR6ryhcow0MZJ4qf4SML7m/test"` 检查是否成功绕过缓存。

### Cloudflare

Domains → 缓存 → Cache Rules → 创建规则。

自定义筛选表达式, 选择一种即可:

| 字段     | 运算符 | 值                                        | 缓存资格 |
| -------- | ------ | ----------------------------------------- | -------- |
| URI 完整 | 包含   | 6Lyq6pDS5bSqffPtyhtR6ryhcow0MZJ4qf4SML7m  | 绕过缓存 |
| URI 路径 | 开头为 | /6Lyq6pDS5bSqffPtyhtR6ryhcow0MZJ4qf4SML7m | 绕过缓存 |

### Fastly

CDN → Service configuration → (右上角 Clone to edit) → Settings → Cache settings → Create your first cache setting:

`Name` 填 `Bypass for XHTTP`, `Action` 选择 `pass`, 其余项不用填, `Create` 后点击右侧 `Attach a condition`, `Name` 填 `Match Bypass Path`, `Apply if…` 填

```
req.url ~ "^/6Lyq6pDS5bSqffPtyhtR6ryhcow0MZJ4qf4SML7m"
```

### Gcore

CDN → CDN 资源 → 规则 → 创建规则:

匹配标准 (规则模式): `^/6Lyq6pDS5bSqffPtyhtR6ryhcow0MZJ4qf4SML7m`

选项 (添加选项):

| CDN 缓存 | 浏览器缓存 |
| -------- | ---------- |
| CDN 受控 | CDN 受控   |
| 不缓存   | 不缓存     |

## Cloudflare优选域名

来源:

- https://cf.090227.xyz/
- https://vps789.com/cfip/?remarks=domain
- https://www.wetest.vip/page/cloudflare/cname.html

综合加权排序后:

```
cfcn-a-proctusa.chinabaidu.pp.ua
cf-cname.xingpingcn.top
singgcdn.singgnetworkcdn.com
www.shopify.com
store.ubi.com
staticdelivery.nexusmods.com
```

### 网络不通?

`address` 填入自己的 CDN 域名或 Cloudflare 优选域名时, 网络不可用, 填入优选 IP 时正常, 大概率是客户端陷入了 DNS 逻辑陷阱。
在 DNS 路由规则中, 设置自己的 CDN 域名和 Cloudflare 优选域名的 DNS 解析走直连即可解决。

对于 xray, 类似:

```json
{
  "dns": {
    "servers": [
      {
        "address": "https+local://dns.alidns.com/dns-query",
        "domains": [
          "domain:example.com",
          "cfcn-a-proctusa.chinabaidu.pp.ua",
          "cf-cname.xingpingcn.top",
          "singgcdn.singgnetworkcdn.com",
          "www.shopify.com",
          "store.ubi.com",
          "staticdelivery.nexusmods.com"
        ],
        "skipFallback": true
      }
    ]
  }
}
```

如果 xray 同时承担路由功能, 还需要把你的 CDN 域名和 Cloudflare 优选域名在路由规则中走直连:

```json
{
  "routing": {
    "rules": [
      {
        "domain": [
          "domain:example.com",
          "cfcn-a-proctusa.chinabaidu.pp.ua",
          "cf-cname.xingpingcn.top",
          "singgcdn.singgnetworkcdn.com",
          "www.shopify.com",
          "store.ubi.com",
          "staticdelivery.nexusmods.com"
        ],
        "outboundTag": "out-direct"
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
        "domain_suffix": [
          "example.com",
          "cfcn-a-proctusa.chinabaidu.pp.ua",
          "cf-cname.xingpingcn.top",
          "singgcdn.singgnetworkcdn.com",
          "www.shopify.com",
          "store.ubi.com",
          "staticdelivery.nexusmods.com"
        ],
        "server": "dns-direct"
      }
    ]
  }
}
```

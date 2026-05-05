
改自 https://github.com/zxcvos/Xray-script/blob/main/service/nginx.sh

**只支持 Ubuntu / Debian / CentOS**

## 命令用法

```bash
用法: nginx-install.sh [选项]

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
  nginx-install.sh --install
  nginx-install.sh --install --brotli
  nginx-install.sh --install --brotli --zstd
  nginx-install.sh --install --prefix /opt/nginx
  nginx-install.sh --install --version nginx-1.30.0 --openssl-version openssl-4.0.0
  nginx-install.sh --update
  nginx-install.sh --update --brotli --zstd
  nginx-install.sh --purge
```

## 已编译模块

| 模块                                                   | 类型 |
| ------------------------------------------------------ | ---- |
| http_ssl, http_v2, http_v3                             | 内置 |
| http_realip, http_addition, http_sub, http_dav         | 内置 |
| http_flv, http_mp4, http_gunzip, http_gzip_static      | 内置 |
| http_auth_request, http_random_index, http_secure_link | 内置 |
| http_degradation, http_slice, http_stub_status         | 内置 |
| threads, file-aio, google_perftools                    | 内置 |
| stream, stream_ssl, stream_realip, stream_ssl_preread  | 内置 |
| mail_ssl                                               | 内置 |
| http_xslt, http_image_filter, http_geoip, http_perl    | 动态 |
| mail                                                   | 动态 |
| stream_geoip                                           | 动态 |
| ngx_brotli                                             | 可选 |
| zstd-nginx-module                                      | 可选 |

## 路径速查

| 内容              | 路径                                             |
| ----------------- | ------------------------------------------------ |
| 安装根目录        | `/usr/local/nginx/`                              |
| 二进制文件        | `/usr/local/nginx/sbin/nginx`, `/usr/sbin/nginx` |
| 配置文件          | `/usr/local/nginx/conf/nginx.conf`               |
| 动态模块          | `/usr/local/nginx/modules/`                      |
| 日志目录          | `/var/log/nginx/`                                |
| PID 文件          | `/run/nginx.pid`                                 |
| systemd 服务      | `/etc/systemd/system/nginx.service`              |
| 日志轮转          | `/etc/logrotate.d/nginx`                         |
| tcmalloc 共享内存 | `/dev/shm/nginx/tcmalloc/`                       |

# panel

[![docker-publish](https://github.com/GoAsyncFunc/Panel/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/GoAsyncFunc/Panel/actions/workflows/docker-publish.yml)

单容器 LNRP 镜像：**Debian 12 (bookworm) + nginx + PHP-FPM + Redis + cron**，由 supervisord 统一托管，用于部署 PHP 面板（v2board 等）。

同一容器内跑齐 Web、PHP、Redis、cron，挂载面板代码即可用；配置文件全部随镜像提供，不做运行时原地打补丁。

## 组件版本（当前默认构建）

| 组件 | 版本 | 来源 |
| --- | --- | --- |
| 基础镜像 | debian:12-slim（digest 固定） | 官方 |
| nginx | 1.30.6（stable） | nginx.org |
| PHP-FPM / CLI | 8.1.34（可参数化为 8.2/8.3/8.4） | sury.org |
| Redis | 8.10.3 | packages.redis.io |
| Composer | 2.11.1（sha256 校验） | getcomposer.org |
| supervisor | 4.2.5 | Debian |
| ionCube Loader | 15.5.1（按 PHP 版本 + 架构自动选择） | ioncube.com |

PHP 扩展：fpm, cli, common, opcache, readline, mbstring, curl, gd, imagick, mysql(pdo_mysql/mysqli), pgsql(pdo_pgsql), intl, xml(含 dom/simplexml), bcmath, zip, igbinary, msgpack, redis, memcached，外加 ionCube。
igbinary 与 msgpack 通过 sury 预编译包安装并默认启用。

## 设计要点

- 仓库密钥使用 signed-by keyring 直连各站点，不用 apt-key 与 keyserver；源不可用时构建直接报错，而不是静默缺包
- PHP 扩展全部来自 sury 预编译包，构建快，且可用 `PHP_VERSION` 构建参数在 8.1–8.4 之间切换
- nginx（stable）与 Composer 固定版本，Composer phar 校验 sha256；ionCube loader 按 PHP 版本与架构自动选择
- supervisor 由 apt 安装；nginx 访问日志、PHP-FPM 与 supervisor 日志统一进 `docker logs`
- 健康检查每 30s 请求 `:8999/ping`；amd64 与 arm64 双架构；镜像内所有外网下载带重试

## 发布的镜像（GHCR）

每次推送到 `main`、推送 `v*` 标签或手动触发 Workflow 时，GitHub Actions 会构建并把镜像发布到 GHCR，同时包含 amd64 与 arm64：

```bash
docker pull ghcr.io/goasyncfunc/lnrp:latest   # PHP 8.1，与 Dockerfile 默认一致
docker pull ghcr.io/goasyncfunc/lnrp:8.2
docker pull ghcr.io/goasyncfunc/lnrp:8.3
docker pull ghcr.io/goasyncfunc/lnrp:8.4
```

| 标签 | 内容 |
| --- | --- |
| `latest`、`8.1` | PHP 8.1 构建 |
| `8.2` / `8.3` / `8.4` | 对应 PHP 版本的构建 |
| 推送 `v*` 标签时 | 在 8.1 构建上额外生成语义化版本标签，如 `1.0.0` |

上面运行示例里的镜像名换成 `ghcr.io/goasyncfunc/lnrp:latest` 即可用于部署。

## 构建

```bash
docker build -t lnrp .

# 换 PHP 版本（sury 提供 8.1 ~ 8.4）
docker build --build-arg PHP_VERSION=8.2 -t lnrp:php82 .
```

可调构建参数：

| ARG | 默认值 | 说明 |
| --- | --- | --- |
| `PHP_VERSION` | `8.1` | v2board（Laravel 8）建议 8.1；换版本会自动改包名、socket 路径与 ionCube 加载器 |
| `NGINX_VERSION` | `1.30.6-1~bookworm` | 版本列表见 <https://nginx.org/packages/debian/pool/nginx/n/nginx/> |
| `COMPOSER_VERSION` | `2.11.1` | |
| `COMPOSER_SHA256` | `6f1b891e...882f8c` | 必须与 `COMPOSER_VERSION` 同步更新，哈希取自 <https://getcomposer.org/download/<版本>/composer.phar.sha256sum> |

基础镜像 digest 固定在 Dockerfile 的 `FROM` 里，升级方法：`docker pull debian:12-slim` 后用 `docker inspect --format='{{index .RepoDigests 0}}' debian:12-slim` 取新值。

## 运行

```bash
docker run -d --name panel --restart unless-stopped \
  -p 80:80 \
  -v /srv/panel:/usr/local/share/html \
  -v /srv/panel/nginx-conf.d:/etc/nginx/conf.d \
  -v /srv/panel/cron.d:/etc/cron.d \
  lnrp
```

或参考 `docker-compose.example.yml`（`docker compose up -d --build`）。

### 目录与端口约定

| 路径 / 端口 | 作用 |
| --- | --- |
| `/usr/local/share/html` | 面板代码（容器启动时自动 `chown www-data`，因为 php-fpm 以 www-data 运行） |
| `/etc/nginx/conf.d/` | 站点配置。镜像自带一个 `00-default.conf`（:80 默认站，直接服务上面的目录）；挂载自己的目录即整体替换 |
| `/etc/supervisor/conf.d/*.conf` | 追加进程（如 horizon、队列 worker） |
| `/etc/cron.d/` | 追加定时任务（**文件名不能带点**，否则 cron 会忽略） |
| `80` | 面板 vhost |
| `8999` | 仅容器内可访问的状态端点：`/ping`（FPM ping，返回 `pong`）、`/fpm_status`、`/status`（nginx stub_status） |
| `unix:/run/php/php8.1-fpm.sock` | PHP-FPM socket 路径，vhost 的 fastcgi_pass 指向它；换 PHP 版本构建时随版本变化 |
| `/var/lib/redis` | Redis 工作目录（`dump.rdb` 落在这里，需要持久化就挂载它） |

### 常用操作

```bash
docker exec -it panel supervisorctl status          # 无需账号密码
docker exec -it panel supervisorctl restart php-fpm
docker exec panel curl -s localhost:8999/ping       # pong
docker exec panel php -v                            # 含 ionCube / OPcache
docker logs -f panel                                # supervisor、nginx、PHP-FPM、Redis 日志
```

### 定时任务（v2board 示例）

`/srv/panel/cron.d/panel`：

```
* * * * * www-data php /usr/local/share/html/artisan schedule:run >> /dev/null 2>&1
```

### 追加进程（v2board horizon 示例）

`/srv/panel/supervisor.d/horizon.conf`（挂载到 `/etc/supervisor/conf.d/`）：

```ini
[program:horizon]
command=php /usr/local/share/html/artisan horizon
user=www-data
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

### vhost 示例（v2board）

```nginx
server {
    listen 80;
    server_name panel.example.com;
    root /usr/local/share/html;
    index index.php;

    location / { try_files $uri $uri/ /index.php?$query_string; }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
    }

    location ~ /\.(env|git) { deny all; }
}
```

（换 PHP 版本构建时记得同步改 socket 名。）

## 注意事项

- **PHP 8.1 已停止上游支持**，但 sury 会持续回移安全补丁，2026-10 的两个 RCE（CVE-2026-109618 / CVE-2026-109619）已包含在 8.1.34-9 及之后的版本里。默认 8.1 是为兼容 v2board / Laravel 8；新项目建议用 `--build-arg PHP_VERSION=8.3`（或 8.4）构建。
- `8999` 状态端口只在容器内监听并限制 127.0.0.1，不要在宿主机映射出去。
- Redis 以默认参数运行（无密码、仅容器网络可达）。需要密码/持久化时自行提供 `redis.conf` 并在构建时或 supervisor 配置里指定 `command`；数据目录 `/var/lib/redis`。
- Redis 启动时会提示 `Memory overcommit must be enabled`：宿主机 `sysctl vm.overcommit_memory=1` 可消除（仅影响后台落盘/复制场景）。
- supervisor 的 `unix_http_server` 未设账号密码（socket 权限 0700、仅 root 可连），日志里那行 `CRIT Server 'unix_http_server' running without any HTTP authentication checking` 属预期；好处是 `supervisorctl` 免密使用。
- cron 自身不写 syslog（容器内没有 syslogd），任务输出请按上面示例重定向；要确认任务在跑，可 `docker exec panel crontab -l` / 查看任务自身日志。
- 时区：镜像设 `TZ=Asia/Shanghai`（`/etc/localtime` 已链接），PHP 的 `date.timezone` 未强制，跟随 `TZ`。
- 镜像体积约 653 MB（含 git/zip/imagick 等面板运维常用工具）。

## 实测记录

- `php -v`：PHP 8.1.34 + ionCube Loader 15.5.1 + Zend OPcache
- `nginx -v`：nginx/1.30.6；`composer --version`：2.11.1
- `redis-cli ping`：PONG（8.10.3）
- `php -m`：igbinary / msgpack / redis / memcached / imagick / dom / simplexml / intl / bcmath / zip 全部加载
- `curl localhost:8999/ping` → `pong`；`/fpm_status` 显示 pool www、dynamic、3 个进程
- 健康检查 30s 内转为 `healthy`
- 容器内 `/etc/cron.d` 写入任务，下一分钟实际执行成功
- `docker logs` 可见 supervisor 生命周期、nginx 访问日志与 PHP-FPM 日志（单份，不重复）

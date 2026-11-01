# panel

[![docker-publish](https://github.com/GoAsyncFunc/Panel/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/GoAsyncFunc/Panel/actions/workflows/docker-publish.yml)

单容器 LNRP 镜像：**Debian 12 (bookworm) + nginx + PHP-FPM + Redis + cron**，由 supervisord 统一托管，用于部署 PHP 面板。

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
- 默认参数按 10 万用户量级预置（FPM 并发上限与 fd、nginx 连接数、opcache、Redis 上限与 AOF、日志缓冲），容量说明与两档参考见《性能与容量》

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
| `PHP_VERSION` | `8.1` | Laravel 8 系面板建议 8.1；换版本会自动改包名、socket 路径与 ionCube 加载器 |
| `NGINX_VERSION` | `1.30.6-1~bookworm` | 版本列表见 <https://nginx.org/packages/debian/pool/nginx/n/nginx/> |
| `COMPOSER_VERSION` | `2.11.1` | |
| `COMPOSER_SHA256` | `6f1b891e...882f8c` | 必须与 `COMPOSER_VERSION` 同步更新，哈希取自 <https://getcomposer.org/download/<版本>/composer.phar.sha256sum> |

基础镜像 digest 固定在 Dockerfile 的 `FROM` 里，升级方法：`docker pull debian:12-slim` 后用 `docker inspect --format='{{index .RepoDigests 0}}' debian:12-slim` 取新值。

## 运行

```bash
docker run -d --name panel --restart unless-stopped \
  -p 80:80 \
  --ulimit nofile=65536:65536 \
  --log-opt max-size=50m --log-opt max-file=3 \
  -v /srv/panel:/usr/local/share/html \
  -v /srv/panel/nginx-conf.d:/etc/nginx/conf.d \
  -v /srv/panel/cron.d:/etc/cron.d \
  lnrp
```

或直接用 `docker-compose.example.yml`（`docker compose up -d --build`），里面已经带一个 MariaDB 11.4 服务：面板代码的数据库地址填服务名 `db`，例如 `DB_HOST=db`，示例密码记得改掉；数据库参数按 10 万用户档给，小机器请用文件末尾注释里的“小站档”。

数据库选 MariaDB 而不是 MySQL 8：默认不启用 performance_schema、镜像更小，空闲内存占用明显更低，而这类面板的负载在两者之间没有可感知的性能差别。想换 MySQL 把 `image` 改成 `mysql:8.4`、环境变量前缀从 `MARIADB_` 改成 `MYSQL_` 即可。

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
| `/etc/redis/panel.conf` | 容器内 Redis 配置（`maxmemory`、`volatile-lru`、AOF everysec） |
| `/var/lib/redis` | Redis 数据目录（AOF 落在这里，需要持久化就挂载它） |

### 常用操作

```bash
docker exec -it panel supervisorctl status          # 无需账号密码
docker exec -it panel supervisorctl restart php-fpm  # 更新面板代码后必须执行（opcache 不校验时间戳）
docker exec panel curl -s localhost:8999/ping       # pong
docker exec panel php -v                            # 含 ionCube / OPcache
docker logs -f panel                                # supervisor、nginx、PHP-FPM、Redis 日志
```

### 定时任务（示例）

`/srv/panel/cron.d/panel`：

```
* * * * * www-data php /usr/local/share/html/artisan schedule:run >> /dev/null 2>&1
```

### 追加进程（队列 worker 示例）

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

### vhost 示例

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

## 性能与容量

面板自身的流量不大（用户的代理流量不经过这个容器），压力主要是两块：客户端定时与启动时的订阅拉取洪峰，以及节点每分钟上报引发的流量结算写入。前者吃 PHP-FPM 并发，后者吃数据库写入。镜像默认参数已按 10 万用户量级预置；因为其中大多是“上限”而不是“预分配”，1000 用户的站点同样适用。

### 镜像内已预置

| 位置 | 参数 | 值 |
| --- | --- | --- |
| php-fpm 池 | `pm` / `max_children` / `start_servers` / spare | `dynamic` / 48 / 4 / 4–8 |
| php-fpm 池 | `max_requests` / `listen.backlog` / `rlimit_files` | 500 / 4096 / 65536 |
| nginx | `worker_processes` / `worker_connections` / `worker_rlimit_nofile` | auto / 8192 / 65536 |
| nginx | 访问日志 | 缓冲写入 `buffer=64k flush=5s` |
| opcache | `memory_consumption` / `max_accelerated_files` / `interned_strings_buffer` | 256M / 30000 / 32M |
| opcache | `validate_timestamps` | 0，改代码后必须重启 php-fpm |
| PHP | `memory_limit` / `realpath_cache_size` | 256M / 16M |
| supervisor | `minfds` | 65536 |
| Redis | `maxmemory` / 淘汰策略 / 持久化 | 1gb / `volatile-lru` / AOF everysec |

稳态高负载的大站可以把 `pm` 改成 `static`，常驻进程数给到 48–64（改 `/etc/php/8.1/fpm/pool.d/www.conf`，或挂载自己的池文件替换）；小站保持 `dynamic`，`max_children` 只当上限，空闲时只跑 `start_servers` 个进程。规划内存时按每个 worker 25–50MB 预留。

### 实测空闲占用

| 组件 | 工作集 |
| --- | --- |
| panel 容器（FPM 3 worker、nginx 2 worker、Redis、cron、supervisor） | 42 MiB |
| MariaDB（256M 缓冲池） | 87 MiB |

“上限类”参数设大不产生额外占用：opcache 配 128M 上限时实测只用 8.7MB，Redis 的 `maxmemory` 也只是上限。真正需要按规模给的只有四个：MariaDB 缓冲池、MariaDB redo 日志大小（占磁盘）、FPM 常驻进程数、队列 worker 数量（每个约 100MB）。

### 两档参考

| 旋钮 | 1000 用户 | 10 万用户 |
| --- | --- | --- |
| MariaDB `innodb_buffer_pool_size` | 256M | 8G（16G 内存的库机）到 16–24G（32G 内存） |
| MariaDB `innodb_log_file_size` | 128–256M | 1G |
| FPM 并发 | `dynamic`，上限 16–24 | `dynamic` 上限 48–64，或 `static` 48 |
| 队列 worker | 1–2 | 4–8 |
| 硬件参考 | web 2C4G + DB 2C4G | web 8C16G + DB 8C32G（NVMe） |

`docker-compose.example.yml` 的数据库按 6 核 12G 单机预算配置（缓冲池 6G），文件末尾附了“16G 以上”与“小站档”两个注释块；面板服务已带 `ulimits.nofile=65536` 与日志体积限制。

### 6 核 12G 单机（100G NVMe）

| 项目 | 取值 | 内存预算 |
| --- | --- | --- |
| 系统与 Docker | — | 1.2–1.5G |
| MariaDB `innodb_buffer_pool_size` | 6G | 进程约 6.5G |
| FPM `max_children` | 48 | 最坏约 1.9G（每 worker 25–50MB） |
| Redis `maxmemory` | 1G | 通常占用 0.3–0.6G |
| 合计 | | 约 9.5–11G，余量 1–2.5G |

磁盘：100G 里建议数据库数据控制在 60G 以内；binlog 已设 3 天自动清理；流量类大表按月归档；docker 日志已限制 50M × 3。

CPU：6 核足够。nginx 用 `auto`（6 个 worker），PHP-FPM 的 48 个进程在 6 核上以 IO 等待为主。若并发上来先看到 CPU 打满，优先加核，并把订阅端点接 CDN 或反代并加限速来削峰。

### 队列 worker

流量结算依赖队列，示例在 `supervisor/queue-worker.conf.example`：复制成 `.conf` 挂载到 `/etc/supervisor/conf.d/`（compose 里有对应注释行），`numprocs` 就是 worker 数量。

### 验证与运营

- `docker exec panel curl -s localhost:8999/fpm_status`：`listen queue` 长期大于 0 说明 FPM 并发不够
- 慢查询日志已开（`long_query_time=1`），定期看数据库的慢查询输出找问题语句
- 订阅端点做一次压测看 P95；生产建议前面加一层 CDN 或反代吸收洪峰
- 更新面板代码后执行 `docker exec panel supervisorctl restart php-fpm`；把 `opcache.validate_timestamps` 改回 1 也可以，代价是每个请求多做一次文件检查
- 数据库缓冲池 8G 需要库机至少 16G 内存，否则 MariaDB 起不来
- Redis 队列与缓存共用时策略为 `volatile-lru`：只淘汰带 TTL 的键，队列键不要设置过期时间；更稳的做法是拆成两个实例

## 注意事项

- **PHP 8.1 已停止上游支持**，但 sury 会持续回移安全补丁，2026-10 的两个 RCE（CVE-2026-109618 / CVE-2026-109619）已包含在 8.1.34-9 及之后的版本里。默认 8.1 是为兼容仍在使用 Laravel 8 的面板程序；新项目建议用 `--build-arg PHP_VERSION=8.3`（或 8.4）构建。
- `8999` 状态端口只在容器内监听并限制 127.0.0.1，不要在宿主机映射出去。
- Redis 由镜像内的 `/etc/redis/panel.conf` 启动：`maxmemory 1gb`、`volatile-lru`、AOF everysec、无密码且仅容器内网可达。需要密码时加 `requirepass` 并在面板 `.env` 里配置；数据目录 `/var/lib/redis`，要持久化就挂载它。
- Redis 启动时会提示 `Memory overcommit must be enabled`：宿主机 `sysctl vm.overcommit_memory=1` 可消除（仅影响后台落盘/复制场景）。
- supervisor 的 `unix_http_server` 未设账号密码（socket 权限 0700、仅 root 可连），日志里那行 `CRIT Server 'unix_http_server' running without any HTTP authentication checking` 属预期；好处是 `supervisorctl` 免密使用。
- cron 自身不写 syslog（容器内没有 syslogd），任务输出请按上面示例重定向；要确认任务在跑，可 `docker exec panel crontab -l` / 查看任务自身日志。
- 时区：镜像默认 `TZ=Asia/Shanghai`（`/etc/localtime` 已链接），PHP 的 `date.timezone` 未强制、跟随 `TZ`；compose 示例里 panel 与 db 两个服务都显式设置了 `TZ`，要换时区改这一处即可。
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

# panel — single-container LNRP image: Debian 12 + nginx + PHP-FPM + Redis,
# supervised by supervisord, for hosting PHP panels.
#
# Build:
#   docker build -t lnrp .
#   docker build --build-arg PHP_VERSION=8.2 -t lnrp:php82 .
#
# Runtime contract:
#   :80      panel vhost (replace /etc/nginx/conf.d to install your own)
#   :8999    container-local status endpoints: /ping /fpm_status /status
#   socket   unix:/run/php/php<version>-fpm.sock
#   webroot  /usr/local/share/html
#   programs /etc/supervisor/conf.d/*.conf

FROM debian:12-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3

ARG PHP_VERSION=8.1
ARG NGINX_VERSION=1.30.6-1~bookworm
ARG COMPOSER_VERSION=2.11.1
ARG COMPOSER_SHA256=6f1b891e1d4927d62740276c540fb490e47689e19e102c49e8da849794882f8c

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

LABEL org.opencontainers.image.title="panel" \
      org.opencontainers.image.description="Debian 12 + nginx + PHP-FPM + Redis + supervisor image for hosting PHP panels"

# ---- package sources: signed-by keyrings, no keyservers, no apt-key ----------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    printf 'Acquire::Retries "3";\nAPT::Update::Error-Mode "any";\n' > /etc/apt/apt.conf.d/80-retries; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o /tmp/nginx.key https://nginx.org/keys/nginx_signing.key; \
    gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg /tmp/nginx.key; \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian/ bookworm nginx" > /etc/apt/sources.list.d/nginx.list; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o /usr/share/keyrings/sury-php.gpg https://packages.sury.org/php/apt.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ bookworm main" > /etc/apt/sources.list.d/sury-php.list; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o /tmp/redis.key https://packages.redis.io/gpg; \
    gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg /tmp/redis.key; \
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb bookworm main" > /etc/apt/sources.list.d/redis.list; \
    rm -f /tmp/nginx.key /tmp/redis.key

# ---- runtime packages --------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nginx=${NGINX_VERSION} \
        redis-server \
        supervisor \
        cron \
        git zip unzip \
        locales tzdata \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-common \
        php${PHP_VERSION}-opcache \
        php${PHP_VERSION}-readline \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-imagick \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-pgsql \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-igbinary \
        php${PHP_VERSION}-msgpack \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-memcached; \
    rm -f /etc/nginx/conf.d/default.conf; \
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; \
    locale-gen; \
    ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ---- ionCube loader (some panels/plugins are encoded) ------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) ic_arch=lin_x86-64 ;; \
        arm64) ic_arch=lin_aarch64 ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o /tmp/ioncube.zip "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_${ic_arch}.zip"; \
    unzip -q /tmp/ioncube.zip -d /tmp/ioncube; \
    ext_dir="$(php${PHP_VERSION} -r 'echo ini_get("extension_dir");')"; \
    cp "/tmp/ioncube/ioncube/ioncube_loader_lin_${PHP_VERSION}.so" "${ext_dir}/"; \
    printf 'zend_extension=ioncube_loader_lin_%s.so\n' "${PHP_VERSION}" > "/etc/php/${PHP_VERSION}/mods-available/ioncube.ini"; \
    ln -sf "/etc/php/${PHP_VERSION}/mods-available/ioncube.ini" "/etc/php/${PHP_VERSION}/fpm/conf.d/01-ioncube.ini"; \
    ln -sf "/etc/php/${PHP_VERSION}/mods-available/ioncube.ini" "/etc/php/${PHP_VERSION}/cli/conf.d/01-ioncube.ini"; \
    rm -rf /tmp/ioncube /tmp/ioncube.zip

# ---- composer (pinned release, checksum verified) ----------------------------
RUN set -eux; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o /tmp/composer.phar "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar"; \
    echo "${COMPOSER_SHA256}  /tmp/composer.phar" | sha256sum -c -; \
    chmod 0755 /tmp/composer.phar; \
    mv /tmp/composer.phar /usr/local/bin/composer

# ---- image configuration -----------------------------------------------------
COPY nginx.conf /etc/nginx/nginx.conf
COPY nginx-default.conf /etc/nginx/conf.d/00-default.conf
COPY php/panel.ini /etc/php/${PHP_VERSION}/fpm/conf.d/99-panel.ini
COPY php/panel.ini /etc/php/${PHP_VERSION}/cli/conf.d/99-panel.ini
COPY php/fpm-www.conf /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY redis/panel.conf /etc/redis/panel.conf
COPY html/index.html /usr/local/share/html/index.html
COPY start.sh /start.sh

RUN set -eux; \
    chmod +x /start.sh; \
    sed -i "s/@PHP_VERSION@/${PHP_VERSION}/g" \
        /etc/nginx/nginx.conf \
        /etc/nginx/conf.d/00-default.conf \
        /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf \
        /etc/supervisor/supervisord.conf; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    ln -sf /dev/stderr /var/log/php${PHP_VERSION}-fpm.log; \
    mkdir -p /run/php; \
    nginx -t; \
    php-fpm${PHP_VERSION} -t

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:8999/ping || exit 1

CMD ["/start.sh"]

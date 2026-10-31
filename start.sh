#!/bin/bash
set -euo pipefail

# /run can be repopulated on container start; make sure the fpm socket dir exists
mkdir -p /run/php
chown www-data:www-data /run/php

# the panel code usually arrives via a bind mount; php-fpm runs as www-data and
# needs to write there (storage/, cache/, uploads, ...)
if [ -d /usr/local/share/html ]; then
    chown -Rf www-data:www-data /usr/local/share/html
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf

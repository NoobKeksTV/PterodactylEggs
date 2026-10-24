FROM debian:bookworm-slim

ARG PHP_VERSION=8.3

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Europe/Berlin

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl git unzip tini tzdata nginx-light gettext-base procps; \
    if [ "${PHP_VERSION}" != "none" ]; then \
        curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg; \
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ bookworm main" > /etc/apt/sources.list.d/sury-php.list; \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-mysql php${PHP_VERSION}-pgsql php${PHP_VERSION}-sqlite3 \
            php${PHP_VERSION}-curl php${PHP_VERSION}-gd php${PHP_VERSION}-intl php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml \
            php${PHP_VERSION}-zip php${PHP_VERSION}-bcmath php${PHP_VERSION}-opcache php${PHP_VERSION}-redis php${PHP_VERSION}-imagick; \
        ln -s /usr/sbin/php-fpm${PHP_VERSION} /usr/local/bin/php-fpm; \
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php; \
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; \
        rm /tmp/composer-setup.php; \
    fi; \
    rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default; \
    useradd -m -d /home/container -s /bin/bash container

COPY entrypoint.sh /usr/local/bin/egopvp-web
COPY templates/ /usr/local/share/egopvp-web/
RUN chmod 0755 /usr/local/bin/egopvp-web && echo "${PHP_VERSION}" > /usr/local/share/egopvp-web/php-version

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/usr/local/bin/egopvp-web"]

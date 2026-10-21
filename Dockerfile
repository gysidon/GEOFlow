# GEOFlow 生产应用镜像（PHP-FPM + 业务代码）
#
# 用途：供阿里云 ACR「代码变更时自动构建镜像」使用。
# ACR 构建规则填写（自定义规则，避开内置 release-v* 规则）：
#   分支/标签：   tags: v$version
#   构建上下文目录： /
#   Dockerfile文件名： Dockerfile
#   镜像版本：   $version
#
# 注意：composer/php/node 基础镜像已同步至 ACR（kintreda/base-*），
#       构建时从 ACR 内网拉取，避免 Docker Hub 匿名拉取 429 限流。
#
# 与 docker/Dockerfile.prod 的差异：
#   去掉了 RUN --mount=type=cache（BuildKit 专属语法）。
#   ACR 的托管构建器不保证开启 BuildKit，保留会直接报 unknown flag: mount 导致构建失败。
#   去掉后仅失去跨构建的 composer 缓存复用，不影响产物一致性。
#
# 上游文件 docker/Dockerfile.prod 保持原样，供服务器本地构建与 GitHub Actions 使用。

ARG COMPOSER_IMAGE=registry.cn-chengdu.aliyuncs.com/kintreda/base-composer:2
ARG PHP_FPM_IMAGE=registry.cn-chengdu.aliyuncs.com/kintreda/base-php:8.4-fpm-bookworm
ARG NODE_IMAGE=registry.cn-chengdu.aliyuncs.com/kintreda/base-node:22-bookworm-slim
ARG PECL_REDIS_VERSION=6.3.0
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

FROM ${COMPOSER_IMAGE} AS vendor

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}

WORKDIR /app

# composer:2 基于 Alpine；国内 ECS 需替换 apk 源（与 dev Dockerfile 的 Debian 镜像策略一致）
RUN set -eux; \
    if [ -f /etc/apk/repositories ]; then \
        sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories; \
    fi

ARG COMPOSER_PACKAGIST_MIRROR=
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_MEMORY_LIMIT=-1 \
    COMPOSER_PROCESS_TIMEOUT=2000 \
    COMPOSER_MAX_PARALLEL_HTTP=4

RUN if [ -n "${COMPOSER_PACKAGIST_MIRROR}" ]; then \
    composer config -g repo.packagist composer "${COMPOSER_PACKAGIST_MIRROR}"; \
    fi

COPY composer.json composer.lock ./
RUN set -eu; \
    for attempt in 1 2 3; do \
        if composer install \
            --no-dev \
            --no-interaction \
            --prefer-dist \
            --ignore-platform-req=ext-pcntl \
            --classmap-authoritative \
            --no-scripts; then \
            break; \
        fi; \
        if [ "$attempt" -eq 3 ]; then \
            echo "Composer dependency download failed after three attempts." >&2; \
            exit 1; \
        fi; \
        echo "Composer dependency download failed; retrying attempt $((attempt + 1)) of 3." >&2; \
        sleep "$((attempt * 15))"; \
    done

COPY . .

RUN mkdir -p \
        bootstrap/cache \
        storage/app/public/uploads/images \
        storage/app/tmp \
        storage/framework/cache/data \
        storage/framework/sessions \
        storage/framework/views \
        storage/logs \
    && composer dump-autoload \
    --no-dev \
    --no-interaction \
    --classmap-authoritative \
    --no-scripts \
    && BROADCAST_CONNECTION=null php artisan package:discover --ansi

FROM ${NODE_IMAGE} AS assets

WORKDIR /app

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}

RUN npm config set registry https://registry.npmmirror.com/

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY resources ./resources
COPY public ./public
COPY vite.config.js ./

RUN npm run build

FROM ${PHP_FPM_IMAGE}

ARG PECL_REDIS_VERSION
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}

WORKDIR /var/www/html

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources; \
        sed -i 's|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources; \
    elif [ -f /etc/apt/sources.list ]; then \
        sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list; \
        sed -i 's|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list; \
    fi

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libonig-dev \
        libpq-dev \
        libsqlite3-dev \
        libzip-dev \
        postgresql-client \
        unzip \
    && docker-php-ext-install \
        mbstring \
        opcache \
        pcntl \
        pdo_pgsql \
        pdo_sqlite \
        zip \
    && curl -fsSL "https://pecl.php.net/get/redis-${PECL_REDIS_VERSION}.tgz" -o /tmp/redis.tgz \
    && pecl install /tmp/redis.tgz \
    && docker-php-ext-enable redis \
    && rm -f /tmp/redis.tgz \
    && rm -rf /var/lib/apt/lists/*

COPY docker/php/opcache.ini /usr/local/etc/php/conf.d/99-opcache.ini
COPY docker/php/php-docker-overrides.ini /usr/local/etc/php/conf.d/99-overrides.ini
COPY docker/php-fpm/www.conf /usr/local/etc/php-fpm.d/zz-geoflow.conf
COPY docker/entrypoint.prod.sh /usr/local/bin/geoflow-entrypoint-prod

RUN chmod +x /usr/local/bin/geoflow-entrypoint-prod

COPY --from=vendor /app /var/www/html
COPY --from=assets /app/public/build /var/www/html/public/build

# 构建时创建存储链接，让非 root 运行进程直接使用挂载的公共存储。
RUN ln -sT /var/www/html/storage/app/public public/storage \
    && chown -R www-data:www-data storage bootstrap/cache

ENTRYPOINT ["/usr/local/bin/geoflow-entrypoint-prod"]
CMD ["php-fpm", "-F"]

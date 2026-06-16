# Dockerfile reference - PHP / Laravel

Use this reference only after the user explicitly approves adding deployment
files. It is a generic pattern for PHP web apps whose repo has no usable
Dockerfile. Do not hard-code choices from a previous project; derive PHP
version, package manager, extensions, storage, queues, and database driver from
the current repo.

## When To Use

Use when all are true:

- the project is PHP/Laravel/Symfony/generic PHP
- no existing source-root Dockerfile is available
- OpenDeploy autodetect cannot produce a working PHP HTTP runtime
- the user approved source edits through the "Add deployment files" path

If the repo already has a Dockerfile, use that first. If the repo has a nested
Dockerfile, ask before selecting that path or moving/copying it.

## Evidence To Collect First

Before writing files, inspect:

- `composer.json`, `composer.lock`, and `composer.json.config.platform.php`
- required PHP extensions in `require` / `suggest`
- framework commands: `artisan`, `bin/console`, `public/index.php`
- package manager evidence: `packageManager`, `pnpm-lock.yaml`,
  `package-lock.json`, `yarn.lock`, `bun.lockb`
- asset build scripts: `build`, `production`, `vite build`, `mix --production`
- DB/cache needs: `pdo_mysql`, `pdo_pgsql`, Redis, queues, sessions
- storage needs: `storage/`, `uploads/`, `media/`, S3/object-storage env docs

Then tell the user exactly which files you will add, usually:

```text
Dockerfile
.dockerignore
docker/nginx.conf
docker/php-fpm.conf
docker/php.ini
docker/supervisord.conf
docker/entrypoint.sh
```

## General Rules

- Pick the PHP version from repo evidence. If absent, use a current supported
  PHP version compatible with the framework.
- Install only extensions the app needs. Common Laravel sets include
  `bcmath`, `ctype`, `curl`, `dom`, `fileinfo`, `filter`, `gd`, `intl`,
  `mbstring`, `openssl`, `pcntl`, `pdo_mysql` or `pdo_pgsql`, `session`,
  `tokenizer`, `xml`, and `zip`.
- Choose one DB driver. Use `pdo_mysql` for MySQL/MariaDB and `pdo_pgsql` for
  Postgres. Do not install both unless repo evidence needs both.
- Add Redis extension only when Redis/cache/queue/session evidence exists.
- Add optional native tools such as `ffmpeg`, `imagemagick`, `libvips`, or
  `ghostscript` only when repo docs or dependencies require them.
- For frontend assets, use the repo's pinned package manager. Do not invent a
  pnpm/yarn/npm version. If `package.json.packageManager` exists, use it with
  Corepack. If a pnpm/yarn lockfile exists but `packageManager` is missing, ask
  before adding a package-manager pin; do not silently use latest.
- PHP-FPM must set `clear_env = no`; otherwise OpenDeploy env vars do not
  reach PHP workers.
- OpenDeploy exposes one HTTP listener. Use nginx on port `8080` unless repo
  evidence requires a different HTTP port.

## Common Pitfalls

1. Composer images often lack app-required extensions. If `composer install`
   fails platform checks in the vendor stage, either install the extension in
   that stage or use `--ignore-platform-reqs` there and install real extensions
   in the runtime image.
2. Composer scripts can boot the framework during build. If service providers
   need runtime-only env or extensions, use `--no-scripts` during build and run
   framework discovery/cache commands in the entrypoint.
3. Alpine images use musl. Some Node/Vite/Rolldown/SWC native bindings only
   publish glibc builds. If asset build logs mention missing native bindings,
   use a Debian/Bookworm Node stage for frontend assets.
4. Laravel storage/cache directories must exist and be writable by the runtime
   user.
5. Migrations are an explicit deploy-plan choice. If the user approves running
   migrations before first traffic, make migration failure fatal so the deploy
   does not appear healthy with an empty schema.
6. Symfony-family apps may require a root `.env` file even in production
   because bootstrap code calls Symfony Dotenv `loadEnv()`. OpenDeploy's smart
   archive strips `.env` / `.env.*` by design. Do not try to upload it. If the
   local `.env` contains only safe defaults such as `APP_ENV=prod` and
   `APP_DEBUG=0`, recreate those static lines inside the Dockerfile or
   entrypoint. Keep secrets in OpenDeploy service env.

Example for a PHP/Symfony image when local `.env` is only safe defaults:

```dockerfile
RUN printf '%s\n' \
      'APP_ENV=prod' \
      'APP_DEBUG=0' \
      > .env
```

## Reference Dockerfile

Adjust extension list, package manager, and asset commands from repo evidence.

```dockerfile
# syntax=docker/dockerfile:1.7

FROM node:22-bookworm-slim AS frontend
WORKDIR /app
COPY package.json ./
COPY pnpm-lock.yaml* package-lock.json* yarn.lock* ./
RUN corepack enable
# If package.json has packageManager, activate that exact package manager.
# If pnpm/yarn lockfiles exist without packageManager, add a repo-approved pin
# before using this template; do not let Corepack pick a moving latest version.
RUN node -e "const pm=require('./package.json').packageManager||''; if(pm) console.log(pm)" > /tmp/package-manager \
    && if [ -s /tmp/package-manager ]; then corepack prepare "$(cat /tmp/package-manager)" --activate; fi
RUN if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then npm ci; \
    elif [ -f yarn.lock ]; then yarn install --immutable; \
    else npm install; fi
COPY . .
RUN if node -e "process.exit(require('./package.json').scripts?.build ? 0 : 1)"; then \
      if [ -f pnpm-lock.yaml ]; then pnpm run build; \
      elif [ -f yarn.lock ]; then yarn run build; \
      else npm run build; fi; \
    fi

FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install \
      --no-dev \
      --no-scripts \
      --no-autoloader \
      --no-interaction \
      --prefer-dist \
      --ignore-platform-reqs
COPY . .
RUN composer dump-autoload --optimize --no-dev --classmap-authoritative --no-scripts

FROM php:8.3-fpm-alpine AS runtime

RUN apk add --no-cache \
      nginx supervisor tini bash curl \
      icu-libs libpng libjpeg-turbo libwebp freetype libzip libxml2 oniguruma

RUN apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS \
      icu-dev libpng-dev libjpeg-turbo-dev libwebp-dev freetype-dev \
      libzip-dev libxml2-dev oniguruma-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
         bcmath gd intl opcache pcntl pdo_mysql zip \
    && apk del .build-deps \
    && rm -rf /tmp/* /var/cache/apk/*

# Add only if repo evidence needs Redis:
# RUN apk add --no-cache --virtual .redis-build-deps $PHPIZE_DEPS \
#   && pecl install redis \
#   && docker-php-ext-enable redis \
#   && apk del .redis-build-deps

WORKDIR /var/www/app
COPY --from=vendor   /app/vendor       ./vendor
COPY --from=frontend /app/public/build ./public/build
COPY . .

RUN mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views \
             storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache

COPY docker/nginx.conf       /etc/nginx/nginx.conf
COPY docker/php-fpm.conf     /usr/local/etc/php-fpm.d/zz-app.conf
COPY docker/php.ini          /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
```

For Postgres, replace `pdo_mysql` with `pdo_pgsql` and install the needed
Postgres dev packages. For Symfony, keep the nginx/FPM shape but replace
Laravel entrypoint commands with `bin/console` equivalents.

## Reference `docker/nginx.conf`

```nginx
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /dev/stderr warn;
daemon off;

events { worker_connections 1024; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    server_tokens off;
    access_log    /dev/stdout;
    client_max_body_size 50M;

    server {
        listen 8080 default_server;
        server_name _;
        root        /var/www/app/public;
        index       index.php;

        location / { try_files $uri $uri/ /index.php?$args; }

        location ~ \.php$ {
            try_files $uri =404;
            fastcgi_pass             127.0.0.1:9000;
            fastcgi_index            index.php;
            fastcgi_param            SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include                  fastcgi_params;
        }

        location ~ /\.(?!well-known).* { deny all; }
    }
}
```

## Reference `docker/php-fpm.conf`

```ini
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9000
pm = dynamic
pm.max_children = 16
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 500
clear_env = no
catch_workers_output = yes
access.log = /dev/null
```

`clear_env = no` is mandatory for OpenDeploy env injection.

## Reference `docker/supervisord.conf`

```ini
[supervisord]
nodaemon = true
user = root
logfile = /dev/stdout
logfile_maxbytes = 0
pidfile = /run/supervisord.pid

[program:php-fpm]
command = /usr/local/sbin/php-fpm --nodaemonize
autostart = true
autorestart = true
stdout_logfile = /dev/stdout
stdout_logfile_maxbytes = 0
stderr_logfile = /dev/stderr
stderr_logfile_maxbytes = 0

[program:nginx]
command = /usr/sbin/nginx
autostart = true
autorestart = true
stdout_logfile = /dev/stdout
stdout_logfile_maxbytes = 0
stderr_logfile = /dev/stderr
stderr_logfile_maxbytes = 0
```

## Reference `docker/entrypoint.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
cd /var/www/app

mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views \
    storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache || true

if [ -f artisan ]; then
    php artisan package:discover --ansi --no-interaction || true
    php artisan config:clear || true
    php artisan cache:clear || true
    php artisan view:clear || true

    if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
        echo "[entrypoint] step=migrate"
        php artisan migrate --force --no-interaction
    fi
fi

if [ -x bin/console ]; then
    php bin/console cache:clear --no-warmup || true
    if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
        php bin/console doctrine:migrations:migrate --no-interaction
    fi
fi

exec "$@"
```

Use `RUN_MIGRATIONS=true` only when the user approved migrations as part of
first deploy. If migration fails, let the process exit non-zero so OpenDeploy
marks the deployment failed instead of serving a broken app.

## Reference `.dockerignore`

```text
.git
.github
.vscode
.cursor
.claude
.opendeploy
.env
.env.*
node_modules
vendor
public/build
storage/framework/cache/*
!storage/framework/cache/.gitkeep
storage/framework/sessions/*
!storage/framework/sessions/.gitkeep
storage/framework/views/*
!storage/framework/views/.gitkeep
storage/logs/*
!storage/logs/.gitkeep
bootstrap/cache/*
!bootstrap/cache/.gitkeep
tests
*.log
.DS_Store
```

Keep placeholder files such as `.gitkeep` when the framework expects writable
directories to exist.

## Env Planning

Common keys to plan, never print values:

| key | default / source | note |
|---|---|---|
| `APP_KEY` | generated secret for Laravel | Generate locally and upload as runtime env; never commit. |
| `APP_ENV` | `production` | |
| `APP_DEBUG` | `false` | Never enable for a public deploy. |
| `APP_URL` | late-bound live URL | Patch after live URL is known, then create a new deployment so Laravel sees the updated env. |
| `LOG_CHANNEL` | `stderr` when supported | Route logs to OpenDeploy. |
| `DB_*` / `DATABASE_URL` | managed DB env | Map from OpenDeploy dependency env. |
| `REDIS_*` | managed Redis env | Only when cache/session/queue evidence exists. |
| `SESSION_DRIVER`, `CACHE_DRIVER`, `QUEUE_CONNECTION` | repo-specific | Choose file/database/redis/sync from repo docs and dependency plan. |
| storage keys | repo-specific | Prefer object storage env when the app needs durable uploads. |

Do not promise persistent local uploads. If the app writes important files to
local disk, ask whether to configure object storage or continue with a clear
persistence note.

## What This Reference Does Not Do

- It does not authorize source edits by itself. The user must approve adding
  deployment files first.
- It does not cover every PHP framework. Reuse the nginx/FPM pattern and adapt
  framework commands from repo evidence.
- It does not decide storage, queues, or DB engine for the user. Those come from
  source evidence and the deploy plan.

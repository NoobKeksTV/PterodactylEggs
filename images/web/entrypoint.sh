#!/bin/bash
set -uo pipefail

HOME_DIR=/home/container
SHARE=/usr/local/share/egopvp-web
RUN_DIR=/tmp/egopvp-web
PHP_VERSION_IMAGE=$(cat "${SHARE}/php-version" 2>/dev/null || echo none)

cd "${HOME_DIR}" || exit 1

log() { printf '[web] %s\n' "$*"; }
fail() { printf '[web] Error: %s\n' "$*" >&2; }

is_true() {
    case "${1:-}" in 1|true|TRUE|yes|on) return 0 ;; *) return 1 ;; esac
}

int_or() {
    local value="${1:-}" fallback="$2"
    [[ "${value}" =~ ^[0-9]+$ ]] && echo "${value}" || echo "${fallback}"
}

php_enabled() {
    [ "${PHP_VERSION_IMAGE}" != "none" ]
}

resolve_doc_root() {
    local sub="${DOC_ROOT:-}"
    sub="${sub#/}"
    sub="${sub%/}"
    if [[ -n "${sub}" && ! "${sub}" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "/${sub}/" == *"/../"* ]]; then
        fail "DOC_ROOT \"${DOC_ROOT}\" is invalid, using webroot."
        sub=""
    fi
    DOC_ROOT_PATH="${HOME_DIR}/webroot${sub:+/${sub}}"
    if [ ! -d "${DOC_ROOT_PATH}" ]; then
        fail "Folder ${DOC_ROOT_PATH#${HOME_DIR}/} does not exist, using webroot."
        DOC_ROOT_PATH="${HOME_DIR}/webroot"
    fi
}

real_ip_block() {
    local list="${TRUSTED_PROXIES:-}" entry out=""
    for entry in ${list//,/ }; do
        if [[ "${entry}" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; then
            out+="    set_real_ip_from ${entry};"$'\n'
        else
            fail "TRUSTED_PROXIES: \"${entry}\" ignored."
        fi
    done
    if [ -n "${out}" ]; then
        out+="    real_ip_header X-Forwarded-For;"$'\n'"    real_ip_recursive on;"
    fi
    printf '%s' "${out}"
}

rotate_log() {
    local file="$1" limit=$((50 * 1024 * 1024))
    if [ -f "${file}" ] && [ "$(stat -c %s "${file}")" -gt "${limit}" ]; then
        mv -f "${file}" "${file}.1"
    fi
}

render() {
    local template="$1" target="$2" vars='${RUN_DIR} ${SERVER_PORT} ${DOC_ROOT_PATH} ${INDEX_FILES} ${UPLOAD_MAX} ${WEB_WORKERS} ${ACCESS_LOG} ${REAL_IP_BLOCK} ${PHP_MAX_CHILDREN} ${PHP_START_SERVERS} ${PHP_MEMORY_LIMIT} ${PHP_MAX_EXECUTION} ${PHP_ERROR_LOG} ${TZ} ${LISTEN_V6}'
    envsubst "${vars}" < "${template}" > "${target}"
}

build_config() {
    mkdir -p "${RUN_DIR}"/{client_body,proxy,fastcgi,uwsgi,scgi,site.d,php.d,sessions,uploads,tmp} \
        "${HOME_DIR}/webroot" "${HOME_DIR}/logs" "${HOME_DIR}/config/nginx" "${HOME_DIR}/config/php"

    export RUN_DIR
    export SERVER_PORT="$(int_or "${SERVER_PORT:-}" 8080)"
    export UPLOAD_MAX="$(int_or "${UPLOAD_MAX:-}" 64)"
    export WEB_WORKERS="$(int_or "${WEB_WORKERS:-}" 2)"
    export ACCESS_LOG
    if is_true "${ACCESS_LOG_ENABLED:-1}"; then
        ACCESS_LOG="${HOME_DIR}/logs/access.log egopvp"
        rotate_log "${HOME_DIR}/logs/access.log"
    else
        ACCESS_LOG="off"
    fi
    export REAL_IP_BLOCK="$(real_ip_block)"
    export LISTEN_V6=""
    if [ -s /proc/net/if_inet6 ]; then
        LISTEN_V6="        listen [::]:${SERVER_PORT} default_server;"$'\n'
    fi
    export TZ="${TZ:-Europe/Berlin}"

    resolve_doc_root
    export DOC_ROOT_PATH

    rm -f "${RUN_DIR}"/site.d/*.conf
    if php_enabled; then
        export INDEX_FILES="index.php index.html index.htm"
        local memory server_memory
        server_memory="$(int_or "${SERVER_MEMORY:-}" 1024)"
        [ "${server_memory}" -eq 0 ] && server_memory=4096
        memory="$(int_or "${PHP_MEMORY_LIMIT:-}" 256)"
        export PHP_MEMORY_LIMIT="${memory}"
        export PHP_MAX_EXECUTION="$(int_or "${PHP_MAX_EXECUTION:-}" 60)"
        local children=$(( (server_memory - 128) / (memory > 64 ? memory : 64) ))
        [ "${children}" -lt 2 ] && children=2
        [ "${children}" -gt 32 ] && children=32
        export PHP_MAX_CHILDREN="${children}"
        export PHP_START_SERVERS=$(( children < 4 ? children : 4 ))
        export PHP_ERROR_LOG="${HOME_DIR}/logs/php-error.log"
        rotate_log "${PHP_ERROR_LOG}"
        render "${SHARE}/site-php.conf" "${RUN_DIR}/site.d/00-site.conf"
        render "${SHARE}/php-fpm.conf" "${RUN_DIR}/php-fpm.conf"
        render "${SHARE}/php.ini" "${RUN_DIR}/php.d/00-egopvp.ini"
        export PHP_INI_SCAN_DIR=":${RUN_DIR}/php.d:${HOME_DIR}/config/php"
    else
        export INDEX_FILES="index.html index.htm"
        render "${SHARE}/site-static.conf" "${RUN_DIR}/site.d/00-site.conf"
    fi
    render "${SHARE}/nginx.conf" "${RUN_DIR}/nginx.conf.new"
}

nginx_test() {
    nginx -e stderr -p "${RUN_DIR}" -c "$1" -t -q
}

activate_config() {
    if nginx_test "${RUN_DIR}/nginx.conf.new"; then
        mv -f "${RUN_DIR}/nginx.conf.new" "${RUN_DIR}/nginx.conf"
        return 0
    fi
    fail "The nginx configuration is invalid (see above), usually a file in config/nginx/. The running configuration stays active."
    return 1
}

git_auth_args() {
    if [ -n "${GIT_TOKEN:-}" ]; then
        local basic
        basic=$(printf '%s:%s' "${GIT_USERNAME:-x-access-token}" "${GIT_TOKEN}" | base64 -w0)
        printf -- '-c\nhttp.extraHeader=Authorization: Basic %s\n' "${basic}"
    fi
}

run_git() {
    local -a auth=()
    mapfile -t auth < <(git_auth_args)
    GIT_TERMINAL_PROMPT=0 git "${auth[@]}" "$@"
}

webroot_replaceable() {
    local dir="$1" entries
    entries="$(ls -A "${dir}" 2>/dev/null)"
    [ -z "${entries}" ] && return 0
    [ "${entries}" = "index.html" ] && grep -q egopvp-placeholder "${dir}/index.html" 2>/dev/null
}

deploy() {
    local repo="${GIT_REPO:-}" branch="${GIT_BRANCH:-}" target="${HOME_DIR}/webroot"
    if [ -z "${repo}" ]; then
        log "No Git repository set (GIT_REPO), nothing to do."
        return 0
    fi
    if [[ ! "${repo}" =~ ^https://[A-Za-z0-9._~:/?#@!\$\&\'()*+,\;=%-]+$ ]]; then
        fail "GIT_REPO must be an https address."
        return 1
    fi
    if [ -d "${target}/.git" ]; then
        log "Fetching changes from ${repo}${branch:+ (${branch})} ..."
        run_git -C "${target}" fetch --depth 1 origin ${branch:+"${branch}"} || { fail "git fetch failed."; return 1; }
        run_git -C "${target}" reset --hard FETCH_HEAD >/dev/null || { fail "git reset failed."; return 1; }
    elif webroot_replaceable "${target}"; then
        log "Cloning ${repo}${branch:+ (${branch})} into webroot ..."
        local tmp="${HOME_DIR}/.deploy-tmp"
        rm -rf "${tmp}"
        run_git clone --depth 1 ${branch:+--branch "${branch}"} "${repo}" "${tmp}" || { fail "git clone failed. Check address, branch and token."; rm -rf "${tmp}"; return 1; }
        rm -rf "${target}"
        mv "${tmp}" "${target}"
    else
        fail "webroot contains files that do not come from Git. Empty the folder or back up the files, then deploy again."
        return 1
    fi
    log "Revision: $(git -C "${target}" log -1 --format='%h %s' 2>/dev/null)"
    if php_enabled && is_true "${COMPOSER_INSTALL:-1}" && [ -f "${target}/composer.json" ]; then
        log "composer install ..."
        (cd "${target}" && COMPOSER_HOME="${HOME_DIR}/.composer" composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader) || { fail "composer install failed."; return 1; }
    fi
    log "Deploy finished."
}

NGINX_PID=""
PHP_PID=""

start_services() {
    if php_enabled; then
        php-fpm -y "${RUN_DIR}/php-fpm.conf" -F &
        PHP_PID=$!
    fi
    nginx -e stderr -p "${RUN_DIR}" -c "${RUN_DIR}/nginx.conf" -g 'daemon off;' &
    NGINX_PID=$!
}

reload_services() {
    build_config
    activate_config || return 1
    kill -HUP "${NGINX_PID}" 2>/dev/null
    if php_enabled && [ -n "${PHP_PID}" ]; then
        kill -USR2 "${PHP_PID}" 2>/dev/null
    fi
    log "Configuration reloaded."
}

stop_services() {
    log "Stopping webserver ..."
    [ -n "${NGINX_PID}" ] && kill -QUIT "${NGINX_PID}" 2>/dev/null
    [ -n "${PHP_PID}" ] && kill -QUIT "${PHP_PID}" 2>/dev/null
    wait 2>/dev/null
    log "Stopped."
    exit 0
}

show_status() {
    log "Port ${SERVER_PORT}, document root ${DOC_ROOT_PATH#${HOME_DIR}/}, PHP ${PHP_VERSION_IMAGE}"
    kill -0 "${NGINX_PID}" 2>/dev/null && log "nginx running" || fail "nginx not running"
    if php_enabled; then
        kill -0 "${PHP_PID}" 2>/dev/null && log "PHP-FPM running" || fail "PHP-FPM not running"
    fi
    if [ -d "${HOME_DIR}/webroot/.git" ]; then
        log "Git: $(git -C "${HOME_DIR}/webroot" log -1 --format='%h %s (%cr)' 2>/dev/null)"
    fi
}

show_help() {
    log "Commands: reload (apply configuration), deploy (pull from Git and reload), status, stop"
}

trap stop_services TERM INT

log "EgoPvP Webserver, nginx $(nginx -v 2>&1 | cut -d/ -f2), $(php_enabled && echo "PHP ${PHP_VERSION_IMAGE}" || echo "without PHP")"
build_config
activate_config || exit 1
if [ -n "${GIT_REPO:-}" ] && { is_true "${DEPLOY_ON_START:-0}" || webroot_replaceable "${HOME_DIR}/webroot"; }; then
    deploy || fail "Deploy on start failed, starting with the current files."
    build_config
    activate_config || exit 1
fi
start_services
sleep 1
if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
    fail "nginx could not start."
    exit 1
fi
log "Webserver running on port ${SERVER_PORT}."
show_help

while true; do
    if read -r -t 5 line; then
        case "${line}" in
            reload) reload_services ;;
            deploy) deploy && reload_services ;;
            status) show_status ;;
            stop|end|quit) stop_services ;;
            help|"") show_help ;;
            *) fail "Unknown command: ${line}"; show_help ;;
        esac
    elif [ $? -le 128 ]; then
        sleep 5
    fi
    if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
        fail "nginx stopped unexpectedly."
        [ -n "${PHP_PID}" ] && kill -QUIT "${PHP_PID}" 2>/dev/null
        exit 1
    fi
    if php_enabled && ! kill -0 "${PHP_PID}" 2>/dev/null; then
        fail "PHP-FPM stopped unexpectedly."
        kill -QUIT "${NGINX_PID}" 2>/dev/null
        exit 1
    fi
done

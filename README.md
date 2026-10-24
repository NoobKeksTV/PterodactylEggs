# PterodactylEggs

Docker-Images für die Pterodactyl-Eggs von EgoPvP Hosting. Die Egg-Dateien selbst liegen im Hosting-Panel unter
`docs/eggs/`; hier liegen nur die Images, auf die sie verweisen.

## Images

| Image | Egg | Inhalt |
|---|---|---|
| `ghcr.io/noobkekstv/egopvp-web:php8.4` | Webserver (NGINX + PHP) | Debian bookworm-slim, nginx-light, PHP-FPM 8.4 (sury), Composer, Git |
| `ghcr.io/noobkekstv/egopvp-web:php8.3` | Webserver (NGINX + PHP) | wie oben mit PHP 8.3 |
| `ghcr.io/noobkekstv/egopvp-web:php8.2` | Webserver (NGINX + PHP) | wie oben mit PHP 8.2 |
| `ghcr.io/noobkekstv/egopvp-web:static` | Webserver (NGINX + PHP) | nur nginx, ohne PHP |

PHP-Erweiterungen: opcache, mysql, pgsql, sqlite3, curl, gd, intl, mbstring, xml, zip, bcmath, redis, imagick.

## Webserver-Image (`images/web`)

Der Container erzeugt die nginx- und PHP-Konfiguration bei jedem Start aus `templates/` und liest dafür die
Egg-Variablen aus der Umgebung. Im Serverordner (`/home/container`) liegen nur Kundendateien:

| Pfad | Inhalt |
|---|---|
| `webroot/` | Website; ausgeliefert wird `webroot/` oder der Unterordner aus `DOC_ROOT` |
| `config/nginx/*.conf` | zusätzliche Anweisungen im `server`-Block |
| `config/php/*.ini` | zusätzliche PHP-Einstellungen |
| `logs/` | `access.log`, `php-error.log`, ab 50 MB rotiert |

Befehle über die Konsole (stdin): `reload` (neu erzeugen, mit `nginx -t` prüfen, ohne Neustart übernehmen),
`deploy` (Git nach `webroot/`, `composer install`, `reload`), `status`, `stop`. Startmeldung:
`Webserver laeuft auf Port <port>`.

Umgebungsvariablen: `SERVER_PORT`, `SERVER_MEMORY` (setzt Wings), `GIT_REPO`, `GIT_BRANCH`, `GIT_USERNAME`,
`GIT_TOKEN`, `DEPLOY_ON_START`, `COMPOSER_INSTALL`, `DOC_ROOT`, `PHP_MEMORY_LIMIT`, `PHP_MAX_EXECUTION`,
`UPLOAD_MAX`, `ACCESS_LOG_ENABLED`, `TRUSTED_PROXIES`, `WEB_WORKERS`. Bedeutung und Standardwerte stehen in der
Egg-Anleitung `docs/eggs/web/README.md` des Hosting-Panels.

## Bauen und veröffentlichen

Über GitHub Actions: Actions › „Webserver-Image“ › Run workflow, Variante „alle“ oder eine einzelne. Der Workflow
läuft nur von Hand. Nach dem ersten Lauf unter Packages › `egopvp-web` › Package settings die Sichtbarkeit auf
**Public** stellen, sonst kann Wings das Image nicht ziehen. Für neue nginx- und PHP-Versionen den Workflow erneut
starten; Server bekommen das neue Image beim nächsten Neustart.

Ohne Actions direkt auf einer Node (Docker vorhanden). Wings nimmt das lokale Image, wenn das Ziehen aus der
Registry scheitert:

```bash
git clone --depth 1 https://github.com/NoobKeksTV/PterodactylEggs.git /tmp/pterodactyleggs
cd /tmp/pterodactyleggs/images/web
for v in 8.4 8.3 8.2; do docker build --pull --build-arg PHP_VERSION=$v -t ghcr.io/noobkekstv/egopvp-web:php$v .; done
docker build --pull --build-arg PHP_VERSION=none -t ghcr.io/noobkekstv/egopvp-web:static .
```

## Lokal testen

```bash
docker build --build-arg PHP_VERSION=8.3 -t egopvp-web:php8.3 images/web
mkdir -p /tmp/webtest/webroot && sudo chown -R 988:988 /tmp/webtest
docker run --rm -it --user 988:988 -v /tmp/webtest:/home/container \
  -e SERVER_PORT=8080 -e SERVER_MEMORY=1024 -p 8080:8080 egopvp-web:php8.3
```

## Versionierung

Die Version steht in `VERSION` und landet als Label `org.opencontainers.image.version` im Image.

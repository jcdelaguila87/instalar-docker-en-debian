#!/usr/bin/env bash
# Docker Engine oficial en Debian (WSL2 o bare metal), perfil bajo demanda por defecto.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
LOG="${REPO_ROOT}/install-docker-debian.log"
DOCKER_APT_KEY="/etc/apt/keyrings/docker.asc"
DOCKER_APT_SRC="/etc/apt/sources.list.d/docker.sources"
APT_PREREQS=(ca-certificates curl gnupg)

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG"; }
info() { log "INFO: $*"; echo "→ $*"; }
warn() { log "WARN: $*"; echo "! $*" >&2; }
die() { log "ERROR: $*"; echo "✗ $*" >&2; exit 1; }

confirm() {
  local prompt=${1:-Continuar?}
  read -r -p "${prompt} [s/N] " ans || true
  [[ "${ans,,}" == s || "${ans,,}" == si || "${ans,,}" == y || "${ans,,}" == yes ]]
}

need_sudo() {
  sudo -v || die "Se requiere sudo."
}

docker_cmd() {
  if groups | grep -qw docker && docker info &>/dev/null; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

touch "$LOG"

ensure_apt_prerequisites() {
  need_sudo
  info "Dependencias apt: ${APT_PREREQS[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${APT_PREREQS[@]}"
  log "Dependencias apt instaladas"
}

preflight() {
  info "Preflight…"
  [[ -f /etc/os-release ]] || die "No parece Debian (/etc/os-release ausente)."
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == debian ]] || warn "Pensado para Debian (detectado: ${ID:-?})."
  case "$(dpkg --print-architecture)" in
    amd64|arm64) ;;
    *) die "Arquitectura no soportada: $(dpkg --print-architecture)" ;;
  esac
  command -v sudo >/dev/null || die "sudo no encontrado"
  if ! command -v curl >/dev/null; then
    warn "curl no está instalado; la instalación completa instalará ${APT_PREREQS[*]}."
  fi
  if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
    info "Entorno: WSL."
    if ! systemctl is-system-running &>/dev/null; then
      warn "systemd inactivo. En WSL: [boot] systemd=true en /etc/wsl.conf y 'wsl --shutdown' en Windows."
    else
      info "systemd: activo."
    fi
  else
    info "Entorno: Debian (bare metal o VM)."
    if ! systemctl is-system-running &>/dev/null; then
      warn "systemd no responde; el modo bajo demanda necesita systemd."
    fi
  fi
  log "Preflight OK (${PRETTY_NAME:-unknown})"
}

check_docker_network() {
  command -v curl >/dev/null || die "Falta curl; ejecuta ensure_apt_prerequisites o instalación completa."
  info "Comprobando acceso a download.docker.com…"
  curl -fsSL --connect-timeout 10 -o /dev/null https://download.docker.com/ \
    || die "Sin acceso a download.docker.com"
}

docker_installed() {
  dpkg -l docker-ce &>/dev/null && dpkg -l docker-ce | grep -q '^ii'
}

setup_docker_apt_repo() {
  need_sudo
  # shellcheck source=/dev/null
  source /etc/os-release
  local codename="${VERSION_CODENAME:-}"
  [[ -n "$codename" ]] || die "VERSION_CODENAME vacío en /etc/os-release"
  info "Configurando repositorio Docker (suite: ${codename})…"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o "$DOCKER_APT_KEY"
  sudo chmod a+r "$DOCKER_APT_KEY"
  sudo tee "$DOCKER_APT_SRC" >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: ${DOCKER_APT_KEY}
EOF
  sudo apt-get update -qq
  log "Repositorio Docker configurado"
}

install_docker_packages() {
  need_sudo
  if docker_installed; then
    info "Paquetes docker-ce ya instalados; omitiendo apt install."
    return 0
  fi
  info "Instalando Docker Engine y plugins…"
  sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  log "Paquetes Docker instalados"
}

configure_docker_ondemand() {
  need_sudo
  info "Perfil: bajo demanda (socket activa el daemon al usar el CLI)."
  sudo systemctl disable docker.service 2>/dev/null || true
  sudo systemctl enable docker.socket
  sudo systemctl start docker.socket 2>/dev/null || true
  if systemctl is-active docker.service &>/dev/null; then
    if confirm "¿Parar docker.service ahora para dejar el daemon en reposo?"; then
      sudo systemctl stop docker.service
    fi
  fi
  log "Perfil ondemand aplicado"
}

configure_docker_always_on() {
  need_sudo
  info "Perfil: daemon siempre activo al arrancar el sistema."
  sudo systemctl disable docker.socket 2>/dev/null || true
  sudo systemctl enable --now docker.service
  log "Perfil always_on aplicado"
}

configure_docker_manual() {
  need_sudo
  info "Perfil: manual (sin autoarranque; menú o docker-ensure)."
  sudo systemctl disable docker.service 2>/dev/null || true
  sudo systemctl disable docker.socket 2>/dev/null || true
  if systemctl is-active docker.service &>/dev/null; then
    if confirm "¿Parar docker.service ahora?"; then
      sudo systemctl stop docker.service
    fi
  fi
  sudo systemctl stop docker.socket 2>/dev/null || true
  log "Perfil manual aplicado"
}

ensure_docker_group() {
  need_sudo
  if id -nG "$USER" | grep -qw docker; then
    info "Usuario ${USER} ya está en el grupo docker."
  else
    sudo usermod -aG docker "$USER"
    info "Añadido ${USER} al grupo docker."
    warn "Cierra esta terminal y abre otra para que el grupo docker surta efecto."
  fi
}

docker_daemon_start() {
  need_sudo
  if systemctl is-active docker.service &>/dev/null; then
    info "docker.service ya está activo."
    return 0
  fi
  if systemctl is-enabled docker.socket &>/dev/null; then
    sudo systemctl start docker.socket
  fi
  sudo systemctl start docker.service
  info "Daemon iniciado."
}

docker_daemon_stop() {
  need_sudo
  if ! systemctl is-active docker.service &>/dev/null; then
    info "docker.service ya está parado."
    return 0
  fi
  sudo systemctl stop docker.service
  info "Daemon parado."
}

wait_for_docker() {
  local i
  for i in $(seq 1 30); do
    if docker_cmd info -f '{{.ServerVersion}}' &>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

verify_docker() {
  info "Verificando instalación…"
  docker_daemon_start
  wait_for_docker || die "El daemon no respondió a tiempo."
  docker_cmd compose version
  docker_cmd run --rm hello-world
  info "Verificación OK."
  if confirm "¿Parar el daemon tras la prueba (recomendado en modo bajo demanda)?"; then
    docker_daemon_stop
  fi
}

remove_conflicting_packages() {
  need_sudo
  info "Eliminando paquetes conflictivos (si existen)…"
  sudo apt-get remove -y docker.io docker-doc podman-docker containerd runc 2>/dev/null || true
  log "Limpieza de conflictos hecha"
}

write_docker_ensure() {
  mkdir -p "$BIN_DIR"
  cat >"${BIN_DIR}/docker-ensure" <<'ENSURE'
#!/usr/bin/env bash
set -euo pipefail
docker_ok() {
  if groups | grep -qw docker; then
    docker info -f '{{.ServerVersion}}' &>/dev/null
  else
    sudo docker info -f '{{.ServerVersion}}' &>/dev/null
  fi
}
if docker_ok; then exit 0; fi
if systemctl is-enabled docker.socket &>/dev/null; then
  sudo systemctl start docker.socket 2>/dev/null || true
fi
sudo systemctl start docker.service 2>/dev/null || true
for _ in $(seq 1 30); do
  docker_ok && exit 0
  sleep 1
done
echo "docker-ensure: el daemon no respondió" >&2
exit 1
ENSURE
  chmod +x "${BIN_DIR}/docker-ensure"
  info "Creado ${BIN_DIR}/docker-ensure"
}

write_dev_wrappers() {
  mkdir -p "$BIN_DIR"
  for pair in dev-node:'node:22-bookworm' dev-python:'python:3.12-bookworm' dev-php:'php:8.3-cli-bookworm'; do
    local name="${pair%%:*}" img="${pair#*:}"
    cat >"${BIN_DIR}/${name}" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
"\$(dirname "\$0")/docker-ensure" || exit 1
exec docker run -it --rm -v "\$PWD:/work" -w /work ${img} "\$@"
WRAP
    chmod +x "${BIN_DIR}/${name}"
  done
  info "Wrappers dev-node, dev-python, dev-php en ${BIN_DIR}"
}

write_compose_dev() {
  cat >"${REPO_ROOT}/docker-compose.dev.yml" <<'COMPOSE'
# Uso: docker compose -f docker-compose.dev.yml run --rm node bash
services:
  node:
    image: node:22-bookworm
    working_dir: /work
    volumes:
      - .:/work
    stdin_open: true
    tty: true
  python:
    image: python:3.12-bookworm
    working_dir: /work
    volumes:
      - .:/work
    stdin_open: true
    tty: true
  php:
    image: php:8.3-cli-bookworm
    working_dir: /work
    volumes:
      - .:/work
    stdin_open: true
    tty: true
COMPOSE
  info "Plantilla ${REPO_ROOT}/docker-compose.dev.yml"
}

maybe_add_path_bashrc() {
  local line="export PATH=\"${BIN_DIR}:\$PATH\""
  if grep -Fq "${BIN_DIR}" "${HOME}/.bashrc" 2>/dev/null; then
    info "~/.bashrc ya incluye ${BIN_DIR}."
    return 0
  fi
  if confirm "¿Añadir ${BIN_DIR} al PATH en ~/.bashrc?"; then
    printf '\n# docker dev helpers (install-docker-debian.sh)\n%s\n' "$line" >>"${HOME}/.bashrc"
    info "PATH actualizado (abre nueva shell)."
  fi
}

menu_dev_helpers() {
  echo
  echo "=== Helpers de desarrollo ==="
  select opt in \
    "Precache imágenes LTS" \
    "Generar docker-ensure + wrappers dev-*" \
    "Crear docker-compose.dev.yml" \
    "Añadir bin/ al PATH" \
    "Todo lo anterior" \
    "Volver"; do
    case "${opt:-}" in
      "Precache imágenes LTS") pull_dev_images ;;
      "Generar docker-ensure + wrappers dev-*")
        write_docker_ensure
        write_dev_wrappers
        ;;
      "Crear docker-compose.dev.yml") write_compose_dev ;;
      "Añadir bin/ al PATH") maybe_add_path_bashrc ;;
      "Todo lo anterior")
        write_docker_ensure
        write_dev_wrappers
        write_compose_dev
        maybe_add_path_bashrc
        ;;
      "Volver"|"") break ;;
    esac
  done
}

pull_dev_images() {
  if ! command -v docker &>/dev/null; then
    die "Docker CLI no instalado."
  fi
  docker_daemon_start
  wait_for_docker || die "Daemon no disponible."
  local images=(
    node:22-bookworm
    python:3.12-bookworm
    php:8.3-cli-bookworm
    composer:latest
  )
  for img in "${images[@]}"; do
    if confirm "¿Descargar imagen ${img}?"; then
      docker_cmd pull "$img"
    fi
  done
}

run_diagnostics() {
  echo "=== Diagnóstico ==="
  command -v docker && docker --version || echo "docker CLI: no instalado"
  systemctl is-enabled docker.service 2>/dev/null || echo "docker.service: n/a"
  systemctl is-active docker.service 2>/dev/null || echo "docker.service: inactive/n/a"
  systemctl is-enabled docker.socket 2>/dev/null || echo "docker.socket: n/a"
  systemctl is-active docker.socket 2>/dev/null || echo "docker.socket: inactive/n/a"
  id -nG "$USER" | grep -qw docker && echo "grupo docker: sí" || echo "grupo docker: no"
  if systemctl is-active docker.service &>/dev/null; then
    ps -o rss,cmd -C dockerd 2>/dev/null | tail -n +2 | awk '{rss+=$1} END {if (rss) printf "dockerd RSS ~ %.1f MiB\n", rss/1024}'
    docker_cmd info 2>/dev/null | head -20 || true
  else
    echo "Daemon parado (sin docker info)."
  fi
}

menu_daemon_control() {
  echo
  echo "=== Control del daemon ==="
  select opt in \
    "Iniciar daemon ahora" \
    "Parar daemon ahora" \
    "Aplicar perfil: bajo demanda (socket)" \
    "Aplicar perfil: siempre activo" \
    "Aplicar perfil: manual (sin autoarranque)" \
    "Volver"; do
    case "${opt:-}" in
      "Iniciar daemon ahora") docker_daemon_start; wait_for_docker && info "Listo." || warn "No respondió." ;;
      "Parar daemon ahora") docker_daemon_stop ;;
      "Aplicar perfil: bajo demanda (socket)") configure_docker_ondemand ;;
      "Aplicar perfil: siempre activo") configure_docker_always_on ;;
      "Aplicar perfil: manual (sin autoarranque)") configure_docker_manual ;;
      "Volver"|"") break ;;
    esac
  done
}

menu_choose_docker_profile() {
  echo
  echo
  echo "¿Cómo quieres que se comporte Docker?"
  echo "(Yo suelo elegir bajo demanda en el portátil; en un server iría a siempre activo.)"
  select opt in \
    "Bajo demanda — arranca cuando lo uses" \
    "Siempre activo — como un servicio más al boot" \
    "Manual — lo enciendo yo cuando toque" \
    "Dejarlo como está"; do
    case "${opt:-}" in
      "Bajo demanda — arranca cuando lo uses") configure_docker_ondemand; break ;;
      "Siempre activo — como un servicio más al boot") configure_docker_always_on; break ;;
      "Manual — lo enciendo yo cuando toque") configure_docker_manual; break ;;
      "Dejarlo como está"|"") info "Sin cambios en el perfil."; break ;;
    esac
  done
}

menu_config_only() {
  echo
  echo "=== Solo configuración ==="
  select opt in \
    "Grupo docker + perfil bajo demanda" \
    "Grupo docker + perfil siempre activo" \
    "Grupo docker + perfil manual" \
    "Solo grupo docker" \
    "Instalar dependencias apt (ca-certificates curl gnupg)" \
    "Verificar (hello-world)" \
    "Volver"; do
    case "${opt:-}" in
      "Grupo docker + perfil bajo demanda")
        ensure_docker_group
        configure_docker_ondemand
        ;;
      "Grupo docker + perfil siempre activo")
        ensure_docker_group
        configure_docker_always_on
        ;;
      "Grupo docker + perfil manual")
        ensure_docker_group
        configure_docker_manual
        ;;
      "Solo grupo docker") ensure_docker_group ;;
      "Instalar dependencias apt (ca-certificates curl gnupg)") ensure_apt_prerequisites ;;
      "Verificar (hello-world)") verify_docker ;;
      "Volver"|"") break ;;
    esac
  done
}

full_install() {
  if command -v docker &>/dev/null && docker_installed; then
    warn "Docker ya parece instalado."
    select opt in "Continuar reparando/configurando" "Cancelar"; do
      [[ "${opt:-}" == "Continuar reparando/configurando" ]] && break
      [[ "${opt:-}" == "Cancelar" || -z "${opt:-}" ]] && return 0
    done
  else
    confirm "¿Eliminar paquetes conflictivos (docker.io, etc.) antes de instalar?" \
      && remove_conflicting_packages || true
    ensure_apt_prerequisites
    check_docker_network
    setup_docker_apt_repo
    install_docker_packages
  fi
  menu_choose_docker_profile
  ensure_docker_group
  if confirm "¿Ejecutar prueba hello-world ahora?"; then
    verify_docker
  fi
  if confirm "¿Instalar helpers (docker-ensure + wrappers dev-*)?"; then
    write_docker_ensure
    write_dev_wrappers
  fi
  info "Listo. Cierra y abre la terminal si docker aún pide sudo. Log: ${LOG}"
}

main_menu() {
  while true; do
    echo
    echo
    echo "Docker en Debian — menú"
    echo "(log: ${LOG})"
    select opt in \
      "Instalación completa" \
      "Solo ajustes (grupo, perfil, deps…)" \
      "Quitar docker.io y paquetes viejos" \
      "Helpers para dev (opcional)" \
      "Ver qué tal está todo" \
      "Arrancar / parar / cambiar perfil" \
      "Salir"; do
      case "${opt:-}" in
        "Instalación completa")
          full_install
          ;;
        "Solo ajustes (grupo, perfil, deps…)")
          menu_config_only
          ;;
        "Quitar docker.io y paquetes viejos")
          confirm "¿Seguro? Quita docker.io, podman-docker y similares si están." \
            && remove_conflicting_packages || true
          ;;
        "Helpers para dev (opcional)")
          menu_dev_helpers
          ;;
        "Ver qué tal está todo")
          run_diagnostics
          ;;
        "Arrancar / parar / cambiar perfil")
          menu_daemon_control
          ;;
        "Salir"|"")
          info "Nos vemos."
          exit 0
          ;;
      esac
      break
    done
  done
}

preflight
main_menu

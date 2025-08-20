#!/usr/bin/env bash
#
# migrate-nextcloud-umbrelos.sh

set -Eeuo pipefail

### ========= CONFIG AJUSTÁVEL =========
# UUID do /dev/sda1 (blkid /dev/sda1). Ajuste se necessário.
STORAGE_UUID="${STORAGE_UUID:-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}"
# Ponto de montagem no host (UmbrelOS costuma usar /mnt/storage)
STORAGE_MOUNT="${STORAGE_MOUNT:-/mnt/storage}"
# Nome da pasta de destino no disco
DEST_DIR="${DEST_DIR:-${STORAGE_MOUNT}/nextcloud-data}"

# Prefixo dos containers do app Nextcloud no UmbrelOS
NC_PREFIX="${NC_PREFIX:-nextcloud}"
# Usuário/grupo dentro do container (www-data)
WWW_UID="${WWW_UID:-33}"
WWW_GID="${WWW_GID:-33}"
### ====================================

# ---- Helpers de output ----
log()  { echo -e "\e[1;32m[OK]\e[0m  $*"; }
inf()  { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ERRO]\e[0m $*"; }
die()  { err "$*"; exit 1; }
need() { command -v "$1" >/dev/null || die "Comando '$1' não encontrado. Instale-o e tente novamente."; }

DRY_RUN=false
ROLLBACK_PATH=""

# ---- Parse flags ----
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --rollback) shift; ROLLBACK_PATH="${1:-}";;
    --rollback=*) ROLLBACK_PATH="${arg#*=}" ;;
    *) ;;
  esac
done

# ---- Pré-requisitos ----
need docker
need rsync
need tee
need mountpoint

cd /

# ---- Descobrir containers do Nextcloud (prefixo nextcloud_) ----
mapfile -t ALL_NC_CONTAINERS < <(docker ps -a --format '{{.Names}}' | grep -E "^${NC_PREFIX}_" || true)
[[ ${#ALL_NC_CONTAINERS[@]} -gt 0 ]] || die "Não encontrei containers com prefixo '${NC_PREFIX}_'. O Nextcloud já foi instalado/iniciado no UmbrelOS?"

# Funções utilitárias para start/stop em ordem segura
nc_db="${NC_PREFIX}_db_1"
nc_redis="${NC_PREFIX}_redis_1"
nc_web="${NC_PREFIX}_web_1"
nc_cron="${NC_PREFIX}_cron_1"
nc_proxy="${NC_PREFIX}_app_proxy_1"

stop_nc() {
  inf "Parando containers do Nextcloud…"
  $DRY_RUN && { inf "(dry-run) docker stop ${nc_web} ${nc_cron} ${nc_proxy} ${nc_redis} ${nc_db}"; return; }
  docker stop "${nc_web}" "${nc_cron}" "${nc_proxy}" "${nc_redis}" "${nc_db}" >/dev/null || true
  log "Containers parados."
}
start_nc() {
  inf "Subindo containers (DB/Redis primeiro)…"
  if $DRY_RUN; then
    inf "(dry-run) docker start ${nc_db} ${nc_redis}"
    inf "(dry-run) sleep 5"
    inf "(dry-run) docker start ${nc_proxy} ${nc_web} ${nc_cron}"
  else
    docker start "${nc_db}" "${nc_redis}" >/dev/null || true
    sleep 5
    docker start "${nc_proxy}" "${nc_web}" "${nc_cron}" >/dev/null || true
    log "Containers iniciados."
  fi
}

# ---- Rollback, se solicitado ----
if [[ -n "$ROLLBACK_PATH" ]]; then
  inf "Executando ROLLBACK usando: $ROLLBACK_PATH"
  stop_nc
  SRC_DATA="$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Source }}{{ end }}{{ end }}' "${nc_web}" 2>/dev/null || true)/data"
  [[ -z "$SRC_DATA" ]] && die "Não consegui detectar o host path da pasta data para rollback."
  if mountpoint -q "$SRC_DATA"; then
    $DRY_RUN || sudo umount "$SRC_DATA"
  fi
  # remove linha do bind do fstab
  if grep -Fq " ${SRC_DATA}  none  bind" /etc/fstab; then
    $DRY_RUN || sudo sed -i "\| ${SRC_DATA}  none  bind|d" /etc/fstab
  fi
  if $DRY_RUN; then
    inf "(dry-run) mv ${ROLLBACK_PATH} -> ${SRC_DATA}"
  else
    [[ -d "$ROLLBACK_PATH" ]] || die "Backup não encontrado em ${ROLLBACK_PATH}"
    sudo rm -rf "$SRC_DATA"
    sudo mv "$ROLLBACK_PATH" "$SRC_DATA"
  fi
  start_nc
  log "Rollback concluído."
  exit 0
fi

# ---- Detectar host path do Nextcloud (/var/www/html -> host) ----
inf "Detectando caminho do volume do Nextcloud no host…"
HOST_NC="$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Source }}{{ end }}{{ end }}' "${nc_web}" 2>/dev/null || true)"
if [[ -z "${HOST_NC}" ]]; then
  for p in /home/umbrel/umbrel/app-data/nextcloud/data/nextcloud /umbrel/app-data/nextcloud/data/nextcloud; do
    [[ -d "$p" ]] && HOST_NC="$p" && break
  done
fi
[[ -z "${HOST_NC}" ]] && die "Não consegui localizar o volume do Nextcloud. Garanta que o app já rodou ao menos uma vez."

SRC_DATA="${HOST_NC}/data"
[[ -d "${SRC_DATA}" ]] || die "Diretório de dados não encontrado: ${SRC_DATA}"
inf "HOST_NC=${HOST_NC}"
inf "SRC_DATA=${SRC_DATA}"

# ---- Montar /mnt/storage via UUID (persistente) ----
inf "Garantindo montagem de ${STORAGE_MOUNT} (UUID=${STORAGE_UUID})…"
$DRY_RUN || sudo mkdir -p "${STORAGE_MOUNT}"
if ! mountpoint -q "${STORAGE_MOUNT}"; then
  if ! grep -q "${STORAGE_UUID}.*${STORAGE_MOUNT}" /etc/fstab; then
    $DRY_RUN || echo "UUID=${STORAGE_UUID}  ${STORAGE_MOUNT}  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab >/dev/null
    inf "Adicionada entrada do disco em /etc/fstab."
  fi
  $DRY_RUN || sudo mount "${STORAGE_MOUNT}"
fi
log  "${STORAGE_MOUNT} montado (ou preparado no fstab)."

# ---- Copiar dados -> DEST_DIR ----
inf "Copiando dados para ${DEST_DIR} (rsync preservando ACLs/hardlinks)…"
$DRY_RUN || sudo mkdir -p "${DEST_DIR}"
if $DRY_RUN; then
  inf "(dry-run) (cd / && rsync -aHAX --info=progress2 ${SRC_DATA}/ ${DEST_DIR}/)"
else
  ( cd / && sudo rsync -aHAX --info=progress2 "${SRC_DATA}/" "${DEST_DIR}/" )
fi
log "Cópia concluída."

# ---- Parar containers para troca da pasta ----
stop_nc

# ---- Preparar bind-mount (backup + bind) ----
BACKUP="${SRC_DATA}.bak.$(date +%F-%H%M%S)"
if mountpoint -q "${SRC_DATA}"; then
  warn "${SRC_DATA} já é um mountpoint. Pulando backup/troca de diretório."
else
  if [[ -L "${SRC_DATA}" ]]; then
    inf "Removendo symlink antigo em ${SRC_DATA}…"
    $DRY_RUN || sudo rm -f "${SRC_DATA}"
    $DRY_RUN || sudo mkdir -p "${SRC_DATA}"
  elif [[ -d "${SRC_DATA}" ]]; then
    inf "Movendo diretório antigo para backup: ${BACKUP}"
    if $DRY_RUN; then
      inf "(dry-run) mv ${SRC_DATA} -> ${BACKUP} && mkdir -p ${SRC_DATA}"
    else
      sudo mv "${SRC_DATA}" "${BACKUP}"
      sudo mkdir -p "${SRC_DATA}"
    fi
  else
    $DRY_RUN || sudo mkdir -p "${SRC_DATA}"
  fi
fi

inf "Aplicando bind-mount ${DEST_DIR} -> ${SRC_DATA}…"
if $DRY_RUN; then
  inf "(dry-run) mount --bind ${DEST_DIR} ${SRC_DATA}"
else
  sudo mount --bind "${DEST_DIR}" "${SRC_DATA}"
fi

# persistência do bind no fstab
BIND_LINE="${DEST_DIR}  ${SRC_DATA}  none  bind,nofail,x-systemd.requires-mounts-for=${STORAGE_MOUNT}  0  0"
if ! grep -Fq "${DEST_DIR}  ${SRC_DATA}  none  bind" /etc/fstab; then
  $DRY_RUN || echo "${BIND_LINE}" | sudo tee -a /etc/fstab >/dev/null
  inf "Adicionada entrada de bind-mount ao /etc/fstab."
fi
$DRY_RUN || sudo mount -a
log "Bind-mount ativo e persistente."

# ---- Sentinelas e permissões ----
inf "Criando sentinelas (.ncdata/.ocdata) e ajustando permissões…"
if $DRY_RUN; then
  inf "(dry-run) echo '# Nextcloud data directory' > ${DEST_DIR}/.ncdata"
  inf "(dry-run) touch ${DEST_DIR}/.ocdata"
  inf "(dry-run) chown -R ${WWW_UID}:${WWW_GID} ${DEST_DIR}"
  inf "(dry-run) find ${DEST_DIR} -type d -exec chmod 750 {} \\;"
  inf "(dry-run) find ${DEST_DIR} -type f -exec chmod 640 {} \\;"
else
  printf '# Nextcloud data directory' | sudo tee "${DEST_DIR}/.ncdata" >/dev/null
  sudo touch "${DEST_DIR}/.ocdata"
  sudo chown -R "${WWW_UID}:${WWW_GID}" "${DEST_DIR}"
  sudo find "${DEST_DIR}" -type d -exec chmod 750 {} \;
  sudo find "${DEST_DIR}" -type f -exec chmod 640 {} \;

  # teste de escrita como www-data:
  if sudo -u "#${WWW_UID}" bash -lc "touch '${DEST_DIR}/.write_test' && rm -f '${DEST_DIR}/.write_test'"; then
    log "Permissões OK: www-data consegue escrever no diretório de dados."
  else
    die "www-data NÃO consegue escrever em ${DEST_DIR}. Revise chown/chmod e opções de montagem."
  fi
fi

# ---- Subir containers e validar ----
start_nc

inf "Validações finais…"
if $DRY_RUN; then
  inf "(dry-run) docker exec ${nc_web} bash -lc 'php -r \"include \\'config/config.php\\'; echo \\$CONFIG[\\'datadirectory\\']??\\\"(nao definido)\\\";\"; ls -la /var/www/html/data | head -n 8; test -f /var/www/html/data/.ncdata'"
else
  docker exec "${nc_web}" bash -lc 'php -r "include '\''config/config.php'\''; echo \"datadirectory=\".(\$CONFIG['\''datadirectory'\''] ?? \"(nao definido)\").PHP_EOL;"; ls -la /var/www/html/data | head -n 8; test -f /var/www/html/data/.ncdata && echo ".ncdata OK" || echo ".ncdata AUSENTE"' || true
  df -h | egrep "${STORAGE_MOUNT}|sda1" || true
  mount | egrep "$(printf "%q" "${SRC_DATA}").*bind" || true
fi

echo
log "Migração concluída!"
echo "Se criado, backup da pasta antiga: ${BACKUP:-<sem backup>}"
echo
echo "Rollback (exemplo):"
echo "  sudo bash $0 --rollback \"${BACKUP}\""

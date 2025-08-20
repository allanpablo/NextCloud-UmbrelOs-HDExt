# Nextcloud - UmbrelOS - HDExterno (umbrelOS)


---

### 🎯 Objetivo
Migrar **apenas o diretório `data/`** do Nextcloud no **UmbrelOS (umbrelOS)** para um **segundo disco** (ex.: `/dev/sda1`) usando **bind-mount persistente**.  
Mantém **app/config no SSD** (rápido) e move **arquivos de usuários** para o HD grande.

> **Por que bind-mount e não editar o `docker-compose.yml`?**  
> O UmbrelOS pode sobrescrever o compose em atualizações. O bind-mount é aplicado **no host**, é **estável** e **resiste a updates**.

---

### ✅ O que o script faz
Arquivo: `migrate-nextcloud-umbrelos.sh`

1. Detecta no host o caminho real do volume do Nextcloud por trás de **`/var/www/html`** (via `docker inspect`).
2. Monta o **segundo disco** em `/mnt/storage` (via **UUID** no `/etc/fstab`).
3. Copia **`nextcloud/data/` → `/mnt/storage/nextcloud-data/`** com `rsync` (preservando ACLs/hardlinks).
4. Faz **backup** da antiga pasta `data` (`data.bak.YYYY-MM-DD-HHMMSS`).
5. Aplica **bind-mount**:  
   `/mnt/storage/nextcloud-data` → `<host_nextcloud_path>/data`
6. Persiste o bind-mount no **`/etc/fstab`**.
7. Cria **`.ncdata`** (com o conteúdo exato `# Nextcloud data directory`) e **`.ocdata`**, ajusta permissões (**www-data = 33:33**).
8. Reinicia os **containers na ordem certa** (DB/Redis → Web/Cron) e valida.

---

### 📦 Requisitos
- UmbrelOS (umbrelOS) com Nextcloud já **instalado e executado ao menos uma vez**.
- Acesso com **sudo**.
- Pacotes: `docker`, `rsync`, `tee`, `mountpoint`.
- Disco de dados (ex.: `/dev/sda1`) com **UUID** (veja com `sudo blkid /dev/sda1`).

---

### ⚙️ Variáveis úteis (personalizáveis)
No topo do script:
- `STORAGE_UUID` — UUID do seu `/dev/sda1`.
- `STORAGE_MOUNT` — padrão `/mnt/storage`.
- `DEST_DIR` — padrão `/mnt/storage/nextcloud-data`.
- `NC_PREFIX` — prefixo dos containers do app (`nextcloud` por padrão → `nextcloud_web_1`, etc.).
- `WWW_UID`/`WWW_GID` — usuário/grupo do webserver no container (padrão `33:33` → `www-data`).

---

### 🚀 Uso rápido
```bash
chmod +x migrate-nextcloud-umbrelos.sh
# (Opcional) edite o UUID no topo do script (STORAGE_UUID)
sudo bash ./migrate-nextcloud-umbrelos.sh

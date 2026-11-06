#!/bin/bash
set -euo pipefail

# =====================
# Cores
# =====================
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✔ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
err()  { echo -e "${RED}✖ $1${NC}"; exit 1; }
info() { echo -e "${CYAN}➜ $1${NC}"; }

# =====================
# Header
# =====================
clear
echo -e "${BLUE}"
echo "╔══════════════════════════════╗"
echo "║   Freebuff Installer 💻      ║"
echo "╚══════════════════════════════╝"
echo -e "${NC}"

# =====================
# Spinner
# =====================
spinner() {
    local pid=$1
    local msg="$2"
    local spin='⠋⠙⠸⠴⠦⠇'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r\033[K${CYAN}%s${NC} %s" "${spin:i++%${#spin}:1}" "$msg"
        sleep 0.08
    done

    printf "\r\033[K"
}

# =====================
# Arquitetura
# =====================
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) err "Arquitetura não suportada: $ARCH_RAW" ;;
esac
ok "Arquitetura: $ARCH"

# =====================
# Dependências
# =====================
DEPS=(curl jq pv)
missing=()

for d in "${DEPS[@]}"; do
    command -v "$d" &>/dev/null || missing+=("$d")
done

if [ "${#missing[@]}" -ne 0 ]; then
    warn "Instalando dependências: ${missing[*]}"
    if ! sudo -n true &>/dev/null; then
        echo
        err "Sem acesso sudo disponível (sem timestamp). Execute o script como root ou com sudo e tente novamente."
    fi
    if command -v dnf &>/dev/null; then
        sudo dnf install -y "${missing[@]}" || err "Falha ao instalar as dependências (dnf)"
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm "${missing[@]}" || err "Falha ao instalar as dependências (pacman)"
    else
        err "Gerenciador de pacotes não suportado. Instale manualmente: curl, jq e pv."
    fi
    ok "Dependências prontas"
else
    ok "Dependências OK"
fi

# =====================
# Diretório
# =====================
FREEBUFF_DIR="$HOME/Freebuff"
mkdir -p "$FREEBUFF_DIR"

# =====================
# Download direto (AppImage x86_64)
# =====================
info "Buscando Freebuff..."

case "$ARCH" in
    x86_64) APPIMAGE_URL="https://freebuff.com/api/desktop/download/linux-appimage" ;;
    aarch64) APPIMAGE_URL="https://freebuff.com/api/desktop/download/linux-arm64-appimage" ;;
esac
APPIMAGE="$FREEBUFF_DIR/Freebuff.AppImage"

# Valida se o arquivo é um AppImage (ELF) da arquitetura esperada
# retorno: 0 = OK | 1 = não é AppImage | 2 = AppImage, arquitetura errada (ou indefinida)
check_appimage_arch() {
    local f="$1" exp_arch magic emach
    exp_arch="$2"
    [[ -s "$f" ]] || return 1
    magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]] || return 1
    emach="$(od -An -tx1 -j18 -N2 "$f" 2>/dev/null | tr -d ' \n')"
    [[ -n "$emach" ]] || return 1
    case "$exp_arch" in
        x86_64) [[ "$emach" == "3e00" ]] || return 2 ;;
        aarch64) [[ "$emach" == "b700" ]] || return 2 ;;
        *) return 2 ;;
    esac
    return 0
}

shopt -s nullglob

# =====================
# Limpeza de downloads anteriores
# =====================
for old in "$FREEBUFF_DIR"/*.deb; do
    warn "Removendo .deb de instalação antiga: $(basename "$old")"
    rm -f "$old"
done

for old in "$FREEBUFF_DIR"/*.AppImage; do
    if check_appimage_arch "$old" "$ARCH"; then
        continue
    fi
    warn "Removendo AppImage inválido/não $ARCH: $(basename "$old")"
    rm -f "$old"
done

# =====================
# Reinstalar
# =====================
if [[ -f "$APPIMAGE" ]] && check_appimage_arch "$APPIMAGE" "$ARCH"; then
    warn "Já instalado ($(basename "$APPIMAGE"))"
    read -p "Reinstalar? (y/n) " r
    [[ ! "$r" =~ ^[Yy]$ ]] && exit 0
fi

shopt -u nullglob

# =====================
# Download
# =====================
echo
info "Baixando Freebuff (AppImage $ARCH)..."

TMP_DOWNLOAD="$(mktemp "$FREEBUFF_DIR/.freebuff-download.XXXXXX")"
trap 'rm -f "$TMP_DOWNLOAD"' EXIT

curl -Lfs "$APPIMAGE_URL" -o - \
| pv -w 60 -p -t -e -r -b -F "%b %t [%r] [%40b]" \
> "$TMP_DOWNLOAD"

check_appimage_arch "$TMP_DOWNLOAD" "$ARCH"
case $? in
    0) : ;;
    2) rm -f "$TMP_DOWNLOAD"; err "O download veio em arquitetura $ARCH (não $ARCH). Nada foi instalado." ;;
    *) rm -f "$TMP_DOWNLOAD"; err "O arquivo baixado não é um AppImage válido. Nada foi instalado." ;;
esac

chmod +x "$TMP_DOWNLOAD"
mv -f "$TMP_DOWNLOAD" "$APPIMAGE"
echo
ok "Download concluído"
ok "Arquivo: $APPIMAGE (AppImage $ARCH)"

# =====================
# Wrapper (detecta AppImage mais recente)
# =====================
WRAPPER="$FREEBUFF_DIR/freebuff-launcher.sh"

cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/bin/bash
FREEBUFF_DIR="$HOME/Freebuff"
APPIMAGE=$(ls -t "$FREEBUFF_DIR"/*.AppImage 2>/dev/null | head -n1)

if [[ -z "$APPIMAGE" ]]; then
    notify-send "Freebuff" "Nenhum AppImage encontrado em $FREEBUFF_DIR"
    exit 1
fi

exec "$APPIMAGE" "$@"
WRAPPER_EOF

chmod +x "$WRAPPER"
ok "Wrapper criado"

# =====================
# Ícone
# =====================
info "Baixando ícone..."

ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$ICON_DIR"

ICON_RAW_URL="https://github.com/InoCity/Freebuff-installer/blob/main/freebuff-logo.png?raw=true"
ICON_DEST="$ICON_DIR/freebuff.png"

if curl -sL "$ICON_RAW_URL" -o "$ICON_DEST" && [[ -s "$ICON_DEST" ]]; then
    ok "Ícone baixado e instalado"
else
    warn "Não foi possível baixar o ícone"
    rm -f "$ICON_DEST"
fi

# =====================
# Desktop
# =====================
mkdir -p "$HOME/.local/share/applications"

# Remove .desktop de instalações anteriores deste script
rm -f "$HOME/.local/share/applications/freebuff.desktop"
rm -f "$HOME/.local/share/applications/com.freebuff.desktop"

if [[ -f "$ICON_DEST" ]]; then
    ICON_VALUE="freebuff"
else
    ICON_VALUE="application-x-executable"
fi

DESKTOP_FILE="$HOME/.local/share/applications/com.freebuff.desktop"

# O .desktop aponta para o wrapper, que sempre encontra o AppImage mais recente
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Freebuff
Exec=$WRAPPER
Type=Application
Categories=AudioVideo;Music;
Terminal=false
Icon=$ICON_VALUE
StartupWMClass=freebuff
EOF

chmod +x "$DESKTOP_FILE"

# Atualiza os caches para o ícone/atalho aparecerem imediatamente
command -v update-desktop-database &>/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache &>/dev/null && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

ok "Atalho criado"

# =====================
# Final
# =====================
echo
echo -e "${GREEN}╔══════════════════════════════╗${NC}"
echo -e "${GREEN}║   Instalação concluída ✅    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════╝${NC}"
echo
echo "Se ainda assim o ícone não pegar na taskbar/dock, feche o app completamente"
echo "(inclusive o processo em segundo plano) e abra de novo — o cache de ícones"
echo "às vezes só atualiza depois de reiniciar o app ou a sessão."
echo

read -p "Executar agora? (y/n) " r
[[ "$r" =~ ^[Yy]$ ]] && "$WRAPPER" &

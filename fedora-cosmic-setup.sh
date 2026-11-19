#!/usr/bin/env bash
# =============================================================================
#  fedora-cosmic-setup.sh  -  Setup automatico Fedora (o derivate: Nobara...)
#
#  Uso (da curl):
#    curl -fsSL https://TUO-URL/fedora-cosmic-setup.sh | sudo bash
#    curl -fsSL https://TUO-URL/fedora-cosmic-setup.sh | sudo bash -s -- --skip=remove-de --yes
#
#  Opzioni:
#    --skip=a,b     salta gli step indicati
#    --only=a,b     esegue SOLO gli step indicati
#    --force        riesegue anche gli step già completati
#    --yes | -y     niente conto alla rovescia prima di rimuovere i DE
#    --reboot       riavvia alla fine
#    --list         mostra gli step
#  Variabili: TARGET_USER, WALLPAPER (percorso dell'immagine di sfondo per xfdesktop)
#
#  Step (in ordine): repos system cosmic audio gnome-apps backup shell devtools
#                    desktop theme remove-de
# =============================================================================
set -Eeuo pipefail

LOG=/var/log/fedora-cosmic-setup.log
STATE_DIR=/var/lib/fedora-cosmic-setup
BACKUP_DIR=/var/backups/fedora-cosmic-setup/$(date +%Y%m%d-%H%M%S)
STEPS=(repos system cosmic audio gnome-apps backup shell devtools desktop theme remove-de)

SKIP="${SKIP:-}"; ONLY="${ONLY:-}"; FORCE=0; ASSUME_YES=0; DO_REBOOT=0
TARGET_USER="${TARGET_USER:-}"; TARGET_HOME=""
SKIPFLAG=""
TMP=""
OK=(); FAILED=(); SKIPPED=()

# ---------------------------------------------------------------- utilità ----
C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_0=$'\e[0m'
C_M=$'\e[95m'; C_C=$'\e[96m'; C_BD=$'\e[1m'; C_DIM=$'\e[2m'
STEP_I=0; STEP_N=${#STEPS[@]}
info() { echo "${C_B}[i]${C_0} $*"; }
ok()   { echo "${C_G}[ok]${C_0} $*"; }
warn() { echo "${C_Y}[!]${C_0} $*" >&2; }
err()  { echo "${C_R}[x]${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }

banner() {
  echo "${C_C}${C_BD}"
  cat <<'ART'
 _____ _____ ____   ___  ____      _
|  ___| ____|  _ \ / _ \|  _ \    / \
| |_  |  _| | | | | | | | |_) |  / _ \
|  _| | |___| |_| | |_| |  _ <  / ___ \
|_|   |_____|____/ \___/|_| \_\/_/   \_\
ART
  echo "${C_M}"
  cat <<'ART'
  ____ ___  ____  __  __ ___ ____
 / ___/ _ \/ ___||  \/  |_ _/ ___|
| |  | | | \___ \| |\/| || | |
| |__| |_| |___) | |  | || | |___
 \____\___/|____/|_|  |_|___\____|
ART
  echo "${C_0}${C_DIM}            S E T U P   A U T O M A T I C O${C_0}"
  echo
}

progress_bar() { # progress_bar fatti totale [etichetta]
  local done=$1 total=$2 label=${3:-} width=30 filled pct i bar=""
  (( total > 0 )) || total=1
  filled=$(( done * width / total )); pct=$(( done * 100 / total ))
  for ((i = 0; i < width; i++)); do
    if (( i < filled )); then bar+="█"; else bar+="░"; fi
  done
  echo "${C_C}[${C_G}${bar}${C_C}]${C_0} ${C_BD}${pct}%${C_0} (${done}/${total}) ${label}"
}

retry() { # retry N comando...
  local n=$1 i; shift
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    warn "tentativo $i/$n fallito: $*"; sleep $((i * 3))
  done
  return 1
}

backup_file() { # copia di sicurezza prima di toccare un file
  [[ -e $1 ]] || return 0
  mkdir -p "$BACKUP_DIR$(dirname "$1")"
  cp -a "$1" "$BACKUP_DIR$1"
}

wait_pkg_lock() {
  local i
  for i in {1..45}; do
    pgrep -x 'dnf|dnf5|yum|rpm' >/dev/null || return 0
    sleep 2
  done
  warn "un altro gestore pacchetti è ancora attivo, procedo comunque"
}

# Installa una lista di pacchetti: prima in blocco, poi uno per uno.
# Un pacchetto mancante NON blocca lo script.
pkgs() {
  wait_pkg_lock
  if retry 2 dnf -y install "$SKIPFLAG" "${DNF_OPTS[@]}" "$@"; then return 0; fi
  warn "installazione in blocco fallita, provo pacchetto per pacchetto"
  local p
  for p in "$@"; do
    [[ $p == @* ]] && continue
    rpm -q "$p" &>/dev/null && continue
    retry 2 dnf -y install "${DNF_OPTS[@]}" "$p" || warn "salto $p (non disponibile)"
  done
  return 0
}
DNF_OPTS=()

run_as_user() { runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"; }

need_user() {
  [[ -n $TARGET_USER ]] || die "nessun utente normale trovato: usa TARGET_USER=nome"
}

skip_step() {
  [[ -n $ONLY && ,$ONLY, != *",$1,"* ]] && return 0
  [[ ,$SKIP, == *",$1,"* ]]
}

run_step() {
  local name=$1 fn="step_${1//-/_}" rc
  STEP_I=$((STEP_I + 1))
  if skip_step "$name"; then SKIPPED+=("$name"); return 0; fi
  if [[ -f $STATE_DIR/$name.done && $FORCE -ne 1 ]]; then
    SKIPPED+=("$name (già fatto)"); return 0
  fi
  echo
  progress_bar $((STEP_I - 1)) "$STEP_N" "${C_DIM}in corso:${C_0} ${C_M}${C_BD}$name${C_0}"
  info "${C_BD}==================== $name ====================${C_0}"
  set +e
  ( set -Eeuo pipefail; trap 'warn "errore riga $LINENO: $BASH_COMMAND"' ERR; "$fn" )
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    OK+=("$name"); touch "$STATE_DIR/$name.done"
  else
    FAILED+=("$name"); err "step '$name' fallito (codice $rc), continuo con gli altri"
  fi
}

# --------------------------------------------------------------- preflight ---
preflight() {
  [[ $EUID -eq 0 ]] || die "esegui come root:  curl -fsSL URL | sudo bash"
  [[ -r /etc/os-release ]] || die "/etc/os-release mancante"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == fedora || ${ID_LIKE:-} == *fedora* ]] || die "distro non supportata (serve Fedora o derivata)"
  [[ -e /run/ostree-booted ]] && die "sistema atomic/ostree (Silverblue, Kinoite...) non supportato"
  command -v dnf >/dev/null || die "dnf non trovato"
  [[ $(uname -m) == x86_64 ]] || warn "architettura $(uname -m): alcuni step potrebbero non funzionare"

  local free_gb boot_mb
  free_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
  (( free_gb >= 10 )) || die "spazio insufficiente su / (${free_gb}G liberi, ne servono almeno 10G)"
  boot_mb=$(df --output=avail -BM /boot | tail -1 | tr -dc '0-9')
  (( boot_mb >= 150 )) || warn "poco spazio su /boot (${boot_mb}M)"

  retry 3 curl -fsS --max-time 15 -o /dev/null https://mirrors.fedoraproject.org/ \
    || die "nessuna connessione a internet / ai mirror Fedora"

  exec 9>/var/lock/fedora-cosmic-setup.lock
  flock -n 9 || die "un'altra istanza dello script è già in esecuzione"

  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  TMP=$(mktemp -d /tmp/fcs.XXXXXX)

  if dnf --version 2>/dev/null | grep -qi dnf5; then SKIPFLAG="--skip-unavailable"; else SKIPFLAG="--setopt=strict=0"; fi

  # utente di destinazione per le configurazioni personali
  if [[ -z $TARGET_USER ]]; then TARGET_USER="${SUDO_USER:-}"; fi
  if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
    TARGET_USER=$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7!~/nologin|false/ {print $1; exit}')
  fi
  if [[ -n $TARGET_USER ]]; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    [[ -d $TARGET_HOME ]] || { warn "home di $TARGET_USER non trovata"; TARGET_USER=""; }
  fi
  info "Sistema: ${PRETTY_NAME:-Fedora} | utente: ${TARGET_USER:-<nessuno>} | log: $LOG"
}

# ============================================================ 0) REPOSITORY ==
step_repos() {
  pkgs dnf-plugins-core curl ca-certificates flatpak python3 xz tar
  if dnf --version 2>/dev/null | grep -qi dnf5; then pkgs dnf5-plugins; fi

  # dnf più veloce e tollerante verso mirror/repo che non rispondono
  backup_file /etc/dnf/dnf.conf
  grep -q '^max_parallel_downloads' /etc/dnf/dnf.conf || echo 'max_parallel_downloads=10' >> /etc/dnf/dnf.conf
  grep -q '^skip_if_unavailable' /etc/dnf/dnf.conf   || echo 'skip_if_unavailable=True' >> /etc/dnf/dnf.conf

  # RPM Fusion (codec, driver, giochi). Nobara lo ha già.
  local fv; fv=$(rpm -E %fedora)
  if ! rpm -q rpmfusion-free-release &>/dev/null; then
    retry 3 dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fv}.noarch.rpm" \
      || warn "RPM Fusion free non installato"
  fi
  if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
    retry 3 dnf -y install "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fv}.noarch.rpm" \
      || warn "RPM Fusion nonfree non installato"
  fi

  # Flathub
  retry 3 flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
    || warn "Flathub non aggiunto"

  # metadati: se falliscono, pulisco la cache e riprovo
  if ! retry 2 dnf -y makecache; then
    dnf -y clean all || true
    retry 3 dnf -y makecache || die "impossibile aggiornare i metadati dei repository"
  fi
  ok "repository pronti"
}

# ============================ ORA (dual boot Windows) + SUDO PASSWORD ========
step_system() {
  # --- orario: Linux e Windows leggono l'orologio hardware in modo diverso.
  # Metto l'RTC in "ora locale" (come Windows) cosi' l'ora non sballa tra i due sistemi.
  timedatectl set-ntp true 2>/dev/null || warn "impossibile attivare la sincronizzazione NTP"
  if timedatectl set-local-rtc 1 --adjust-system-clock 2>/dev/null; then
    ok "orologio hardware in ora locale (compatibile con Windows)"
  else
    warn "impossibile impostare l'RTC in ora locale"
  fi
  info "fuso orario attuale: $(timedatectl show -p Timezone --value 2>/dev/null || echo ?)"

  # --- sudo: mostra gli asterischi mentre scrivi la password
  local f=/etc/sudoers.d/90-pwfeedback
  backup_file "$f"
  printf 'Defaults pwfeedback\n' > "$TMP/pwfeedback"
  if visudo -cf "$TMP/pwfeedback" >/dev/null; then       # valido PRIMA di installare, per non rompere sudo
    install -m 0440 -o root -g root "$TMP/pwfeedback" "$f"
    visudo -c >/dev/null || { rm -f "$f"; die "sudoers non valido, modifica annullata"; }
    ok "sudo mostra gli asterischi (pwfeedback)"
  else
    die "regola sudoers non valida, non la installo"
  fi
}

# ================================================================ 2) COSMIC ===
step_cosmic() {
  local g done=0
  for g in cosmic-desktop-environment cosmic-desktop; do
    wait_pkg_lock
    if retry 2 dnf -y group install "$SKIPFLAG" "$g"; then done=1; break; fi
  done
  if [[ $done -eq 0 ]]; then
    warn "gruppo COSMIC non trovato, installo i pacchetti singoli"
    pkgs cosmic-session cosmic-greeter cosmic-comp cosmic-panel cosmic-launcher cosmic-settings \
         cosmic-settings-daemon cosmic-files cosmic-term cosmic-edit cosmic-store cosmic-applets \
         cosmic-bg cosmic-osd cosmic-workspaces cosmic-app-library cosmic-notifications \
         cosmic-idle cosmic-initial-setup xdg-desktop-portal-cosmic cosmic-player
  fi

  # senza questi due NON si tocca nulla
  rpm -q cosmic-session cosmic-greeter &>/dev/null \
    || die "COSMIC non risulta installato: interrompo (non rimuovo altri DE)"

  # login manager: cosmic-greeter al posto di gdm/sddm/lightdm
  local dm
  for dm in gdm sddm lightdm lxdm; do
    systemctl list-unit-files "$dm.service" &>/dev/null && systemctl disable "$dm.service" 2>/dev/null || true
  done
  systemctl enable --force cosmic-greeter.service
  systemctl set-default graphical.target
  # schermata di login = quella di COSMIC (cosmic-greeter): controllo che sia davvero lei il display manager
  local dmtarget; dmtarget=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
  [[ $dmtarget == *cosmic-greeter* ]] || warn "display-manager.service punta a '${dmtarget:-nulla}', non a cosmic-greeter"
  ok "COSMIC installato, login = cosmic-greeter"
}

# ============================================================== 3) AUDIO ======
step_audio() {
  pkgs pipewire wireplumber pipewire-alsa pipewire-pulseaudio alsa-utils pavucontrol
  local wpv; wpv=$(wireplumber --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
  if [[ -n $wpv && ${wpv%%.*} -eq 0 && ${wpv##*.} -lt 5 ]]; then
    warn "WirePlumber $wpv (<0.5): configurazione non supportata da questo script"; return 0
  fi

  # Schede audio che hanno SOLO codec HDMI/DisplayPort (le GPU). L'audio analogico non si tocca.
  local card n codecs pci name rules=""
  for card in /sys/class/sound/card[0-9]*; do
    [[ -e $card/device ]] || continue
    n=${card##*card}
    codecs=$(cat /proc/asound/card"$n"/codec#* 2>/dev/null | grep -E '^Codec:' || true)
    [[ -n $codecs ]] || continue
    if grep -qviE 'hdmi|displayport|\bdp\b|gpu' <<<"$codecs"; then continue; fi
    pci=$(basename "$(readlink -f "$card/device")")
    [[ $pci =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$ ]] || continue
    name="alsa_card.pci-${pci//:/_}"
    info "scheda HDMI/DP trovata: $name"
    rules+="    { matches = [ { device.name = \"$name\" } ]
      actions = { update-props = {
        api.acp.auto-profile = false
        api.acp.auto-port = false
        device.profile = \"pro-audio\"
      } } }
"
  done

  if [[ -z $rules ]]; then
    warn "nessuna scheda audio HDMI/DP rilevata ora (driver non caricato?). Rilancia: --only=audio --force"
    return 0
  fi

  mkdir -p /etc/wireplumber/wireplumber.conf.d
  backup_file /etc/wireplumber/wireplumber.conf.d/51-split-hdmi-dp.conf
  cat > /etc/wireplumber/wireplumber.conf.d/51-split-hdmi-dp.conf <<EOF
# Ogni uscita HDMI/DP della GPU diventa un dispositivo audio separato
monitor.alsa.rules = [
$rules]
EOF
  ok "uscite HDMI/DP separate (effettivo dopo il riavvio / riavvio di wireplumber)"
}

# ============================================================ 4) APP GNOME ====
step_gnome_apps() {
  DNF_OPTS=(--setopt=install_weak_deps=False)   # niente dipendenze opzionali che richiamerebbero GNOME Shell
  pkgs gparted gnome-disk-utility baobab gnome-system-monitor gnome-screenshot gnome-calculator \
       gnome-font-viewer gnome-logs loupe papers file-roller gnome-characters
  ok "app GNOME installate"
}

# ================================================================ 5) BACKUP ===
step_backup() {
  pkgs timeshift rsync restic
  if command -v flatpak >/dev/null; then
    retry 2 flatpak install --system -y --noninteractive flathub org.gnome.World.PikaBackup \
      || { warn "Pika Backup (flatpak) non installato, uso Déjà Dup"; pkgs deja-dup; }
  fi
  ok "backup: Timeshift (sistema) + Pika Backup (file personali) + restic"
}

# ============================================================ 7) KITTY + ZSH ==
step_shell() {
  need_user
  pkgs kitty zsh zsh-autosuggestions zsh-syntax-highlighting zsh-completions fzf git \
       jetbrains-mono-fonts-all fontconfig util-linux-user starship tldr
  local ts; ts=$(date +%s)
  if [[ -e $TARGET_HOME/.zshrc ]] && ! grep -q 'fedora-cosmic-setup' "$TARGET_HOME/.zshrc"; then
    cp -a "$TARGET_HOME/.zshrc" "$TARGET_HOME/.zshrc.bak-$ts"
  fi
  cat > "$TARGET_HOME/.zshrc" <<'EOF'
# fedora-cosmic-setup: configurazione zsh

# --- cronologia ---
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY INC_APPEND_HISTORY EXTENDED_HISTORY
setopt HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS HIST_FIND_NO_DUPS HIST_REDUCE_BLANKS HIST_IGNORE_SPACE
setopt AUTO_CD INTERACTIVE_COMMENTS

# --- completamento (aiuto comandi con TAB) ---
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{magenta}-- %d --%f'

# --- frecce su/giù cercano nella cronologia in base a quanto scritto ---
autoload -U up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
bindkey '^[OA' up-line-or-beginning-search
bindkey '^[OB' down-line-or-beginning-search

# --- fzf: Ctrl+R cerca nella cronologia, Ctrl+T file, Alt+C cartelle ---
for f in /usr/share/fzf/shell/key-bindings.zsh /usr/share/fzf/key-bindings.zsh; do
  [[ -r $f ]] && source "$f" && break
done

# --- "comando non trovato": suggerisce il pacchetto da installare ---
command_not_found_handler() {
  if [[ -x /usr/libexec/pk-command-not-found ]]; then
    /usr/libexec/pk-command-not-found "$@"
  else
    print -u2 "zsh: comando non trovato: $1"
  fi
  return 127
}

# --- alias utili ---
alias ll='ls -lah --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias update='sudo dnf upgrade --refresh'

# --- prompt ---
if command -v starship >/dev/null; then
  eval "$(starship init zsh)"
else
  PROMPT='%F{magenta}%n%f@%F{cyan}%m%f %F{green}%~%f %# '
fi

# --- suggerimenti in grigio mentre scrivi + colori sintassi (syntax-highlighting SEMPRE ultimo) ---
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
[[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF
  chown "$TARGET_USER:" "$TARGET_HOME/.zshrc"

  if [[ -x /usr/bin/zsh ]]; then usermod -s /usr/bin/zsh "$TARGET_USER" || warn "impossibile impostare zsh come shell"; fi
  fc-cache -f >/dev/null 2>&1 || true
  ok "kitty + zsh (suggerimenti, completamento, cronologia, fzf)"
}

# ============================================================ 8) VS CODE ======
step_devtools() {
  retry 3 rpm --import https://packages.microsoft.com/keys/microsoft.asc \
    || die "impossibile importare la chiave Microsoft"
  backup_file /etc/yum.repos.d/vscode.repo
  cat > /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
skip_if_unavailable=1
EOF
  retry 2 dnf -y makecache || warn "makecache con repo VS Code fallito"
  pkgs code

  # linguaggi e toolchain
  pkgs gcc gcc-c++ clang clang-tools-extra cmake ninja-build make gdb valgrind \
       python3 python3-pip python3-devel python3-virtualenv pipx \
       rust cargo rustfmt clippy rust-analyzer \
       java-latest-openjdk-devel java-21-openjdk-devel maven gradle \
       golang nodejs npm git

  # estensioni VS Code (non bloccanti)
  if [[ -n $TARGET_USER ]] && command -v code >/dev/null; then
    local ext
    for ext in ms-vscode.cpptools ms-vscode.cmake-tools ms-python.python rust-lang.rust-analyzer \
               vscjava.vscode-java-pack golang.go; do
      timeout 180 runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" code --install-extension "$ext" --force >/dev/null 2>&1 \
        && info "estensione $ext" || warn "estensione $ext non installata (puoi farlo dopo da VS Code)"
    done
  fi
  ok "VS Code + C/C++, Python, Rust, Java, Go, Node"
}

# ================= XFDESKTOP (icone sul desktop) + PAPIRUS ====================
find_wallpaper() {  # $WALLPAPER > immagine "papirus" trovata nel sistema > sfondo di default
  local w=""
  if [[ -n ${WALLPAPER:-} && -f $WALLPAPER ]]; then echo "$WALLPAPER"; return 0; fi
  w=$(find /usr/share/backgrounds /usr/share/wallpapers "$TARGET_HOME/Pictures" "$TARGET_HOME/.local/share/backgrounds" \
        -type f -iname '*pap[iy]rus*' \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        2>/dev/null | head -1 || true)
  if [[ -z $w ]]; then
    w=$(find /usr/share/backgrounds -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' \) \
          2>/dev/null | head -1 || true)
  fi
  echo "$w"
}

set_gtk_icon_theme() {  # $1 = nome tema
  local d file key=gtk-icon-theme-name
  for d in gtk-3.0 gtk-4.0; do
    file=$TARGET_HOME/.config/$d/settings.ini
    mkdir -p "$(dirname "$file")"
    backup_file "$file"
    if [[ ! -e $file ]]; then
      printf '[Settings]\n%s=%s\n' "$key" "$1" > "$file"
    elif grep -q "^$key=" "$file"; then
      sed -i "s|^$key=.*|$key=$1|" "$file"
    elif grep -q '^\[Settings\]' "$file"; then
      sed -i "/^\[Settings\]/a $key=$1" "$file"
    else
      printf '\n[Settings]\n%s=%s\n' "$key" "$1" >> "$file"
    fi
    chown -R "$TARGET_USER:" "$TARGET_HOME/.config/$d"
  done
}

step_desktop() {
  need_user
  pkgs papirus-icon-theme xfdesktop thunar xfconf gtk-layer-shell wlr-randr dbus-tools
  rpm -q papirus-icon-theme &>/dev/null || warn "papirus-icon-theme non installato"
  command -v xfdesktop >/dev/null || [[ -x $TARGET_HOME/.local/bin/xfdesktop ]] \
    || die "xfdesktop non disponibile"

  # --- Papirus: icone per xfdesktop (GTK) e per COSMIC
  set_gtk_icon_theme Papirus-Dark
  mkdir -p "$TARGET_HOME/.config/cosmic/com.system76.CosmicTk/v1"
  printf '"Papirus-Dark"' > "$TARGET_HOME/.config/cosmic/com.system76.CosmicTk/v1/icon_theme"
  chown -R "$TARGET_USER:" "$TARGET_HOME/.config/cosmic"

  # --- sfondo
  local wall; wall=$(find_wallpaper)
  mkdir -p /etc/xfdesktop-cosmic
  if [[ -n $wall ]]; then
    printf '%s\n' "$wall" > /etc/xfdesktop-cosmic/wallpaper
    info "sfondo: $wall"
  else
    warn "nessuno sfondo trovato: rilancia con WALLPAPER=/percorso/immagine --only=desktop --force"
  fi

  # --- launcher: avvia xfdesktop e lo tiene vivo
  cat > /usr/local/bin/xfdesktop-cosmic <<'XFD'
#!/usr/bin/env bash
# xfdesktop sempre attivo: parte al login, riparte se muore o se cambia lo stato
# (monitor collegato/scollegato, risveglio dalla sospensione, sblocco schermo)
exec 8>"${XDG_RUNTIME_DIR:-/tmp}/xfdesktop-cosmic.lock"
flock -n 8 || exit 0

bin=$(command -v xfdesktop || true)
[[ -x $HOME/.local/bin/xfdesktop ]] && bin=$HOME/.local/bin/xfdesktop   # build Wayland personale
[[ -n $bin ]] || { logger -t xfdesktop-cosmic "xfdesktop non trovato"; exit 1; }
export LD_LIBRARY_PATH="$HOME/.local/lib64:$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

args=()
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  if ldd "$bin" 2>/dev/null | grep -q gtk-layer-shell; then
    export GDK_BACKEND=wayland
  else
    export GDK_BACKEND=x11; args+=(--disable-wm-check)
    logger -t xfdesktop-cosmic "xfdesktop senza supporto Wayland: uso XWayland"
  fi
fi

apply_wallpaper() {
  local img prop mon list
  img=$(cat /etc/xfdesktop-cosmic/wallpaper 2>/dev/null) || return 0
  [[ -f $img ]] || return 0
  list=$(wlr-randr 2>/dev/null | awk '/^[^ ]/{print $1}')
  [[ -n $list ]] || list=$(xrandr --listmonitors 2>/dev/null | awk 'NR>1{print $4}')
  {
    xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/last-image$'
    for mon in $list; do echo "/backdrop/screen0/monitor${mon}/workspace0/last-image"; done
  } | sort -u | while read -r prop; do
    xfconf-query -c xfce4-desktop -p "$prop" -n -t string -s "$img" 2>/dev/null
    xfconf-query -c xfce4-desktop -p "${prop%last-image}image-style" -n -t int -s 5 2>/dev/null
  done
  "$bin" --reload 2>/dev/null || true
}

start() {
  "$bin" --quit 2>/dev/null; pkill -u "$UID" -x xfdesktop 2>/dev/null
  "$bin" "${args[@]}" &
  pid=$!
  ( sleep 3; apply_wallpaper ) &
}

main=$$; want=0; pid=""
trap 'want=1' USR1
trap 'pkill -P $main 2>/dev/null' EXIT TERM INT

# eventi: hotplug monitor, risveglio dalla sospensione, sblocco schermo
udevadm monitor --udev --subsystem-match=drm 2>/dev/null \
  | while read -r l; do [[ $l == UDEV*" change "* ]] && kill -USR1 "$main"; done &
dbus-monitor --system \
    "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" \
    "type='signal',interface='org.freedesktop.login1.Session',member='Unlock'" 2>/dev/null \
  | while read -r l; do [[ $l == *"boolean false"* || $l == *"member=Unlock"* ]] && kill -USR1 "$main"; done &

start
while sleep 1; do
  if ! kill -0 "$pid" 2>/dev/null; then          # è morto: riparte
    sleep 2; start
  elif (( want )); then                           # cambio di stato: riavvio pulito
    sleep 2; want=0
    "$bin" --quit 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    start
  fi
done
XFD
  chmod 755 /usr/local/bin/xfdesktop-cosmic

  # --- avvio automatico al login (per tutti gli utenti)
  cat > /etc/xdg/autostart/xfdesktop-cosmic.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Desktop (xfdesktop)
Exec=/usr/local/bin/xfdesktop-cosmic
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  ok "Papirus + xfdesktop installati, avvio automatico e riavvio a ogni cambio di stato"
}

# ============================= TEMA COSMIC "GARGANTUA" =======================
# Palette presa dal buco nero: nero caldo, marroni bruciati, ambra e crema.
# Pannelli, finestre e popup semitrasparenti con sfocatura; stesso stile su kitty.
step_theme() {
  need_user
  local cfg="$TARGET_HOME/.config/cosmic" ron="$TARGET_HOME/Gargantua.ron" p

  backup_file "$ron"
  cat > "$ron" <<'RON'
(
    palette: Dark((
        name: "Gargantua",
        bright_red: "#FFA09AFF", bright_green: "#5EDB8CFF", bright_orange: "#FFA37DFF",
        gray_1: "#14100DFF", gray_2: "#1E1814FF",
        neutral_0: "#000000FF", neutral_1: "#050302FF", neutral_2: "#14100DFF",
        neutral_3: "#2A211CFF", neutral_4: "#463930FF", neutral_5: "#64534AFF",
        neutral_6: "#866759FF", neutral_7: "#A68B7CFF", neutral_8: "#C7AEA0FF",
        neutral_9: "#E6D1CDFF", neutral_10: "#FFF8F2FF",
        accent_blue: "#63D0DFFF", accent_indigo: "#A1C0EBFF", accent_purple: "#E79CFEFF",
        accent_pink: "#FF9CB1FF", accent_red: "#FDA1A0FF", accent_orange: "#FFAD00FF",
        accent_yellow: "#F7E062FF", accent_green: "#92CF9CFF", accent_warm_grey: "#CABAB4FF",
        ext_warm_grey: "#9B8E8AFF", ext_orange: "#FFAD00FF", ext_yellow: "#FEDB40FF",
        ext_blue: "#48B9C7FF", ext_purple: "#CF7DFFFF", ext_pink: "#F93A83FF", ext_indigo: "#3E88FFFF",
    )),
    spacing: (space_none: 0, space_xxxs: 4, space_xxs: 8, space_xs: 12, space_s: 16,
              space_m: 24, space_l: 32, space_xl: 48, space_xxl: 64, space_xxxl: 128),
    corner_radii: (radius_0: (0.0, 0.0, 0.0, 0.0), radius_xs: (4.0, 4.0, 4.0, 4.0),
                   radius_s: (8.0, 8.0, 8.0, 8.0), radius_m: (16.0, 16.0, 16.0, 16.0),
                   radius_l: (32.0, 32.0, 32.0, 32.0), radius_xl: (160.0, 160.0, 160.0, 160.0)),
    neutral_tint: Some("#342924"),
    bg_color: Some("#0A0705FF"),
    primary_container_bg: Some("#17110EFF"),
    secondary_container_bg: Some("#221913FF"),
    text_tint: Some("#F3E3D3"),
    accent: Some("#E8A05A"),
    success: Some("#A8C686"),
    warning: Some("#F2B24C"),
    destructive: Some("#E5604D"),
    frosted: High,
    is_frosted: true,
    gaps: (0, 8),
    active_hint: 3,
    window_hint: Some("#E8A05A"),
    frosted_windows: true,
    frosted_system_interface: true,
    frosted_panel: true,
    frosted_applets: true,
    frosted_maximized_apps: false,
    icon_theme: "Papirus-Dark",
)
RON

  # modalità scura fissa
  mkdir -p "$cfg/com.system76.CosmicTheme.Mode/v1"
  printf 'true'  > "$cfg/com.system76.CosmicTheme.Mode/v1/is_dark"
  printf 'false' > "$cfg/com.system76.CosmicTheme.Mode/v1/auto_switch"

  # pannello e dock semitrasparenti
  for p in Panel Dock; do
    mkdir -p "$cfg/com.system76.CosmicPanel.$p/v1"
    backup_file "$cfg/com.system76.CosmicPanel.$p/v1/opacity"
    printf '0.6' > "$cfg/com.system76.CosmicPanel.$p/v1/opacity"
  done


  # --- kitty: stesso tema, trasparente, con le schede IN ALTO
  local ts; ts=$(date +%s)
  mkdir -p "$TARGET_HOME/.config/kitty"
  [[ -e $TARGET_HOME/.config/kitty/kitty.conf ]] && cp -a "$TARGET_HOME/.config/kitty/kitty.conf" "$TARGET_HOME/.config/kitty/kitty.conf.bak-$ts"
  cat > "$TARGET_HOME/.config/kitty/kitty.conf" <<'EOF'
# --- Kitty: tema Gargantua (nero caldo, ambra, crema) ---
font_family      JetBrains Mono
font_size        12.0
shell            zsh
scrollback_lines 20000
enable_audio_bell no
confirm_os_window_close 0
window_padding_width 8
remember_window_size yes

# trasparenza + blur
background_opacity 0.80
background_blur    40

# cursore animato (scia) e lampeggio morbido
cursor_shape beam
cursor_blink_interval 0.5 ease-in-out
cursor_trail 3
cursor_trail_decay 0.1 0.4

# schede IN ALTO, sempre visibili, trasparenti
tab_bar_edge top
tab_bar_min_tabs 1
tab_bar_style powerline
tab_powerline_style slanted
tab_bar_background none
tab_bar_margin_width 8
tab_bar_margin_height 6 0
tab_title_template "{index}: {title}"
active_tab_font_style bold

# bordi finestre divise
active_border_color #E8A05A
inactive_border_color #463930

# --- Gargantua ---
foreground #F3E3D3
background #0A0705
selection_foreground #0A0705
selection_background #E8A05A
url_color #F2B24C
cursor #E8A05A
cursor_text_color #0A0705
color0  #14100D
color8  #64534A
color1  #E5604D
color9  #FF8672
color2  #A8C686
color10 #C2DBA2
color3  #F2B24C
color11 #FFD07A
color4  #B7876A
color12 #D4A98A
color5  #C47A6B
color13 #E39A8A
color6  #D9B99B
color14 #F0D6BD
color7  #E6D1CD
color15 #FFF8F2
active_tab_foreground   #0A0705
active_tab_background   #E8A05A
inactive_tab_foreground #C7AEA0
inactive_tab_background #2A211C
EOF
  chown -R "$TARGET_USER:" "$cfg" "$ron" "$TARGET_HOME/.config/kitty"
  ok "tema Gargantua creato: $ron + kitty (schede in alto)"
  warn "ULTIMO PASSAGGIO (un clic): Impostazioni > Desktop > Aspetto > Importa > $ron"
}

# ============================================== ULTIMO: RIMUOVI ALTRI DE ======
de_packages() { # nomi dei pacchetti installati che combaciano con i glob
  rpm -qa --qf '%{NAME}\n' "$@" 2>/dev/null | sort -u \
    | grep -vE '^(cosmic-.*|xdg-desktop-portal-cosmic|kernel.*|plasma-wayland-protocols|.*-devel|xfdesktop|thunar|thunar-.*|xfconf|garcon|exo|libxfce4.*)$' || true
}

remove_family() {
  local label=$1; shift
  local list=()
  mapfile -t list < <(de_packages "$@")
  (( ${#list[@]} )) || { info "$label: nessun pacchetto installato"; return 0; }
  info "$label: rimuovo ${#list[@]} pacchetti"
  wait_pkg_lock
  retry 2 dnf -y remove --setopt=clean_requirements_on_remove=False "${list[@]}" \
    || warn "$label: rimozione non completata (probabile dipendenza protetta), proseguo"
}

step_remove_de() {
  rpm -q cosmic-session cosmic-greeter &>/dev/null \
    || die "COSMIC non installato: non rimuovo nessun altro DE"
  systemctl is-enabled cosmic-greeter.service &>/dev/null \
    || die "cosmic-greeter non abilitato: non rimuovo nessun altro DE"

  # dnf si rifiuta di rimuovere ciò che romperebbe COSMIC, xfdesktop o il sistema
  mkdir -p /etc/dnf/protected.d
  printf '%s\n' cosmic-session cosmic-greeter cosmic-comp cosmic-settings cosmic-files cosmic-term \
    NetworkManager pipewire wireplumber flatpak sudo xfdesktop thunar xfconf > /etc/dnf/protected.d/cosmic-setup.conf

  if [[ $ASSUME_YES -ne 1 ]]; then
    warn "Sto per RIMUOVERE GNOME, KDE Plasma, Xfce (tranne xfdesktop), MATE, Cinnamon, LXQt/LXDE, Budgie, Deepin, Pantheon."
    warn "Meglio da una TTY (Ctrl+Alt+F3). Ctrl+C entro 10 secondi per annullare."
    for i in {10..1}; do printf '%s ' "$i"; sleep 1; done; echo
  fi

  remove_family "GNOME" gnome-shell 'gnome-shell-extension-*' gdm gnome-session 'gnome-session-*' mutter \
    gnome-control-center gnome-initial-setup gnome-classic-session gnome-tour gnome-browser-connector \
    nautilus gnome-terminal gnome-console gnome-text-editor gnome-software
  remove_family "KDE Plasma" 'plasma-*' 'kwin*' 'sddm*' 'kde-settings*' kdeplasma-addons dolphin konsole \
    kate kscreen kinfocenter 'kdeconnect*' kde-gtk-config
  remove_family "Xfce" xfwm4 xfce4-session xfce4-panel xfce4-power-manager xfce4-terminal xfce4-appfinder \
    xfce4-notifyd xfce4-screensaver xfce4-taskmanager xfce4-screenshooter 'xfce4-*-plugin' lightdm 'lightdm-*'
  remove_family "MATE" 'mate-*' caja 'caja-*' marco mozo
  remove_family "Cinnamon" cinnamon 'cinnamon-*' nemo 'nemo-*' muffin cjs
  remove_family "LXQt/LXDE" 'lxqt-*' 'lxde-*' lxsession pcmanfm pcmanfm-qt lxdm
  remove_family "Budgie" 'budgie-*'
  remove_family "Deepin" 'deepin-*' 'dde-*'
  remove_family "Pantheon" 'pantheon-*'

  info "Window manager puri (Hyprland, i3, Sway, Openbox) NON toccati."
  # ricontrollo che COSMIC sia ancora integro
  rpm -q cosmic-session cosmic-greeter &>/dev/null || die "COSMIC danneggiato dalla rimozione! Reinstallalo: dnf group install cosmic-desktop-environment"
  # ...e che xfdesktop non sia stato portato via insieme agli altri DE
  rpm -q xfdesktop &>/dev/null || {
    warn "xfdesktop rimosso insieme agli altri DE: lo reinstallo"
    DNF_OPTS=(--setopt=install_weak_deps=False); pkgs xfdesktop thunar xfconf
  }
  systemctl enable --force cosmic-greeter.service
  ok "altri DE rimossi"
}

# ==================================================================== MAIN ====
usage() { sed -n '2,20p' "$0" 2>/dev/null || true; }

cleanup() { [[ -n $TMP && -d $TMP ]] && rm -rf "$TMP"; }

main() {
  exec </dev/null                       # dnf & co. non devono mai leggere lo script da stdin (curl | bash)
  for a in "$@"; do
    case $a in
      --skip=*) SKIP+="${SKIP:+,}${a#*=}" ;;
      --only=*) ONLY+="${ONLY:+,}${a#*=}" ;;
      --force)  FORCE=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --reboot) DO_REBOOT=1 ;;
      --list)   printf '%s\n' "${STEPS[@]}"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) die "opzione sconosciuta: $a" ;;
    esac
  done

  [[ $EUID -eq 0 ]] || die "esegui come root:  curl -fsSL URL | sudo bash"
  mkdir -p "$(dirname "$LOG")"
  if [[ ! -t 1 ]]; then C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; C_M=""; C_C=""; C_BD=""; C_DIM=""; fi
  exec > >(tee -a "$LOG") 2>&1
  trap cleanup EXIT
  banner
  trap 'err "interrotto"; exit 130' INT TERM

  info "fedora-cosmic-setup $(date '+%F %T')"
  preflight

  local s
  for s in "${STEPS[@]}"; do run_step "$s"; done

  echo; progress_bar "$STEP_N" "$STEP_N" "${C_G}${C_BD}finito${C_0}"
  info "${C_BD}==================== RIEPILOGO ====================${C_0}"
  (( ${#OK[@]} ))      && ok   "completati: ${OK[*]}"
  (( ${#SKIPPED[@]} )) && info "saltati:    ${SKIPPED[*]}"
  (( ${#FAILED[@]} ))  && err  "FALLITI:    ${FAILED[*]}   (rilancia con --only=nome --force)"
  info "log: $LOG | backup dei file modificati: $BACKUP_DIR"
  info "RIAVVIA il PC per entrare in COSMIC e applicare audio e desktop."
  (( DO_REBOOT )) && { info "riavvio tra 5s"; sleep 5; systemctl reboot; }
  (( ${#FAILED[@]} == 0 ))
}

main "$@"; exit $?

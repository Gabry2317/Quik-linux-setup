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
#  Variabili: TARGET_USER, GRUB_THEME_URL (link diretto allo zip/tar del tema)
#
#  Step (in ordine): repos system cosmic remove-de audio gnome-apps backup shell
#                    devtools browser grub network
# =============================================================================
set -Eeuo pipefail

LOG=/var/log/fedora-cosmic-setup.log
STATE_DIR=/var/lib/fedora-cosmic-setup
BACKUP_DIR=/var/backups/fedora-cosmic-setup/$(date +%Y%m%d-%H%M%S)
STEPS=(repos system cosmic remove-de audio gnome-apps backup shell devtools browser grub network)

GRUB_THEME_ID="${GRUB_THEME_ID:-2377285}"
GRUB_THEME_URL="${GRUB_THEME_URL:-}"
SKIP="${SKIP:-}"; ONLY="${ONLY:-}"; FORCE=0; ASSUME_YES=0; DO_REBOOT=0
TARGET_USER="${TARGET_USER:-}"; TARGET_HOME=""
SKIPFLAG=""
TMP=""
OK=(); FAILED=(); SKIPPED=()

# ---------------------------------------------------------------- utilità ----
C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_0=$'\e[0m'
info() { echo "${C_B}[i]${C_0} $*"; }
ok()   { echo "${C_G}[ok]${C_0} $*"; }
warn() { echo "${C_Y}[!]${C_0} $*" >&2; }
err()  { echo "${C_R}[x]${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }

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
  if skip_step "$name"; then SKIPPED+=("$name"); return 0; fi
  if [[ -f $STATE_DIR/$name.done && $FORCE -ne 1 ]]; then
    SKIPPED+=("$name (già fatto)"); return 0
  fi
  echo; info "==================== $name ===================="
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
  [[ $(uname -m) == x86_64 ]] || warn "architettura $(uname -m): alcuni step (Helium, GRUB) potrebbero non funzionare"

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

# ====================================================== 6) RIMUOVI ALTRI DE ===
de_packages() { # nomi dei pacchetti installati che combaciano con i glob
  rpm -qa --qf '%{NAME}\n' "$@" 2>/dev/null | sort -u \
    | grep -vE '^(cosmic-.*|xdg-desktop-portal-cosmic|kernel.*|plasma-wayland-protocols|.*-devel)$' || true
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

  # dnf si rifiuta di rimuovere ciò che romperebbe COSMIC o il sistema
  mkdir -p /etc/dnf/protected.d
  printf '%s\n' cosmic-session cosmic-greeter cosmic-comp cosmic-settings cosmic-files cosmic-term \
    NetworkManager pipewire wireplumber flatpak sudo > /etc/dnf/protected.d/cosmic-setup.conf

  if [[ $ASSUME_YES -ne 1 ]]; then
    warn "Sto per RIMUOVERE GNOME, KDE Plasma, Xfce, MATE, Cinnamon, LXQt/LXDE, Budgie, Deepin, Pantheon."
    warn "Meglio da una TTY (Ctrl+Alt+F3). Ctrl+C entro 10 secondi per annullare."
    for i in {10..1}; do printf '%s ' "$i"; sleep 1; done; echo
  fi

  remove_family "GNOME" gnome-shell 'gnome-shell-extension-*' gdm gnome-session 'gnome-session-*' mutter \
    gnome-control-center gnome-initial-setup gnome-classic-session gnome-tour gnome-browser-connector \
    nautilus gnome-terminal gnome-console gnome-text-editor gnome-software
  remove_family "KDE Plasma" 'plasma-*' 'kwin*' 'sddm*' 'kde-settings*' kdeplasma-addons dolphin konsole \
    kate kscreen kinfocenter 'kdeconnect*' kde-gtk-config
  remove_family "Xfce" 'xfce4-*' xfwm4 xfdesktop thunar Thunar lightdm 'lightdm-*'
  remove_family "MATE" 'mate-*' caja 'caja-*' marco mozo
  remove_family "Cinnamon" cinnamon 'cinnamon-*' nemo 'nemo-*' muffin cjs
  remove_family "LXQt/LXDE" 'lxqt-*' 'lxde-*' lxsession pcmanfm pcmanfm-qt lxdm
  remove_family "Budgie" 'budgie-*'
  remove_family "Deepin" 'deepin-*' 'dde-*'
  remove_family "Pantheon" 'pantheon-*'

  info "Window manager puri (Hyprland, i3, Sway, Openbox) NON toccati."
  # ricontrollo che COSMIC sia ancora integro
  rpm -q cosmic-session cosmic-greeter &>/dev/null || die "COSMIC danneggiato dalla rimozione! Reinstallalo: dnf group install cosmic-desktop-environment"
  systemctl enable --force cosmic-greeter.service
  ok "altri DE rimossi"
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
  mkdir -p "$TARGET_HOME/.config/kitty"

  [[ -e $TARGET_HOME/.config/kitty/kitty.conf ]] && cp -a "$TARGET_HOME/.config/kitty/kitty.conf" "$TARGET_HOME/.config/kitty/kitty.conf.bak-$ts"
  cat > "$TARGET_HOME/.config/kitty/kitty.conf" <<'EOF'
# --- Kitty: tema Dracula + animazioni ---
font_family      JetBrains Mono
font_size        12.0
shell            zsh
scrollback_lines 20000
enable_audio_bell no
confirm_os_window_close 0
window_padding_width 8
remember_window_size yes

# trasparenza + blur
background_opacity 0.88
background_blur    32

# cursore animato (scia) e lampeggio morbido
cursor_shape beam
cursor_blink_interval 0.5 ease-in-out
cursor_trail 3
cursor_trail_decay 0.1 0.4

# tab bar
tab_bar_style powerline
tab_powerline_style slanted

# --- Dracula ---
foreground #f8f8f2
background #282a36
selection_foreground #ffffff
selection_background #44475a
url_color #8be9fd
cursor #f8f8f2
color0  #21222c
color8  #6272a4
color1  #ff5555
color9  #ff6e6e
color2  #50fa7b
color10 #69ff94
color3  #f1fa8c
color11 #ffffa5
color4  #bd93f9
color12 #d6acff
color5  #ff79c6
color13 #ff92df
color6  #8be9fd
color14 #a4ffff
color7  #f8f8f2
color15 #ffffff
active_tab_foreground   #282a36
active_tab_background   #bd93f9
inactive_tab_foreground #f8f8f2
inactive_tab_background #44475a
EOF

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
  chown -R "$TARGET_USER": "$TARGET_HOME/.config/kitty" "$TARGET_HOME/.zshrc"

  if [[ -x /usr/bin/zsh ]]; then usermod -s /usr/bin/zsh "$TARGET_USER" || warn "impossibile impostare zsh come shell"; fi
  fc-cache -f >/dev/null 2>&1 || true
  ok "kitty (Dracula, trasparenza, scia cursore) + zsh (suggerimenti, completamento, cronologia, fzf)"
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

# ============================================== 9) FIREFOX -> HELIUM ==========
install_helium_tarball() {
  local url dir bin
  url=$(curl -fsSL https://api.github.com/repos/imputnet/helium-linux/releases/latest \
    | python3 -c 'import sys,json
for a in json.load(sys.stdin)["assets"]:
    if a["name"].endswith("x86_64_linux.tar.xz"): print(a["browser_download_url"]); break') || true
  [[ -n $url ]] || return 1
  retry 3 curl -fL --max-time 600 -o "$TMP/helium.tar.xz" "$url" || return 1
  dir=/opt/helium; rm -rf "$dir"; mkdir -p "$dir"
  tar -xJf "$TMP/helium.tar.xz" -C "$dir" --strip-components=1 || return 1
  bin=$(find "$dir" -maxdepth 1 -type f -executable \( -name helium -o -name chrome \) | head -1)
  [[ -n $bin ]] || return 1
  ln -sf "$bin" /usr/local/bin/helium
  [[ -f $dir/chrome-sandbox ]] && chmod 4755 "$dir/chrome-sandbox" || true
  [[ -f $dir/helium.desktop ]] && install -Dm644 "$dir/helium.desktop" /usr/share/applications/helium.desktop
  return 0
}

step_browser() {
  # installo Helium PRIMA di togliere Firefox: non resti mai senza browser
  local helium_ok=0
  if retry 2 dnf -y copr enable imput/helium && retry 2 dnf -y install helium-bin; then
    helium_ok=1
  else
    warn "COPR non disponibile, provo il tarball ufficiale da GitHub"
    install_helium_tarball && helium_ok=1
  fi
  [[ $helium_ok -eq 1 ]] || die "Helium non installato: lascio Firefox al suo posto"

  wait_pkg_lock
  rpm -qa 'firefox*' | grep -q . && dnf -y remove 'firefox*' --setopt=clean_requirements_on_remove=False \
    || info "Firefox (rpm) non presente"
  flatpak list --system --app 2>/dev/null | grep -q org.mozilla.firefox \
    && flatpak uninstall --system -y --noninteractive org.mozilla.firefox || true

  if [[ -n $TARGET_USER ]]; then
    local desk=helium.desktop
    [[ -f /usr/share/applications/$desk ]] || desk=$(basename "$(ls /usr/share/applications/helium*.desktop 2>/dev/null | head -1)")
    [[ -n $desk ]] && run_as_user xdg-settings set default-web-browser "$desk" 2>/dev/null \
      || warn "imposta Helium come browser predefinito dalle impostazioni di COSMIC"
  fi
  ok "Helium installato, Firefox rimosso"
}

# ====================================================== 1) TEMA GRUB ==========
step_grub() {
  command -v grub2-mkconfig >/dev/null || pkgs grub2-tools
  command -v grub2-mkconfig >/dev/null || die "grub2-mkconfig non disponibile (sistema senza GRUB?)"
  pkgs python3 curl

  local url="$GRUB_THEME_URL" meta=""
  if [[ -z $url ]]; then
    meta=$(curl -fsSL --max-time 30 "https://www.gnome-look.org/ocs/v1/content/data/${GRUB_THEME_ID}?format=json" 2>/dev/null || true)
    url=$(printf '%s' "$meta" | python3 -c '
import sys, json
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "downloadlink1" and isinstance(v, str) and v:
                print(v); raise SystemExit
            walk(v)
    elif isinstance(o, list):
        for i in o: walk(i)
try: walk(json.load(sys.stdin))
except SystemExit: pass
except Exception: pass' || true)
    if [[ -z $url ]]; then   # fallback XML
      meta=$(curl -fsSL --max-time 30 "https://www.gnome-look.org/ocs/v1/content/data/${GRUB_THEME_ID}" 2>/dev/null || true)
      url=$(grep -oP '(?<=<downloadlink1>)[^<]+' <<<"$meta" | head -1 | sed 's/&amp;/\&/g' || true)
    fi
  fi
  [[ -n $url ]] || die "link del tema non ricavato dall'API di gnome-look. Rilancia con GRUB_THEME_URL=<link diretto allo zip>"

  info "scarico il tema: $url"
  retry 3 curl -fL --max-time 300 -o "$TMP/theme.bin" "$url" || die "download del tema fallito"
  [[ $(stat -c %s "$TMP/theme.bin") -gt 10000 ]] || die "file scaricato troppo piccolo"
  head -c 200 "$TMP/theme.bin" | grep -qi '<html' && die "ho scaricato una pagina HTML invece del tema (usa GRUB_THEME_URL)"

  mkdir -p "$TMP/theme"
  python3 - "$TMP/theme.bin" "$TMP/theme" <<'PY' || die "archivio del tema non riconosciuto"
import shutil, sys
for fmt in ("zip", "gztar", "xztar", "bztar", "tar"):
    try:
        shutil.unpack_archive(sys.argv[1], sys.argv[2], fmt); sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PY
  local tfile tdir tname
  tfile=$(find "$TMP/theme" -name theme.txt | head -1)
  [[ -n $tfile ]] || die "theme.txt non trovato nell'archivio"
  [[ $(find "$TMP/theme" -name theme.txt | wc -l) -gt 1 ]] && warn "più varianti nel tema, uso: $tfile"
  tdir=$(dirname "$tfile")
  tname=$(basename "$tdir" | tr -c 'A-Za-z0-9._-\n' '_')
  [[ $tname == "theme" || -z $tname ]] && tname="custom-theme-$GRUB_THEME_ID"

  mkdir -p /boot/grub2/themes
  rm -rf "/boot/grub2/themes/$tname"
  cp -a "$tdir" "/boot/grub2/themes/$tname"

  backup_file /etc/default/grub
  sed -i -e '/^GRUB_THEME=/d' -e '/^GRUB_TERMINAL_OUTPUT=/d' -e '/^GRUB_TERMINAL=/d' /etc/default/grub
  {
    echo 'GRUB_TERMINAL_OUTPUT="gfxterm"'
    echo "GRUB_THEME=\"/boot/grub2/themes/$tname/theme.txt\""
  } >> /etc/default/grub
  grep -q '^GRUB_GFXMODE=' /etc/default/grub || echo 'GRUB_GFXMODE=auto' >> /etc/default/grub

  # genero in un file temporaneo, controllo, e solo dopo sostituisco il vero grub.cfg
  local cfg; cfg=$(readlink -f /etc/grub2.cfg 2>/dev/null || echo /boot/grub2/grub.cfg)
  [[ -e $cfg ]] || cfg=/boot/grub2/grub.cfg
  if ! grub2-mkconfig -o "$TMP/grub.cfg"; then
    cp -a "$BACKUP_DIR/etc/default/grub" /etc/default/grub; die "grub2-mkconfig fallito, ripristinato /etc/default/grub"
  fi
  if command -v grub2-script-check >/dev/null && ! grub2-script-check "$TMP/grub.cfg"; then
    cp -a "$BACKUP_DIR/etc/default/grub" /etc/default/grub; die "grub.cfg generato non valido, ripristinato /etc/default/grub"
  fi
  grep -q "themes/$tname/theme.txt" "$TMP/grub.cfg" || warn "il tema non compare nel grub.cfg generato"
  backup_file "$cfg"
  cp -f "$TMP/grub.cfg" "$cfg"
  ok "tema GRUB '$tname' installato (se ne usi uno dinamico per voce, resta compatibile)"
}

# ================================================== 10) OTTIMIZZAZIONI RETE ===
step_network() {
  modprobe tcp_bbr 2>/dev/null || true
  local cc=""
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    cc=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
    echo tcp_bbr > /etc/modules-load.d/tcp_bbr.conf
  else
    warn "BBR non disponibile in questo kernel, uso il controllo di congestione di default"
  fi

  backup_file /etc/sysctl.d/99-net-lowlatency.conf
  cat > /etc/sysctl.d/99-net-lowlatency.conf <<EOF
# Ottimizzazioni rete: bassa latenza + buon throughput (TCP e UDP)
$cc

# TCP
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Buffer socket (valgono anche per UDP: giochi, VoIP, QUIC)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Code
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 4096
EOF
  sysctl --system >/dev/null || warn "sysctl --system ha dato errori (controlla il log)"

  # Wi-Fi: il risparmio energetico è una causa comune di ping alto e picchi di lag
  mkdir -p /etc/NetworkManager/conf.d
  backup_file /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf
  printf '[connection]\nwifi.powersave = 2\n' > /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf
  systemctl reload NetworkManager 2>/dev/null || true

  info "congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)"
  ok "rete ottimizzata (TCP/UDP) + Wi-Fi power save disattivato"
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
  exec > >(tee -a "$LOG") 2>&1
  trap cleanup EXIT
  trap 'err "interrotto"; exit 130' INT TERM

  info "fedora-cosmic-setup $(date '+%F %T')"
  preflight

  local s
  for s in "${STEPS[@]}"; do run_step "$s"; done

  echo; info "==================== RIEPILOGO ===================="
  (( ${#OK[@]} ))      && ok   "completati: ${OK[*]}"
  (( ${#SKIPPED[@]} )) && info "saltati:    ${SKIPPED[*]}"
  (( ${#FAILED[@]} ))  && err  "FALLITI:    ${FAILED[*]}   (rilancia con --only=nome --force)"
  info "log: $LOG | backup dei file modificati: $BACKUP_DIR"
  info "RIAVVIA il PC per entrare in COSMIC e applicare audio/rete/GRUB."
  (( DO_REBOOT )) && { info "riavvio tra 5s"; sleep 5; systemctl reboot; }
  (( ${#FAILED[@]} == 0 ))
}

main "$@"; exit $?

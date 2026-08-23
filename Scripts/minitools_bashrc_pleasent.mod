#!/usr/bin/bash
#writen by dberistain
#Adds a pleasant Bash configuration, blue/white/gold prompt, aliases,
#history improvements, syntax highlighting and smart inline suggestions.

PROFILE_FILE="$HOME/.bashrc"
FLAG_FILE="$HOME/.bashrc_update_flag"
BLESH_DIR="$HOME/.local/share/blesh"
BLOCK_START="# >>> MINITOOLS PLEASANT BASHRC >>>"
BLOCK_END="# <<< MINITOOLS PLEASANT BASHRC <<<"

red="$(tput setaf 196 2>/dev/null || true)";
yellow="$(tput setaf 226 2>/dev/null || true)";
blue="$(tput setaf 69 2>/dev/null || true)";
gold="$(tput setaf 220 2>/dev/null || true)";
white="$(tput setaf 15 2>/dev/null || true)";
green="$(tput setaf 118 2>/dev/null || true)";
bold="$(tput bold 2>/dev/null || true)";
r="$(tput sgr0 2>/dev/null || true)";

masterWidth="110"
bbar=$(printf '%0.s—' $(seq 1 $masterWidth))

center() {
    width=$masterWidth
    echo
    echo "$blue$bbar$r"
    for i
    do
        iCount="${#i}"
        [ $((iCount%2)) -eq 0 ] && fill="" || fill=" "
        padding=$(( (width-iCount-2)/2 ))
        [ "$padding" -lt 0 ] && padding=0
        [ "$padding" -gt 0 ] && padding=$(printf '%0.s ' $(seq 1 "$padding")) || padding=""
        echo "$padding" "$bold$i$r" "$padding$fill"
    done
    echo "$blue$bbar$r"
}

yes_answer() {
    case "${1,,}" in
        y|yes|s|si|sí) return 0 ;;
        *) return 1 ;;
    esac
}

remove_managed_block() {
    local file="$1" tmp
    [ -f "$file" ] || return 0
    tmp="$(mktemp)"
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
        $0==start {inside=1; next}
        $0==end   {inside=0; next}
        !inside   {print}
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
}

install_blesh() {
    if [ -f "$BLESH_DIR/ble.sh" ]; then
        echo " ${green}* ble.sh already installed: $BLESH_DIR${r}"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v xz >/dev/null 2>&1; then
        echo " ${yellow}! Smart prediction requires curl, tar and xz.${r}"
        echo " ${yellow}! Prompt/aliases will still be installed, but ble.sh will be skipped.${r}"
        return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    echo " Installing ble.sh smart suggestions/syntax highlighting..."

    if curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz \
        | tar -xJf - -C "$tmpdir" \
        && [ -f "$tmpdir/ble-nightly/ble.sh" ] \
        && bash "$tmpdir/ble-nightly/ble.sh" --install "$HOME/.local/share" >/dev/null 2>&1; then
        echo " ${green}* ble.sh installed successfully.${r}"
        rm -rf "$tmpdir"
        return 0
    fi

    echo " ${yellow}! Could not install ble.sh. Bash prompt changes will still be installed.${r}"
    rm -rf "$tmpdir"
    return 1
}

clear -x
center "MINITOOLS BASHRC MOD"

# The flag intentionally prevents silent repeated modifications.
# If it exists, tell the user exactly what happened and allow an explicit reinstall/update.
if [ -f "$FLAG_FILE" ]; then
    echo " ${yellow}${bold}A minitools Bash modification flag already exists:${r}"
    echo " $FLAG_FILE"
    echo
    echo " This means this Bash profile has already been modified by this tool."
    read -r -p " Remove the flag and continue with a reinstall/update? [y/N]: " answer
    if yes_answer "$answer"; then
        rm -f "$FLAG_FILE" || { echo "${red}Could not remove flag file.${r}"; exit 1; }
        echo " ${green}* Flag removed. Continuing.${r}"
    else
        echo " No changes made."
        exit 0
    fi
fi

[ -f "$PROFILE_FILE" ] || touch "$PROFILE_FILE"
backup="${PROFILE_FILE}.minitools_backup_$(date +%Y%m%d_%H%M%S)"
cp -a "$PROFILE_FILE" "$backup" || { echo "${red}Could not back up $PROFILE_FILE${r}"; exit 1; }
echo " Backup created: $backup"

# If this newer managed block already exists (for example after manually deleting only the flag),
# replace it instead of appending duplicate settings.
remove_managed_block "$PROFILE_FILE"

install_blesh || true

cat <<'EOF_BLOCK' >> "$PROFILE_FILE"

# >>> MINITOOLS PLEASANT BASHRC >>>
# Managed by minitools_bashrc_pleasent.mod

# Better interactive history
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=100000
HISTFILESIZE=200000
shopt -s histappend
shopt -s cmdhist
shopt -s checkwinsize

# Save history after every command and merge history from other open shells.
__minitools_history_sync='history -a; history -n'
case ";${PROMPT_COMMAND:-};" in
    *";${__minitools_history_sync};"*) ;;
    ";;") PROMPT_COMMAND="$__minitools_history_sync" ;;
    *) PROMPT_COMMAND="$__minitools_history_sync;${PROMPT_COMMAND}" ;;
esac
unset __minitools_history_sync

# Useful aliases
alias ll='ls -lash --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Enable Debian programmable completion when available.
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# Blue / White / Gold prompt
#   username = blue
#   separators = white
#   hostname = gold
#   working directory = blue
#   prompt symbol = gold
PS1='\[\e[38;5;33m\]\u\[\e[97m\]@\[\e[38;5;220m\]\h\[\e[97m\]:\[\e[38;5;33m\]\w\[\e[38;5;220m\]\$ \[\e[0m\]'

# ble.sh: Bash syntax highlighting + smart inline suggestions.
# Right Arrow / End accepts a suggestion.
if [[ $- == *i* && -f "$HOME/.local/share/blesh/ble.sh" ]]; then
    source -- "$HOME/.local/share/blesh/ble.sh" --attach=none

    # Suggestions should be visible but not overpower the prompt.
    bleopt complete_auto_delay=180
    ble-face auto_complete='fg=244'
    bleopt prompt_eol_mark=''

    ble-attach
fi

# <<< MINITOOLS PLEASANT BASHRC <<<
EOF_BLOCK

touch "$FLAG_FILE"

center "BASHRC UPDATE COMPLETE"
printf " %-22s %s\n" "Profile:" "$PROFILE_FILE"
printf " %-22s %s\n" "Backup:" "$backup"
printf " %-22s %s\n" "Flag:" "$FLAG_FILE"
printf " %-22s %s\n" "Prompt colors:" "BLUE / WHITE / GOLD"
if [ -f "$BLESH_DIR/ble.sh" ]; then
    printf " %-22s %s\n" "Smart suggestions:" "ENABLED (ble.sh)"
    printf " %-22s %s\n" "Syntax highlighting:" "ENABLED"
else
    printf " %-22s %s\n" "Smart suggestions:" "NOT INSTALLED"
fi

echo
echo " ${green}Open a new Bash shell to use the new configuration.${r}"
echo " Or run: ${gold}source ~/.bashrc${r}"
echo

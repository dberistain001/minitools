#!/bin/bash

# Define the file to be modified
PROFILE_FILE="$HOME/.bashrc"
# Define the flag file
FLAG_FILE="$HOME/.bashrc_update_flag"

# Check if the script has already been run
if [ -f "$FLAG_FILE" ]; then
    echo "The script has already been run. Exiting."
    exit 0
fi

# Backup the existing profile file
cp "$PROFILE_FILE" "$PROFILE_FILE.bak"

# Add aliases and prompt customization to the profile file
cat << 'EOF' >> "$PROFILE_FILE"

# Alias ll to ls -lash
alias ll='ls -lash'

# Enable colors for ls and grep
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Quick navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# File and directory operations
alias rm='rm -i'  # Prompt before removing files
alias cp='cp -i'  # Prompt before overwriting files
alias mv='mv -i'  # Prompt before overwriting files

# Enhanced prompt with username in green, hostname in red, and full path
PS1='\[\033[01;32m\]\u\[\033[00m\]@\[\033[01;31m\]\h\[\033[00m\]:\[\033[01;32m\]\w\[\033[00m\]\$ '
EOF

# Create the flag file to indicate that the script has been run
touch "$FLAG_FILE"

# Apply changes
echo "Sourcing $PROFILE_FILE to apply changes..."
source "$PROFILE_FILE"

echo "Changes applied successfully."

#!/bin/bash
# Visar inloggningen till WordPress adminpanel. Ta ingen skärmdump av lösenordet.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh "${1:-prod}"
echo "Användare: $(secret_field "$EnvName/wp/admin" username)"
echo "Lösenord:  $(secret_field "$EnvName/wp/admin" password)"

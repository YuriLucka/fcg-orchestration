#!/usr/bin/env bash
# Apaga o cluster e tudo do rg-fcg (o ACR fica, está em outro resource group).
set -euo pipefail
az group delete -n rg-fcg --yes --no-wait

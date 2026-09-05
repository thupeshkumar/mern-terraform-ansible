#!/usr/bin/env bash
# Run this from the project root AFTER `terraform apply` has finished successfully.
# It reads terraform outputs and rewrites ansible/inventory/hosts.ini and
# ansible/group_vars/all.yml with the real IP addresses.
set -euo pipefail

cd "$(dirname "$0")/terraform"

WEB_PUBLIC_IP=$(terraform output -raw web_server_public_ip)
WEB_PRIVATE_IP=$(terraform output -raw web_server_private_ip)
DB_PRIVATE_IP=$(terraform output -raw db_server_private_ip)

cd ..

sed -e "s/WEB_PUBLIC_IP/${WEB_PUBLIC_IP}/g" \
    -e "s/DB_PRIVATE_IP/${DB_PRIVATE_IP}/g" \
    ansible/inventory/hosts.ini > /tmp/hosts.ini.tmp
mv /tmp/hosts.ini.tmp ansible/inventory/hosts.ini

sed -e "s/DB_PRIVATE_IP/${DB_PRIVATE_IP}/g" \
    -e "s/WEB_PRIVATE_IP/${WEB_PRIVATE_IP}/g" \
    ansible/group_vars/all.yml > /tmp/all.yml.tmp
mv /tmp/all.yml.tmp ansible/group_vars/all.yml

echo "Inventory updated:"
echo "  web (public):  ${WEB_PUBLIC_IP}"
echo "  web (private): ${WEB_PRIVATE_IP}"
echo "  db  (private): ${DB_PRIVATE_IP}"

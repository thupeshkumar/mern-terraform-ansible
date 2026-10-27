# AWS application deployment with Terraform and Ansible

A training assignment for provisioning an AWS web/database environment and configuring the upstream [TravelMemory](https://github.com/UnpredictablePrashant/TravelMemory) MERN application. This repository's portfolio focus is infrastructure as code and configuration automation; the application is credited to its upstream author.

## Architecture

```text
Internet -> public EC2 web host -> private EC2 MongoDB host
            Nginx + React         no public IP
            Express/systemd      package access through NAT Gateway

Administrator -> SSH to web host -> SSH jump to database host
```

Terraform defines the VPC, public/private subnets, Internet/NAT gateways, route tables, security groups, IAM role/profile and two EC2 instances. The database security group accepts SSH and MongoDB traffic from the web security group. Ansible configures the database before the application tier.

## Repository map

- `terraform/`: infrastructure, variables and outputs.
- `ansible/playbooks/site.yml`: database and web configuration sequence.
- `ansible/playbooks/database.yml`: MongoDB installation, users and host configuration.
- `ansible/playbooks/webserver.yml`: application checkout, Node.js, Nginx, frontend build and systemd service.
- `ansible/templates/`: application environment, database, Nginx and service templates.
- `ansible/inventory/`: host inventory and the adjacent variables used for that inventory.
- `generate_inventory.sh`: helper requiring the corrections described below.

## Status

Infrastructure and configuration files are present. This README does not claim a fresh successful deployment, idempotence result, performance improvement or production readiness. A screenshot document is retained in the repository; screenshots do not substitute for a repeatable run against a recorded commit.

## Prerequisites

Use Bash/WSL, Terraform, Ansible, Git, AWS CLI authentication, an EC2 key pair in the chosen region and suitable AWS permissions/quota. Review the provider constraints, AMI lookup and instance types in `terraform/` before planning. The NAT Gateway, instances and associated resources can incur charges.

## Provision the infrastructure

```bash
git clone https://github.com/thupeshkumar/mern-terraform-ansible.git
cd mern-terraform-ansible
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Set key_name, my_ip and other required values privately.
terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=lab.tfplan
```

Review the plan before running `terraform -chdir=terraform apply lab.tfplan`. Obtain current addresses with `terraform -chdir=terraform output`.

## Configure inventory correctly

Do not rely on the current helper to refresh an existing inventory. It replaces literal placeholders in place, so subsequent runs may retain stale addresses. It also writes `ansible/group_vars/all.yml`, whereas the active inventory has variables under `ansible/inventory/group_vars/all.yml`.

Before running Ansible, manually update:

1. `ansible/inventory/hosts.ini`: web public IP, database private IP and the SSH jump-host address.
2. `ansible/inventory/group_vars/all.yml`: `db_private_ip`, `web_private_ip` and application settings.
3. `ansible/ansible.cfg`: private-key path and SSH host-key verification appropriate to your lab.

Replace example database passwords using private overrides or Ansible Vault. Do not commit credentials or expose inventory output containing secrets.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml --syntax-check
ansible all -m ping
ansible-playbook playbooks/site.yml
```

The last command changes the target hosts. Review the playbooks and templates first, particularly package versions and MongoDB compatibility with the selected OS.

## Important implementation limits

- The frontend build currently points to `http://<web-public-ip>:3001`. The AWS security group restricts that port to the administrator CIDR, and the web UFW tasks allow SSH and ports 80/443 without an explicit 3001 rule. The API path may therefore fail even when the frontend loads. Prefer implementing and testing a same-origin Nginx API proxy before sharing the application publicly; that change is not included in this README.
- `host_key_checking = False` is present in the Ansible configuration. Establish trusted host keys and enable checking for a stronger operational setup.
- The web UFW SSH rule allows the OpenSSH profile; the administrator-IP restriction is enforced by the AWS security group, not by that UFW rule.
- The code selects Node.js 18 and installs MongoDB through a configured apt repository. Review version support and OS/package compatibility before reuse.
- The application checkout follows upstream `main`; pin a reviewed commit when you need reproducibility.
- Opening port 443 does not configure a TLS certificate or prove HTTPS works.

## Verify the result

Check the Ansible recap, `systemctl status travelmemory-backend`, `systemctl status nginx` and `systemctl status mongod` on the relevant hosts. Confirm MongoDB listens on intended interfaces and that the database has no public IP.

Test both UI loading and an actual create/read operation. If API calls fail, inspect the browser request URL, the security group, UFW, service logs and Nginx configuration before changing access rules. Record the source commit, environment, command outcome and sanitized evidence. A successful page load alone does not validate database persistence.

## Cleanup

Back up any required data, review `terraform -chdir=terraform plan -destroy`, then use `terraform -chdir=terraform destroy` for the lab resources. Check NAT Gateway, Elastic IP and other residual resources in AWS. Preserve upstream attribution and any applicable license notices when reusing application code.

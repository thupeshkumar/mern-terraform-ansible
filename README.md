# Deploying TravelMemory (MERN) on AWS with Terraform + Ansible

This repository provisions AWS infrastructure with Terraform and configures/deploys
the [TravelMemory](https://github.com/UnpredictablePrashant/TravelMemory) MERN app
with Ansible. This document is the implementation report: it walks through every
step in the order you should run them, explains how the pieces interact, and
includes a troubleshooting log of the real issues hit during an actual deployment
run (Ubuntu 26.04 + MongoDB compatibility quirks) so the process is reproducible
even where the environment has moved since a given tutorial was written.

**📸 = insert a screenshot here for your submission.**

## Table of contents
1. [Architecture](#1-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Part 1 — Provision infrastructure with Terraform](#3-part-1--provision-infrastructure-with-terraform)
4. [Part 2 — Configure and deploy with Ansible](#4-part-2--configure-and-deploy-with-ansible)
5. [How the pieces talk to each other](#5-how-the-pieces-talk-to-each-other)
6. [Verifying the deployment](#6-verifying-the-deployment)
7. [Security hardening summary](#7-security-hardening-summary)
8. [Cleaning up](#8-cleaning-up)
9. [Troubleshooting log — real issues hit during this deployment](#9-troubleshooting-log--real-issues-hit-during-this-deployment)
10. [Screenshot / video checklist for submission](#10-screenshot--video-checklist-for-submission)

---

## 1. Architecture

**Editable diagram:** [`architecture-diagram.drawio`](./architecture-diagram.drawio) —
open it at [app.diagrams.net](https://app.diagrams.net) (File → Open From → Device)
to view, edit, or export it as PNG/SVG for your submission.

ASCII summary for quick reference:

```
                          Internet
                             │
                     ┌───────▼────────┐
                     │ Internet Gateway│
                     └───────┬────────┘
                             │
                    VPC 10.0.0.0/16
        ┌────────────────────┴─────────────────────┐
        │                                           │
┌───────▼────────┐                          ┌───────▼────────┐
│ Public Subnet   │                          │ Private Subnet │
│ 10.0.1.0/24     │                          │ 10.0.2.0/24    │
│                 │   MongoDB :27017 (SG)    │                │
│  EC2: web       │ ───────────────────────► │  EC2: db       │
│  Nginx :80      │  SSH via web as jump     │  MongoDB :27017│
│  Node/Express   │ ◄─────────────────────── │                │
│  React (build)  │                          │  no public IP  │
│  :3001          │                          │  outbound via  │
└───────┬─────────┘                          │  NAT Gateway   │
        │ SSH (your IP only)                 └────────────────┘
        ▼
    Your laptop
```

- **Web server (public subnet)**: has a public IP, runs Nginx (serves the built React
  app on port 80) and the Express API via a systemd service on port 3001.
- **DB server (private subnet)**: no public IP; only reachable from the web server's
  security group. Outbound internet (for `apt`/package installs) goes through the
  NAT Gateway in the public subnet.
- Only your IP can SSH to the web server; the web server is used as an SSH jump host
  (`ProxyCommand`) to reach the DB server, mirroring how the DB security group only
  allows traffic from the web security group.

**📸 Screenshot:** AWS Console → VPC → "Resource map" view, showing both subnets,
the IGW and the NAT Gateway wired together.

## 2. Prerequisites

- AWS account + an IAM user with EC2/VPC/IAM permissions, and its access key configured:
  ```bash
  aws configure
  ```
- Terraform >= 1.5 and Ansible >= 2.14 installed locally.
- An EC2 key pair created in the target region:
  ```bash
  aws ec2 create-key-pair --key-name travelmemory-key \
    --query 'KeyMaterial' --output text > ~/.ssh/travelmemory-key.pem
  chmod 400 ~/.ssh/travelmemory-key.pem
  ```
- Your public IP (for the SSH security group rule):
  ```bash
  curl -s https://checkip.amazonaws.com
  ```
- Ansible collections used by the DB playbook:
  ```bash
  cd ansible
  ansible-galaxy collection install -r requirements.yml
  ```

**📸 Screenshot:** terminal output of `aws sts get-caller-identity` (proves the CLI
is authenticated) and `terraform -version` / `ansible --version`.

## 3. Part 1 — Provision infrastructure with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set key_name and my_ip (as x.x.x.x/32)

terraform init
terraform plan
terraform apply       # type "yes" when prompted
```

**📸 Screenshot:** `terraform init` success output, `terraform plan` showing the
resource count to be added, and the final `terraform apply` summary
(`Apply complete! Resources: N added...`).

What gets created (one resource file per concern, see `terraform/*.tf`):

| File | Resources |
|---|---|
| `vpc.tf` | VPC (10.0.0.0/16) |
| `subnets.tf` | Public subnet (10.0.1.0/24), private subnet (10.0.2.0/24) |
| `igw_nat.tf` | Internet Gateway, Elastic IP, NAT Gateway (in the public subnet) |
| `route_tables.tf` | Public RT → IGW; Private RT → NAT Gateway |
| `security_groups.tf` | `web-sg` (22 from your IP, 80/443 open, 3001 from your IP); `db-sg` (27017 and 22 only from `web-sg`) |
| `iam.tf` | IAM role + instance profile with SSM + CloudWatch policies |
| `ec2.tf` | Ubuntu 26.04 LTS (Resolute Raccoon) EC2 web instance (public subnet, public IP) and db instance (private subnet, no public IP) |
| `outputs.tf` | Public IP/DNS of web server, private IPs of both instances |

After `apply` finishes, note the outputs (or re-print them anytime with `terraform output`):

```bash
terraform output
```

**📸 Screenshot:** AWS Console → EC2 → Instances, showing both instances `running`
with 2/2 status checks passed — one with a public IPv4 address, one without.

**📸 Screenshot:** the `terraform output` command's result (public/private IPs).

## 4. Part 2 — Configure and deploy with Ansible

From the project root, populate the inventory automatically from Terraform's outputs:

```bash
bash generate_inventory.sh
```

This fills in `ansible/inventory/hosts.ini` and `ansible/inventory/group_vars/all.yml`
with the real public/private IPs (both files start with placeholders like
`WEB_PUBLIC_IP` so Ansible commands are inert until this script — or a manual
edit — runs). **`group_vars/` must live alongside the inventory file** (i.e.
`ansible/inventory/group_vars/`, not `ansible/group_vars/`) — Ansible only
auto-loads `group_vars`/`host_vars` from directories next to the inventory source
or next to the playbook, so a `group_vars/` sitting at the `ansible/` root is
silently never read. See the troubleshooting log below for how this surfaced.

Give the instances ~30–60 seconds to finish booting, then check connectivity:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible all -m ping
```

**📸 Screenshot:** `ansible all -m ping` returning `SUCCESS`/`pong` for both hosts.

Review/override the MongoDB credentials in `inventory/group_vars/all.yml` (or pass
them with `--extra-vars` / an `ansible-vault` file — don't leave real passwords in
git history), then run the full deployment:

```bash
ansible-playbook playbooks/site.yml
```

**📸 Screenshot:** the final `PLAY RECAP` line for both plays showing `failed=0`.

`site.yml` runs `database.yml` first (so the app's Mongo user exists before the
backend starts) and then `webserver.yml`. What each does:

**`database.yml`** (targets `db`)
- Installs MongoDB 7.0 from the official repo. Its apt repo only publishes for the
  `jammy` (22.04) suite (it was never extended to `noble`), and Ubuntu 26.04
  ("resolute") has no native MongoDB suite yet either, so the playbook points 26.04
  hosts at `jammy` instead — the documented workaround, one LTS further back than
  the 8.0/`noble` workaround that would apply to newer MongoDB branches.
- Uses the modern `signed-by` keyring approach for the apt repo (`gpg --dearmor`
  into `/usr/share/keyrings/`) instead of the deprecated `apt-key`, which Ubuntu
  26.04 has removed outright.
- Installs `python3-pymongo` via `apt` rather than `pip3 install pymongo`, because
  Ubuntu 26.04 ships Python 3.14 with PEP 668 enforced (no unmanaged system-wide
  pip installs).
- Creates an admin user, then an app-specific user scoped to the `travelmemory`
  database only (least privilege — the app account can't touch other databases).
- Rewrites `/etc/mongod.conf` to bind only to `127.0.0.1` and the instance's private
  IP (never `0.0.0.0`), and turns on `security.authorization`.
- Locks down `ufw` to allow SSH and port 27017 only from the web server's private IP,
  as a second layer behind the security group.
- Disables SSH root login and password authentication.

**`webserver.yml`** (targets `web`)
- Installs Node.js 18.x, npm, `pm2`, Nginx.
- Clones TravelMemory into `/opt/travelmemory`, installs backend and frontend deps.
- Templates `backend/.env` with `MONGO_URI` (pointing at the db server's private IP)
  and `PORT`.
- Patches `frontend/src/url.js`'s `BASE_URL` to the web server's public IP so the
  built React app calls the right backend — then runs `npm run build`.
- Creates a systemd service (`travelmemory-backend`) so the Express API survives
  reboots and crashes.
- Configures Nginx to serve the React build on port 80.
- Enables `ufw` (SSH from your IP only, 80/443 open) and disables SSH root
  login/password auth.

## 5. How the pieces talk to each other

1. Browser → `http://<web-public-ip>/` → Nginx serves the React static build.
2. React app (compiled with `BASE_URL=http://<web-public-ip>:3001`) makes AJAX calls
   straight to the Express API on port 3001.
3. Express (`backend/index.js`, run by the `travelmemory-backend` systemd service)
   connects to `mongodb://tm_app_user:...@<db-private-ip>:27017/travelmemory` — this
   only works because the db security group allows port 27017 from the web
   security group, and `mongod` is bound to that private IP.
4. The db instance has no public IP; its own outbound package installs go out through
   the NAT Gateway sitting in the public subnet.
5. SSH access mirrors that same trust chain: your laptop → web server (only your IP
   allowed) → db server (only the web server's private IP allowed), via an SSH
   `ProxyCommand` jump rather than a direct route.

## 6. Verifying the deployment

```bash
# Backend health check directly
curl http://<web-public-ip>:3001/trip

# Frontend
open http://<web-public-ip>/          # or just visit it in a browser
```

**📸 Screenshot:** the React app loaded in a browser.

**📸 Screenshot:** a trip successfully added through the UI, then reloading the page
to show it persisted — this is the single screenshot that proves frontend → backend
→ MongoDB all actually work end to end.

**📸 Screenshot:** `sudo systemctl status travelmemory-backend` on the web server and
`sudo systemctl status mongod` on the db server, both showing `active (running)`.

## 7. Security hardening summary

- DB has no public IP; reachable only through the VPC.
- Security groups are least-privilege: db-sg only trusts web-sg, not the internet.
- MongoDB `bindIp` is explicit (never `0.0.0.0`); `authorization: enabled`; separate
  admin vs. least-privilege app user.
- `ufw` on both hosts is a second layer behind the security groups.
- SSH: key-pair only, `PermitRootLogin no`, `PasswordAuthentication no`.
- IAM role uses AWS managed policies scoped to SSM/CloudWatch — no long-lived keys
  on the instances.

**📸 Screenshot:** `sudo ufw status verbose` on both hosts, showing the scoped rules.

## 8. Cleaning up

```bash
cd terraform
terraform destroy
```

This removes every resource created above (EC2s, NAT Gateway + its Elastic IP,
subnets, route tables, IGW, VPC, security groups, IAM role/profile) so nothing keeps
billing after you're done.

## 9. Troubleshooting log — real issues hit during this deployment

This project targets AWS's current Ubuntu LTS (26.04, "Resolute Raccoon") and the
current MongoDB line, both of which are new enough that some standard tutorials and
default package configs don't line up cleanly yet. These are the actual issues hit
while deploying this stack, in the order they came up, so the same fixes apply if
you hit the same symptoms.

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `pip3 install pymongo` fails: `error: externally-managed-environment` | Ubuntu 26.04 ships Python 3.14 with PEP 668 enforced — no unmanaged system-wide `pip install` | Install `python3-pymongo` via `apt` instead of `pip3` |
| 2 | `Failed to find required executable "apt-key"` | `apt-key` was removed entirely in Ubuntu 26.04 (deprecated since 22.04) | Download the GPG key, `gpg --dearmor` it into `/usr/share/keyrings/`, and reference it with `signed-by=` in the repo line instead of the `apt_key` module |
| 3 | Ansible's "Wait for MongoDB to accept connections" times out, `mongod` crash-loops | MongoDB 5.0+ requires the AVX CPU instruction set; `t2.*` instances (older Xeon generation) don't have it | Use `t3.micro` or newer instance types (this repo defaults to `t3.micro`) |
| 4 | `Unrecognized option: processManagement.timeoutSecondsForKill`, exit code 2 | That config key doesn't exist in MongoDB 7.0 (only later branches) — leftover from an earlier config draft | Remove the `processManagement` block from `mongod.conf.j2` entirely |
| 5 | `mongod` core-dumps (`status=6/ABRT`) or later `Error parsing YAML config: duplicate key: security.authorization` | A manual on-box edit to fix issue #4 left a duplicate `security:` block in `/etc/mongod.conf` | Fix the **template source** (`mongod.conf.j2`), not just the on-box file — `template:` always overwrites the destination in full on the next Ansible run, so any manual patch that isn't also applied to the `.j2` source gets reverted/re-broken on every subsequent run |
| 6 | `community.mongodb.mongodb_user` fails: `Command createUser requires authentication` | The MongoDB "localhost exception" (which allows creating the very first user without auth) only applies when **zero users exist anywhere** — a partial user from an earlier crash-looped run silently disables it | On a fresh test deployment with no real data: `systemctl stop mongod`, wipe `/var/lib/mongodb/*`, `systemctl start mongod`, then re-run the playbook so users are created cleanly |
| 7 | Ansible fails: `'mongo_admin_user' is undefined` even though it's set in `group_vars/all.yml` | `group_vars/` was placed at `ansible/group_vars/`, but the inventory lives at `ansible/inventory/hosts.ini` — Ansible only auto-loads `group_vars` from directories **alongside the inventory file** (or alongside the playbook), so a `group_vars/` at the `ansible/` root is never read | Move it to `ansible/inventory/group_vars/all.yml` |
| 8 | `ssh` through the `ProxyCommand` jump host hangs with "Connection timed out during banner exchange" / "Connection closed by UNKNOWN port 65535" | Stale IP baked into the `ProxyCommand` string in `hosts.ini` (a manually re-typed IP was missing its last digit) after Terraform replaced the instances | Regenerate the inventory with `bash generate_inventory.sh` instead of hand-editing IPs into `hosts.ini` — the script rewrites it cleanly from Terraform's current outputs |
| 9 | AMI lookup for `ubuntu-jammy-22.04-*` returns nothing / not the intended OS | AWS's current default LTS is Ubuntu 26.04 ("Resolute Raccoon"); the naming pattern also changed to `hvm-ssd-gp3` for releases ≥23.10 | Point `data.aws_ami.ubuntu`'s filter at `ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*` |

**General lesson that came out of issues #5 and #7 in particular:** when a
templated file or a var isn't behaving as expected, check the *source of truth*
(the `.j2` template, or where `group_vars` actually needs to live) rather than
patching the live box — Ansible re-applies from source on every run, so any
divergence between the two just resurfaces the same bug on the next `apply`.

**📸 Screenshot (optional but recommended):** `journalctl -u mongod` output showing
one of the above errors, next to the corrected config/task, as before/after
evidence of the debugging process.

## 10. Screenshot / video checklist for submission

Pulling together every 📸 marker above into one list:

- [ ] `aws sts get-caller-identity` — proves AWS CLI auth
- [ ] Exported PNG/SVG of `architecture-diagram.drawio` (File → Export As in draw.io)
- [ ] `terraform init` / `plan` / `apply` output
- [ ] AWS Console VPC resource map (subnets, IGW, NAT Gateway)
- [ ] AWS Console EC2 instance list (both running, one with/one without public IP)
- [ ] `terraform output` showing the IPs
- [ ] `ansible all -m ping` success
- [ ] `ansible-playbook playbooks/site.yml` final `PLAY RECAP` (failed=0)
- [ ] `systemctl status travelmemory-backend` and `systemctl status mongod`
- [ ] `ufw status verbose` on both hosts
- [ ] React app in the browser, plus a trip added and persisted after reload
- [ ] Short screen recording: browser → add a trip → refresh → trip still there
      (this single clip demonstrates the entire stack working together)

## 11. Notes / things to double check against the live repo

- TravelMemory's exact file layout (e.g. `frontend/src/url.js`, backend entry file
  name) can drift between commits. If a templated task doesn't take effect, `ssh`
  into the web server and `grep -rn BASE_URL frontend/src/` / check
  `backend/package.json`'s `main`/`start` script, then adjust the corresponding
  Ansible task path.
- Passwords in `inventory/group_vars/all.yml` are placeholders — change them, and
  prefer `ansible-vault encrypt inventory/group_vars/all.yml` before committing
  anything to a public GitHub repo.

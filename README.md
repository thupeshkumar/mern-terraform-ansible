# Deploying TravelMemory (MERN) on AWS with Terraform + Ansible

This repository provisions AWS infrastructure with Terraform and configures/deploys
the [TravelMemory](https://github.com/UnpredictablePrashant/TravelMemory) MERN app
with Ansible.

## 1. Architecture

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

## 3. Part 1 — Provision infrastructure with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set key_name and my_ip (as x.x.x.x/32)

terraform init
terraform plan
terraform apply       # type "yes" when prompted
```

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

## 4. Part 2 — Configure and deploy with Ansible

From the project root, populate the inventory automatically from Terraform's outputs:

```bash
./generate_inventory.sh
```

This fills in `ansible/inventory/hosts.ini` and `ansible/group_vars/all.yml` with the
real public/private IPs (both files start with placeholders like `WEB_PUBLIC_IP` so
Ansible commands are inert until this script — or a manual edit — runs).

Give the instances ~30–60 seconds to finish booting, then check connectivity:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible all -m ping
```

Review/override the MongoDB credentials in `group_vars/all.yml` (or pass them with
`--extra-vars` / an `ansible-vault` file — don't leave real passwords in git history),
then run the full deployment:

```bash
ansible-playbook playbooks/site.yml
```

`site.yml` runs `database.yml` first (so the app's Mongo user exists before the
backend starts) and then `webserver.yml`. What each does:

**`database.yml`** (targets `db`)
- Installs MongoDB 7.0 from the official repo. Its apt repo only publishes for the
  `jammy` (22.04) suite (it was never extended to `noble`), and Ubuntu 26.04
  ("resolute") has no native MongoDB suite yet either, so the playbook points 26.04
  hosts at `jammy` instead — the documented workaround, one LTS further back than
  the 8.0/`noble` workaround used for newer MongoDB branches.
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

## 6. Verifying the deployment

```bash
# Backend health check directly
curl http://<web-public-ip>:3001/trip

# Frontend
open http://<web-public-ip>/          # or just visit it in a browser
```

Also worth capturing for your submission screenshots/video:
- `terraform apply` output showing the created resources.
- AWS Console: VPC resource map, the two EC2 instances (one with/one without a public IP).
- `ansible all -m ping` success output.
- The React app loaded in a browser, adding a trip end-to-end (proves frontend →
  backend → MongoDB all work).
- `sudo systemctl status travelmemory-backend` and `sudo systemctl status mongod`
  on the respective hosts.

## 7. Security hardening summary

- DB has no public IP; reachable only through the VPC.
- Security groups are least-privilege: db-sg only trusts web-sg, not the internet.
- MongoDB `bindIp` is explicit (never `0.0.0.0`); `authorization: enabled`; separate
  admin vs. least-privilege app user.
- `ufw` on both hosts is a second layer behind the security groups.
- SSH: key-pair only, `PermitRootLogin no`, `PasswordAuthentication no`.
- IAM role uses AWS managed policies scoped to SSM/CloudWatch — no long-lived keys
  on the instances.

## 8. Cleaning up

```bash
cd terraform
terraform destroy
```

This removes every resource created above (EC2s, NAT Gateway + its Elastic IP,
subnets, route tables, IGW, VPC, security groups, IAM role/profile) so nothing keeps
billing after you're done.

## 9. Notes / things to double check against the live repo

- **Instance type matters for MongoDB.** MongoDB 5.0 and later require the AVX CPU
  instruction set. `t2.*` instances (older Xeon generation) don't have AVX — `mongod`
  will start, crash immediately, and loop, which shows up as Ansible's "Wait for
  MongoDB to accept connections" task timing out. Use `t3.micro` or newer (already
  the default here). If you hit that timeout, `ssh` in and check
  `sudo systemctl status mongod` / `sudo journalctl -u mongod --no-pager | tail -50`
  to confirm before assuming it's a config problem.
- TravelMemory's exact file layout (e.g. `frontend/src/url.js`, backend entry file
  name) can drift between commits. If a templated task doesn't take effect, `ssh`
  into the web server and `grep -rn BASE_URL frontend/src/` / check
  `backend/package.json`'s `main`/`start` script, then adjust the corresponding
  Ansible task path.
- Passwords in `group_vars/all.yml` are placeholders — change them, and prefer
  `ansible-vault encrypt group_vars/all.yml` before committing anything to a public
  GitHub repo.

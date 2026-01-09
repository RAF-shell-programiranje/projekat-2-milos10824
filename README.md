
# Projekat 2 – Automatizovani deployment aplikacije i monitoring (Azure + Terraform + Ansible + Bash)

Ovaj repozitorijum implementira kompletan sistem koji:
- **provisionuje 2 VM-a na Azure-u** (APP VM + MONITOR VM) koristeći Terraform,
- **deploy-uje Java aplikaciju** kao **systemd servis** koristeći Ansible,
- **deploy-uje monitoring sistem** bash skriptom na MONITOR VM (systemd timer),
- **šalje email notifikacije** kada aplikacija nije dostupna / servis nije aktivan / postoje ERROR u logu / resursi pređu prag.

> U repozitorijumu je zadržan originalni `project2_dummy_service-1.0-SNAPSHOT.jar` i `text.pdf` (materijal koji si dobio na početku).

---

## Arhitektura

- **APP VM** (Ubuntu 22.04):
  - Java 17 runtime
  - `project2-dummy` systemd servis pokreće jar:
    - log: `/var/log/project2-dummy/app.log`
    - broj agenata: promenljiv (`APP_AGENTS`, podrazumevano 50)

- **MONITOR VM** (Ubuntu 22.04):
  - `/opt/monitoring/monitoring-agent.sh` periodično radi:
    - HTTP proveru dostupnosti aplikacije
    - proveru systemd statusa servisa na APP VM
    - analizu poslednjih 500 linija log-a (WARN/ERROR)
    - proveru resursa APP VM (CPU/MEM/DISK)
    - email alert preko SMTP (msmtp)
  - pokretanje preko systemd timer-a

---

## Preduslovi na tvom računaru

Instalirano lokalno:
- `az` (Azure CLI) i login: `az login`
- `terraform`
- `ansible`
- `ssh`, `scp`

---

## Pokretanje (glavna skripta)

Skripta `automatic_deploy.sh` ima režime rada iz specifikacije:

### 1) Provision (Terraform)
```bash
./automatic_deploy.sh --provision
```

Ovo će:
- generisati SSH ključ u `.keys/` (da ne zavisi od tvog `~/.ssh`),
- napraviti `terraform/terraform.tfvars` (ako ne postoji),
- uraditi `terraform apply`,
- generisati `ansible/inventory.ini`,
- generisati `monitoring/monitoring.conf` (moraš ručno popuniti SMTP podatke).

**Preporuka (bezbednost):** pre provision-a setuj:
```bash
export ALLOWED_SSH_CIDR="TVOJ_PUBLIC_IP/32"
```

### 2) Deploy aplikacije (Ansible)
```bash
./automatic_deploy.sh --deploy
```

Podrazumevano koristi 50 agenata. Ako želiš drugačije:
```bash
APP_AGENTS=200 ./automatic_deploy.sh --deploy
```

> Napomena: 500 agenata često preoptereti `Standard_B1s` (free trial), zato je default 50.

### 3) Check status
```bash
./automatic_deploy.sh --check-status
```

### 4) Monitoring (bash)
1) Otvori i izmeni `monitoring/monitoring.conf`:
- `SMTP_HOST/SMTP_PORT/SMTP_USER/SMTP_PASS/SMTP_TO/SMTP_FROM`

2) Instaliraj monitoring:
```bash
./automatic_deploy.sh --monitor
```

Log na MONITOR VM:
```bash
sudo tail -n 200 /var/log/monitoring-agent.log
```

### 5) Teardown (brisanje resursa)
```bash
./automatic_deploy.sh --teardown
```

---

## SMTP napomena (Azure ograničenje)

Na Azure-u je često **blokiran port 25** (outbound SMTP). Zato je predviđen SMTP preko **587/STARTTLS** (npr. Gmail app password ili neki drugi SMTP provider).

---

## Pokretanje jar-a ručno (informativno)

Originalni način:
```bash
java -jar project2_dummy_service-1.0-SNAPSHOT.jar <log_location> <number_of_agents>
```

U ovom rešenju to radi systemd servis i prosleđuje:
- `log_location=/var/log/project2-dummy/app.log`
- `number_of_agents` = `APP_AGENTS`

---

## Struktura projekta

- `terraform/` – Azure infrastruktura (2 VM + networking + NSG)
- `ansible/` – playbook za deploy aplikacije kao systemd servis
- `monitoring/` – monitoring-agent + instalacija na MONITOR VM
- `automatic_deploy.sh` – orkestracija režima rada

---
>>>>>>> 55bf94a (Projekat 2 - Terraform + Ansible + monitoring)

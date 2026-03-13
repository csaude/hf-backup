# SOP — Sistema de Backup de Unidade Sanitária

**Projecto:** CSaude — Sistema de Backups de Recuperação de Desastres
**Âmbito:** Instalação, operação e recuperação do cliente de backup nas Unidades Sanitárias (US)

---

## Índice

1. [Visão Geral](#1-visão-geral)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Instalação](#3-instalação)
4. [Configuração do `.env`](#4-configuração-do-env)
5. [Passos Pós-Instalação](#5-passos-pós-instalação)
6. [Operações do Dia-a-Dia](#6-operações-do-dia-a-dia)
7. [Informação Crítica a Guardar](#7-informação-crítica-a-guardar)
8. [Troubleshooting](#8-troubleshooting)
9. [Listar e Restaurar Backups](#9-listar-e-restaurar-backups)
10. [Recuperação Total numa Máquina Nova](#10-recuperação-total-numa-máquina-nova)

---

## 1. Visão Geral

O sistema de backup é composto por um único script instalador — `hf_backup.sh` — que, quando executado na directoria de trabalho da US, gera automaticamente todos os ficheiros necessários:

- `.env` — ficheiro de configuração e estado
- `hf-tool.sh` — ferramenta de gestão do dia-a-dia
- `compose.yml` — definição do contentor Docker
- `config/borgmatic.d/config.yaml` — configuração do borgmatic
- `runtime/backup.sh` — script de backup executado dentro do contentor
- Chaves SSH (`id_rsa`, `id_kek`) para comunicação com o servidor central

O **nome da directoria de trabalho** é o identificador da US (código da facilidade), por exemplo `namacurra`. Todos os serviços, utilizadores remotos e caminhos são derivados deste nome.

```
Arquitectura simplificada:

  [US: namacurra/]          SSH/Borg         [Servidor Central]
  hf-tool.sh           ─────────────────►   /backup/<partner>/namacurra/repo/
  contentor Docker     ─── SFTP (KEK) ───►  /backup/<partner>/namacurra/csr/
                                         ◄── signed cert ────────────────────
```

---

## 2. Pré-requisitos

Na máquina da US, antes de executar o instalador:

| Requisito | Verificação |
|---|---|
| Sistema operativo Ubuntu 22.04/24.04 | `lsb_release -a` |
| Docker Engine instalado | `docker --version` |
| Docker Compose (plugin ou standalone) | `docker compose version` |
| OpenSSL | `openssl version` |
| Cliente OpenSSH | `ssh -V` |
| Acesso root (sudo) | `sudo -v` |
| Conectividade ao servidor central | ver secção [Troubleshooting](#8-troubleshooting) |

---

## 3. Instalação

### 3.1. Criar a directoria de trabalho

O nome da directoria **deve ser exactamente o código da US** (letras minúsculas, sem espaços):

```bash
mkdir namacurra
cd namacurra
```

> **Atenção:** Todos os serviços, chaves e caminhos remotos são derivados deste nome. Nunca renomear esta directoria após a instalação.

### 3.2. Executar o instalador

```bash
sudo bash /caminho/para/hf_backup.sh
```

O instalador irá:

1. Pedir confirmação da directoria de instalação
2. Criar o ficheiro `.env` com a configuração base
3. Solicitar a definição do `BORG_PASSPHRASE` (guardada no `.env`)
4. Gerar as chaves SSH `id_rsa` (backup Borg) e `id_kek` (SFTP/monitorização)
5. Criar o arquivo `hf-namacurra-keys.tar.gz` com as chaves públicas para o administrador central
6. Escrever todos os scripts e ficheiros de configuração
7. Instalar e activar o serviço e timer systemd

### 3.3. Regras para a BORG_PASSPHRASE

A palavra-passe deve conter **pelo menos 3 dos 4 grupos** seguintes:
- Letras minúsculas
- Letras maiúsculas
- Números
- Caracteres especiais (ex: `!@#$%`)

> **GUARDAR IMEDIATAMENTE** esta palavra-passe num local seguro. Sem ela é **impossível** recuperar os backups.

---

## 4. Configuração do `.env`

Após a instalação, editar o ficheiro `.env` na directoria da US:

```bash
sudo vim .env
```

### Parâmetros principais

```ini
# Código da US (não alterar)
FACILITY_CODE="namacurra"

# Servidor central de backup
CENTRAL_HOST=hf-backup.csaude.org.mz
CENTRAL_PORT=22

# Activa monitorização mTLS (true/false)
ENABLE_MONIT=true

# Directoria de backups dentro do contentor
BACKUP_ROOT=/var/backups

# Retenção de dumps locais em dias (7 = apagar dumps com mais de 7 dias)
LOCAL_DUMP_RETENTION_DAYS=7

# Borg
BORG_REPO=ssh://namacurra@hf-backup.csaude.org.mz:22/./repo
BORG_PASSPHRASE=<palavra-passe-definida-na-instalacao>
BORG_FAIL_MODE=warn   # warn = falha não crítica | fail = falha crítica

# Base de dados MySQL/MariaDB (deixar vazio para ignorar)
MYSQL_HOST=localhost
MYSQL_PORT=3306
MYSQL_USER=
MYSQL_PASSWORD=
MYSQL_DATABASE=

# Base de dados PostgreSQL (deixar vazio para ignorar)
PGHOST=localhost
PGPORT=5432
PGUSER=
PGPASSWORD=
PGDATABASE=
```

---

## 5. Passos Pós-Instalação

### 5.1. Enviar as chaves públicas ao administrador central

```bash
# O ficheiro foi criado na directoria da US:
ls hf-namacurra-keys.tar.gz
```

Enviar este ficheiro ao administrador do servidor central. O administrador irá:
- Criar o utilizador `namacurra` no servidor
- Configurar o `authorized_keys` com as chaves públicas recebidas
- Inicializar a estrutura de directorias do repositório

### 5.2. Gerar certificado de monitorização (se `ENABLE_MONIT=true`)

```bash
./hf-tool.sh --gen-cert
```

Este comando:
1. Gera a chave TLS privada e o CSR
2. Envia o CSR ao servidor central via SFTP (usando `id_kek`)
3. Tenta descarregar o certificado assinado (se já disponível)

Aguardar que o administrador central assine o CSR. Quando disponível, executar novamente:

```bash
./hf-tool.sh --gen-cert
```

Verificar o estado:

```bash
./hf-tool.sh --status
```

Saída esperada quando pronto:
```
_monitoring=enabled
_private_key_generated=yes
_csr_generated=yes
_csr_submitted=yes
_cert_downloaded=yes
_borg_initialized=no
_status=complete
```

### 5.3. Inicializar o repositório Borg

```bash
./hf-tool.sh --init
```

### 5.4. Testar o primeiro backup

```bash
sudo ./hf-tool.sh --backup-now
```

Verificar os logs:

```bash
tail -f /opt/hf-backup/namacurra/logs/*.log
```

---

## 6. Operações do Dia-a-Dia

O `hf-tool.sh` é a ferramenta principal para gestão. Deve ser executado **a partir da directoria da US**:

```bash
cd /opt/hf-backup/namacurra
```

### Comandos disponíveis

| Comando | Descrição |
|---|---|
| `./hf-tool.sh --help` | Mostrar ajuda |
| `./hf-tool.sh --status` | Ver estado interno (flags do `.env`) |
| `./hf-tool.sh --backup-now` | Executar backup imediato |
| `./hf-tool.sh --gen-cert` | Gerar/renovar certificado TLS de monitorização |
| `./hf-tool.sh --init` | Inicializar repositório Borg no servidor central |
| `./hf-tool.sh --schedule` | Editar o horário do backup automático (requer sudo) |
| `./hf-tool.sh --shell` | Abrir consola administrativa no contentor |

### Verificar o serviço systemd

```bash
# Estado do timer (agendamento)
systemctl status hf-backup-namacurra.timer

# Estado do serviço (última execução)
systemctl status hf-backup-namacurra.service

# Ver logs do serviço
journalctl -u hf-backup-namacurra.service -n 50 --no-pager
```

### Alterar horário do backup

```bash
sudo ./hf-tool.sh --schedule
# Formato: HH:MM ou múltiplos separados por vírgula (ex: 01:00,13:00)
```

---

## 7. Informação Crítica a Guardar

> **AVISO:** Os dados abaixo são **indispensáveis** para recuperar os backups numa máquina diferente. Guardar em local seguro, fora da máquina da US (ex: cofre, gestor de palavras-passe corporativo).

### 7.1. Valores do `.env` a preservar

| Chave | Importância | Localização |
|---|---|---|
| `BORG_PASSPHRASE` | **CRÍTICA** — sem ela os backups são inacessíveis | `.env` |
| `CENTRAL_HOST` | Endereço do servidor central | `.env` |
| `CENTRAL_PORT` | Porta SSH do servidor central | `.env` |
| `FACILITY_CODE` | Código da US (= nome da directoria) | `.env` |
| `BORG_REPO` | URL completo do repositório Borg | `.env` |
| `MYSQL_*` / `PG*` | Credenciais de base de dados | `.env` |

### 7.2. Ficheiros a fazer backup

```bash
# Directoria base de instalação
BASE=/opt/hf-backup/namacurra

# Ficheiros críticos:
$BASE/.env                          # Toda a configuração
$BASE/ssh/id_rsa                    # Chave privada SSH (Borg)
$BASE/ssh/id_rsa.pub                # Chave pública SSH (Borg)
$BASE/ssh/id_kek                    # Chave privada SSH (SFTP/KEK)
$BASE/ssh/id_kek.pub                # Chave pública SSH (SFTP/KEK)
$BASE/ssh/known_hosts               # Fingerprint do servidor central
$BASE/ssh/tls/                      # Certificados TLS (monitorização)
$BASE/config/borgmatic.d/config.yaml  # Configuração borgmatic
```

Comando para criar um arquivo de recuperação:

```bash
sudo tar -czf /tmp/hf-namacurra-recovery-$(date +%F).tar.gz \
  /opt/hf-backup/namacurra/.env \
  /opt/hf-backup/namacurra/ssh/ \
  /opt/hf-backup/namacurra/config/
```

> Guardar este arquivo num servidor externo ou pen drive segura.

---

## 8. Troubleshooting

### 8.1. Verificar conectividade de rede básica

```bash
# Testar conectividade ICMP ao servidor central
ping -c 4 hf-backup.csaude.org.mz

# Se o nome não resolver, testar por IP
ping -c 4 <ip-do-servidor>
```

### 8.2. Verificar resolução DNS

```bash
# Com dig (preferido)
dig hf-backup.csaude.org.mz

# Ver apenas o endereço IP
dig +short hf-backup.csaude.org.mz

# Especificar servidor DNS manualmente
dig @8.8.8.8 hf-backup.csaude.org.mz

# Com nslookup (alternativa)
nslookup hf-backup.csaude.org.mz

# Verificar configuração DNS local
cat /etc/resolv.conf
```

**Resultado esperado:** O nome deve resolver para o IP do servidor central. Se não resolver, verificar:
- Configuração de DNS (`/etc/resolv.conf`)
- Firewall local ou do ISP
- Contactar o administrador de rede

### 8.3. Verificar conectividade SSH

```bash
# Testar porta SSH do servidor central
nc -zv hf-backup.csaude.org.mz 22
# ou
ssh -p 22 -i /opt/hf-backup/namacurra/ssh/id_rsa namacurra@hf-backup.csaude.org.mz

# Teste verbose (para diagnóstico detalhado)
ssh -vvv -p 22 -i /opt/hf-backup/namacurra/ssh/id_rsa namacurra@hf-backup.csaude.org.mz
```

**Nota:** A ligação SSH com `id_rsa` executa apenas `borg serve` no servidor (acesso restrito). Uma ligação bem-sucedida pode mostrar `Connection closed` — isso é normal.

### 8.4. Verificar estado da instalação

```bash
cd /opt/hf-backup/namacurra
./hf-tool.sh --status
```

| Flag | Valor esperado | Descrição |
|---|---|---|
| `_monitoring` | `enabled` ou `disabled` | Monitorização mTLS activa |
| `_private_key_generated` | `yes` | Chave TLS gerada |
| `_csr_generated` | `yes` | CSR gerado |
| `_csr_submitted` | `yes` | CSR enviado ao servidor |
| `_cert_downloaded` | `yes` | Certificado assinado recebido |
| `_borg_initialized` | `yes` | Repositório Borg inicializado |
| `_status` | `complete` | Instalação concluída |

### 8.5. Verificar se o Docker está a correr

```bash
docker ps
docker compose -f /opt/hf-backup/namacurra/compose.yml ps
```

### 8.6. Ver logs de backup

```bash
# Logs do contentor (última execução)
journalctl -u hf-backup-namacurra.service --no-pager -n 100

# Logs dentro da directoria
ls /opt/hf-backup/namacurra/logs/
tail -f /opt/hf-backup/namacurra/logs/*.log
```

### 8.7. Erros comuns

| Erro | Causa | Solução |
|---|---|---|
| `BORG_PASSPHRASE` is wrong | Palavra-passe incorrecta | Verificar `.env` |
| `Repository does not exist` | Repo não inicializado | Executar `./hf-tool.sh --init` |
| `Connection refused` porta 22 | Firewall ou servidor em baixo | Verificar rede, contactar admin |
| `Signed certificate not yet available` | Admin ainda não assinou o CSR | Aguardar e re-executar `--gen-cert` |
| `Docker Compose not found` | Docker não instalado correctamente | Reinstalar Docker Engine |

---

## 9. Listar e Restaurar Backups

Todos os comandos Borg e borgmatic são executados **dentro do contentor**, através da consola administrativa:

```bash
cd /opt/hf-backup/namacurra
./hf-tool.sh --shell
```

O script pergunta o directório de restauro local (por defeito `/tmp/hf-backup-namacurra`). Este directório é montado em `/restore` dentro do contentor.

### 9.1. Listar todos os arquivos (archives)

Dentro do contentor:

```bash
# Via borgmatic (recomendado)
borgmatic list

# Directamente via borg
borg list

# Com mais detalhe
borg list --format '{archive}{NL}'
```

Exemplo de saída:
```
namacurra-2026-03-10T01:00:05       Mon, 2026-03-10 01:00:05
namacurra-2026-03-11T01:00:03       Tue, 2026-03-11 01:00:03
namacurra-2026-03-12T01:00:06       Wed, 2026-03-12 01:00:06
```

### 9.2. Ver informação do repositório

```bash
borgmatic info

# Ou directamente
borg info
```

### 9.3. Listar ficheiros dentro de um arquivo específico

```bash
# Via borgmatic
borgmatic list --archive namacurra-2026-03-12T01:00:06

# Via borg (mostra todos os ficheiros)
borg list ::namacurra-2026-03-12T01:00:06

# Filtrar por caminho
borg list ::namacurra-2026-03-12T01:00:06 var/backups/db/
```

### 9.4. Restaurar um ficheiro específico

```bash
# Dentro do contentor, o directório /restore está montado localmente

# Extrair um ficheiro (caminhos sem / inicial)
cd /restore
borg extract ::namacurra-2026-03-12T01:00:06 var/backups/db/mysql/mysql_openimis_2026-03-12.sql.gz

# Extrair uma directoria completa
borg extract ::namacurra-2026-03-12T01:00:06 var/backups/db/

# Extrair tudo do arquivo
borg extract ::namacurra-2026-03-12T01:00:06
```

Os ficheiros ficam disponíveis em `/restore` (dentro do contentor) e no directório local que indicou ao iniciar o `--shell`.

### 9.5. Restaurar dump de base de dados MySQL

```bash
# Dentro do contentor, após extracção:
cd /restore
gunzip -c var/backups/db/mysql/mysql_openimis_2026-03-12.sql.gz | mysql -h localhost -u root -p openimis
```

### 9.6. Restaurar dump de base de dados PostgreSQL

```bash
# Dentro do contentor, após extracção:
cd /restore
pg_restore -h localhost -U postgres -d openimis -F c var/backups/db/postgres/pg_openimis_2026-03-12.dump
```

---

## 10. Recuperação Total numa Máquina Nova

Seguir estes passos quando a máquina original é destruída/insubstituível e é necessário recuperar numa nova máquina.

### Pré-condição

Ter disponíveis (da secção [7. Informação Crítica a Guardar](#7-informação-crítica-a-guardar)):
- `BORG_PASSPHRASE`
- `CENTRAL_HOST`, `CENTRAL_PORT`
- Chaves SSH privadas (`id_rsa`, `id_kek`) **ou** acordar novas chaves com o administrador central
- Código da US (`FACILITY_CODE`)

### 10.1. Preparar a nova máquina

```bash
# Instalar Docker (Ubuntu)
apt-get update
apt-get install -y docker.io docker-compose-plugin openssl openssh-client

# Activar Docker
systemctl enable --now docker
```

### 10.2. Recriar a estrutura de directorias

```bash
# O nome da directoria DEVE ser o mesmo código da US
mkdir -p /opt/hf-backup/namacurra
cd /opt/hf-backup/namacurra
```

### 10.3. Executar o instalador

```bash
sudo bash /caminho/para/hf_backup.sh
```

Quando solicitar a `BORG_PASSPHRASE`, **inserir a palavra-passe original** (guardada na secção 7).

### 10.4. Restaurar os ficheiros críticos (se disponíveis)

Se tiver o arquivo de recuperação criado na secção 7:

```bash
# Extrair o arquivo de recuperação
sudo tar -xzf hf-namacurra-recovery-YYYY-MM-DD.tar.gz -C /

# Verificar que as chaves foram restauradas
ls -la /opt/hf-backup/namacurra/ssh/
```

Se **não tiver** as chaves SSH antigas, será necessário registar as novas chaves no servidor central:

```bash
# Ver as novas chaves públicas geradas
cat /opt/hf-backup/namacurra/ssh/id_rsa.pub
cat /opt/hf-backup/namacurra/ssh/id_kek.pub

# Enviar ao administrador central para actualizar o authorized_keys
ls hf-namacurra-keys.tar.gz
```

### 10.5. Editar o `.env` com os valores correctos

```bash
sudo vim /opt/hf-backup/namacurra/.env
```

Garantir que os seguintes valores estão correctos:

```ini
BORG_PASSPHRASE=<palavra-passe-original>
CENTRAL_HOST=hf-backup.csaude.org.mz
CENTRAL_PORT=22
BORG_REPO=ssh://namacurra@hf-backup.csaude.org.mz:22/./repo
```

### 10.6. Aguardar confirmação do administrador central

O administrador central precisa de confirmar que:
- As chaves SSH estão registadas no `authorized_keys`
- O repositório Borg no servidor central está intacto

### 10.7. Regenerar certificado de monitorização (se aplicável)

```bash
cd /opt/hf-backup/namacurra
./hf-tool.sh --gen-cert
```

Aguardar assinatura do CSR pelo administrador e executar novamente até `_cert_downloaded=yes`.

### 10.8. Verificar acesso ao repositório existente

```bash
# Não executar --init (o repositório já existe no servidor!)
# Verificar apenas o acesso
./hf-tool.sh --shell
```

Dentro do contentor:

```bash
# Testar acesso ao repositório
borg list

# Se retornar a lista de arquivos, o acesso está funcional
```

### 10.9. Restaurar dados

Seguir os passos da [secção 9](#9-listar-e-restaurar-backups) para restaurar os ficheiros necessários.

### 10.10. Retomar backups automáticos

```bash
# Verificar que o timer está activo
systemctl status hf-backup-namacurra.timer

# Activar se necessário
sudo systemctl enable --now hf-backup-namacurra.timer

# Testar backup imediato
sudo ./hf-tool.sh --backup-now
```

---

## Referência Rápida

```
Instalação:
  mkdir <codigo_us> && cd <codigo_us>
  sudo bash hf_backup.sh

Pós-instalação:
  sudo vim .env                    # configurar credenciais BD e BORG_PASSPHRASE
  ./hf-tool.sh --gen-cert          # gerar/enviar CSR (se ENABLE_MONIT=true)
  ./hf-tool.sh --init              # inicializar repositório Borg
  sudo ./hf-tool.sh --backup-now   # primeiro backup manual

Gestão:
  ./hf-tool.sh --status            # ver estado
  ./hf-tool.sh --backup-now        # backup imediato
  sudo ./hf-tool.sh --schedule     # alterar horário
  ./hf-tool.sh --shell             # consola administrativa

Dentro da consola (--shell):
  borgmatic list                           # listar arquivos
  borg list ::nome-arquivo                 # listar ficheiros no arquivo
  borg extract ::nome-arquivo caminho/     # extrair ficheiros para /restore

Recuperação de desastre:
  1. Nova máquina + Docker
  2. mkdir <mesmo_codigo_us> && cd <mesmo_codigo_us>
  3. sudo bash hf-backup.sh        # usar BORG_PASSPHRASE original
  4. Restaurar .env e chaves SSH
  5. ./hf-tool.sh --shell → borg list → borg extract
```

---

*Documento gerado para o projecto CSaude — Sistema de Backups HF*

# SOP — Sistema de Backup de Unidades Sanitárias (hf-backup)

**Projecto:** CSaude — Sistema de Backups de Recuperação de Desastres
**Âmbito:** Instalação, operação e recuperação do cliente de backup nas Unidades Sanitárias (US)

---

## Índice

0. [Guia de Arranque Rápido](#0-guia-de-arranque-rápido)
1. [Visão Geral](#1-visão-geral)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Instalação](#3-instalação)
4. [Configuração do `.env`](#4-configuração-do-env)
5. [Passos Pós-Instalação](#5-passos-pós-instalação)
6. [Operações do Dia-a-Dia](#6-operações-do-dia-a-dia)
7. [Monitorização Local (Web)](#7-monitorização-local-web)
8. [Informação Crítica a Guardar](#8-informação-crítica-a-guardar)
9. [Troubleshooting](#9-troubleshooting)
10. [Listar e Restaurar Backups](#10-listar-e-restaurar-backups)
11. [Recuperação Total numa Máquina Nova](#11-recuperação-total-numa-máquina-nova)
12. [Actualizações e Re-execução do Instalador](#12-actualizações-e-re-execução-do-instalador)

---

## 0. Guia de Arranque Rápido

Para quem quer instalar e activar o sistema de backups o mais rapidamente possível. O exemplo usa `namacurra` como código da US — substituir pelo código real.

### Passo 1 — Criar a directoria de trabalho

```bash
sudo mkdir -p /opt/hf-backup/namacurra
cd /opt/hf-backup/namacurra
```

> O nome da directoria **é** o identificador da US. Usar apenas letras minúsculas e sem espaços.

### Passo 2 — Obter o instalador

**US com acesso à internet:**

```bash
git clone https://github.com/csaude/hf-backup.git .
```

**US sem acesso à internet:**

1. Noutro computador com internet, aceder a [https://github.com/csaude/hf-backup](https://github.com/csaude/hf-backup) e descarregar o repositório como ZIP (botão **Code → Download ZIP**).
2. Copiar o ficheiro ZIP para uma pen drive.
3. Na máquina da US, copiar o ZIP para a directoria criada no passo anterior e extrair:

```bash
cp /media/<pen>/hf-backup-main.zip /opt/hf-backup/namacurra/
unzip hf-backup-main.zip && mv hf-backup-main/* . && rm -rf hf-backup-main
```

### Passo 3 — Executar o instalador

```bash
sudo bash hf-backup.sh
```

Quando solicitado, definir uma `BORG_PASSPHRASE` forte (mínimo 8 caracteres). **Guardar imediatamente num local seguro fora desta máquina** — sem ela é impossível recuperar qualquer backup.

### Passo 4 — Enviar as chaves ao administrador central

O instalador gera o ficheiro `hf-namacurra-keys.tar.gz`. Enviar ao administrador do servidor central e aguardar confirmação de que o utilizador foi criado e as chaves registadas.

```bash
ls hf-namacurra-keys.tar.gz   # confirmar que o ficheiro existe
```

### Passo 5 — (Opcional) Adicionar bases de dados ao backup

Repetir para cada base de dados a incluir:

```bash
sudo ./hf-tool.sh --db-add
```

### Passo 6 — Inicializar o repositório

```bash
sudo ./hf-tool.sh --init
```

Este comando trata de tudo: troca de certificados mTLS (se aplicável), inicialização do repositório Borg, instalação do serviço systemd e configuração do horário do backup automático.

> Se a monitorização estiver activa (`ENABLE_MONIT=true`) e o administrador ainda não tiver assinado o certificado, o comando avisa e termina — basta re-executá-lo após confirmação.

### Passo 7 — Executar o primeiro backup

```bash
sudo ./hf-tool.sh --backup-now
```

### Passo 8 — Verificar o estado no browser

Abrir num browser da rede local:

```
http://<IP_DA_US>:22587
```

A página mostra o estado em tempo real, o histórico de backups e permite accionar um backup imediato.

### Resumo de comandos essenciais

| O que fazer | Comando |
|---|---|
| Ver estado da instalação | `./hf-tool.sh --init-status` |
| Fazer backup imediato | `sudo ./hf-tool.sh --backup-now` |
| Ver todos os parâmetros | `./hf-tool.sh --list-vars` |
| Alterar um parâmetro | `sudo ./hf-tool.sh --set PARAMETRO` |
| Abrir consola de restauro | `./hf-tool.sh --shell` |
| Criar arquivo de recuperação | `./hf-tool.sh --backup-config` |
| Monitorização web | `http://<IP_DA_US>:22587` |

---

## 1. Visão Geral

O sistema de backup é composto por um único script instalador — `hf-backup.sh` — que, quando executado na directoria de trabalho da US, gera automaticamente todos os ficheiros necessários:

- `.env` — ficheiro de configuração e estado
- `hf-tool.sh` — ferramenta de gestão do dia-a-dia
- `compose.yml` — definição dos contentores Docker
- `config/borgmatic.d/config.yaml` — configuração do borgmatic
- `runtime/backup.sh` — script de backup executado dentro do contentor
- `runtime/web-server/server.py` — servidor de monitorização local (porta 22587)
- Chaves SSH (`id_rsa`, `id_kek`) para comunicação com o servidor central

O **nome da directoria de trabalho** é o identificador da US (código da facilidade), por exemplo `namacurra`. Todos os serviços, utilizadores remotos e caminhos são derivados deste nome.

```
Arquitectura simplificada:

  [US: namacurra/]          SSH/Borg         [Servidor Central]
  hf-tool.sh           ─────────────────►   /backup/<partner>/namacurra/repo/
  contentor Docker     ─── SFTP (KEK) ───►  /backup/<partner>/namacurra/csr/
                                         ◄── signed cert ────────────────────

  [Browser LAN]    HTTP :22587
       └──────────────────────► contentor hf-web  (estado + histórico)
```

### Modos de backup

| Modo | Descrição |
|---|---|
| `central` (padrão) | Repositório Borg num servidor remoto via SSH |
| `local` | Repositório Borg num dispositivo de armazenamento externo (USB, NAS, disco externo) |

### Contentores Docker

| Contentor | Função |
|---|---|
| `hf-backup-<us>` | Executa o borgmatic (backup, prune, compact, check) |
| `hf-web-<us>` | Servidor HTTP de monitorização local (porta 22587) |

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
| Conectividade ao servidor central | ver secção [Troubleshooting](#9-troubleshooting) |

---

## 3. Instalação

### 3.1. Criar a directoria de trabalho

O nome da directoria **deve ser exactamente o código da US** (letras minúsculas, sem espaços):

```bash
mkdir namacurra
cd namacurra
```

> **Atenção:** Todos os serviços, chaves e caminhos remotos são derivados deste nome. Nunca renomear esta directoria após a instalação.

### 3.2. Obter o instalador

**US com acesso à internet:**

```bash
git clone https://github.com/csaude/hf-backup.git .
```

**US sem acesso à internet:**

1. Noutro computador com internet, aceder a [https://github.com/csaude/hf-backup](https://github.com/csaude/hf-backup) e descarregar o repositório como ZIP (botão **Code → Download ZIP**).
2. Copiar o ficheiro ZIP para uma pen drive.
3. Na máquina da US, copiar o ZIP para a directoria da US e extrair:

```bash
cp /media/<pen>/hf-backup-main.zip /opt/hf-backup/namacurra/
unzip hf-backup-main.zip && mv hf-backup-main/* . && rm -rf hf-backup-main
```

### 3.3. Executar o instalador

```bash
sudo bash hf-backup.sh
```

O instalador irá:

1. Pedir confirmação da directoria de instalação
2. Criar o ficheiro `.env` com a configuração base
3. Solicitar a definição do `BORG_PASSPHRASE`
4. Gerar as chaves SSH `id_rsa` (backup Borg) e `id_kek` (SFTP/monitorização)
5. Criar o arquivo `hf-namacurra-keys.tar.gz` com as chaves públicas para o administrador central
6. Escrever todos os scripts e ficheiros de configuração
7. Verificar/obter a imagem Docker necessária

> **Nota:** O instalador **não** instala os serviços systemd. Isso acontece durante o passo `--init`.

### 3.4. Regras para a BORG_PASSPHRASE

A palavra-passe deve ter **pelo menos 8 caracteres**. É solicitada durante a instalação e também durante o `--init` caso ainda não esteja definida.

> **GUARDAR IMEDIATAMENTE** esta palavra-passe num local seguro fora da máquina. Sem ela é **impossível** recuperar os backups.

---

## 4. Configuração do `.env`

O ficheiro `.env` é criado automaticamente pelo instalador na directoria da US. Pode rever e alterar os parâmetros com:

```bash
sudo ./hf-tool.sh --list-vars        # listar todos os parâmetros
sudo ./hf-tool.sh --set PARAMETRO    # alterar um parâmetro
```

### Parâmetros principais

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `FACILITY_CODE` | nome da dir. | Código da US (não alterar) |
| `CENTRAL_HOST` | `hf-backup.csaude.org.mz` | Endereço do servidor central |
| `CENTRAL_PORT` | `22` | Porta SSH do servidor central |
| `ENABLE_MONIT` | `true` | Activar monitorização mTLS (true/false) |
| `BACKUP_ROOT` | `/app/backups` | Directoria de dumps dentro do contentor |
| `LOCAL_DUMP_RETENTION_DAYS` | `7` | Retenção de dumps locais (dias; 0=apaga todos; vazio=guarda sempre) |
| `BORG_SERVER_ENABLED` | `true` | Activar upload para servidor central (false = apenas dumps locais) |
| `BORG_FAIL_MODE` | `warn` | `warn` = falha não crítica; `fail` = falha crítica |
| `BORG_MODE` | `central` | Modo de backup: `central` ou `local` |
| `EXTERNAL_STORAGE_PATH` | _(vazio)_ | Caminho do dispositivo externo (modo `local`) |
| `BORG_REPO` | _gerado_ | URL completo do repositório Borg |
| `BORG_PASSPHRASE` | _(definido na instalação)_ | Palavra-passe de encriptação Borg |
| `BORGMATIC_VERBOSITY` | `2` | Nível de detalhe do borgmatic (0–4) |
| `SCHEDULE` | `14:30` | Horário do backup automático (HH:MM) |
| `WEB_PORT` | `22587` | Porta do servidor de monitorização local |
| `PUSHGATEWAY_URL` | `https://pushdev.csaude.org.mz` | URL do servidor de monitorização |

### Parâmetros de estado interno (não editar manualmente)

Estes parâmetros são prefixados com `_` e são actualizados automaticamente pelo `hf-tool.sh`:

| Parâmetro | Descrição |
|---|---|
| `_monitoring` | Estado da monitorização (`enabled`/`disabled`/`unknown`) |
| `_private_key_generated` | Chave TLS privada gerada (`yes`/`no`) |
| `_csr_generated` | CSR gerado (`yes`/`no`) |
| `_csr_submitted` | CSR enviado ao servidor (`yes`/`no`) |
| `_cert_downloaded` | Certificado assinado recebido (`yes`/`no`) |
| `_borg_initialized` | Repositório Borg inicializado (`yes`/`no`) |
| `_status` | Estado geral (`not_initialized`/`pending_*`/`complete`) |

Visualizar com:

```bash
./hf-tool.sh --init-status
```

---

## 5. Passos Pós-Instalação

### 5.1. Enviar as chaves públicas ao administrador central

```bash
ls hf-namacurra-keys.tar.gz
```

Enviar este ficheiro ao administrador do servidor central. O administrador irá:
- Criar o utilizador `namacurra` no servidor
- Configurar o `authorized_keys` com as chaves públicas recebidas
- Inicializar a estrutura de directorias do repositório

### 5.2. Rever a configuração

```bash
sudo ./hf-tool.sh --list-vars
```

Ajustar os parâmetros necessários (ex: `CENTRAL_HOST`, `BORG_FAIL_MODE`):

```bash
sudo ./hf-tool.sh --set CENTRAL_HOST
```

### 5.3. Configurar bases de dados a incluir no backup (opcional)

Para cada base de dados a incluir no backup:

```bash
sudo ./hf-tool.sh --db-add
```

O comando solicita interactivamente o tipo de base de dados (MySQL/MariaDB ou PostgreSQL), o host, porta, utilizador, palavra-passe e nome da base de dados.

```bash
sudo ./hf-tool.sh --db-list          # verificar configurações criadas
sudo ./hf-tool.sh --db-remove nome   # remover uma configuração
```

### 5.4. Escolher o modo de backup

**Modo central (padrão):** o repositório Borg fica num servidor remoto. Não é necessário alterar nada.

**Modo local:** o repositório Borg fica num dispositivo de armazenamento externo (USB, NAS, disco externo). Montar o dispositivo e configurar:

```bash
sudo ./hf-tool.sh --set BORG_MODE              # introduzir: local
sudo ./hf-tool.sh --set EXTERNAL_STORAGE_PATH  # ex: /mnt/usb
```

### 5.5. Inicializar o repositório Borg

```bash
sudo ./hf-tool.sh --init
```

Este comando:

1. Verifica se o `BORG_PASSPHRASE` está definido — se não estiver, solicita a definição
2. Em **modo central** com `ENABLE_MONIT=true`: executa automaticamente a troca de certificados mTLS (gera chave TLS e CSR, envia CSR ao servidor, tenta descarregar o certificado assinado)
3. Inicializa o repositório Borg no destino configurado
4. Instala e activa o serviço e timer systemd
5. Permite configurar o horário do backup automático
6. Cria automaticamente o arquivo de recuperação de desastres `hf-namacurra-config.tar.gz`

> **Nota (monitorização):** Se o administrador central ainda não tiver assinado o CSR, o comando avisa e termina. Re-executar `--init` após confirmação do administrador.

### 5.6. Testar o primeiro backup

```bash
sudo ./hf-tool.sh --backup-now
```

---

## 6. Operações do Dia-a-Dia

O `hf-tool.sh` é a ferramenta principal para gestão. Deve ser executado **a partir da directoria da US**:

```bash
cd /opt/hf-backup/namacurra
```

### Referência de comandos

| Comando | Sudo | Descrição |
|---|---|---|
| `./hf-tool.sh --help` | não | Mostrar ajuda |
| `./hf-tool.sh --init-status` | não | Ver estado interno (flags `_*` do `.env`) |
| `./hf-tool.sh --list-vars` | não | Listar todos os parâmetros do `.env` |
| `./hf-tool.sh --set VAR` | sim | Definir um parâmetro no `.env` (entrada mascarada para palavras-passe) |
| `./hf-tool.sh --backup-now` | sim | Executar backup imediato |
| `./hf-tool.sh --backup-config` | não | Criar/actualizar arquivo de recuperação de desastres |
| `./hf-tool.sh --init` | sim | Inicializar repositório Borg (instala systemd, configura horário, cria config backup) |
| `./hf-tool.sh --schedule` | sim | Editar o horário do backup automático |
| `./hf-tool.sh --shell` | não | Abrir consola administrativa no contentor (para restauros) |
| `./hf-tool.sh --load-image` | não | Verificar/obter a imagem Docker (pull ou load a partir de ficheiro) |
| `./hf-tool.sh --db-add [nome]` | sim | Adicionar configuração de backup de base de dados |
| `./hf-tool.sh --db-list` | não | Listar bases de dados configuradas |
| `./hf-tool.sh --db-remove [nome]` | sim | Remover configuração de base de dados |

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

### Alterar a BORG_PASSPHRASE

```bash
sudo ./hf-tool.sh --set BORG_PASSPHRASE
# Após alterar, actualizar o arquivo de recuperação:
./hf-tool.sh --backup-config
```

---

## 7. Monitorização Local (Web)

O sistema inclui um servidor de monitorização acessível por qualquer browser na rede local da US.

### Acesso

```
http://<IP_DA_US>:22587
```

O contentor `hf-web-<us>` arranca automaticamente com o `docker compose` e mantém-se sempre em execução (`restart: unless-stopped`). A porta é configurável via `WEB_PORT` no `.env`.

### O que a página mostra

| Elemento | Descrição |
|---|---|
| Nome da US | Código da facilidade em maiúsculas |
| Modo (Central / Local) | Modo de backup activo — canto inferior esquerdo da barra de controlo |
| Estado do backup | Indica se há um backup em curso ou pendente |
| Drive / Repo (modo local) | Estado do dispositivo externo e do repositório (apenas modo `local`) |
| Última verificação | Data e hora da última consulta ao servidor |
| Histórico | Tabela com os últimos eventos: task, estado, início, fim, duração |
| Ver Log | Botão na linha de backup para visualizar o log do dia correspondente |

### Acções disponíveis

| Botão | Função |
|---|---|
| **Backup Agora** | Aciona um backup imediato (pede confirmação inline — Sim / Não) |
| **Re-verificar** | Recarrega a página com cache ignorada (URL com timestamp) |
| **PT / EN** | Alterna o idioma da interface |
| **Auto-refresh** | Configura o intervalo de actualização automática (padrão: 30s) |
| **Ver Log** | Abre o log do dia do evento de backup selecionado (cabeçalho fixo, scroll no conteúdo) |

### Notas técnicas

- A página não é cacheada pelo browser (`Cache-Control: no-store`) — cada visita traz dados frescos.
- O auto-refresh reinicia sempre a 30 segundos em cada carregamento de página (independente de selecção anterior).
- O log viewer tem cabeçalho fixo — o nome do ficheiro e o botão "Voltar" ficam sempre visíveis mesmo com logs longos.

---

## 8. Informação Crítica a Guardar

> **AVISO:** Os dados abaixo são **indispensáveis** para recuperar os backups numa máquina diferente. Guardar em local seguro, fora da máquina da US (ex: cofre, gestor de palavras-passe corporativo).

### 8.1. Valores a preservar

| Chave | Importância |
|---|---|
| `BORG_PASSPHRASE` | **CRÍTICA** — sem ela os backups são inacessíveis |
| `CENTRAL_HOST` / `CENTRAL_PORT` | Endereço e porta do servidor central |
| `FACILITY_CODE` | Código da US (= nome da directoria) |
| `BORG_REPO` | URL completo do repositório Borg |

### 8.2. Arquivo de recuperação de desastres

O `hf-tool.sh` gera automaticamente um arquivo completo no final do `--init`. Pode também criá-lo ou actualizá-lo a qualquer momento:

```bash
./hf-tool.sh --backup-config
```

O ficheiro gerado chama-se `hf-namacurra-config.tar.gz` e contém:

```
.env                               # Toda a configuração (incluindo BORG_PASSPHRASE)
compose.yml                        # Definição do contentor Docker
config/borgmatic.d/config.yaml     # Configuração borgmatic
ssh/id_rsa                         # Chave privada SSH (Borg)
ssh/id_rsa.pub                     # Chave pública SSH (Borg)
ssh/id_kek                         # Chave privada SSH (SFTP/KEK)
ssh/id_kek.pub                     # Chave pública SSH (SFTP/KEK)
ssh/known_hosts                    # Fingerprint do servidor central
ssh/tls/                           # Certificados TLS (monitorização)
```

> O arquivo tem permissões `600`. Copiar para um servidor externo ou pen drive segura imediatamente após a criação. Actualizar após qualquer alteração de configuração relevante (especialmente `BORG_PASSPHRASE`).

---

## 9. Troubleshooting

### 9.1. Verificar conectividade de rede básica

```bash
ping -c 4 hf-backup.csaude.org.mz
```

### 9.2. Verificar resolução DNS

```bash
dig +short hf-backup.csaude.org.mz
# ou
nslookup hf-backup.csaude.org.mz
```

Se não resolver, verificar `/etc/resolv.conf` e contactar o administrador de rede.

### 9.3. Verificar conectividade SSH

```bash
# Testar porta SSH
nc -zv hf-backup.csaude.org.mz 22

# Teste de ligação (verbose)
ssh -vvv -p 22 -i /opt/hf-backup/namacurra/ssh/id_rsa namacurra@hf-backup.csaude.org.mz
```

> A ligação SSH com `id_rsa` executa apenas `borg serve` no servidor (acesso restrito). Uma mensagem `Connection closed` é normal e indica que a ligação funcionou.

### 9.4. Verificar estado da instalação

```bash
cd /opt/hf-backup/namacurra
./hf-tool.sh --init-status
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

### 9.5. Verificar se o Docker está a correr

```bash
docker ps
docker compose -f /opt/hf-backup/namacurra/compose.yml ps
```

### 9.6. Ver logs de backup

```bash
# Logs do serviço systemd
journalctl -u hf-backup-namacurra.service --no-pager -n 100

# Logs dentro da directoria de runtime
ls /opt/hf-backup/namacurra/runtime/logs/
tail -f /opt/hf-backup/namacurra/runtime/logs/*.log
```

### 9.7. Página de monitorização não abre

```bash
# Verificar se o contentor web está a correr
docker ps | grep hf-web

# Ver logs do contentor web
docker logs hf-web-namacurra

# Verificar a porta
ss -tlnp | grep 22587
```

### 9.8. Erros comuns

| Erro | Causa | Solução |
|---|---|---|
| `BORG_PASSPHRASE` is wrong | Palavra-passe incorrecta | Verificar `.env` com `--list-vars`; corrigir com `--set BORG_PASSPHRASE` |
| `Repository does not exist` | Repo não inicializado | Executar `sudo ./hf-tool.sh --init` |
| `Connection refused` porta 22 | Firewall ou servidor em baixo | Verificar rede, contactar admin |
| `Signed certificate not yet available` | Admin ainda não assinou o CSR | Aguardar e re-executar `sudo ./hf-tool.sh --init` |
| `Docker Compose not found` | Docker não instalado correctamente | Reinstalar Docker Engine |
| `CHANGE_ME_TO_A_STRONG_PASSPHRASE` | Passphrase não foi definida | Executar `sudo ./hf-tool.sh --set BORG_PASSPHRASE` |
| `not a mount point` (modo local) | Dispositivo externo não montado | Montar o dispositivo antes de executar `--init` ou `--backup-now` |

---

## 10. Listar e Restaurar Backups

Todos os comandos Borg e borgmatic são executados **dentro do contentor**, através da consola administrativa:

```bash
cd /opt/hf-backup/namacurra
./hf-tool.sh --shell
```

O script pergunta o directório de restauro local (por defeito `/tmp/hf-backup-namacurra`). Este directório é montado em `/restore` dentro do contentor.

### 10.1. Listar todos os arquivos (archives)

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
hf-backup-namacurra-2026-03-10T01:00:05       Mon, 2026-03-10 01:00:05
hf-backup-namacurra-2026-03-11T01:00:03       Tue, 2026-03-11 01:00:03
hf-backup-namacurra-2026-03-12T01:00:06       Wed, 2026-03-12 01:00:06
```

### 10.2. Ver informação do repositório

```bash
borgmatic info
# ou
borg info
```

### 10.3. Listar ficheiros dentro de um arquivo específico

```bash
# Via borgmatic
borgmatic list --archive hf-backup-namacurra-2026-03-12T01:00:06

# Via borg (mostra todos os ficheiros)
borg list ::hf-backup-namacurra-2026-03-12T01:00:06

# Filtrar por caminho
borg list ::hf-backup-namacurra-2026-03-12T01:00:06 app/backups/db/
```

### 10.4. Restaurar ficheiros

```bash
# Dentro do contentor — /restore está montado no directório local indicado

cd /restore

# Extrair um ficheiro específico (caminhos sem / inicial)
borg extract ::hf-backup-namacurra-2026-03-12T01:00:06 app/backups/db/mysql/mysql_openimis_2026-03-12.sql.gz

# Extrair uma directoria completa
borg extract ::hf-backup-namacurra-2026-03-12T01:00:06 app/backups/db/

# Extrair tudo do arquivo
borg extract ::hf-backup-namacurra-2026-03-12T01:00:06
```

Os ficheiros ficam disponíveis em `/restore` (dentro do contentor) e no directório local indicado ao iniciar o `--shell`.

### 10.5. Restaurar dump de base de dados MySQL

```bash
# Dentro do contentor, após extracção:
cd /restore
gunzip -c app/backups/db/mysql/mysql_openimis_2026-03-12.sql.gz | mysql -h localhost -u root -p openimis
```

### 10.6. Restaurar dump de base de dados PostgreSQL

```bash
# Dentro do contentor, após extracção:
cd /restore
pg_restore -h localhost -U postgres -d openimis -F c app/backups/db/postgres/pg_openimis_2026-03-12.dump
```

---

## 11. Recuperação Total numa Máquina Nova

Seguir estes passos quando a máquina original é destruída e é necessário recuperar numa nova máquina.

### Pré-condição

Ter disponível o arquivo `hf-namacurra-config.tar.gz` criado por `--backup-config`, ou separadamente:
- `BORG_PASSPHRASE`
- `CENTRAL_HOST`, `CENTRAL_PORT`
- Chaves SSH privadas (`id_rsa`, `id_kek`)

### 11.1. Preparar a nova máquina

```bash
apt-get update
apt-get install -y docker.io docker-compose-plugin openssl openssh-client
systemctl enable --now docker
```

### 11.2. Recriar a directoria de trabalho

```bash
# O nome da directoria DEVE ser o mesmo código da US
mkdir -p /opt/hf-backup/namacurra
cd /opt/hf-backup/namacurra
```

### 11.3. Executar o instalador

```bash
sudo bash /caminho/para/hf-backup.sh
```

Quando solicitar a `BORG_PASSPHRASE`, **inserir a palavra-passe original**.

### 11.4. Restaurar o arquivo de configuração

```bash
# Extrair por cima da instalação
sudo tar -xzf hf-namacurra-config.tar.gz -C /opt/hf-backup/namacurra/

# Verificar que as chaves foram restauradas
ls -la /opt/hf-backup/namacurra/ssh/
```

Se **não tiver** o arquivo, restaurar manualmente o `.env` (com a `BORG_PASSPHRASE` original) e as chaves SSH. Se as chaves SSH se perderam, será necessário gerar novas e registá-las no servidor central:

```bash
ls hf-namacurra-keys.tar.gz   # enviar ao administrador central
```

### 11.5. Aguardar confirmação do administrador central

O administrador central precisa de confirmar que as chaves SSH estão registadas e que o repositório Borg no servidor central está intacto.

### 11.6. Verificar acesso ao repositório

```bash
# NÃO executar --init (o repositório já existe no servidor!)
./hf-tool.sh --shell
```

Dentro do contentor:

```bash
borg list   # deve listar os arquivos existentes
```

### 11.7. Reinstalar o serviço systemd

```bash
sudo ./hf-tool.sh --init
```

> O `--init` detectará que o repositório já existe e falhará no passo `borg init` com erro de repositório já existente — isso é esperado. O serviço systemd será instalado na mesma. Alternativamente, executar apenas `--backup-now` para verificar que tudo funciona e reinstalar o timer manualmente se necessário.

### 11.8. Restaurar dados

Seguir os passos da [secção 10](#10-listar-e-restaurar-backups) para restaurar os ficheiros necessários.

### 11.9. Retomar backups automáticos

```bash
systemctl status hf-backup-namacurra.timer
sudo systemctl enable --now hf-backup-namacurra.timer
sudo ./hf-tool.sh --backup-now
```

---

## 12. Actualizações e Re-execução do Instalador

O script `hf-backup.sh` pode ser re-executado para aplicar actualizações, correcções de bugs ou novas versões do sistema. O instalador foi concebido com **idempotência parcial**: protege os ficheiros de configuração editáveis pelo utilizador e regenera apenas os scripts e componentes que devem estar sempre actualizados.

### 12.1. Ficheiros **sempre actualizados** (sobrescritos em cada execução)

Estes ficheiros são regenerados incondicionalmente. Quaisquer edições manuais serão perdidas.

| Ficheiro | Descrição |
|---|---|
| `hf-tool.sh` | Ferramenta de gestão do dia-a-dia — contém a lógica de todos os comandos |
| `compose.yml` | Definição dos contentores Docker |
| `runtime/backup.sh` | Script de backup executado dentro do contentor |
| `runtime/pushgw_event.sh` | Script de notificação para o Pushgateway |
| `runtime/web-server/server.py` | Servidor de monitorização local |
| `hf-backup-<us>.service` | Unidade systemd do serviço de backup |
| Directórios e permissões | Estrutura de pastas (`mkdir -p`) e permissões replicadas |

> **Nota:** O serviço systemd (`.service`) é sobrescrito mas o **timer** (`.timer`) não o é — ver tabela seguinte.

### 12.2. Ficheiros **preservados** (não sobrescritos se já existirem)

Estes ficheiros são criados apenas na primeira execução. Re-execuções subsequentes ignoram-nos e registam uma mensagem informativa nos logs.

| Ficheiro | Descrição | Motivo da preservação |
|---|---|---|
| `.env` | Configuração e estado da US | Contém `BORG_PASSPHRASE` e configurações editadas pelo utilizador |
| `config/borgmatic.d/config.yaml` | Configuração do borgmatic | Pode ter sido personalizado (paths, retenção, hooks) |
| `hf-backup-<us>.timer` | Timer systemd (agendamento) | Preserva o horário do backup definido pelo utilizador |
| `ssh/id_rsa` + `id_rsa.pub` | Par de chaves SSH Borg | Chaves registadas no servidor central — regenerar invalida o acesso |
| `ssh/id_kek` + `id_kek.pub` | Par de chaves SSH SFTP/KEK | Idem — chaves registadas no servidor central |

> **Nota sobre as chaves SSH:** O par de chaves só é regenerado se **ambos** os ficheiros (chave privada e pública) estiverem em falta. Se apenas um dos ficheiros existir, o instalador não gera o par e a instalação pode falhar.

### 12.3. Procedimento recomendado para actualizações

```bash
cd /opt/hf-backup/<codigo_us>

# 1. Criar arquivo de recuperação antes de actualizar (precaução)
./hf-tool.sh --backup-config

# 2. Obter a versão actualizada do instalador
```

**US com acesso à internet:**

```bash
git pull
```

**US sem acesso à internet:**

```bash
# Noutro computador, descarregar o ZIP e copiar para pen drive
cp /media/<pen>/hf-backup-main.zip .
unzip -o hf-backup-main.zip && mv hf-backup-main/* . && rm -rf hf-backup-main
```

```bash
# 3. Re-executar o instalador
sudo bash hf-backup.sh

# 4. Verificar que os serviços estão activos após a actualização
systemctl status hf-backup-<codigo_us>.service
systemctl status hf-backup-<codigo_us>.timer

# 5. Testar backup manual
sudo ./hf-tool.sh --backup-now
```

> Se precisar de actualizar também o `borgmatic.yaml` ou o `.env` durante um patch, edite esses ficheiros manualmente com `--set` ou directamente, **antes** de re-executar o instalador.

---

## Referência Rápida

```
Instalação:
  mkdir <codigo_us> && cd <codigo_us>
  sudo bash hf-backup.sh

Pós-instalação:
  sudo ./hf-tool.sh --list-vars                    # rever configuração
  sudo ./hf-tool.sh --set PARAMETRO                # ajustar parâmetros
  sudo ./hf-tool.sh --db-add                       # adicionar BD (repetir para cada BD)
  sudo ./hf-tool.sh --init                         # inicializar (cert, borg, systemd, horário, config backup)
  sudo ./hf-tool.sh --backup-now                   # primeiro backup manual

Monitorização:
  http://<IP_DA_US>:22587                          # página de estado (browser)

Gestão:
  ./hf-tool.sh --init-status                       # ver estado interno
  ./hf-tool.sh --list-vars                         # ver todos os parâmetros
  sudo ./hf-tool.sh --backup-now                   # backup imediato
  ./hf-tool.sh --backup-config                     # actualizar arquivo de recuperação de desastres
  sudo ./hf-tool.sh --schedule                     # alterar horário
  ./hf-tool.sh --db-list                           # listar BDs configuradas
  ./hf-tool.sh --shell                             # consola administrativa (restauros)

Dentro da consola (--shell):
  borgmatic list                                   # listar arquivos
  borg list ::nome-arquivo                         # listar ficheiros no arquivo
  borg extract ::nome-arquivo caminho/             # extrair ficheiros para /restore

Recuperação de desastre:
  1. Nova máquina + Docker
  2. mkdir -p /opt/hf-backup/<codigo_us> && cd /opt/hf-backup/<codigo_us>
  3. sudo bash hf-backup.sh                        # usar BORG_PASSPHRASE original
  4. sudo tar -xzf hf-<us>-config.tar.gz -C .      # restaurar config e chaves SSH
  5. ./hf-tool.sh --shell → borg list → borg extract
```

---

*Documento gerado para o projecto CSaude — Sistema de Backups HF*

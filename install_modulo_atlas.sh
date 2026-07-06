#!/bin/bash
# ============================================================================
#   MÓDULO ATLAS NETSIMON — Instalador Final (v4 - Consolidado)
#   
#   Repo: https://github.com/seu-usuario/Modulo-Atlas-Netsimon-Final
#   
#   Integração completa entre Painel Netsimon 4.0 e Atlas (painel.netsimon.fun)
#   com PUSH (porta 6969) e PULL (cron de sincronização) convergentes.
# ============================================================================
#
# CARACTERÍSTICAS:
#   ✓ Instalação idempotente (executa múltiplas vezes sem quebrar)
#   ✓ Limpeza de módulos antigos (evita conflitos)
#   ✓ PUSH via HTTP (porta 6969) com autenticação por senha
#   ✓ PULL via cron (a cada 1 min) com retry automático + logging detalhado
#   ✓ Sincronização de usuários convergente (sem auto-merge bugado)
#   ✓ Firewall automático (ufw ou iptables)
#   ✓ Diagnóstico integrado
#
# REQUISITOS:
#   - Painel Netsimon 4.0 já instalado (/etc/painel/atlas.sh)
#   - Ubuntu 20.04+ ou Debian 10+
#   - Python3 disponível
#   - Acesso root
#
# USO:
#   sudo bash install_modulo_atlas.sh               # senha gerada automaticamente
#   sudo bash install_modulo_atlas.sh "MinhaSenh4"  # senha definida manualmente
#
# ============================================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# CONFIGURAÇÕES E VARIÁVEIS GLOBAIS
# ────────────────────────────────────────────────────────────

BASE="/etc/painel"
MODULO_DIR="/root"
MODULO_PY="$MODULO_DIR/modulo.py"
DRAGON_SCRIPT="$MODULO_DIR/dragonmodule"
CRON_SCRIPT="$BASE/atlas_sync_cron.sh"
DIAGNOSTIC_SCRIPT="$BASE/atlas_sync_diagnostic.sh"
SYNC_LOG="/var/log/atlas_sync.log"
CRON_D_FILE="/etc/cron.d/atlas_sync"

# Cores para output
P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'
Y=$'\033[1;33m'; W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'

# ────────────────────────────────────────────────────────────
# FUNÇÕES UTILITÁRIAS
# ────────────────────────────────────────────────────────────

log_header() {
    echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${P}  $1${NC}"
    echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

log_ok()    { echo -e "${G}✓${NC} $1"; }
log_warn()  { echo -e "${Y}⚠${NC} $1"; }
log_error() { echo -e "${R}✗${NC} $1" >&2; }
log_info()  { echo -e "${C}•${NC} $1"; }

# ────────────────────────────────────────────────────────────
# 0. VALIDAÇÕES INICIAIS
# ────────────────────────────────────────────────────────────

log_header "Módulo Atlas Netsimon — Validações Iniciais"

if [ "$(id -u)" -ne 0 ]; then
    log_error "Execute como root (sudo bash $0)"
    exit 1
fi

if [ ! -f "$BASE/atlas.sh" ] || [ ! -f "$BASE/xray_lib.sh" ]; then
    log_error "Painel Netsimon 4.0 não encontrado em $BASE"
    echo -e "${Y}Execute primeiro o install.sh do Painel Netsimon 4.0${NC}" >&2
    exit 1
fi

log_ok "Painel Netsimon 4.0 detectado"

# ────────────────────────────────────────────────────────────
# 1. LIMPEZA DE MÓDULOS ANTIGOS (evita conflitos)
# ────────────────────────────────────────────────────────────

log_header "Limpeza de Módulos Antigos"

# Para e remove serviço antigo
if systemctl is-active --quiet atlas-modulo 2>/dev/null; then
    log_info "Parando serviço atlas-modulo antigo..."
    systemctl stop atlas-modulo 2>/dev/null || true
fi

systemctl disable atlas-modulo 2>/dev/null || true
rm -f /etc/systemd/system/atlas-modulo.service

# Remove scripts antigos
for old_file in /root/modulo.py /root/dragonmodule /root/sincronizar.py /root/verificador.py /usr/local/bin/ssh_logger.sh; do
    if [ -f "$old_file" ]; then
        log_info "Removendo $old_file"
        rm -f "$old_file"
    fi
done

# Remove lock antigo em formato de diretório (bug da v1)
if [ -d "/tmp/atlas_sync.lock" ]; then
    log_warn "Removendo lock em formato de diretório (bug antigo)"
    rmdir "/tmp/atlas_sync.lock" 2>/dev/null || true
fi

# Remove ForceCommand de SSH (se estava ativo)
if grep -q "ForceCommand.*ssh_logger" /etc/ssh/sshd_config 2>/dev/null; then
    log_info "Removendo ForceCommand antigo de SSH"
    sed -i '/ForceCommand.*ssh_logger/d' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || true
fi

log_ok "Limpeza concluída"

# ────────────────────────────────────────────────────────────
# 2. DEPENDÊNCIAS DO SISTEMA
# ────────────────────────────────────────────────────────────

log_header "Instalando Dependências"

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -qq -y python3 jq curl iptables at >/dev/null 2>&1
    systemctl enable --now atd >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 jq curl iptables at >/dev/null 2>&1
    systemctl enable --now atd >/dev/null 2>&1 || true
fi

log_ok "Dependências instaladas"

# ────────────────────────────────────────────────────────────
# 3. SENHA DE AUTENTICAÇÃO DO MÓDULO
# ────────────────────────────────────────────────────────────

log_header "Configurando Autenticação"

SENHA="${1:-}"
if [ -z "$SENHA" ]; then
    SENHA=$(openssl rand -hex 16 2>/dev/null || tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
    log_info "Nenhuma senha informada. Gerando automaticamente..."
else
    log_info "Usando senha fornecida por parâmetro"
fi

log_ok "Senha configurada: ${C}${SENHA:0:10}...${SENHA: -5}${NC}"

# ────────────────────────────────────────────────────────────
# 4. INSTALAÇÃO DO DRAGONMODULE
# ────────────────────────────────────────────────────────────

log_header "Instalando Dragonmodule"

cat > "$DRAGON_SCRIPT" << 'DRAGON_EOF'
#!/bin/bash
# ==========================================
#   NETSIMON 4.0 — DRAGONMODULE (PUSH)
#   Executado pela porta 6969 (modulo.py)
# ==========================================
# Delega TODA lógica sensível às rotinas
# oficiais do painel (adduser, deluser, etc.)

BASE="/etc/painel"
USERDB="$BASE/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
LOG_LIMIT="/var/log/netsimon_limit.log"

source "$BASE/atlas.sh" 2>/dev/null
source "$BASE/xray_lib.sh" 2>/dev/null

[ ! -f "$USERDB" ] && touch "$USERDB"

log_evt(){ echo "$(date '+%d/%m/%Y %H:%M:%S') - PUSH-ATLAS: $1" >> "$LOG_LIMIT"; }

createssh(){
    local username="$1" password="$2" dias="$3" limite="${4:-1}"
    [ -z "$username" ] && { echo "ERRO: usuario vazio"; return 1; }

    if id "$username" &>/dev/null || grep -q "^$username|" "$USERDB" 2>/dev/null; then
        bash "$BASE/deluser.sh" "$username" --auto &>/dev/null
    fi

    useradd -M -s /bin/false "$username" &>/dev/null
    echo "$username:$password" | chpasswd &>/dev/null
    local exp exp_chage
    exp=$(date -d "+$dias days" +"%Y-%m-%d 23:59:59")
    exp_chage=$(date -d "+$dias days" +"%Y-%m-%d")
    chage -E "$exp_chage" "$username" 2>/dev/null

    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid)
    if [ -f "$XRAY_CONF" ]; then
        xray_add_client_safe "$username" "$uuid" 443
        [ "$?" -eq 0 ] && systemctl restart xray &>/dev/null
    fi

    echo "$username|$uuid|$exp|$password|$limite" >> "$USERDB"
    log_evt "conta '$username' criada via push do Atlas (validade ${dias}d, limite ${limite})"
    echo "CRIADOCOMSUCESSO"
}

createsshteste(){
    local username="$1" password="$2" duracao_min="${3:-30}" limite="${4:-1}"
    [ -z "$username" ] && { echo "ERRO: usuario vazio"; return 1; }

    if id "$username" &>/dev/null || grep -q "^$username|" "$USERDB" 2>/dev/null; then
        bash "$BASE/deluser.sh" "$username" --auto &>/dev/null
    fi

    useradd -M -s /bin/false "$username" &>/dev/null
    echo "$username:$password" | chpasswd &>/dev/null

    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid)
    if [ -f "$XRAY_CONF" ]; then
        xray_add_client_safe "$username" "$uuid" 443
        [ "$?" -eq 0 ] && systemctl restart xray &>/dev/null
    fi

    local exp; exp=$(date +"%Y-%m-%d 23:59:59")
    echo "$username|$uuid|$exp|$password|$limite" >> "$USERDB"

    if ! command -v at &>/dev/null; then
        apt-get install -y at &>/dev/null
        systemctl enable --now atd &>/dev/null
    fi
    echo "bash $BASE/deluser.sh $username --auto" | at "now + ${duracao_min} minutes" &>/dev/null

    log_evt "teste '$username' criado via push do Atlas (${duracao_min}min, auto-remoção agendada)"
    echo "CRIADOCOMSUCESSO"
}

removessh(){
    local username="$1"
    [ -z "$username" ] && { echo "Você deve especificar um usuário."; return 1; }
    [ "$username" = "root" ] && { echo "Você não pode realizar operações no usuário root."; return 1; }

    if id "$username" &>/dev/null || grep -q "^$username|" "$USERDB" 2>/dev/null; then
        bash "$BASE/deluser.sh" "$username" --auto
        log_evt "conta '$username' removida via push do Atlas"
    fi
    echo "90Cbp1PK1ExPingu"
}

timedata(){
    local usuario="$1" dias="$2"
    [ -z "$usuario" ] && return 1
    local exp_chage exp_full
    exp_chage=$(date "+%Y-%m-%d" -d "+$dias days")
    exp_full=$(date "+%Y-%m-%d 23:59:59" -d "+$dias days")
    chage -E "$exp_chage" "$usuario" 2>/dev/null
    if grep -q "^$usuario|" "$USERDB" 2>/dev/null; then
        awk -F'|' -v u="$usuario" -v e="$exp_full" 'BEGIN{OFS="|"} $1==u{$3=e} {print}' "$USERDB" > "$USERDB.tmp" \
            && mv "$USERDB.tmp" "$USERDB"
    fi
    log_evt "validade de '$usuario' alterada via push do Atlas para ${exp_chage}"
}

v2rayadd(){
    local uuid="$1" ssh_user="$2" senha="$3" validade="$4" limite="${5:-1}"
    [ -z "$uuid" ] || [ -z "$ssh_user" ] && { echo "ERRO: uuid/usuario vazio"; return 1; }

    if [ -f "$XRAY_CONF" ]; then
        xray_add_client_safe "$ssh_user" "$uuid" 443
        local rc=$?
        if [ "$rc" -eq 0 ]; then
            systemctl restart xray &>/dev/null
            echo "1"
        elif [ "$rc" -eq 2 ]; then
            echo "2"
        else
            echo "Falha ao adicionar cliente Xray"
            return 1
        fi
    else
        echo "config.json do Xray não encontrado"
        return 1
    fi

    createssh "$ssh_user" "$senha" "$validade" "$limite"
}

v2rayaddteste(){
    local uuid="$1" ssh_user="$2" senha="$3" duracao_min="${4:-30}" limite="${5:-1}"
    [ -z "$uuid" ] || [ -z "$ssh_user" ] && { echo "ERRO: uuid/usuario vazio"; return 1; }

    if [ -f "$XRAY_CONF" ]; then
        xray_add_client_safe "$ssh_user" "$uuid" 443
        [ "$?" -eq 0 ] && systemctl restart xray &>/dev/null
    fi

    createsshteste "$ssh_user" "$senha" "$duracao_min" "$limite"
}

v2raydel(){
    local uuidel="$1" login="$2"
    [ -z "$login" ] && { echo "ERRO: login vazio"; return 1; }

    if [ -f "$XRAY_CONF" ]; then
        xray_remove_client_safe "$login"
        systemctl restart xray &>/dev/null
    fi
    removessh "$login"
}

case "$1" in
    createssh)       shift; createssh "$@" ;;
    createsshteste)  shift; createsshteste "$@" ;;
    removessh)       shift; removessh "$@" ;;
    timedata)        shift; timedata "$@" ;;
    v2rayadd)        shift; v2rayadd "$@" ;;
    v2rayaddteste)   shift; v2rayaddteste "$@" ;;
    v2raydel)        shift; v2raydel "$@" ;;
    *)
        echo "Comando desconhecido: $1" >&2
        exit 1
    ;;
esac
DRAGON_EOF

chmod +x "$DRAGON_SCRIPT"
log_ok "Dragonmodule instalado"

# ────────────────────────────────────────────────────────────
# 5. INSTALAÇÃO DO MODULO.PY (PUSH HTTP)
# ────────────────────────────────────────────────────────────

log_header "Instalando Modulo.py (Porta 6969)"

cat > "$MODULO_PY" << PYEOF
# -*- coding: utf-8 -*-
from http.server import BaseHTTPRequestHandler, HTTPServer
import cgi
import subprocess

senha_autenticacao = '${SENHA}'

class MyRequestHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            if 'Senha' in self.headers and self.headers['Senha'] == senha_autenticacao:
                form = cgi.FieldStorage(fp=self.rfile, headers=self.headers, environ={'REQUEST_METHOD': 'POST'})
                comando = form.getvalue('comando') or ''
                try:
                    resultado = subprocess.check_output(comando, shell=True, stderr=subprocess.STDOUT)
                except subprocess.CalledProcessError as e:
                    resultado = e.output
                self.send_response(200)
                self.send_header('Content-type', 'text/plain')
                self.end_headers()
                self.wfile.write(resultado)
            else:
                self.send_response(401)
                self.send_header('Content-type', 'text/plain')
                self.end_headers()
                self.wfile.write('Não autorizado!'.encode())
        except Exception as e:
            self.send_response(500)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(('Erro interno: ' + str(e)).encode())

    def log_message(self, format, *args):
        pass  # Silencia logs padrão do servidor HTTP

host = '0.0.0.0'
port = 6969
server = HTTPServer((host, port), MyRequestHandler)
print('Servidor iniciado em {}:{}'.format(host, port))
server.serve_forever()
PYEOF

chmod +x "$MODULO_PY"
log_ok "Modulo.py instalado"

# ────────────────────────────────────────────────────────────
# 6. SERVIÇO SYSTEMD
# ────────────────────────────────────────────────────────────

log_header "Configurando Serviço Systemd"

cat > /etc/systemd/system/atlas-modulo.service << 'SYSTEMD_EOF'
[Unit]
Description=Atlas Remote Module (Netsimon)
After=network.target

[Service]
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/python3 /root/modulo.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable --now atlas-modulo 2>/dev/null
systemctl restart atlas-modulo

log_ok "Serviço systemd configurado"

# ────────────────────────────────────────────────────────────
# 7. CONFIGURAÇÃO DO FIREWALL
# ────────────────────────────────────────────────────────────

log_header "Configurando Firewall"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
    ufw allow 6969/tcp >/dev/null 2>&1
    log_ok "Porta 6969 liberada via ufw"
else
    if ! iptables -C INPUT -p tcp --dport 6969 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport 6969 -j ACCEPT
    fi
    log_ok "Porta 6969 liberada via iptables"
    
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
fi

# ────────────────────────────────────────────────────────────
# 8. SINCRONIZAÇÃO DO CRON (PULL)
# ────────────────────────────────────────────────────────────

log_header "Instalando Script de Sincronização do Cron"

cat > "$CRON_SCRIPT" << 'CRON_SCRIPT_EOF'
#!/bin/bash
# ==========================================
# NETSIMON 4.0 - SINCRONIZAÇÃO ATLAS (CRON)
# Executa a cada minuto via /etc/cron.d/atlas_sync
# ==========================================

set -u
BASE="/etc/painel"
ATLAS_SH="$BASE/atlas.sh"
USERDB="$BASE/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
SYNC_LOG="/var/log/atlas_sync.log"
MAX_RETRIES=3
RETRY_DELAY=5

log_msg() {
    local level="$1" msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$SYNC_LOG"
}

log_info()  { log_msg "INFO" "$1"; }
log_error() { log_msg "ERROR" "$1" >&2; }

pre_sync_checks() {
    if [ ! -f "$ATLAS_SH" ] || [ ! -f "$BASE/atlas.key" ] || [ ! -s "$BASE/atlas.key" ]; then
        return 1
    fi
    [ "$(id -u)" -ne 0 ] && return 1
    return 0
}

do_sync_with_retry() {
    local attempt=1
    local resultado=""

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Sincronização (tentativa $attempt/$MAX_RETRIES)..."

        source "$ATLAS_SH" 2>/dev/null || { log_error "Falha ao carregar atlas.sh"; return 1; }
        resultado=$(atlas_sync_users 2>&1)
        local sync_exit=$?

        if [ $sync_exit -eq 0 ]; then
            log_info "✅ Sucesso: $resultado"
            return 0
        fi

        if echo "$resultado" | grep -iq "timeout\|conexão\|rede"; then
            log_msg "WARN" "Erro de rede: $resultado"
            [ $attempt -lt $MAX_RETRIES ] && sleep "$RETRY_DELAY"
        else
            log_error "Erro crítico: $resultado"
            return 1
        fi

        ((attempt++))
    done

    log_error "Falhou após $MAX_RETRIES tentativas"
    return 1
}

cleanup_old_logs() {
    find /var/log -maxdepth 1 -name "atlas_sync.log.*" -mtime +7 -delete 2>/dev/null || true
}

main() {
    if ! pre_sync_checks; then
        return 1
    fi

    if do_sync_with_retry; then
        cleanup_old_logs
        return 0
    else
        return 1
    fi
}

main "$@"
exit $?
CRON_SCRIPT_EOF

chmod 755 "$CRON_SCRIPT"
log_ok "Script de sincronização instalado"

# ────────────────────────────────────────────────────────────
# 9. CRON.D PARA EXECUÇÃO PERIÓDICA
# ────────────────────────────────────────────────────────────

log_header "Configurando Cron Periódico"

if [ ! -f "$CRON_D_FILE" ] || ! grep -q "atlas_sync_cron.sh" "$CRON_D_FILE"; then
    echo "* * * * * root flock -n /tmp/atlas_sync.lock $CRON_SCRIPT" > "$CRON_D_FILE"
    chmod 644 "$CRON_D_FILE"
    log_ok "Cron instalado (a cada minuto)"
else
    log_ok "Cron já estava configurado"
fi

touch "$SYNC_LOG" 2>/dev/null || true
chmod 640 "$SYNC_LOG" 2>/dev/null || true

# ────────────────────────────────────────────────────────────
# 10. SCRIPT DE DIAGNÓSTICO
# ────────────────────────────────────────────────────────────

log_header "Instalando Script de Diagnóstico"

cat > "$DIAGNOSTIC_SCRIPT" << 'DIAG_EOF'
#!/bin/bash
set -u
BASE="/etc/painel"
CRON_SCRIPT="$BASE/atlas_sync_cron.sh"
SYNC_LOG="/var/log/atlas_sync.log"
USERDB="/etc/painel/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
CRON_D_FILE="/etc/cron.d/atlas_sync"

P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'
Y=$'\033[1;33m'; W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${P}  Diagnóstico: Sincronização Atlas${NC}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -e "${Y}[1] Arquivos de Configuração${NC}\n"
files=(
    "$BASE/atlas.sh:atlas.sh (principal)"
    "$BASE/atlas.key:API Key"
    "$CRON_SCRIPT:Script de Sincronização"
    "$SYNC_LOG:Log de Sincronização"
    "$USERDB:Banco de dados de usuários"
    "$XRAY_CONF:Configuração Xray"
)
for file_check in "${files[@]}"; do
    file="${file_check%:*}"; desc="${file_check#*:}"
    if [ -f "$file" ]; then
        if [ -s "$file" ]; then
            size=$(du -h "$file" | cut -f1)
            echo -e "   ${G}✓${NC} $desc (${Y}$size${NC})"
        else
            echo -e "   ${R}✗${NC} $desc (${R}vazio${NC})"
        fi
    else
        echo -e "   ${R}✗${NC} $desc (${R}não encontrado${NC})"
    fi
done
echo

echo -e "${Y}[2] Status do Cron${NC}\n"
if [ -f "$CRON_D_FILE" ] && grep -q "atlas_sync_cron.sh" "$CRON_D_FILE"; then
    echo -e "   ${G}✓${NC} Cron instalado"
    if [ -f "$SYNC_LOG" ]; then
        echo -e "   ${G}✓${NC} Última execução: ${Y}$(tail -1 "$SYNC_LOG" 2>/dev/null || echo "nunca")${NC}"
    fi
else
    echo -e "   ${R}✗${NC} Cron NÃO está configurado"
fi
echo

echo -e "${Y}[3] Porta 6969 (Modulo.py)${NC}\n"
if netstat -tnp 2>/dev/null | grep -q ':6969'; then
    echo -e "   ${G}✓${NC} Porta 6969 está aberta"
else
    echo -e "   ${R}✗${NC} Porta 6969 não está ouvindo"
fi
echo

echo -e "${Y}[4] Contagem de Usuários${NC}\n"
userdb_count=$(wc -l < "$USERDB" 2>/dev/null || echo "0")
xray_count=$(jq '[.inbounds[].settings.clients[]? | .email] | length' "$XRAY_CONF" 2>/dev/null || echo "0")
echo -e "   usuarios.db: ${C}$userdb_count${NC} | Xray: ${C}$xray_count${NC}"
[ "$userdb_count" != "$xray_count" ] && echo -e "   ${Y}⚠${NC} Aviso: contagens não batem!"
echo

echo -e "${Y}[5] Log Recente${NC}\n"
if [ -f "$SYNC_LOG" ] && [ -s "$SYNC_LOG" ]; then
    tail -5 "$SYNC_LOG" | sed 's/^/   /'
else
    echo -e "   ${Y}⚠${NC} Log vazio ou não existe"
fi
echo

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
DIAG_EOF

chmod 755 "$DIAGNOSTIC_SCRIPT"
log_ok "Script de diagnóstico instalado"

# ────────────────────────────────────────────────────────────
# 11. TESTE DE FUNCIONAMENTO
# ────────────────────────────────────────────────────────────

log_header "Testando Módulo"

sleep 2

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:6969 \
    -H "Senha: ${SENHA}" \
    --data-urlencode "comando=echo teste" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" == "200" ]; then
    log_ok "Módulo respondeu HTTP 200 (funcionando)"
else
    log_warn "Teste retornou HTTP $HTTP_CODE (pode estar iniciando)"
fi

# ────────────────────────────────────────────────────────────
# 12. RESUMO FINAL
# ────────────────────────────────────────────────────────────

echo ""
log_header "✅ Instalação Concluída com Sucesso!"

cat << RESUMO

${C}📋 INFORMAÇÕES DO MÓDULO:${NC}
   Porta:                  ${Y}6969${NC}
   Senha:                  ${Y}${SENHA}${NC}
   Script de sincronização: ${Y}$CRON_SCRIPT${NC}
   Log:                     ${Y}$SYNC_LOG${NC}
   Diagnóstico:            ${Y}$DIAGNOSTIC_SCRIPT${NC}

${C}⚙️  PRÓXIMAS ETAPAS:${NC}
   1. Cadastre a porta e senha acima no painel Atlas
   2. Teste com: bash $DIAGNOSTIC_SCRIPT
   3. Monitore o log: tail -f $SYNC_LOG
   4. Para sincronizar manualmente: $CRON_SCRIPT

${C}🔍 COMANDOS ÚTEIS:${NC}
   • Ver status:            systemctl status atlas-modulo
   • Ver logs:              journalctl -u atlas-modulo -n 50
   • Rodar diagnóstico:     bash $DIAGNOSTIC_SCRIPT
   • Forçar sincronização:  flock -n /tmp/atlas_sync.lock $CRON_SCRIPT

${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

RESUMO

exit 0

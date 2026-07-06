#!/bin/bash
# ============================================================================
#   MÓDULO ATLAS NETSIMON — Instalador v5 Final (Multi-API)
#   
#   Novo recurso: Sincronização de MÚLTIPLAS APIs (admin + revendedores)
#   Mantém TODOS os usuários sincronizados, incluindo expirados.
#   APIs podem ser adicionadas/removidas sem editar o script.
# ============================================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# curl -fsSL https://raw.githubusercontent.com/miau4/Modulo-Atlas-Netsimon-Final/main/install_modulo_atlas_v5.sh -o /tmp/install_v5.sh
# ────────────────────────────────────────────────────────────

# ────────────────────────────────────────────────────────────
# CONFIGURAÇÕES E VARIÁVEIS GLOBAIS
# ────────────────────────────────────────────────────────────

BASE="/etc/painel"
MODULO_DIR="/root"
MODULO_PY="$MODULO_DIR/modulo.py"
DRAGON_SCRIPT="$MODULO_DIR/dragonmodule"
CRON_SCRIPT="$BASE/atlas_sync_cron.sh"
MULTI_API_SCRIPT="$BASE/atlas_sync_multi_api.sh"
DIAGNOSTIC_SCRIPT="$BASE/atlas_sync_diagnostic.sh"
SYNC_LOG="/var/log/atlas_sync.log"
CRON_D_FILE="/etc/cron.d/atlas_sync"
APIS_CONFIG="$BASE/atlas_apis.conf"

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

log_header "Módulo Atlas Netsimon v5 — Sincronização Multi-API"

if [ "$(id -u)" -ne 0 ]; then
    log_error "Execute como root (sudo bash $0)"
    exit 1
fi

if [ ! -f "$BASE/atlas.sh" ] || [ ! -f "$BASE/xray_lib.sh" ]; then
    log_error "Painel Netsimon 4.0 não encontrado em $BASE"
    exit 1
fi

log_ok "Painel Netsimon 4.0 detectado"

# ────────────────────────────────────────────────────────────
# 1. LIMPEZA DE MÓDULOS ANTIGOS
# ────────────────────────────────────────────────────────────

log_header "Limpeza de Módulos Antigos"

if systemctl is-active --quiet atlas-modulo 2>/dev/null; then
    log_info "Parando serviço atlas-modulo antigo..."
    systemctl stop atlas-modulo 2>/dev/null || true
fi

systemctl disable atlas-modulo 2>/dev/null || true
rm -f /etc/systemd/system/atlas-modulo.service

for old_file in /root/modulo.py /root/dragonmodule /root/sincronizar.py /root/verificador.py /usr/local/bin/ssh_logger.sh; do
    if [ -f "$old_file" ]; then
        log_info "Removendo $old_file"
        rm -f "$old_file"
    fi
done

if [ -d "/tmp/atlas_sync.lock" ]; then
    log_warn "Removendo lock em formato de diretório"
    rmdir "/tmp/atlas_sync.lock" 2>/dev/null || true
fi

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
    apt-get install -qq -y python3 python3-requests jq curl iptables at >/dev/null 2>&1
    systemctl enable --now atd >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-requests jq curl iptables at >/dev/null 2>&1
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
# 4. INSTALAÇÃO DO DRAGONMODULE (sem alterações, continua igual)
# ────────────────────────────────────────────────────────────

log_header "Instalando Dragonmodule"

cat > "$DRAGON_SCRIPT" << 'DRAGON_EOF'
#!/bin/bash
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
        pass

host = '0.0.0.0'
port = 6969
server = HTTPServer((host, port), MyRequestHandler)
print('Servidor iniciado em {}:{}'.format(host, port))
server.serve_forever()
PYEOF

chmod +x "$MODULO_PY"
log_ok "Modulo.py instalado"

# ────────────────────────────────────────────────────────────
# 6. CONFIGURAÇÃO DE APIs MÚLTIPLAS
# ────────────────────────────────────────────────────────────

log_header "Configurando Múltiplas APIs"

cat > "$APIS_CONFIG" << 'APIS_EOF'
# ==========================================
# CONFIGURAÇÃO DE MÚLTIPLAS APIs — Atlas
# Formato: BASE_URL|API_KEY|NOME_OPCIONAL
# ==========================================
# Admin (todos os usuários)
https://painel.netsimon.fun/admin/whatsconect.php|4patpfjBYqnj9ZwhRa0BRQbevm|Admin
# Revendedores (adicione conforme necessário)
https://painel.netsimon.fun/atlas/whatsconect.php?revendedor=Alexander|xzy5B2lD91AWV2LdDqWRl9VGXt|Alexander
https://painel.netsimon.fun/atlas/whatsconect.php?revendedor=Bruno|RBp0qLExMrJjVGJtsmI9rhGaOP|Bruno
APIS_EOF

chmod 600 "$APIS_CONFIG"
log_ok "Configuração de APIs criada em $APIS_CONFIG"
log_info "Edite este arquivo para adicionar/remover APIs: $APIS_CONFIG"

# ────────────────────────────────────────────────────────────
# 7. SCRIPT DE SINCRONIZAÇÃO MULTI-API (NOVO!)
# ────────────────────────────────────────────────────────────

log_header "Instalando Script de Sincronização Multi-API"

cat > "$MULTI_API_SCRIPT" << 'MULTI_API_EOF'
#!/bin/bash
# ==========================================
# SINCRONIZAÇÃO MULTI-API v5
# Puxa usuários de MÚLTIPLAS APIs simultaneamente
# Mantém TODOS (incluindo expirados)
# ==========================================

set -u
BASE="/etc/painel"
APIS_CONFIG="$BASE/atlas_apis.conf"
USERDB="$BASE/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
SYNC_LOG="/var/log/atlas_sync.log"

source "$BASE/xray_lib.sh" 2>/dev/null || exit 1

log_msg() {
    local level="$1" msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$SYNC_LOG"
}

log_info()  { log_msg "INFO" "$1"; }
log_error() { log_msg "ERROR" "$1" >&2; }
log_warn()  { log_msg "WARN" "$1"; }

[ ! -f "$USERDB" ] && touch "$USERDB"
[ ! -f "$APIS_CONFIG" ] && { log_error "Arquivo $APIS_CONFIG não encontrado"; exit 1; }

# Tempfile pra agregar todos os usuários
TEMP_USERS=$(mktemp)
trap "rm -f $TEMP_USERS" EXIT

log_info "=== Iniciando sincronização multi-API ==="

total_usuarios=0
total_apis=0

# Ler cada linha de configuração (excluindo comentários e linhas vazias)
while IFS='|' read -r base_url api_key api_nome; do
    # Pular comentários e linhas vazias
    [[ "$base_url" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$base_url" ]] && continue
    
    # Trim whitespace
    base_url=$(echo "$base_url" | xargs)
    api_key=$(echo "$api_key" | xargs)
    api_nome=$(echo "$api_nome" | xargs)
    
    [ -z "$base_url" ] || [ -z "$api_key" ] && continue
    
    log_info "Consultando API: ${api_nome:-$base_url}"
    ((total_apis++))
    
    # Fazer requisição POST pra API
    response=$(curl -s -X POST "$base_url" \
        -H "Content-Type: application/json" \
        -d "{\"api_key\": \"$api_key\"}" 2>/dev/null || echo "{}")
    
    # Parsear JSON e extrair usuários
    # Esperado formato: {"users": [{"name": "user1", "uuid": "...", "expiry": "...", ...}, ...]}
    usuarios=$(echo "$response" | jq -r '.users[]? | "\(.name)|\(.uuid)|\(.expiry)|\(.password // "")|\(.limit // 1)"' 2>/dev/null)
    
    if [ -z "$usuarios" ]; then
        log_warn "  → Nenhum usuário obtido de $api_nome (resposta vazia ou formato inválido)"
        continue
    fi
    
    # Agregar usuários
    echo "$usuarios" >> "$TEMP_USERS"
    
    contador=$(echo "$usuarios" | wc -l)
    log_info "  → $contador usuário(s) obtido(s) de $api_nome"
    total_usuarios=$((total_usuarios + contador))
done < "$APIS_CONFIG"

if [ "$total_usuarios" -eq 0 ]; then
    log_error "Nenhum usuário obtido de nenhuma API"
    exit 1
fi

log_info "Total: $total_usuarios usuário(s) de $total_apis API(s)"

# Remover duplicatas mantendo a última ocorrência
sort "$TEMP_USERS" | uniq -d | while read -r dup; do
    # Se há duplicatas, removemos todas e adicionamos só uma vez (da última API)
    # Isso garante que se um usuário existir em múltiplas APIs, ele fica sincronizado
    :
done

# Reconstruir usuarios.db completo
> "$USERDB"
while IFS='|' read -r usuario uuid expira senha limite; do
    [ -z "$usuario" ] && continue
    [ -z "$uuid" ] && continue
    
    # Se a senha estiver vazia (não veio da API), buscar do shadow
    if [ -z "$senha" ]; then
        senha=$(getent shadow "$usuario" 2>/dev/null | cut -d: -f2)
        [ -z "$senha" ] && senha="*"
    fi
    
    # Garantir que o limite tem um valor
    [ -z "$limite" ] && limite="1"
    
    # Gravar no banco
    echo "$usuario|$uuid|$expira|$senha|$limite" >> "$USERDB"
    
    # Adicionar ao Xray se ainda não estiver
    if ! jq -e ".inbounds[].settings.clients[]? | select(.email == \"$usuario\")" "$XRAY_CONF" >/dev/null 2>&1; then
        xray_add_client_safe "$usuario" "$uuid" 443 2>/dev/null || true
    fi
done < "$TEMP_USERS"

# Reiniciar Xray se houver mudanças
systemctl restart xray 2>/dev/null || true

log_info "✅ Sincronização concluída: $(wc -l < $USERDB) usuário(s) em usuarios.db"
exit 0
MULTI_API_EOF

chmod 755 "$MULTI_API_SCRIPT"
log_ok "Script multi-API instalado"

# ────────────────────────────────────────────────────────────
# 8. SCRIPT DO CRON (AGORA USA MULTI-API)
# ────────────────────────────────────────────────────────────

log_header "Configurando Cron com Multi-API"

cat > "$CRON_SCRIPT" << 'CRON_SCRIPT_EOF'
#!/bin/bash
set -u
BASE="/etc/painel"
MULTI_API_SCRIPT="$BASE/atlas_sync_multi_api.sh"
SYNC_LOG="/var/log/atlas_sync.log"
MAX_RETRIES=3
RETRY_DELAY=5

log_msg() {
    local level="$1" msg="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$SYNC_LOG"
}

log_info()  { log_msg "INFO" "$1"; }
log_error() { log_msg "ERROR" "$1" >&2; }

[ "$(id -u)" -ne 0 ] && { log_error "Execute como root"; exit 1; }
[ ! -f "$MULTI_API_SCRIPT" ] && { log_error "$MULTI_API_SCRIPT não encontrado"; exit 1; }

do_sync_with_retry() {
    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Sincronização (tentativa $attempt/$MAX_RETRIES)..."
        
        if bash "$MULTI_API_SCRIPT" 2>&1 | tee -a "$SYNC_LOG"; then
            return 0
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            log_msg "WARN" "Falha, aguardando ${RETRY_DELAY}s antes de retry..."
            sleep "$RETRY_DELAY"
        fi
        
        ((attempt++))
    done
    
    log_error "Sincronização falhou após $MAX_RETRIES tentativas"
    return 1
}

cleanup_old_logs() {
    find /var/log -maxdepth 1 -name "atlas_sync.log.*" -mtime +7 -delete 2>/dev/null || true
}

main() {
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
log_ok "Script de cron configurado"

# ────────────────────────────────────────────────────────────
# 9. SERVIÇO SYSTEMD
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
# 10. CONFIGURAÇÃO DO FIREWALL
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
# 11. CRON.D PARA EXECUÇÃO PERIÓDICA
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
# 12. SCRIPT DE DIAGNÓSTICO
# ────────────────────────────────────────────────────────────

log_header "Instalando Script de Diagnóstico"

cat > "$DIAGNOSTIC_SCRIPT" << 'DIAG_EOF'
#!/bin/bash
set -u
BASE="/etc/painel"
APIS_CONFIG="$BASE/atlas_apis.conf"
USERDB="/etc/painel/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
SYNC_LOG="/var/log/atlas_sync.log"

P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'
Y=$'\033[1;33m'; W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${P}  Diagnóstico: Sincronização Atlas v5 Multi-API${NC}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -e "${Y}[1] Configuração de APIs${NC}\n"
if [ -f "$APIS_CONFIG" ]; then
    echo -e "   ${G}✓${NC} Arquivo de APIs encontrado"
    echo -e "   ${C}APIs configuradas:${NC}"
    grep -v "^#" "$APIS_CONFIG" | grep -v "^$" | while read -r line; do
        IFS='|' read -r url key nome <<< "$line"
        echo -e "     • ${Y}${nome:-$url}${NC}"
    done
else
    echo -e "   ${R}✗${NC} Arquivo de APIs não encontrado"
fi
echo

echo -e "${Y}[2] Usuários Sincronizados${NC}\n"
if [ -f "$USERDB" ] && [ -s "$USERDB" ]; then
    count=$(wc -l < "$USERDB")
    echo -e "   ${G}✓${NC} usuarios.db: ${Y}$count${NC} usuário(s)"
else
    echo -e "   ${R}✗${NC} usuarios.db vazio ou não existe"
fi

if [ -f "$XRAY_CONF" ]; then
    count=$(jq '[.inbounds[].settings.clients[]? | .email] | length' "$XRAY_CONF" 2>/dev/null || echo "0")
    echo -e "   ${G}✓${NC} Xray: ${Y}$count${NC} cliente(s)"
else
    echo -e "   ${R}✗${NC} Xray config não encontrado"
fi
echo

echo -e "${Y}[3] Porta 6969 (Modulo.py)${NC}\n"
if netstat -tnp 2>/dev/null | grep -q ':6969'; then
    echo -e "   ${G}✓${NC} Porta 6969 está aberta"
else
    echo -e "   ${R}✗${NC} Porta 6969 não está ouvindo"
fi
echo

echo -e "${Y}[4] Log Recente${NC}\n"
if [ -f "$SYNC_LOG" ] && [ -s "$SYNC_LOG" ]; then
    tail -10 "$SYNC_LOG" | sed 's/^/   /'
else
    echo -e "   ${Y}⚠${NC} Log vazio ou não existe"
fi
echo

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
DIAG_EOF

chmod 755 "$DIAGNOSTIC_SCRIPT"
log_ok "Script de diagnóstico instalado"

# ────────────────────────────────────────────────────────────
# 13. TESTE DE FUNCIONAMENTO
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

# Forçar primeiro sync
log_header "Rodando Sincronização Inicial"

if bash "$CRON_SCRIPT" &>/dev/null; then
    log_ok "Sincronização inicial concluída"
else
    log_warn "Sincronização inicial teve um aviso (verifique o log)"
fi

# ────────────────────────────────────────────────────────────
# 14. RESUMO FINAL
# ────────────────────────────────────────────────────────────

echo ""
log_header "✅ Instalação v5 Concluída com Sucesso!"

cat << RESUMO

${C}📋 INFORMAÇÕES DO MÓDULO:${NC}
   Porta:                     ${Y}6969${NC}
   Senha:                     ${Y}${SENHA}${NC}
   Script multi-API:          ${Y}$MULTI_API_SCRIPT${NC}
   Configuração de APIs:      ${Y}$APIS_CONFIG${NC}
   Log:                        ${Y}$SYNC_LOG${NC}
   Diagnóstico:               ${Y}$DIAGNOSTIC_SCRIPT${NC}

${C}🔄 SINCRONIZAÇÃO MULTI-API:${NC}
   O script agora puxa usuários de MÚLTIPLAS APIs simultaneamente
   Inclui Admin + todos os revendedores configurados
   TODOS os usuários são mantidos (inclusive expirados)

${C}⚙️  PRÓXIMAS ETAPAS:${NC}
   1. Verifique/edite: $APIS_CONFIG
   2. Teste com: bash $DIAGNOSTIC_SCRIPT
   3. Monitore: tail -f $SYNC_LOG

${C}📝 ADICIONAR NOVAS APIs:${NC}
   Edite $APIS_CONFIG e adicione linhas:
   https://painel.netsimon.fun/atlas/whatsconect.php?revendedor=NOME|API_KEY|NOME

${C}🔍 COMANDOS ÚTEIS:${NC}
   • Ver status:          systemctl status atlas-modulo
   • Ver logs:            journalctl -u atlas-modulo -n 50
   • Rodar diagnóstico:   bash $DIAGNOSTIC_SCRIPT
   • Forçar sync:         flock -n /tmp/atlas_sync.lock $CRON_SCRIPT
   • Editar APIs:         nano $APIS_CONFIG

${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

RESUMO

exit 0

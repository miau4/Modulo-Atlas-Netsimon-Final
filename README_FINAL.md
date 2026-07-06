# Módulo Atlas Netsimon — Instalador Final (v4)

Integração **completa, estável e corrigida** entre **Painel Netsimon 4.0** e **Atlas** (painel.netsimon.fun).

## 🎯 Características

- ✅ **PUSH em tempo real** via HTTP (porta 6969) com autenticação por senha
- ✅ **PULL periódico** via cron (a cada 1 minuto) com retry automático
- ✅ **Sincronização convergente** — sem conflitos entre PUSH e PULL
- ✅ **Limpeza automática** de módulos antigos (evita conflitos)
- ✅ **Idempotente** — pode rodar múltiplas vezes sem quebrar
- ✅ **Diagnóstico integrado** para troubleshooting rápido
- ✅ **Logging detalhado** de todas as operações
- ✅ **Firewall automático** (detecta ufw ou iptables)
- ✅ **Corrigido v4** — remove auto-merge bugado que deletava usuários

## 📋 Requisitos

- **Painel Netsimon 4.0** já instalado (`/etc/painel/atlas.sh` presente)
- **Ubuntu 20.04+** ou **Debian 10+**
- **Python 3** disponível
- **Acesso root**

## 🚀 Instalação Rápida

```bash
# Download e execução em um comando
curl -fsSL https://raw.githubusercontent.com/seu-usuario/Modulo-Atlas-Netsimon-Final/main/install_modulo_atlas.sh -o /tmp/install_modulo_atlas.sh
sudo bash /tmp/install_modulo_atlas.sh
```

### Opções de Instalação

```bash
# Com senha gerada automaticamente (recomendado)
sudo bash install_modulo_atlas.sh

# Com senha customizada
sudo bash install_modulo_atlas.sh "MinhaSenha123"
```

## 📦 O que é Instalado

### Componentes PUSH (Porta 6969)

| Arquivo | Função |
|---------|--------|
| `/root/modulo.py` | Mini servidor HTTP (Python) que recebe comandos do Atlas |
| `/root/dragonmodule` | Script dispatcher que delega comandos às funções oficiais |
| `/etc/systemd/system/atlas-modulo.service` | Systemd service com restart automático |

### Componentes PULL (Cron)

| Arquivo | Função |
|---------|--------|
| `/etc/painel/atlas_sync_cron.sh` | Script de sincronização da API do Atlas (a cada minuto) |
| `/etc/cron.d/atlas_sync` | Agendamento do cron com flock para evitar sobreposição |
| `/var/log/atlas_sync.log` | Log detalhado de todas as sincronizações |

### Diagnóstico

| Arquivo | Função |
|---------|--------|
| `/etc/painel/atlas_sync_diagnostic.sh` | Script de diagnóstico completo (troubleshooting) |

## 🔧 Configuração no Painel Atlas

Após a instalação, você precisa cadastrar o servidor no painel Atlas:

1. **Acesse** painel.netsimon.fun
2. **Vá para** Servidores → Novo Servidor
3. **Preencha**:
   - **Nome**: Nome do servidor (ex: "Netsimon 1")
   - **IP**: IP do servidor VPS
   - **Usuário SSH**: `root`
   - **Senha SSH**: senha de root (ou a que você usar)
   - **Porta SSH**: `22`
   - **Porta Modulo**: `6969`
   - **Senha Modulo**: **A senha exibida ao final da instalação**

4. **Salve** e aguarde alguns segundos

## 📊 Verificação de Status

### Verificação Rápida

```bash
# Ver status do módulo (porta 6969)
systemctl status atlas-modulo --no-pager

# Ver últimas linhas do log de sincronização
tail -10 /var/log/atlas_sync.log
```

### Diagnóstico Completo

```bash
# Executar diagnóstico completo
sudo bash /etc/painel/atlas_sync_diagnostic.sh
```

### Monitorar em Tempo Real

```bash
# Ver log ao vivo
tail -f /var/log/atlas_sync.log
```

## 🔄 Sincronização Manual

```bash
# Executar sincronização manual
sudo bash /etc/painel/atlas_sync_cron.sh
```

## 📝 Logs e Troubleshooting

```bash
# Ver log de sincronização
cat /var/log/atlas_sync.log

# Ver logs do serviço
journalctl -u atlas-modulo -n 50 --no-pager
```

## 🛠️ Limpeza de Módulos Antigos

O script **já remove automaticamente** módulos antigos durante a instalação. Não é necessário fazer limpeza manual.

## 🔐 Segurança

1. **Mude a senha padrão** se necessário
2. **Proteja o arquivo de API Key** (`/etc/painel/atlas.key` — já vem com permissão 600)
3. **Monitore os logs** regularmente

## 📚 Estrutura de Arquivos

```
/root/
├── modulo.py                    # Servidor HTTP (PUSH)
└── dragonmodule                 # Dispatcher de comandos

/etc/painel/
├── atlas.sh                     # Atlas functions (oficial)
├── atlas_sync_cron.sh           # Sincronização (PULL)
├── atlas_sync_diagnostic.sh     # Diagnóstico
├── usuarios.db                  # Banco de usuários
└── atlas.key                    # API Key do Atlas

/etc/systemd/system/
└── atlas-modulo.service         # Service file

/etc/cron.d/
└── atlas_sync                   # Cron job (a cada 1 min)

/var/log/
└── atlas_sync.log               # Log de sincronização
```

## 🔄 Fluxo de Sincronização

### PUSH (Tempo Real — 6969)
```
Atlas → HTTP POST :6969 → modulo.py → dragonmodule → adduser/deluser
```

### PULL (Periódico — Cron)
```
cron (a cada 1 min) → atlas_sync_cron.sh → atlas_sync_users() → Atlas API → usuarios.db ↔ Xray
```

## 🐛 Histórico de Correções (v4)

| Versão | Problema | Solução |
|--------|----------|---------|
| v1 | Auto-merge deletava usuários | Removido |
| v2 | Lock em diretório travava cron | Mudado para flock (arquivo) |
| v3 | apt travava sem DEBIAN_FRONTEND | Adicionado nos scripts |
| v4 | Consolidação de duas repos diferentes | Mesclou o melhor de cada |

## 🤝 Suporte

Encontrou um bug? Abra uma issue no GitHub com:
- Saída do diagnóstico
- Últimas linhas do log
- Descrição do problema

---

**Versão:** 4.0 | **Atualizado:** Jul/2026 | **Status:** Estável ✅

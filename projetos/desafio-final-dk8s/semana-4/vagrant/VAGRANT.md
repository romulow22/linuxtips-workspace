# Vagrant — Cluster Kubernetes Local

Cluster kubeadm com 1 control-plane e N workers em VirtualBox.

**Rede:** `192.168.10.0/24`
- `192.168.10.100` → control-plane
- `192.168.10.2` → node1, `192.168.10.3` → node2, …

**Stack:** Ubuntu 22.04 · Docker · Kubernetes 1.33 · Calico CNI

---

## Arquivos

### `Vagrantfile`
Define as VMs. Lê variáveis de `.env` via `ENV[]`; usa valores padrão se ausentes.
Ordem de provisionamento por VM:

| VM | Scripts executados |
|---|---|
| Todas | `requirements.sh` |
| control-plane | `requirements.sh` → `controlplane.sh` → `post-install.sh` |
| node_N | `requirements.sh` → `node.sh` |

### `cluster.ps1`
Script de gerenciamento para Windows (PowerShell 5.1+).

```
.\cluster.ps1 create              # sobe as VMs e aguarda o cluster ficar pronto
.\cluster.ps1 destroy             # destrói as VMs
.\cluster.ps1 status              # VMs + nodes + pods
.\cluster.ps1 kubeconfig          # extrai o kubeconfig para .\kubeconfig
.\cluster.ps1 kubeconfig -Merge   # extrai e faz merge em ~\.kube\config
.\cluster.ps1 ssh [node]          # SSH na VM (padrão: control-plane)
.\cluster.ps1 validate            # roda validate-cluster.sh
.\cluster.ps1 logs [node]         # logs do kubelet / kubeadm
.\cluster.ps1 restart             # halt + up
.\cluster.ps1 config              # exibe variáveis do .env
```

### `.env` / `.env.example`
Variáveis de configuração do cluster. Copie `.env.example` para `.env` e ajuste.

| Variável | Padrão | Descrição |
|---|---|---|
| `NODE_COUNT` | `1` | Número de workers |
| `CP_MEMORY` | `4096` | RAM do control-plane (MB) |
| `CP_CPUS` | `4` | CPUs do control-plane |
| `NODE_MEMORY` | `4096` | RAM por worker (MB) |
| `NODE_CPUS` | `2` | CPUs por worker |
| `ENABLE_GUI` | `false` | Interface gráfica da VM |
| `PROVIDER` | `virtualbox` | Provider do Vagrant |

### `joincluster.sh`
Gerado automaticamente pelo `controlplane.sh` com o comando `kubeadm join`. Consumido pelo `node.sh`. Não editar manualmente.

### `kubeconfig`
Gerado pelo `cluster.ps1 kubeconfig`. Aponta para `https://192.168.10.100:6443` com `insecure-skip-tls-verify: true`. Não commitar.

---

## scripts/

### `requirements.sh`
Executado em **todos os nós** antes de qualquer outro script.

1. Popula `/etc/hosts` com IPs do cluster
2. Instala Docker e utilitários
3. Instala `kubelet`, `kubeadm`, `kubectl` (v1.33, pinados com `apt-mark hold`)
4. Configura containerd
5. Desabilita swap

### `controlplane.sh`
Executado **apenas no control-plane**.

1. `kubeadm init` — API server em `192.168.10.100`, CIDR `10.244.0.0/16`
2. Copia `admin.conf` para `/home/vagrant/.kube/config`
3. Aplica Calico CNI
4. Gera `/vagrant/joincluster.sh` via `kubeadm token create`

### `node.sh`
Executado **em cada worker**.

1. Aguarda `/vagrant/joincluster.sh` existir (timeout 5 min)
2. Verifica conectividade com a API (`192.168.10.100:6443`)
3. Executa o join com até 3 tentativas (retry com 15s de intervalo)
4. Log em `/tmp/kubeadm-join.log`

### `post-install.sh`
Executado no control-plane **como usuário `vagrant`** (sem root), após o cluster estar de pé.

1. Configura aliases kubectl (`k`, `kgp`, etc.) no `.bashrc`
2. Instala Metrics Server + patch `--kubelet-insecure-tls` (necessário para clusters com cert self-signed)
3. Cria namespace `examples`
4. Gera `~/check-cluster.sh` para verificação rápida do cluster

### `validate-cluster.sh`
Script de validação de saúde do cluster. Deve ser executado no control-plane.

Verifica: acesso kubectl · nodes Ready · componentes do control-plane · CoreDNS · CNI (Calico/Flannel) · kube-proxy · pressão de recursos (memória/disco/PID) · DNS interno · eventos recentes.

Saída: `✓` passa · `⚠` aviso · `✗` erro. Exit code `1` se houver erros.

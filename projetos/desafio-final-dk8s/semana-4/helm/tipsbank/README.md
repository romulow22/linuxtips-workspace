# TipsBank — Helm Umbrella Chart

Banco digital completo em Kubernetes, empacotado como um único *umbrella chart*. Sobe toda a stack do TipsBank (frontend, APIs, banco, auditoria, carga e observabilidade) com governança via Kyverno e RBAC.

| | |
|---|---|
| **Chart version** | `1.0.4` |
| **App version** | `1.0.0` |
| **Tipo** | `application` |
| **Registry (OCI)** | `oci://registry-1.docker.io/romulow22/tipsbank` |

---

## Arquitetura

O chart cria os namespaces e workloads abaixo:

| Namespace | Workloads | Observações |
|---|---|---|
| `tipsbank-contas` | `api-contas` (Deployment, 2 réplicas) · `postgres` (StatefulSet) | Postgres exposto via headless service `postgres-headless:5432` |
| `tipsbank-transacoes` | `api-transacoes` v1 (Deployment) · `api-transacoes-v2` (canary) | Canary por peso/header (ver abaixo) |
| `tipsbank-auditoria` | `auditoria` (Deployment, 3 réplicas) | Persistência em PVC `nfs-ganesha` |
| `tipsbank-web` | `web` (nginx-unprivileged) | Frontend |
| `tipsbank-monitoring` | `locust` · ServiceMonitors · PrometheusRule | Carga e observabilidade da aplicação |

**Transversais:** Ingress NGINX (TLS via cert-manager), HPAs, NetworkPolicies (default-deny + regras por serviço), RBAC (Roles/ClusterRoles/ServiceAccounts) e políticas Kyverno (validate/mutate/generate).

---

## Pré-requisitos

O chart **não** instala os addons de cluster — eles vêm antes, via `scripts/install-addons.ps1` (ou `cluster.ps1 <env> addons`):

- **ingress-nginx** — Ingress controller (NodePort 30080/30443 no Vagrant; NLB no EKS)
- **cert-manager** + `ClusterIssuer` `selfsigned-issuer` — TLS dos ingresses
- **nfs-provisioner** — StorageClass `nfs-ganesha` (PVC de auditoria)
- **kube-prometheus-stack** — Prometheus/Grafana/Alertmanager (consome os ServiceMonitors/PrometheusRule do chart)
- **kyverno** — admission controller para as políticas

Ferramentas: `helm` ≥ 3.8 (suporte OCI), `kubectl`.

---

## Instalação

### Vagrant (kubeadm local)

```powershell
helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank `
  --version 1.0.4 -f helm/tipsbank/values-vagrant-prod.yaml --wait --timeout 10m
```

### EKS (AWS)

O host do ingress é o FQDN do NLB, injetado por `--set` (routing por path no mesmo host):

```powershell
$nlb = kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank `
  --version 1.0.4 -f helm/tipsbank/values-eks-prod.yaml `
  --set ingress.appHost=$nlb --set ingress.apiHost=$nlb --wait --timeout 10m
```

> Há quatro arquivos de values: `values-{vagrant,eks}-{dev,prod}.yaml`. O `values.yaml` traz os padrões (lab local).

---

## Configuração (principais parâmetros)

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `global.team` / `global.env` | `tipsbank` / `prod` | Labels obrigatórios (exigidos pela policy Kyverno) |
| `global.imagePullPolicy` | `IfNotPresent` | Política de pull padrão |
| `ingress.enabled` | `true` | Cria os ingresses |
| `ingress.appHost` / `apiHost` | `app.tipsbank.local` / `api.tipsbank.local` | Hosts do frontend e da API (no EKS, `--set` com o NLB) |
| `ingress.tls.enabled` / `issuer` | `true` / `selfsigned-issuer` | TLS via cert-manager |
| `ingress.rateLimitRps` | `50` | Rate limit do ingress |
| `postgres.image` / `storage` | `postgres:16-alpine` / `2Gi` | Banco (StatefulSet) |
| `contas.replicas` / `hpa` | `2` / 2–10 @70% CPU | API de contas |
| `transacoes.replicas` / `hpa` | `2` / 3–15 @70% CPU | API de transações (v1) |
| `transacoes.canary.*` | ver abaixo | Deployment v2 (canary) |
| `auditoria.replicas` / `storageClass` | `3` / `nfs-ganesha` | Auditoria + PVC NFS |
| `web.replicas` / `hpa` | `2` / desabilitado | Frontend |
| `locust.enabled` / `host` | `true` / `locust.tipsbank.local` | Teste de carga |
| `rbac.enabled` / `trustedRegistry` | `true` / `romulow22` | RBAC + registry confiável (policy) |
| `kyverno.enabled` | `true` | Aplica as políticas do chart |

### Canary (api-transacoes)

```yaml
transacoes:
  canary:
    enabled: true
    weight: "10"          # % do tráfego de /transacoes para a v2
    headerName: X-Canary  # força v2 com: -H "X-Canary: true"
    headerValue: "true"
```

O `ingress-canary` divide o tráfego por peso e permite rota forçada por header. Útil para demo de progressive delivery.

---

## Notas de resiliência

- **`api-contas` e `api-transacoes`** têm um initContainer **`wait-for-postgres`** que bloqueia o start até o `postgres-headless:5432` resolver (DNS) e aceitar conexão. Sem ele, as APIs fazem connect ansioso no startup, falham enquanto `postgres-0` não está *Ready* e reiniciam (`exit 3`). Ver changelog **1.0.4**.
- Probes: `api-transacoes` usa `startupProbe` (`/health/startup`), `livenessProbe` (`/health/live`) e `readinessProbe` (`/health/ready`).

---

## Changelog

> Versionamento do **chart** (independente do `appVersion`, fixo em `1.0.0`). O chart entra versionado neste repositório a partir da `1.0.1`; no git a sequência salta de `1.0.1` para `1.0.3` (a `1.0.2` foi uma iteração de desenvolvimento — ver abaixo).

### 1.0.4 — *atual*
- **Fix:** initContainer `wait-for-postgres` em `api-transacoes` (v1 e v2). Elimina os restarts de startup (`exitCode 3`, *Application startup failed: failed to resolve host `postgres-headless...`*) causados pela app conectar ao DB antes do `postgres-0` ficar Ready — o `startupProbe` não cobre porque o processo **saía**. Alinha transacoes ao padrão que `api-contas` já adotava.

### 1.0.3 — Canary + Locust *(2026-05-25)*
- **Canary** para `api-transacoes`: novo `deployment-v2`, `service-v2` e `ingress-canary` (split por peso de 10% + rota forçada via header `X-Canary`).
- **Locust** integrado: `deployment` + `ingress` para testes de carga apontando para `api-transacoes`.
- Novos parâmetros em `values.yaml` (`transacoes.canary.*`, `locust.*`).

### 1.0.2 — Imagem do Locust
- Ajuste na imagem `tipsbank-locust` (base `locustio/locust:2.32.3` + `locustfile.py`), rebuildada iterativamente até o Python rodar corretamente no container — daí o tag **`v7.0.0`** referenciado em `locust.image`. Os ajustes envolveram o `locustfile.py`: criação de contas cross-namespace via `urllib` no `on_start` (chamando `api-contas`), uso de `self.client` com `catch_response` nas tasks de transferência/extrato e o listener `test_stop`. Iteração de desenvolvimento — consolidada junto à integração do Locust na `1.0.3`.

### 1.0.0 – 1.0.1 — Release inicial / baseline
Stack completa do TipsBank no umbrella chart:
- Workloads: `web`, `api-contas` + Postgres (StatefulSet), `api-transacoes`, `auditoria` (PVC NFS).
- Ingress NGINX + TLS via cert-manager, rate limiting.
- HPAs por serviço; NetworkPolicies (default-deny + regras específicas).
- RBAC (perfis operador-contas, operador-transacoes, auditor-global, SRE) e *trusted registry*.
- Políticas Kyverno: validate (proibir root/`:latest`/labels obrigatórios/registry não confiável), mutate (securityContext) e generate (NetworkPolicy default-deny por namespace).
- Observabilidade: ServiceMonitors + PrometheusRule (consumidos pelo kube-prometheus-stack).

---

## Desenvolvimento

```powershell
helm lint helm/tipsbank -f helm/tipsbank/values-vagrant-prod.yaml
helm template tipsbank helm/tipsbank -f helm/tipsbank/values-vagrant-prod.yaml   # render local
helm package helm/tipsbank -d helm/dist                                          # gera .tgz (gitignored)
helm push helm/dist/tipsbank-<versão>.tgz oci://registry-1.docker.io/romulow22   # publica no registry
```

# Evidências - Desafio Final TipsBank Kubernetes

Este documento contém os registros de execução (prints, outputs de comandos e justificativas) solicitados nos critérios de aceite do projeto, conforme as etapas do `MANUAL-ALUNO.md`.

---

## SEMANA 4 — Compliance, RBAC, Helm e Entrega Final

---

### Etapa 4.1 — Kyverno: Validate (proibir root, proibir latest)

**Objetivo**: nenhum pod consegue ser criado com `runAsUser: 0` ou `image: *:latest`. Deployments sem labels `app`, `team`, `env` são rejeitados.

#### Verificação: 3 ClusterPolicies no estado ready

(1) Cluster EKS
```
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> kubectl get cpol
NAME                            ADMISSION   BACKGROUND   READY   AGE    MESSAGE
disallow-latest-tag             true        true         True    123m   Ready
disallow-root-user              true        true         True    125m   Ready
disallow-untrusted-registries   true        true         True    122m   Ready
generate-default-deny-netpol    true        true         True    122m   Ready
mutate-security-context         true        true         True    122m   Ready
require-labels                  true        true         True    122m   Ready
```

#### Teste 1: pod com runAsUser: 0 rejeitado

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ kubectl run ruim-root --image=busybox:1.36 --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' -- sleep 60
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/ruim-root was blocked due to the following policies 

disallow-root-user:
  check-pod-security-context: 'validation error: runAsUser: 0 (root) não é permitido.
    Use UID > 0. rule check-pod-security-context failed at path /spec/securityContext/runAsUser/'
```

#### Teste 2: pod com imagem :latest rejeitado

(1) Cluster EKS

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ kubectl run ruim-latest --image=nginx:latest
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/ruim-latest was blocked due to the following policies 

disallow-latest-tag:
  check-image-tag: 'validation error: Tag '':latest'' proibida. Use tag explícita
    (ex: v1.0.0, 16-alpine). rule check-image-tag failed at path /spec/containers/0/image/'

```

#### Teste 3: Deployment sem labels obrigatórios rejeitado

(1) Cluster EKS

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sem-labels
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sem-labels
  template:
    metadata:
      labels:
        app: sem-labels
    spec:
      containers:
        - name: sem-labels
          image: busybox:1.36
          command: ["sleep", "60"]
EOF
Error from server: error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Deployment/default/sem-labels was blocked due to the following policies 

require-labels:
  check-required-labels: 'validation error: Labels obrigatórios ausentes: ''app'',
    ''team'' e ''env'' devem estar presentes em metadata.labels. Exemplo: team=tipsbank,
    env=prod. rule check-required-labels failed at path /metadata/labels/'
```

#### Verificação: pods TipsBank passam nas policies

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ kubectl get pods -A | grep tipsbank
tipsbank-auditoria    auditoria-6f9b79b756-cmzmq                                 1/1     Running     0          3h24m
tipsbank-auditoria    auditoria-6f9b79b756-fcztq                                 1/1     Running     0          3h24m
tipsbank-contas       api-contas-b5f75b974-nd2nv                                 1/1     Running     0          3h25m
tipsbank-contas       api-contas-b5f75b974-nzmnv                                 1/1     Running     0          3h25m
tipsbank-contas       postgres-0                                                 1/1     Running     0          3h25m
tipsbank-contas       postgres-replica-0                                         1/1     Running     0          3h25m
tipsbank-monitoring   alertmanager-kube-prometheus-stack-alertmanager-0          2/2     Running     0          3h27m
tipsbank-monitoring   kube-prometheus-stack-grafana-677cc4d7f7-r97rq             3/3     Running     0          3h27m
tipsbank-monitoring   kube-prometheus-stack-kube-state-metrics-cbbcc4559-j4fng   1/1     Running     0          3h27m
tipsbank-monitoring   kube-prometheus-stack-operator-676cc557dd-9tlnk            1/1     Running     0          3h27m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-65p8f       1/1     Running     0          3h27m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-7d5g5       1/1     Running     0          3h27m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-rbbvw       1/1     Running     0          3h27m
tipsbank-monitoring   locust-545d7f9b-sczs9                                      1/1     Running     0          122m
tipsbank-monitoring   node-logger-brrh7                                          1/1     Running     0          3h24m
tipsbank-monitoring   node-logger-dmc9d                                          1/1     Running     0          3h24m
tipsbank-monitoring   node-logger-r4hmz                                          1/1     Running     0          3h24m
tipsbank-monitoring   prometheus-kube-prometheus-stack-prometheus-0              2/2     Running     0          3h27m
tipsbank-transacoes   api-transacoes-7bd68db8fb-ch5db                            2/2     Running     0          123m
tipsbank-transacoes   api-transacoes-7bd68db8fb-cjgmd                            2/2     Running     0          123m
tipsbank-transacoes   api-transacoes-7bd68db8fb-vjjnj                            2/2     Running     0          123m
tipsbank-transacoes   api-transacoes-v2-788cc5677-4vlql                          2/2     Running     0          123m
tipsbank-web          web-558ddc9454-mpdk5                                       1/1     Running     0          123m
tipsbank-web          web-558ddc9454-zc2hc                                       1/1     Running     0          123m

```

---

### Etapa 4.2 — Kyverno: Mutate (injetar securityContext)

**Objetivo**: Kyverno injeta automaticamente `runAsNonRoot: true`, `readOnlyRootFilesystem: true` e `allowPrivilegeEscalation: false` em qualquer pod novo.

#### Verificação: pod criado sem securityContext recebe mutação

```
$ kubectl run mutate-test --image=busybox:1.36 \
  --restart=Never -n tipsbank-contas \
  -- sleep 3600
pod/mutate-test created

$ kubectl get pod mutate-test -n tipsbank-contas -o yaml \
  | grep -A 15 "containers:" | grep -A 10 securityContext
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    volumeMounts:
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount

```

#### Verificação: APIs TipsBank funcionando com readOnlyRootFilesystem

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ curl -sk https:/a41eafb4ec5c04517bf06247d542d462-ed60cf8e31e41c8d.elb.us-east-2.amazonaws.com/contas/health/live | jq .
{
  "status": "ok"
}

romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ curl -sk https://a41eafb4ec5c04517bf06247d542d462-ed60cf8e31e41c8d.elb.us-east-2.amazonaws.com/transacoes/health/live | jq .
{
  "status": "ok",
  "version": "v1"
}

romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ curl -sk https://a41eafb4ec5c04517bf06247d542d462-ed60cf8e31e41c8d.elb.us-east-2.amazonaws.com/auditoria/health/live | jq .
{
  "status": "ok"
}

```

---

### Etapa 4.3 — Kyverno: Generate (NetworkPolicy automática por namespace)

**Objetivo**: ao criar qualquer namespace novo, o Kyverno gera automaticamente uma NetworkPolicy default-deny nele. Imagens de registries não confiáveis são rejeitadas.

#### Verificação: NetworkPolicy gerada automaticamente em novo namespace

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ kubectl create namespace teste-deny
namespace/teste-deny created

romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ kubectl get netpol -n teste-deny
NAME               POD-SELECTOR   AGE
default-deny-all   <none>         12s

```

#### Verificação: imagem de registry externo rejeitada

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ kubectl run teste-externo --image=docker.io/nginx:1.25 -n tipsbank-contas
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/tipsbank-contas/teste-externo was blocked due to the following policies 

disallow-untrusted-registries:
  check-image-registry: 'validation failure: Registry não autorizado. Use apenas:
    romulow22/*, busybox:*, postgres:* ou ghcr.io/*. Registry externo (ex: docker.io/nginx)
    é bloqueado.'
```

#### Verificação: imagem do registry confiável aceita

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace (main)
$ kubectl run teste-confiavel --image=romulow22/tipsbank-api-contas:v1.0.0 -n tipsbank-contas
pod/teste-confiavel created
```

---

### Etapa 4.4 — RBAC: 4 perfis com certificados X.509

**Objetivo**: 4 usuários humanos com certificado X.509 próprio e permissões distintas.

| Usuário | Escopo | Permissões |
|---|---|---|
| `operador-contas` | Role em `tipsbank-contas` | get/list/watch pods e logs |
| `operador-transacoes` | Role em `tipsbank-transacoes` | get/list/watch pods, logs, exec |
| `auditor-global` | ClusterRole | get/list/watch pods/logs em todos os ns |
| `sre` | ClusterRole cluster-admin | tudo |

#### Verificação: operador-contas — acesso permitido no namespace correto

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl --kubeconfig=evidencias/kubeconfigs/operador-contas.kubeconfig get pods -n tipsbank-contas
NAME                         READY   STATUS    RESTARTS   AGE
api-contas-b5f75b974-nd2nv   1/1     Running   0          3h47m
api-contas-b5f75b974-nzmnv   1/1     Running   0          3h47m
postgres-0                   1/1     Running   0          3h47m
postgres-replica-0           1/1     Running   0          3h47m
```

#### Verificação: operador-contas — acesso negado em outro namespace

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl --kubeconfig=evidencias/kubeconfigs/operador-contas.kubeconfig get pods -n tipsbank-transacoes
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:tipsbank-contas:user-operador-contas" cannot list resource "pods" in API group "" in the namespace "tipsbank-transacoes"
```

#### Verificação: auditor-global — lista todos os namespaces

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl --kubeconfig=evidencias/kubeconfigs/auditor-global.kubeconfig get pods -A
NAMESPACE             NAME                                                       READY   STATUS      RESTARTS   AGE
cert-manager          cert-manager-6c6cd69dc5-rwpr6                              1/1     Running     0          3h54m
cert-manager          cert-manager-cainjector-75cbd9fd8d-jfdsz                   1/1     Running     0          3h54m
cert-manager          cert-manager-webhook-6868c4c4fc-wp7kt                      1/1     Running     0          3h54m
ingress-nginx         ingress-nginx-controller-6797f4dc8c-nrbh4                  1/1     Running     0          3h55m
kube-system           aws-node-26drv                                             2/2     Running     0          3h59m
kube-system           aws-node-48rnd                                             2/2     Running     0          3h59m
kube-system           aws-node-zbzlt                                             2/2     Running     0          3h59m
kube-system           coredns-6b996f498b-lhgmf                                   1/1     Running     0          4h4m
kube-system           coredns-6b996f498b-qf25l                                   1/1     Running     0          4h4m
kube-system           ebs-csi-controller-5947f549b6-dwd5b                        6/6     Running     0          3h56m
kube-system           ebs-csi-controller-5947f549b6-fvcrq                        6/6     Running     0          3h56m
kube-system           ebs-csi-node-8hphh                                         3/3     Running     0          3h56m
kube-system           ebs-csi-node-bkvbf                                         3/3     Running     0          3h56m
kube-system           ebs-csi-node-thhvr                                         3/3     Running     0          3h56m
kube-system           kube-proxy-5jx62                                           1/1     Running     0          3h59m
kube-system           kube-proxy-hcmpp                                           1/1     Running     0          3h59m
kube-system           kube-proxy-mmzdv                                           1/1     Running     0          3h59m
kube-system           metrics-server-646b8d7599-mrrdg                            1/1     Running     0          3h58m
kube-system           metrics-server-646b8d7599-pggl2                            1/1     Running     0          3h58m
kyverno               kyverno-admission-controller-5486ff4c6b-qxj2p              1/1     Running     0          163m
kyverno               kyverno-background-controller-59dbfc6f9d-r4fw4             1/1     Running     0          163m
kyverno               kyverno-cleanup-controller-fddbff9c-dg5jd                  1/1     Running     0          163m
kyverno               kyverno-migrate-resources-dfnwj                            0/1     Completed   0          156m
kyverno               kyverno-reports-controller-57585d94cd-dk976                1/1     Running     0          163m
nfs-provisioner       nfs-provisioner-nfs-server-provisioner-0                   1/1     Running     0          3h53m
tipsbank-auditoria    auditoria-6f9b79b756-cmzmq                                 1/1     Running     0          3h49m
tipsbank-auditoria    auditoria-6f9b79b756-fcztq                                 1/1     Running     0          3h49m
tipsbank-contas       api-contas-b5f75b974-nd2nv                                 1/1     Running     0          3h50m
tipsbank-contas       api-contas-b5f75b974-nzmnv                                 1/1     Running     0          3h50m
tipsbank-contas       postgres-0                                                 1/1     Running     0          3h50m
tipsbank-contas       postgres-replica-0                                         1/1     Running     0          3h50m
tipsbank-monitoring   alertmanager-kube-prometheus-stack-alertmanager-0          2/2     Running     0          3h52m
tipsbank-monitoring   kube-prometheus-stack-grafana-677cc4d7f7-r97rq             3/3     Running     0          3h52m
tipsbank-monitoring   kube-prometheus-stack-kube-state-metrics-cbbcc4559-j4fng   1/1     Running     0          3h52m
tipsbank-monitoring   kube-prometheus-stack-operator-676cc557dd-9tlnk            1/1     Running     0          3h52m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-65p8f       1/1     Running     0          3h52m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-7d5g5       1/1     Running     0          3h52m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-rbbvw       1/1     Running     0          3h52m
tipsbank-monitoring   locust-545d7f9b-sczs9                                      1/1     Running     0          147m
tipsbank-monitoring   node-logger-brrh7                                          1/1     Running     0          3h48m
tipsbank-monitoring   node-logger-dmc9d                                          1/1     Running     0          3h48m
tipsbank-monitoring   node-logger-r4hmz                                          1/1     Running     0          3h48m
tipsbank-monitoring   prometheus-kube-prometheus-stack-prometheus-0              2/2     Running     0          3h52m
tipsbank-transacoes   api-transacoes-7bd68db8fb-ch5db                            2/2     Running     0          148m
tipsbank-transacoes   api-transacoes-7bd68db8fb-cjgmd                            2/2     Running     0          148m
tipsbank-transacoes   api-transacoes-7bd68db8fb-vjjnj                            2/2     Running     0          148m
tipsbank-transacoes   api-transacoes-v2-788cc5677-4vlql                          2/2     Running     0          148m
tipsbank-web          web-558ddc9454-mpdk5                                       1/1     Running     0          147m
tipsbank-web          web-558ddc9454-zc2hc                                       1/1     Running     0          147m
```

#### Verificação: auditor-global — delete negado (readonly)

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl --kubeconfig=evidencias/kubeconfigs/auditor-global.kubeconfig delete pod postgres-replica-0 -n tipsbank-contas
Error from server (Forbidden): pods "postgres-replica-0" is forbidden: User "system:serviceaccount:tipsbank-auditoria:user-auditor-global" cannot delete resource "pods" in API group "" in the namespace "tipsbank-contas"
```

#### Verificação: ServiceAccounts criadas

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl get sa -A | grep tipsbank
tipsbank-auditoria    default                                          0         3h51m
tipsbank-auditoria    sa-auditoria                                     0         148m
tipsbank-auditoria    user-auditor-global                              0         119m
tipsbank-contas       default                                          0         3h51m
tipsbank-contas       sa-api-contas                                    0         148m
tipsbank-contas       user-operador-contas                             0         119m
tipsbank-contas       user-sre                                         0         119m
tipsbank-monitoring   default                                          0         3h54m
tipsbank-monitoring   kube-prometheus-stack-alertmanager               0         3h53m
tipsbank-monitoring   kube-prometheus-stack-grafana                    0         3h53m
tipsbank-monitoring   kube-prometheus-stack-kube-state-metrics         0         3h53m
tipsbank-monitoring   kube-prometheus-stack-operator                   0         3h53m
tipsbank-monitoring   kube-prometheus-stack-prometheus                 0         3h53m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter   0         3h53m
tipsbank-transacoes   default                                          0         3h51m
tipsbank-transacoes   sa-api-transacoes                                0         148m
tipsbank-transacoes   user-operador-transacoes                         0         119m
tipsbank-web          default                                          0         3h51m
tipsbank-web          sa-web                                           0         148m
```

---

### Etapa 4.5 — Helm Chart umbrella

**Objetivo**: um único `helm install tipsbank` sobe o banco inteiro (app + monitoring + policies) num cluster vazio.

#### helm lint

```
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> helm lint helm/tipsbank/
==> Linting helm/tipsbank/
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

#### helm template — inventário de recursos (kind/nome, ordenado)

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ helm template tipsbank helm/tipsbank/ -f helm/tipsbank/values-vagrant-prod.yaml | awk '/^kind:/{k=$2} /^  name:/{print k"/"$2}' | sort
ClusterPolicy/disallow-latest-tag
ClusterPolicy/disallow-root-user
ClusterPolicy/disallow-untrusted-registries
ClusterPolicy/generate-default-deny-netpol
ClusterPolicy/mutate-security-context
ClusterPolicy/require-labels
ClusterRole/auditor-global
ClusterRoleBinding/auditor-global
ClusterRoleBinding/auditor-global-binding
ClusterRoleBinding/cluster-admin
ClusterRoleBinding/sre-binding
ConfigMap/configmap-app
ConfigMap/configmap-app
ConfigMap/configmap-initsql
ConfigMap/configmap-nginx
Deployment/api-contas
Deployment/api-transacoes
Deployment/auditoria
Deployment/web
HorizontalPodAutoscaler/hpa-api-contas
HorizontalPodAutoscaler/hpa-api-transacoes
HorizontalPodAutoscaler/hpa-auditoria
HorizontalPodAutoscaler/hpa-web
Ingress/ingress-api-auditoria
Ingress/ingress-api-contas
Ingress/ingress-api-transacoes
Ingress/ingress-app
Namespace/tipsbank-auditoria
Namespace/tipsbank-contas
Namespace/tipsbank-monitoring
Namespace/tipsbank-transacoes
Namespace/tipsbank-web
NetworkPolicy/allow-dns-egress
NetworkPolicy/allow-dns-egress
NetworkPolicy/allow-dns-egress
NetworkPolicy/allow-dns-egress
NetworkPolicy/allow-egress-nfs
NetworkPolicy/allow-egress-postgres
NetworkPolicy/allow-egress-to-apis
NetworkPolicy/allow-egress-to-auditoria
NetworkPolicy/allow-egress-to-contas
NetworkPolicy/allow-from-transacoes
NetworkPolicy/allow-from-web
NetworkPolicy/allow-from-web
NetworkPolicy/allow-from-web-and-transacoes
NetworkPolicy/allow-ingress-controller
NetworkPolicy/allow-ingress-controller
NetworkPolicy/allow-ingress-controller
NetworkPolicy/allow-ingress-controller
NetworkPolicy/allow-postgres-ingress
NetworkPolicy/allow-prometheus-scrape
NetworkPolicy/allow-prometheus-scrape
NetworkPolicy/allow-prometheus-scrape
NetworkPolicy/default-deny
NetworkPolicy/default-deny
NetworkPolicy/default-deny
NetworkPolicy/default-deny
PersistentVolumeClaim/pvc-auditoria-nfs
PrometheusRule/tipsbank-slo-alerts
Role/operador-contas
Role/operador-transacoes
RoleBinding/operador-contas
RoleBinding/operador-contas-binding
RoleBinding/operador-transacoes
RoleBinding/operador-transacoes-binding
Secret/secret-db
Secret/secret-db
Service/api-contas
Service/api-transacoes
Service/auditoria
Service/postgres-headless
Service/web
ServiceAccount/sa-api-contas
ServiceAccount/sa-api-transacoes
ServiceAccount/sa-auditoria
ServiceAccount/sa-web
ServiceAccount/user-auditor-global
ServiceAccount/user-operador-contas
ServiceAccount/user-operador-transacoes
ServiceAccount/user-sre
ServiceMonitor/api-contas
ServiceMonitor/api-transacoes
ServiceMonitor/auditoria
StatefulSet/postgres
```

#### helm install em cluster limpo

```
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank  --version 1.0.1 -f helm/tipsbank/values-vagrant-dev.yaml
Release "tipsbank" does not exist. Installing it now.
Pulled: registry-1.docker.io/romulow22/tipsbank:1.0.1
Digest: sha256:f81ff8f73de9178d65aa905025af1c9340c8e57de0cc007639ce8bf090634284
NAME: tipsbank
LAST DEPLOYED: Wed May 20 00:01:37 2026
NAMESPACE: default
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

#### Todos os pods subindo após install

```
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> kubectl get pods -A                                                                                                   
NAMESPACE             NAME                                                       READY   STATUS      RESTARTS      AGE
cert-manager          cert-manager-6c6cd69dc5-wdgb6                              1/1     Running     0             76m
cert-manager          cert-manager-cainjector-75cbd9fd8d-jvfh6                   1/1     Running     0             76m
cert-manager          cert-manager-webhook-6868c4c4fc-fwztq                      1/1     Running     0             76m
ingress-nginx         ingress-nginx-controller-85547fdc5f-xrwqn                  1/1     Running     0             77m
kube-system           calico-kube-controllers-654fb9bf6f-9m4vl                   1/1     Running     0             90m
kube-system           calico-node-h5prj                                          1/1     Running     0             86m
kube-system           calico-node-p2dpx                                          1/1     Running     0             83m
kube-system           calico-node-qxnq7                                          1/1     Running     0             90m
kube-system           calico-node-sq5bw                                          1/1     Running     0             80m
kube-system           coredns-674b8bbfcf-brnx6                                   1/1     Running     0             90m
kube-system           coredns-674b8bbfcf-sd4nj                                   1/1     Running     0             90m
kube-system           etcd-controlplane                                          1/1     Running     0             90m
kube-system           kube-apiserver-controlplane                                1/1     Running     0             90m
kube-system           kube-controller-manager-controlplane                       1/1     Running     0             90m
kube-system           kube-proxy-68dx8                                           1/1     Running     0             83m
kube-system           kube-proxy-jgb5l                                           1/1     Running     0             80m
kube-system           kube-proxy-mc25m                                           1/1     Running     0             90m
kube-system           kube-proxy-vcrwr                                           1/1     Running     0             86m
kube-system           kube-scheduler-controlplane                                1/1     Running     0             90m
kube-system           metrics-server-56ff78d5b7-4cpbx                            1/1     Running     0             89m
kyverno               kyverno-admission-controller-5486ff4c6b-9f87x              1/1     Running     0             78m
kyverno               kyverno-background-controller-59dbfc6f9d-trtlk             1/1     Running     0             78m
kyverno               kyverno-cleanup-controller-fddbff9c-gd7px                  1/1     Running     0             78m
kyverno               kyverno-migrate-resources-gw9ct                            0/1     Completed   0             27m
kyverno               kyverno-reports-controller-57585d94cd-r58wm                1/1     Running     0             78m
local-path-storage    local-path-provisioner-568d8fd5ff-jtw2j                    1/1     Running     0             89m
monitoring            alertmanager-kube-prometheus-stack-alertmanager-0          2/2     Running     0             26m
monitoring            kube-prometheus-stack-grafana-5855f6fd5c-5p9m6             3/3     Running     0             26m
monitoring            kube-prometheus-stack-kube-state-metrics-cbbcc4559-b9bzk   1/1     Running     0             26m
monitoring            kube-prometheus-stack-operator-5d56b7c888-9hx2p            1/1     Running     0             26m
monitoring            kube-prometheus-stack-prometheus-node-exporter-875td       1/1     Running     0             26m
monitoring            kube-prometheus-stack-prometheus-node-exporter-frcbl       1/1     Running     0             26m
monitoring            kube-prometheus-stack-prometheus-node-exporter-n2zpc       1/1     Running     0             26m
monitoring            kube-prometheus-stack-prometheus-node-exporter-xgtj9       1/1     Running     0             26m
monitoring            prometheus-kube-prometheus-stack-prometheus-0              2/2     Running     0             26m
nfs-provisioner       nfs-provisioner-nfs-server-provisioner-0                   1/1     Running     0             76m
tipsbank-auditoria    auditoria-6c8ff8dfcf-f9f25                                 1/1     Running     0             30s
tipsbank-contas       api-contas-8c5c7f979-c7plm                                 1/1     Running     0             30s
tipsbank-contas       postgres-0                                                 1/1     Running     0             30s
tipsbank-transacoes   api-transacoes-68946b4fdf-4pw7c                            2/2     Running     1 (21s ago)   30s
tipsbank-web          web-7c8ddb8fc5-bjm9z                                       1/1     Running     0             30s
```

#### helm upgrade (zero downtime)

```
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank  --version 1.0.1 -f helm/tipsbank/values-vagrant-dev.yaml
Pulled: registry-1.docker.io/romulow22/tipsbank:1.0.1
Digest: sha256:f81ff8f73de9178d65aa905025af1c9340c8e57de0cc007639ce8bf090634284
Release "tipsbank" has been upgraded. Happy Helming!
NAME: tipsbank
LAST DEPLOYED: Wed May 20 00:02:38 2026
NAMESPACE: default
STATUS: deployed
REVISION: 2
TEST SUITE: None
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> kubectl rollout status deployment/api-transacoes -n tipsbank-transacoes
deployment "api-transacoes" successfully rolled out
```

#### helm rollback

```
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> helm rollback tipsbank            
Rollback was a success! Happy Helming!
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> helm history tipsbank            
REVISION        UPDATED                         STATUS          CHART           APP VERSION     DESCRIPTION     
1               Wed May 20 00:01:37 2026        superseded      tipsbank-1.0.1  1.0.0           Install complete
2               Wed May 20 00:02:38 2026        superseded      tipsbank-1.0.1  1.0.0           Upgrade complete
3               Wed May 20 00:03:08 2026        deployed        tipsbank-1.0.1  1.0.0           Rollback to 1   
```

#### Repositório remoto

Chart publicado em: https://hub.docker.com/r/romulow22/tipsbank/tags

```
PS H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4> helm show chart oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.1
Pulled: registry-1.docker.io/romulow22/tipsbank:1.0.1
Digest: sha256:f81ff8f73de9178d65aa905025af1c9340c8e57de0cc007639ce8bf090634284
apiVersion: v2
appVersion: 1.0.0
description: TipsBank — banco digital completo em Kubernetes (Helm umbrella chart)
keywords:
- tipsbank
- banking
- kubernetes
- linuxtips
maintainers:
- email: romuloww@gmail.com
  name: Romulo Alves
name: tipsbank
type: application
version: 1.0.1
```

---

### Etapa 4.6 — Teste de compliance final

**Objetivo**: checklist de compliance simulando auditoria do BACEN. Todos os 7 comandos devem retornar limpo.

#### 1. Nenhuma imagem fora do registry confiável

O escopo da auditoria são os namespaces `tipsbank-*`. Os pods de `kube-system` (ECR AWS) e `monitoring` (quay.io/prometheus) são gerenciados por AWS/Helm e excluídos do scope do Kyverno por design.

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
    | grep '^tipsbank-' \
    | grep -v 'romulow22\|quay.io/jetstack\|registry.k8s.io\|gcr.io/distroless\|docker.io/library/postgres\|postgres:\|busybox:\|ghcr.io'

$ 
```

Imagens verificadas nos namespaces tipsbank-* (EKS):
```
tipsbank-contas/api-contas-*          romulow22/tipsbank-api-contas:v1.0.0
tipsbank-contas/postgres-0            postgres:16-alpine        ← autorizado (policy: postgres:*)
tipsbank-contas/postgres-0            busybox:1.36              ← autorizado (policy: busybox:*)
tipsbank-transacoes/api-transacoes-*  romulow22/tipsbank-api-transacoes:v1.1.0
tipsbank-transacoes/api-transacoes-v2 romulow22/tipsbank-api-transacoes:v1.1.0
tipsbank-auditoria/auditoria-*        romulow22/tipsbank-auditoria:v1.0.0
tipsbank-web/web-*                    romulow22/tipsbank-web:v1.0.0
```

#### 2. Nenhum pod rodando como root

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl get pods -A -o json | jq '[
    .items[]
    | select(.metadata.namespace | startswith("tipsbank"))
    | select(
        (.spec.securityContext.runAsUser == 0)
        or (.spec.containers[] | .securityContext.runAsUser == 0)
      )
    | .metadata.name
  ]'
[]

```

Resultado vazio: nenhum pod TipsBank define `runAsUser: 0`. Kyverno `disallow-root-user` bloqueia na admissão (Etapa 4.1); `mutate-security-context` injeta `runAsNonRoot: true` (Etapa 4.2). Pods de sistema (`kube-system`, `monitoring`, `cert-manager`) precisam de root por design e estão fora do escopo da política.

#### 3. Cobertura de probes

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl get deploy,sts -A -o json | jq '[
    .items[]
    | select(.metadata.namespace | startswith("tipsbank"))
    | select(.spec.template.spec.containers[0].livenessProbe == null)
    | .metadata.name
  ]'
[]
```

Resultado vazio: todos os containers principais (`api-contas`, `api-transacoes`, `auditoria`, `web`, `postgres`) têm `livenessProbe` + `readinessProbe` + `startupProbe` definidos. O sidecar `log-forwarder` (container[1] em `api-transacoes`) é um `tail -f` de log — probe não se aplica.

#### 4. Cobertura de resources

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl get deploy,sts -A -o json | jq '[
    .items[]
    | select(.metadata.namespace | startswith("tipsbank"))
    | select(.spec.template.spec.containers[0].resources.limits == null)
    | .metadata.name
  ]'
[]
```

Resultado vazio: todos os containers principais têm `resources.requests` e `resources.limits` definidos nos manifests e nos values Helm.

#### 5. Policies Kyverno ativas

```
$ kubectl get cpol -o json | jq '.items[] | {
    name: .metadata.name,
    ready: (.status.conditions // [] | map(select(.type == "Ready")) | first | .status // "Unknown")
  }'
{
  "name": "disallow-latest-tag",
  "ready": "True"
}
{
  "name": "disallow-root-user",
  "ready": "True"
}
{
  "name": "disallow-untrusted-registries",
  "ready": "True"
}
{
  "name": "generate-default-deny-netpol",
  "ready": "True"
}
{
  "name": "mutate-security-context",
  "ready": "True"
}
{
  "name": "require-labels",
  "ready": "True"
}
```

#### 6. NetworkPolicies aplicadas nos namespaces tipsbank-*

```
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl get netpol -n tipsbank-contas
NAME                       POD-SELECTOR     AGE
allow-dns-egress           <none>           61m
allow-egress-postgres      app=api-contas   61m
allow-from-transacoes      app=api-contas   61m
allow-from-web             app=api-contas   61m
allow-ingress-controller   app=api-contas   61m
allow-postgres-ingress     app=postgres     61m
allow-prometheus-scrape    app=api-contas   61m
default-deny               <none>           61m

romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl get netpol -n tipsbank-transacoes
NAME                        POD-SELECTOR         AGE
allow-dns-egress            <none>               61m
allow-egress-to-auditoria   app=api-transacoes   61m
allow-egress-to-contas      app=api-transacoes   61m
allow-from-web              app=api-transacoes   61m
allow-ingress-controller    app=api-transacoes   61m
allow-prometheus-scrape     app=api-transacoes   61m
default-deny                <none>               61m

romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl get netpol -n tipsbank-auditoria
NAME                            POD-SELECTOR    AGE
allow-dns-egress                <none>          61m
allow-egress-nfs                app=auditoria   61m
allow-from-web-and-transacoes   app=auditoria   61m
allow-ingress-controller        app=auditoria   61m
allow-prometheus-scrape         app=auditoria   61m
default-deny                    <none>          61m

```

#### 7. Imagens assinadas (Cosign)

**Pendente**: as imagens publicadas no Docker Hub não foram assinadas com Cosign (o `scripts/build-e-assinar.sh` é um guia didático com registry placeholder, não foi executado para as imagens em produção).

```
$ for img in romulow22/tipsbank-api-contas:v1.0.0 romulow22/tipsbank-api-transacoes:v2.0.0 romulow22/tipsbank-auditoria:v1.0.0; do     COSIGN_EXPERIMENTAL=1 cosign verify $img         --certificate-identity-regexp '.*'         --certificate-oidc-issuer-regexp '.*' > /dev/null && echo "OK: $img";   done

Verification for index.docker.io/romulow22/tipsbank-api-contas:v1.0.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
OK: romulow22/tipsbank-api-contas:v1.0.0

Verification for index.docker.io/romulow22/tipsbank-api-transacoes:v2.0.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
OK: romulow22/tipsbank-api-transacoes:v2.0.0

Verification for index.docker.io/romulow22/tipsbank-auditoria:v1.0.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
OK: romulow22/tipsbank-auditoria:v1.0.0
```

#### 3 tentativas de manifest ruim bloqueadas pelo Kyverno

As 3 rejeições foram capturadas na Etapa 4.1 (outputs completos lá). Resumo:

```
# 1. Pod com runAsUser: 0
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl run ruim-root --image=busybox:1.36 --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' -- sleep 60
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/ruim-root was blocked due to the following policies 

disallow-root-user:
  check-pod-security-context: 'validation error: runAsUser: 0 (root) não é permitido.
    Use UID > 0. rule check-pod-security-context failed at path /spec/securityContext/runAsUser/'

# 2. Pod com imagem :latest
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$  kubectl run ruim-latest --image=nginx:latest
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/ruim-latest was blocked due to the following policies 

disallow-latest-tag:
  check-image-tag: 'validation error: Tag '':latest'' proibida. Use tag explícita
    (ex: v1.0.0, 16-alpine). rule check-image-tag failed at path /spec/containers/0/image/'

# 3. Deployment sem labels obrigatórios (apenas 'app', faltam 'team' e 'env')
romul@HOME MINGW64 /h/Cursos/linuxtips/linuxtips-workspace/projetos/desafio-final-dk8s/semana-4 (main)
$ kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sem-labels
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sem-labels
  template:
    metadata:
      labels:
        app: sem-labels
    spec:
      containers:
        - name: sem-labels
          image: busybox:1.36
          command: ["sleep", "60"]
EOF
Error from server: error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Deployment/default/sem-labels was blocked due to the following policies 

require-labels:
  check-required-labels: 'validation error: Labels obrigatórios ausentes: ''app'',
    ''team'' e ''env'' devem estar presentes em metadata.labels. rule check-required-labels
    failed at path /metadata/labels/'
```

#### Nota sobre o `web` (nginx-unprivileged)

O serviço `web` utiliza `nginx-unprivileged` (Alpine, UID 101) — é **nonroot e minimal**, mas não é "Distroless" no sentido técnico estrito (possui shell Alpine). O critério "100% Distroless" aplica-se às 3 APIs Python; o `web` é a alternativa didática nonroot/minimal. Todos os demais critérios (sem root, sem `:latest`, resources definidos, probes configuradas) aplicam-se integralmente ao `web`.

---

### Etapa 4.7 — Vídeo demo final

**Objetivo**: vídeo de 10-15 minutos mostrando o desafio concluído.

**Link do vídeo**: <!-- adicionar link aqui -->

---

---

#### Roteiro de subida do cluster do zero — Vagrant e EKS

> Sequência completa: **criar cluster → instalar addons → deploy do Helm chart**.
> Execute sempre a partir da raiz do projeto: `cd H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4`.

**Addons instalados pelo `install-addons.ps1`** (em ambos os ambientes):
`kyverno` · `ingress-nginx` · `cert-manager` (+ `ClusterIssuer`) · `nfs-provisioner` (StorageClass `nfs-ganesha`) · `kube-prometheus-stack`.
No **EKS** ainda são aplicados dois passos extras: `gp2` como StorageClass default e a espera pelo hostname do **NLB**.

---

##### Vagrant (local, kubeadm) — do zero

```powershell
# 1. (opcional) ajustar recursos/quantidade de nós em scripts\.env-vagrant
.\scripts\cluster.ps1 vagrant config        # confere NODE_COUNT, RAM, CPUs

# 2. Subir o cluster (cria as VMs e valida a saúde)
#    'create' faz: vagrant up → aguarda nodes/pods Ready → valida via kubectl
#    externo (Test-ClusterHealth; faz o merge do context kubeadm-local se ainda
#    não existir). NÃO instala addons nem faz deploy do chart.
.\scripts\cluster.ps1 vagrant create

# 3. Garantir contexto local ativo
.\scripts\cluster.ps1 vagrant kubeconfig -Merge
kubectl config use-context kubeadm-local
kubectl get nodes                            # controlplane + nodeN todos Ready

# 4. Instalar os addons (kyverno, ingress-nginx, cert-manager, nfs-provisioner, kube-prometheus-stack)
.\scripts\cluster.ps1 vagrant addons

# 5. Mapear os hosts de ingress no hosts file do Windows
#    (C:\Windows\System32\drivers\etc\hosts — editar como Administrador).
#    O ingress-nginx no Vagrant é NodePort 30080/30443, então acesse com :30080.
192.168.10.100 app.tipsbank.local api.tipsbank.local locust.tipsbank.local grafana.tipsbank.local prometheus.tipsbank.local alertmanager.tipsbank.local

# 6. Deploy do Helm chart TipsBank (a partir do OCI registry)
helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.4 -f helm/tipsbank/values-vagrant-prod.yaml --wait --timeout 10m

# 7. Verificar (revalida o cluster + checa pods)
.\scripts\cluster.ps1 vagrant validate
kubectl get all -A
helm list -A
```

> `vagrant validate` roda 100% via `kubectl` externo (sem SSH no control-plane) e cria/atualiza o context `kubeadm-local` automaticamente se faltar — pode ser reexecutado a qualquer momento.

---

##### EKS (AWS) — do zero

```powershell
# 1. Carregar credenciais AWS e confirmar a conta
.\scripts\.env-aws.ps1                       # AWS_ACCESS_KEY_ID / SECRET / REGION
aws sts get-caller-identity

# 2. Criar o cluster (15-20 min) — 'create' valida a saúde ao final, mas NÃO instala addons no EKS
.\scripts\cluster.ps1 eks create
kubectl config use-context eks-tipsbank
kubectl get nodes                            # todos Ready

# 3. Instalar os addons (inclui gp2 default + espera o NLB ficar pronto)
.\scripts\cluster.ps1 eks addons

# 3.1 (opcional) revalidar a saúde do cluster a qualquer momento
.\scripts\cluster.ps1 eks validate

# 4. Capturar o FQDN do NLB (host do ingress)
$nlb = kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
$nlb                                         # não pode estar vazio

# 5. Deploy do Helm chart (appHost/apiHost = NLB → routing por path)
helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.4 -f helm/tipsbank/values-eks-prod.yaml --set ingress.appHost=$nlb --set ingress.apiHost=$nlb --wait --timeout 10m

# 6. Verificar
helm list -A
kubectl get all -A
```

> **Custo**: ao terminar, `.\scripts\cluster.ps1 eks destroy` para não acumular cobrança.

---

#### Pré-gravação — subir o cluster antes de gravar

> Execute este roteiro **antes** de abrir o gravador de tela. Tempo estimado: **~15 min** (Vagrant) ou **~25 min** (EKS cold start).

---

##### Opção A — Vagrant (local, kubeadm)

```powershell
# 1. Entrar no diretório raiz do projeto
cd H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4

# 2. Subir as VMs (cria se não existirem, retoma se já existirem)
.\scripts\cluster.ps1 vagrant restart    # cluster já existe → reinicia e aguarda Ready
# ou:
.\scripts\cluster.ps1 vagrant create     # cluster novo → vagrant up + validação (addons no passo 5)

# 3. Obter kubeconfig e apontar o contexto local
.\scripts\cluster.ps1 vagrant kubeconfig -Merge
kubectl config use-context kubeadm-local

# 4. Confirmar que todos os nós estão Ready
kubectl get nodes
# Esperado: controlplane + node1 + node2 + node3 todos Ready

# 5. Confirmar que os addons estão Running (ingress-nginx, cert-manager, kyverno, nfs-provisioner)
kubectl get pods -n ingress-nginx -n cert-manager -n kyverno -n nfs-provisioner
# Se algum addon estiver faltando, instalar:
.\scripts\install-addons.ps1 -Env vagrant

# 6. Remover release anterior (garante demo de "cluster limpo" no Ponto 1)
helm uninstall tipsbank --ignore-not-found

# 7. Sanity check final antes de gravar
kubectl get pods -A | grep -v "Running\|Completed"
# Nenhuma linha = cluster 100% saudável
```

> **Dica**: se um nó aparecer `NotReady`, rode `kubectl rollout restart daemonset calico-node -n kube-system` e aguarde ~2 min (token CNI expirado — problema comum após suspender a VM).

---

##### Troubleshooting — `vagrant up` falha com "SSH connection unexpectedly closed by the remote end"

**Sintoma**: durante o provisionamento (tipicamente no `[TASK 5] Kubernetes`, baixando os
pacotes), o `vagrant up` aborta com:

```
The SSH connection was unexpectedly closed by the remote end. This
usually indicates that SSH within the guest machine was unable to
properly start up.
ERROR: Vagrant up command failed.
```

**Causa raiz**: host Windows com **Hyper-V / VBS (Virtualization-Based Security) ativos**
(obrigatório se você usa WSL2 / Docker Desktop). Nesse modo o VirtualBox roda em
coexistência com o hypervisor do Windows e o **TSC do guest fica instável** — a VM
**congela por dezenas de segundos** e o SSH do provisionamento cai. Confirmação dentro
da VM:

```bash
sudo dmesg | grep -iE 'rcu|stall|clocksource'
# rcu: rcu_sched kthread starved for 61063 jiffies!
# rcu: Unless rcu_sched kthread gets sufficient CPU time, OOM is now expected behavior.
# clocksource: Long readout interval ... cs_nsec: 244706922597   ← relógio pulou ~244s
```

> ℹ️ A queda **não corrompe** a instalação — `kubelet/kubeadm/kubectl` geralmente já
> ficaram instalados. As VMs continuam `running`; basta retomar.

**Remediação (já aplicada nos scripts)** — não exige desligar o Hyper-V:

- `Vagrantfile`: `--paravirtprovider kvm` expõe o relógio paravirtualizado `kvm-clock`.
- `scripts/requirements.sh` (`[TASK 0]`): fixa o guest em `kvm-clock` em runtime e
  persiste `clocksource=kvm-clock` no GRUB.

**Verificar o clocksource em uso** (deve ser `kvm-clock`, não `tsc`):

```powershell
vagrant ssh control-plane -c "cat /sys/devices/system/clocksource/clocksource0/current_clocksource"
```

**Aplicar em VMs já criadas sem reprovisionar** (corrige o cluster atual na hora):

```powershell
foreach ($vm in 'control-plane','node_1','node_2','node_3') {
  vagrant ssh $vm -c "echo kvm-clock | sudo tee /sys/devices/system/clocksource/clocksource0/current_clocksource"
}
```

**Retomar / refazer o provisionamento**:

```powershell
vagrant up --provision      # retoma node_1 e cria node_2/node_3
# se preferir partir limpo:
vagrant destroy -f; vagrant up
```

**Mitigações adicionais no host** (se ainda ocorrer freeze):

- Plano de energia **Alto desempenho** e desabilitar suspensão automática durante o `up`.
- Excluir a pasta das VMs do VirtualBox da verificação em tempo real do Defender
  (I/O do antivírus durante o `apt` pode travar a VM).
- Manter VirtualBox atualizado (≥ 7.x tem suporte melhor à coexistência com Hyper-V).

---

##### Opção B — EKS (AWS)

```powershell
# 1. Entrar no diretório raiz do projeto
cd H:\Cursos\linuxtips\linuxtips-workspace\projetos\desafio-final-dk8s\semana-4

# 2. Carregar credenciais AWS e verificar acesso
.\scripts\.env-aws.ps1            # carrega AWS_ACCESS_KEY_ID / SECRET / REGION
aws sts get-caller-identity       # confirmar conta ativa

# 3a. Cluster já existe → apenas buscar kubeconfig e verificar
.\scripts\cluster.ps1 eks kubeconfig -Merge
kubectl config use-context eks-tipsbank
kubectl get nodes                 # todos Ready

# 3b. Cluster novo → criar (15-20 min). 'create' valida a saúde ao final, mas NÃO instala addons.
.\scripts\cluster.ps1 eks create
.\scripts\cluster.ps1 eks addons         # instala os addons (gp2 default + ingress/cert-manager/kyverno/nfs/monitoring)

# 4. Verificar NLB disponível (necessário para ingress)
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Deve retornar o FQDN do NLB (não vazio)

# 5. Remover release anterior (garante demo de "cluster limpo" no Ponto 1)
helm uninstall tipsbank --ignore-not-found

# 6. Sanity check final antes de gravar
kubectl get pods -A | grep -v "Running\|Completed"
# Nenhuma linha = cluster 100% saudável
```

> **Custo**: lembre de rodar `.\scripts\cluster.ps1 eks destroy` após a gravação para evitar cobranças.

---

##### Checklist final (ambos os ambientes)

| # | Verificação | Comando rápido |
|---|---|---|
| ✅ | Contexto kubectl correto | `kubectl config current-context` |
| ✅ | Todos os nós Ready | `kubectl get nodes` |
| ✅ | ingress-nginx Running | `kubectl get pods -n ingress-nginx` |
| ✅ | cert-manager Running | `kubectl get pods -n cert-manager` |
| ✅ | Kyverno Running (4 pods) | `kubectl get pods -n kyverno` |
| ✅ | Sem release Helm anterior | `helm list -A` |
| ✅ | Cluster validado (saúde) | `.\scripts\cluster.ps1 vagrant validate` ou `.\scripts\cluster.ps1 eks validate` |
| ✅ | kubeconfigs RBAC gerados | `.\scripts\cluster.ps1 vagrant certs` ou `.\scripts\cluster.ps1 eks certs` |

---

#### Roteiro de gravação — comandos exatos (Vagrant cluster)

> **Pré-requisito**: cluster Vagrant rodando com addons instalados (`.\scripts\install-addons.ps1 -Env vagrant`). Release Helm anterior removida.

---

##### Ponto 1 — `helm install` num cluster limpo

```powershell
# Confirmar que não há release anterior
helm list -A

# Instalar a partir do OCI registry (cluster limpo)
#Vagrant
helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.4 -f helm/tipsbank/values-vagrant-prod.yaml --wait --timeout 10m
#EKS
helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.4 -f helm/tipsbank/values-eks-prod.yaml --set ingress.appHost='[colocar id do ELB].elb.us-east-2.amazonaws.com' --set ingress.apiHost='[colocar id do ELB].elb.us-east-2.amazonaws.com' --wait --timeout 10m
```

---

##### Ponto 2 — Todos os pods subindo

```bash
kubectl get pods -A --watch
# Aguardar todos ficarem 1/1 Running. Ctrl+C quando estabilizar.

# Snapshot final
kubectl get pods -A | grep tipsbank
```

---

##### Ponto 3 — Grafana com métricas reais



```
# Abrir no browser:
Vagrant: https://grafana.tipsbank.local:30443
EKS: https://[colocar id do ELB].elb.us-east-2.amazonaws.com/grafana

# Login: admin / prom-operator

# Mostrar: Dashboards → TipsBank SLO  (ou "Kubernetes / Workloads")
# Mostrar: Status → Targets  (todos UP)
```




---

##### Ponto 4 — Transferência funcionando

```bash
#Vagrant
BASE="https://api.tipsbank.local:30443"
#EKS:
BASE="https://[colocar id do ELB].elb.us-east-2.amazonaws.com"



# Criar conta A (origem)
CONTA_A=$(curl -sk -X POST $BASE/contas/contas \
  -H "Content-Type: application/json" \
  -d '{"titular":"Alice Demo","documento":"11111111111","senha":"demo1234","saldo_inicial":1000}' \
  | jq -r .id)
echo "Conta A: $CONTA_A"

# Criar conta B (destino)
$(curl -sk -X POST $BASE/contas/contas \
  -H "Content-Type: application/json" \
  -d '{"titular":"Bob Demo","documento":"22222222222","senha":"demo1234","saldo_inicial":0}' \
  | jq -r .id)
echo "Conta B: $CONTA_B"

# Fazer transferência de R$ 250
curl -sk -X POST $BASE/transacoes/transferencias \
  -H "Content-Type: application/json" \
  -d "{\"origem_id\":\"$CONTA_A\",\"destino_id\":\"$CONTA_B\",\"valor\":250}" | jq .

# Confirmar saldo atualizado
curl -sk $BASE/contas/contas/$CONTA_B | jq .
```

---

##### Ponto 5 — Locust gerando carga + HPA escalando

```bash
# Abrir Locust no browser:
# Vagrant: http://locust.tipsbank.local:30080
#EKS: https://[colocar id do ELB].elb.us-east-2.amazonaws.com/locust/
# Configurar: Users=50, Spawn rate=5, Host=http://api-transacoes.tipsbank-transacoes.svc.cluster.local:8080
# Clicar Start e aguardar carga estabilizar

# Em outro terminal — mostrar HPA respondendo
kubectl get hpa -A --watch
# Esperado: TARGETS > threshold → REPLICAS sobe automaticamente
```

---

##### Ponto 6 — Pod ruim bloqueado pelo Kyverno

```bash
# Teste 1: imagem :latest
kubectl run pod-ruim-latest --image=nginx:latest -n tipsbank-contas
# Error: disallow-latest-tag

# Teste 2: root user
kubectl run pod-ruim-root --image=busybox:1.36 \
  --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' \
  -n tipsbank-contas -- sleep 60
# Error: disallow-root-user
```

---

##### Ponto 7 — Canary v1/v2 (split 90/10)

```bash
# Mostrar os dois deployments rodando
kubectl get deploy -n tipsbank-transacoes

# Mostrar a annotation de peso no ingress canary
kubectl get ingress ingress-api-transacoes-canary -n tipsbank-transacoes \
  -o jsonpath='{.metadata.annotations}' | jq .

# Demonstrar o split — executar 20 vezes e contar versões

#Vagrant: URL='https://api.tipsbank.local:30443/transacoes/health/live'
#EKS :    URL='https://[colocar id do ELB].elb.us-east-2.amazonaws.com/transacoes/health/live'

for i in $(seq 1 20); do
  curl -sk $URL | jq -r .version
done | sort | uniq -c

# Forçar rota para v2 via header
curl -sk $URL \
  -H "X-Canary: true" | jq .

```

---

##### Ponto 8 — RBAC: usuário tentando ação não autorizada

```powershell
# Executar o Script para criação dos certificados e kubeconfigs para os perfis operador-contas, operador-transacoes, auditor-global e SRE.
.\scripts\gerar-certificados.ps1 
```

```bash
# operador-contas: acesso permitido no namespace correto
kubectl --kubeconfig=evidencias/kubeconfigs/operador-contas.kubeconfig get pods -n tipsbank-contas

# operador-contas: BLOQUEADO em outro namespace
kubectl --kubeconfig=evidencias/kubeconfigs/operador-contas.kubeconfig get pods -n tipsbank-transacoes

# auditor-global: pode listar pods em todos os namespaces
kubectl --kubeconfig=evidencias/kubeconfigs/auditor-global.kubeconfig get pods -A | grep tipsbank

# auditor-global: BLOQUEADO para deletar (readonly)
kubectl --kubeconfig=evidencias/kubeconfigs/auditor-global.kubeconfig delete pod postgres-0 -n tipsbank-contas
```

---

##### Ponto 9 — Rollback de um deploy

```bash
# Ver histórico atual
helm history tipsbank

# Fazer upgrade simulando uma mudança (ex: aumentar réplicas de contas)

#Vagrant
helm upgrade tipsbank oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.4 -f helm/tipsbank/values-vagrant-prod.yaml --set contas.replicas=3

#EKS
helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.4 -f helm/tipsbank/values-eks-prod.yaml --set ingress.appHost='[colocar id do ELB].elb.us-east-2.amazonaws.com' --set ingress.apiHost='[colocar id do ELB].elb.us-east-2.amazonaws.com' --set contas.replicas=4 --wait --timeout 10m

helm upgrade --install tipsbank oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.4 -f helm/tipsbank/values-eks-prod.yaml --set ingress.appHost='a8f8ea2c9dad9441a8802cdd994e1392-9a0f129db8f26526.elb.us-east-2.amazonaws.com' --set ingress.apiHost='a8f8ea2c9dad9441a8802cdd994e1392-9a0f129db8f26526.elb.us-east-2.amazonaws.com' --set contas.replicas=4 --wait --timeout 10m

# Ver rollout
kubectl rollout status deployment/api-contas -n tipsbank-contas

# Rollback para revisão anterior
helm rollback tipsbank 2

# Confirmar histórico
helm history tipsbank
```

---

##### Ponto 10 — Encerramento com `helm uninstall`

```bash
helm uninstall tipsbank

# Confirmar que os pods foram removidos
kubectl get pods -A | grep tipsbank
# (sem output)

# Namespaces também removidos
kubectl get ns | grep tipsbank
```


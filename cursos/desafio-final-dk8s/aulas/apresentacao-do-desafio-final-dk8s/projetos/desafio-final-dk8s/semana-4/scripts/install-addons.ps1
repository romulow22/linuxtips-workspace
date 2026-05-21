# install-addons.ps1 -- Instala addons Helm do TipsBank.
#
# Auto-detecta o ambiente a partir do providerID do primeiro node:
#   aws://... -> eks
#   (vazio)   -> vagrant / kubeadm
#
# Execute a partir da raiz do projeto (semana-2/):
#   .\scripts\install-addons.ps1
#
# Ou force o ambiente:
#   .\scripts\install-addons.ps1 -Env eks
#   .\scripts\install-addons.ps1 -Env vagrant
#
# Apos instalar em EKS, o hostname do NLB fica disponivel em:
#   $env:TIPSBANK_NLB

param(
    [ValidateSet("eks", "vagrant", "auto")]
    [string]$Env = "auto"
)

$ErrorActionPreference = "Stop"
$ROOT    = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$HELMDIR = "$ROOT\helm"

$EKS_CONTEXT   = "eks-tipsbank"
$LOCAL_CONTEXT = "kubeadm-local"

# Detectar ambiente
if ($Env -eq "auto") {
    $providerID = kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>$null
    $Env = if ($providerID -match "^aws://") { "eks" } else { "vagrant" }
}

# Garantir context correto antes de qualquer kubectl/helm
$targetContext = if ($Env -eq "eks") { $EKS_CONTEXT } else { $LOCAL_CONTEXT }
kubectl config use-context $targetContext | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Contexto '$targetContext' nao encontrado. Execute kubeconfig primeiro." }
Write-Host "Context: $targetContext" -ForegroundColor DarkGray

Write-Host "================================================" -ForegroundColor Cyan
Write-Host " TipsBank -- Helm addons  [env: $Env]" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# RecoverHelm: desfaz operacoes Helm travadas (pending-install/upgrade/rollback)
# antes de cada helm upgrade --install, evitando "another operation is in progress".
function RecoverHelm([string]$release, [string]$namespace) {
    # 2>$null on native commands in PS5.1 generates NativeCommandError when the command fails.
    # Wrapping everything in try/catch handles both "release not found" and stuck states.
    try {
        $json = helm status $release -n $namespace -o json 2>$null
        if (-not $json) { return }
        $st = ($json | ConvertFrom-Json).info.status
        if ($st -match "^pending-") {
            Write-Host "  '$release' preso em '$st'. Recuperando..." -ForegroundColor Yellow
            helm rollback $release 0 -n $namespace --wait 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Rollback falhou. Deletando release e recriando..." -ForegroundColor Yellow
                helm delete $release -n $namespace 2>$null | Out-Null
            }
        }
    } catch {}
}

# Repos
helm repo add ingress-nginx        https://kubernetes.github.io/ingress-nginx 2>$null
helm repo add jetstack             https://charts.jetstack.io                2>$null
helm repo add nfs-ganesha          https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ 2>$null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>$null
helm repo add kyverno              https://kyverno.github.io/kyverno/ 2>$null
helm repo update | Out-Null
Write-Host ""

# [0/5] gp2 como default StorageClass (EKS only)
if ($Env -eq "eks") {
    Write-Host "[0/5] Definindo gp2 como default StorageClass..." -ForegroundColor Cyan
    kubectl patch storageclass gp2 `
        -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'
    if ($LASTEXITCODE -ne 0) { Write-Warning "Nao foi possivel patchear gp2 (pode ja ser default)." }
    Write-Host "  gp2 = default StorageClass" -ForegroundColor Green
    Write-Host ""
}

# [1/6] Kyverno
Write-Host "[1/6] Kyverno..." -ForegroundColor Cyan
RecoverHelm "kyverno" "kyverno"
helm upgrade --install kyverno kyverno/kyverno `
    --namespace kyverno `
    --create-namespace `
    --set replicaCount=1 `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "kyverno falhou" }
Write-Host "  Kyverno OK" -ForegroundColor Green
Write-Host ""

# [2/6] Ingress Nginx
Write-Host "[2/6] Ingress Nginx ($Env)..." -ForegroundColor Cyan
$ingressValues = "$HELMDIR\ingress-nginx\values-$Env.yaml"
RecoverHelm "ingress-nginx" "ingress-nginx"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
    --namespace ingress-nginx `
    --create-namespace `
    --values $ingressValues `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "ingress-nginx falhou" }
Write-Host "  ingress-nginx OK" -ForegroundColor Green
Write-Host ""

# [3/6] cert-manager + ClusterIssuer
Write-Host "[3/6] cert-manager..." -ForegroundColor Cyan
RecoverHelm "cert-manager" "cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager `
    --namespace cert-manager `
    --create-namespace `
    --values "$HELMDIR\cert-manager\values-common.yaml" `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "cert-manager falhou" }

kubectl wait --for=condition=available deployment/cert-manager `
    -n cert-manager --timeout=120s 2>$null
kubectl wait --for=condition=available deployment/cert-manager-webhook `
    -n cert-manager --timeout=120s 2>$null

kubectl apply -f "$HELMDIR\cluster-issuer.yaml"
if ($LASTEXITCODE -ne 0) { throw "ClusterIssuer falhou" }
Write-Host "  cert-manager + ClusterIssuer OK" -ForegroundColor Green
Write-Host ""

# [4/6] NFS Ganesha provisioner
Write-Host "[4/6] NFS Ganesha provisioner ($Env)..." -ForegroundColor Cyan
$nfsValues = "$HELMDIR\nfs-provisioner\values-$Env.yaml"
RecoverHelm "nfs-provisioner" "nfs-provisioner"
helm upgrade --install nfs-provisioner nfs-ganesha/nfs-server-provisioner `
    --namespace nfs-provisioner `
    --create-namespace `
    --values $nfsValues `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "nfs-provisioner falhou" }
Write-Host "  nfs-provisioner OK  (StorageClass: nfs-ganesha)" -ForegroundColor Green
Write-Host ""

# [5/6] NLB hostname (EKS only) -- aguarda antes do kube-prometheus para injetar o hostname
$nlbHostname = ""
if ($Env -eq "eks") {
    Write-Host "[4/5] Aguardando hostname do NLB..." -ForegroundColor Cyan
    for ($i = 1; $i -le 36; $i++) {
        $nlbHostname = kubectl get svc ingress-nginx-controller -n ingress-nginx `
                           -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
        if ($nlbHostname) { break }
        Write-Host ("  . {0}s" -f ($i * 10)) -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
    if (-not $nlbHostname) { throw "NLB hostname nao disponivel apos 6min." }
    $env:TIPSBANK_NLB = $nlbHostname
    Write-Host "  NLB: $nlbHostname" -ForegroundColor Green
    Write-Host ""
}

# [6/6] kube-prometheus-stack + ServiceMonitors + PrometheusRule
# Separação de namespaces:
#   monitoring          → stack (Prometheus, Grafana, Alertmanager)
#   tipsbank-monitoring → configs da aplicação (ServiceMonitors, PrometheusRules)
Write-Host "[6/6] kube-prometheus-stack..." -ForegroundColor Cyan
kubectl apply -f "$ROOT\k8s\monitoring\namespace.yaml" | Out-Null
kubectl apply -f "$ROOT\k8s\tipsbank-monitoring\namespace.yaml" | Out-Null

$helmMonArgs = @(
    "upgrade", "--install", "kube-prometheus-stack",
    "prometheus-community/kube-prometheus-stack",
    "--namespace", "monitoring",
    "--values", "$HELMDIR\kube-prometheus\values-common.yaml",
    "--values", "$HELMDIR\kube-prometheus\values-$Env.yaml",
    "--wait", "--timeout", "10m"
)
if ($Env -eq "eks") {
    $helmMonArgs += "--set", "grafana.ingress.hosts[0]=$nlbHostname"
    $helmMonArgs += "--set", "prometheus.ingress.hosts[0]=$nlbHostname"
    $helmMonArgs += "--set", "alertmanager.ingress.hosts[0]=$nlbHostname"
    $helmMonArgs += "--set", "grafana.env.GF_SERVER_ROOT_URL=http://$nlbHostname/grafana"
}
RecoverHelm "kube-prometheus-stack" "monitoring"
& helm @helmMonArgs
if ($LASTEXITCODE -ne 0) { throw "kube-prometheus-stack falhou" }

# ServiceMonitors e PrometheusRule são gerenciados pelo Helm chart 'tipsbank'.
# Aplicar via kubectl aqui causaria conflito de ownership.
# Execute: helm install tipsbank oci://registry-1.docker.io/romulow22/tipsbank --version 1.0.1 -f helm/tipsbank/values-vagrant-dev.yaml
Write-Host "  kube-prometheus-stack OK" -ForegroundColor Green
if ($Env -eq "eks") {
    Write-Host "  Grafana:      http://$nlbHostname/grafana" -ForegroundColor DarkGray
    Write-Host "  Prometheus:   http://$nlbHostname/prometheus" -ForegroundColor DarkGray
    Write-Host "  Alertmanager: http://$nlbHostname/alertmanager" -ForegroundColor DarkGray
} else {
    Write-Host "  Grafana:      http://grafana.tipsbank.local" -ForegroundColor DarkGray
    Write-Host "  Prometheus:   http://prometheus.tipsbank.local" -ForegroundColor DarkGray
    Write-Host "  Alertmanager: http://alertmanager.tipsbank.local" -ForegroundColor DarkGray
}
Write-Host ""

Write-Host "================================================" -ForegroundColor Cyan
Write-Host " Todos os addons instalados (6/6)  [env: $Env]" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

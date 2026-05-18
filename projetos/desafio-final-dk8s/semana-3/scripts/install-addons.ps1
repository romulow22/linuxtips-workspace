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

# Repos
helm repo add ingress-nginx        https://kubernetes.github.io/ingress-nginx 2>$null
helm repo add jetstack             https://charts.jetstack.io                2>$null
helm repo add nfs-ganesha          https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ 2>$null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>$null
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

# [1/5] Ingress Nginx
Write-Host "[1/5] Ingress Nginx ($Env)..." -ForegroundColor Cyan
$ingressValues = "$HELMDIR\ingress-nginx\values-$Env.yaml"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
    --namespace ingress-nginx `
    --create-namespace `
    --values $ingressValues `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "ingress-nginx falhou" }
Write-Host "  ingress-nginx OK" -ForegroundColor Green
Write-Host ""

# [2/5] cert-manager + ClusterIssuer
Write-Host "[2/5] cert-manager..." -ForegroundColor Cyan
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

# [3/5] NFS Ganesha provisioner
Write-Host "[3/5] NFS Ganesha provisioner ($Env)..." -ForegroundColor Cyan
$nfsValues = "$HELMDIR\nfs-provisioner\values-$Env.yaml"
helm upgrade --install nfs-provisioner nfs-ganesha/nfs-server-provisioner `
    --namespace nfs-provisioner `
    --create-namespace `
    --values $nfsValues `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "nfs-provisioner falhou" }
Write-Host "  nfs-provisioner OK  (StorageClass: nfs-ganesha)" -ForegroundColor Green
Write-Host ""

# [4/5] NLB hostname (EKS only) -- aguarda antes do kube-prometheus para injetar o hostname
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

# [5/5] kube-prometheus-stack + ServiceMonitors + PrometheusRule
Write-Host "[5/5] kube-prometheus-stack..." -ForegroundColor Cyan
kubectl apply -f "$ROOT\k8s\tipsbank-monitoring\namespace.yaml" | Out-Null

$helmMonArgs = @(
    "upgrade", "--install", "kube-prometheus-stack",
    "prometheus-community/kube-prometheus-stack",
    "--namespace", "tipsbank-monitoring",
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
& helm @helmMonArgs
if ($LASTEXITCODE -ne 0) { throw "kube-prometheus-stack falhou" }

kubectl apply -f "$ROOT\k8s\tipsbank-monitoring\servicemonitor-contas.yaml"
kubectl apply -f "$ROOT\k8s\tipsbank-monitoring\servicemonitor-transacoes.yaml"
kubectl apply -f "$ROOT\k8s\tipsbank-monitoring\servicemonitor-auditoria.yaml"
kubectl apply -f "$ROOT\k8s\tipsbank-monitoring\prometheusrule.yaml"
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
Write-Host " Todos os addons instalados (5/5)  [env: $Env]" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

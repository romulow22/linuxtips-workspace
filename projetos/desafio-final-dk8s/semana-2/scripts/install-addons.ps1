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
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>$null
helm repo add jetstack       https://charts.jetstack.io                2>$null
helm repo add nfs-ganesha    https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ 2>$null
helm repo update | Out-Null
Write-Host ""

# [0/4] gp2 como default StorageClass (EKS only)
if ($Env -eq "eks") {
    Write-Host "[0/4] Definindo gp2 como default StorageClass..." -ForegroundColor Cyan
    kubectl patch storageclass gp2 `
        -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'
    if ($LASTEXITCODE -ne 0) { Write-Warning "Nao foi possivel patchear gp2 (pode ja ser default)." }
    Write-Host "  gp2 = default StorageClass" -ForegroundColor Green
    Write-Host ""
}

# [1/4] Ingress Nginx
Write-Host "[1/4] Ingress Nginx ($Env)..." -ForegroundColor Cyan
$ingressValues = "$HELMDIR\ingress-nginx\values-$Env.yaml"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
    --namespace ingress-nginx `
    --create-namespace `
    --values $ingressValues `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "ingress-nginx falhou" }
Write-Host "  ingress-nginx OK" -ForegroundColor Green
Write-Host ""

# [2/4] cert-manager + ClusterIssuer
Write-Host "[2/4] cert-manager..." -ForegroundColor Cyan
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

# [3/4] NFS Ganesha provisioner
Write-Host "[3/4] NFS Ganesha provisioner ($Env)..." -ForegroundColor Cyan
$nfsValues = "$HELMDIR\nfs-provisioner\values-$Env.yaml"
helm upgrade --install nfs-provisioner nfs-ganesha/nfs-server-provisioner `
    --namespace nfs-provisioner `
    --create-namespace `
    --values $nfsValues `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "nfs-provisioner falhou" }
Write-Host "  nfs-provisioner OK  (StorageClass: nfs-ganesha)" -ForegroundColor Green
Write-Host ""

# [4/4] NLB hostname (EKS only) -- ingress-nginx + cert-manager + nfs install in parallel with NLB provisioning
if ($Env -eq "eks") {
    Write-Host "[4/4] Aguardando hostname do NLB..." -ForegroundColor Cyan
    $env:TIPSBANK_NLB = ""
    for ($i = 1; $i -le 36; $i++) {
        $nlb = kubectl get svc ingress-nginx-controller -n ingress-nginx `
                   -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
        if ($nlb) { $env:TIPSBANK_NLB = $nlb; break }
        Write-Host ("  . {0}s" -f ($i * 10)) -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
    if (-not $env:TIPSBANK_NLB) { Write-Warning "NLB hostname nao disponivel apos 6min." }
    Write-Host "  NLB: $($env:TIPSBANK_NLB)" -ForegroundColor Green
    Write-Host ""
}

Write-Host "================================================" -ForegroundColor Cyan
Write-Host " Todos os addons instalados  [env: $Env]" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

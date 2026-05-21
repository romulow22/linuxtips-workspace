# deploy-apps.ps1 -- Aplica todos os manifests k8s do TipsBank em ordem correta.
#
# Auto-detecta o ambiente a partir do providerID do primeiro node:
#   aws://... -> eks  (substitui hostnames .local pelo NLB hostname)
#   (vazio)   -> vagrant / kubeadm
#
# Execute a partir da raiz do projeto (semana-2/):
#   .\scripts\deploy-apps.ps1
#
# Ou force o ambiente:
#   .\scripts\deploy-apps.ps1 -Env eks
#   .\scripts\deploy-apps.ps1 -Env vagrant
#
# Pre-requisito: instale os addons antes do primeiro deploy:
#   .\scripts\install-addons.ps1

param(
    [ValidateSet("eks", "vagrant", "auto")]
    [string]$Env = "auto"
)

$ErrorActionPreference = "Stop"
$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$K8S  = "$ROOT\k8s"

$EKS_CONTEXT   = "eks-tipsbank"
$LOCAL_CONTEXT = "kubeadm-local"

# Detectar ambiente
if ($Env -eq "auto") {
    $providerID = kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>$null
    $Env = if ($providerID -match "^aws://") { "eks" } else { "vagrant" }
}

# Garantir context correto antes de qualquer kubectl
$targetContext = if ($Env -eq "eks") { $EKS_CONTEXT } else { $LOCAL_CONTEXT }
kubectl config use-context $targetContext | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Contexto '$targetContext' nao encontrado. Execute kubeconfig primeiro." }
Write-Host "Context: $targetContext" -ForegroundColor DarkGray

# EKS needs more time: EBS volume creation (~30-60s) + attachment + postgres init
$pgTimeout = if ($Env -eq "eks") { "300s" } else { "120s" }

# NLB domain (eks only) -- set by install-addons.ps1 or queried live
$DOMAIN = ""
if ($Env -eq "eks") {
    $DOMAIN = if ($env:TIPSBANK_NLB) { $env:TIPSBANK_NLB } else {
        kubectl get svc ingress-nginx-controller -n ingress-nginx `
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
    }
    if (-not $DOMAIN) {
        throw "NLB hostname nao disponivel. Execute install-addons.ps1 primeiro."
    }
    Write-Host "NLB domain: $DOMAIN" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host " TipsBank -- Deploy  [env: $Env]" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

function Apply([string]$file) {
    Write-Host "  kubectl apply $((Split-Path $file -Leaf))" -ForegroundColor DarkGray
    kubectl apply -f $file
    if ($LASTEXITCODE -ne 0) { throw "Falhou: $file" }
}

function ApplyStatefulSet([string]$file) {
    Write-Host "  kubectl apply (statefulset) $((Split-Path $file -Leaf))" -ForegroundColor DarkGray
    $out = kubectl apply -f $file 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($out -match "Forbidden") {
            Write-Host "  Campo imutavel detectado, recriando StatefulSet..." -ForegroundColor Yellow
            kubectl delete -f $file --ignore-not-found --cascade=foreground
            kubectl apply -f $file
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "Falhou statefulset: $file" }
}

function ApplyIngress([string]$file) {
    Write-Host "  kubectl apply (ingress) $((Split-Path $file -Leaf))" -ForegroundColor DarkGray
    if ($Env -eq "eks") {
        (Get-Content $file -Raw) `
            -replace "app\.tipsbank\.local", $DOMAIN `
            -replace "api\.tipsbank\.local", $DOMAIN `
            -replace "tipsbank-app-tls",     "tipsbank-eks-tls" `
            -replace "tipsbank-api-tls",     "tipsbank-eks-tls" |
        kubectl apply -f -
    } else {
        kubectl apply -f $file
    }
    if ($LASTEXITCODE -ne 0) { throw "Falhou ingress: $file" }
}

# [1/5] Namespaces
Write-Host "[1/5] Namespaces" -ForegroundColor Cyan
Apply "$K8S\00-namespaces.yaml"

# [2/5] tipsbank-contas
Write-Host "`n[2/5] tipsbank-contas" -ForegroundColor Cyan
Apply "$K8S\tipsbank-contas\secret-db.yaml"
Apply "$K8S\tipsbank-contas\configmap-initsql.yaml"
Apply "$K8S\tipsbank-contas\configmap-app.yaml"
Apply "$K8S\tipsbank-contas\postgres-headless-svc.yaml"
ApplyStatefulSet "$K8S\tipsbank-contas\postgres-statefulset.yaml"
Apply "$K8S\tipsbank-contas\api-contas-service.yaml"
Apply "$K8S\tipsbank-contas\api-contas-deployment.yaml"
ApplyIngress "$K8S\tipsbank-contas\ingress-api-contas.yaml"
ApplyIngress "$K8S\tipsbank-contas\ingress-api-contas-admin.yaml"
Apply "$K8S\tipsbank-contas\netpol.yaml"

Write-Host "  Aguardando postgres-0 Ready (max 2min)..." -ForegroundColor Yellow
kubectl wait --for=condition=ready pod/postgres-0 -n tipsbank-contas --timeout=$pgTimeout
if ($LASTEXITCODE -ne 0) { throw "postgres-0 nao ficou Ready em $pgTimeout" }
Write-Host "  postgres OK" -ForegroundColor Green

$sha1     = [System.Security.Cryptography.SHA1]::Create()
$pwBytes  = [System.Text.Encoding]::UTF8.GetBytes("giropops")
$pwHash   = [Convert]::ToBase64String($sha1.ComputeHash($pwBytes))
$htpasswd = "admin:{SHA}$pwHash"
kubectl create secret generic basic-auth-admin `
    --from-literal=auth=$htpasswd -n tipsbank-contas `
    --dry-run=client -o yaml | kubectl apply -f -
Write-Host "  Secret basic-auth-admin OK (user=admin pass=giropops)" -ForegroundColor Green

# [3/5] tipsbank-transacoes
Write-Host "`n[3/5] tipsbank-transacoes" -ForegroundColor Cyan
Apply "$K8S\tipsbank-transacoes\secret-db.yaml"
Apply "$K8S\tipsbank-transacoes\configmap-app.yaml"
Apply "$K8S\tipsbank-transacoes\api-transacoes-service.yaml"
Apply "$K8S\tipsbank-transacoes\api-transacoes-deployment.yaml"
ApplyIngress "$K8S\tipsbank-transacoes\ingress-api-transacoes.yaml"

# Canary v2 (Etapa 2.4)
Apply "$K8S\tipsbank-transacoes\api-transacoes-v2-service.yaml"
Apply "$K8S\tipsbank-transacoes\api-transacoes-v2-deployment.yaml"
ApplyIngress "$K8S\tipsbank-transacoes\ingress-api-transacoes-canary.yaml"
Apply "$K8S\tipsbank-transacoes\netpol.yaml"

# [4/5] tipsbank-auditoria
Write-Host "`n[4/5] tipsbank-auditoria" -ForegroundColor Cyan
Apply "$K8S\tipsbank-auditoria\pvc-auditoria.yaml"
Apply "$K8S\tipsbank-auditoria\auditoria-service.yaml"
Apply "$K8S\tipsbank-auditoria\auditoria-deployment.yaml"
ApplyIngress "$K8S\tipsbank-auditoria\ingress-api-auditoria.yaml"
Apply "$K8S\tipsbank-auditoria\netpol.yaml"

# [5/5] tipsbank-web
Write-Host "`n[5/5] tipsbank-web" -ForegroundColor Cyan
Apply "$K8S\tipsbank-web\configmap-nginx.yaml"
Apply "$K8S\tipsbank-web\web-service.yaml"
Apply "$K8S\tipsbank-web\web-deployment.yaml"
ApplyIngress "$K8S\tipsbank-web\ingress-app.yaml"
Apply "$K8S\tipsbank-web\netpol.yaml"

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host " Deploy concluido  [env: $Env]" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
kubectl get pods -A --no-headers | Select-String "tipsbank"

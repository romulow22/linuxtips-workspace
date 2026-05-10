# cluster-eks.ps1 -- Gerencia o cluster EKS do TipsBank.
#
# Pre-requisitos:
#   - aws configure (long-term keys, sem session token)
#   - eksctl  (winget install eksctl)
#   - helm e kubectl no PATH
#
# Execute a partir da raiz do projeto (semana-2/):
#   .\scripts\cluster-eks.ps1 create
#   .\scripts\cluster-eks.ps1 destroy
#   .\scripts\cluster-eks.ps1 status
#   .\scripts\cluster-eks.ps1 addons
#   .\scripts\cluster-eks.ps1 deploy

param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [switch]$Merge
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR   = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load local credentials if present (never committed — see .gitignore)
$_envFile = Join-Path $SCRIPT_DIR ".env-aws.ps1"
if (Test-Path $_envFile) { . $_envFile }
$ROOT         = Split-Path -Parent $SCRIPT_DIR
$EKSDIR       = "$ROOT\eksctl"

$CLUSTER_NAME  = "tipsbank"
$REGION        = "us-east-2"
$EKS_CONTEXT   = "eks-tipsbank"
$LOCAL_CONTEXT = "kubeadm-local"

$script:DOMAIN = $null

function Get-NLB {
    if ($env:TIPSBANK_NLB) { return $env:TIPSBANK_NLB }
    # 2>&1 + Where-Object filters PS5.1 NativeCommandError records without displaying them
    $result = kubectl get svc ingress-nginx-controller -n ingress-nginx `
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>&1 |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    if ($LASTEXITCODE -eq 0) { return $result } else { return $null }
}

# Commands
function Test-Prerequisites {
    Write-Host "[0] Verificando pre-requisitos..." -ForegroundColor Cyan
    foreach ($cmd in @("aws", "eksctl", "kubectl", "helm")) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "'$cmd' nao encontrado. Instale antes de continuar."
        }
    }
    $awsAccount = aws sts get-caller-identity --query Account --output text 2>$null
    if (-not $awsAccount) { throw "AWS CLI nao autenticado. Execute 'aws configure'." }
    Write-Host "  AWS Account: $awsAccount" -ForegroundColor Green
}

function Save-LocalContext {
    Write-Host "[1] Garantindo context '$LOCAL_CONTEXT'..." -ForegroundColor Cyan
    $prevCtx = kubectl config current-context 2>$null
    if ($prevCtx -and $prevCtx -ne $LOCAL_CONTEXT -and $prevCtx -ne $EKS_CONTEXT) {
        kubectl config rename-context $prevCtx $LOCAL_CONTEXT | Out-Null
        Write-Host "  Renomeado '$prevCtx' -> '$LOCAL_CONTEXT'" -ForegroundColor Green
    } else {
        Write-Host "  Context '$LOCAL_CONTEXT' ja configurado" -ForegroundColor DarkGray
    }
}

function New-EKSCluster {
    Write-Host "[2] Criando cluster EKS '$CLUSTER_NAME' em $REGION (15-20 min)..." -ForegroundColor Cyan

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $clusterStatus = aws eks describe-cluster --name $CLUSTER_NAME --region $REGION `
        --query "cluster.status" --output text 2>&1 |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    $ErrorActionPreference = $prevEap
    if ($clusterStatus -eq "ACTIVE") {
        Write-Host "  Cluster '$CLUSTER_NAME' ja existe e esta ACTIVE. Pulando criacao." -ForegroundColor Yellow
        Get-EKSKubeconfig -Merge
        return
    }

    eksctl create cluster -f "$EKSDIR\cluster.yaml"
    if ($LASTEXITCODE -ne 0) { throw "eksctl create cluster falhou" }

    $eksCtx = kubectl config get-contexts -o name 2>$null |
              Where-Object { $_ -match $CLUSTER_NAME -and $_ -ne $LOCAL_CONTEXT } |
              Select-Object -First 1
    if ($eksCtx -and $eksCtx -ne $EKS_CONTEXT) {
        kubectl config rename-context $eksCtx $EKS_CONTEXT | Out-Null
        Write-Host "  Renomeado '$eksCtx' -> '$EKS_CONTEXT'" -ForegroundColor Green
    }
    kubectl config use-context $EKS_CONTEXT
    Write-Host ""
    kubectl get nodes
}

function Install-Addons {
    & "$SCRIPT_DIR\install-addons.ps1" -Env eks
    if ($LASTEXITCODE -ne 0) { throw "install-addons.ps1 falhou" }
}

function Invoke-AppDeploy {
    & "$SCRIPT_DIR\deploy-apps.ps1" -Env eks
    if ($LASTEXITCODE -ne 0) { throw "deploy-apps.ps1 falhou" }
}

function Invoke-FullDeploy {
    Install-Addons
    Invoke-AppDeploy
}

function Show-Status {
    Write-Host "Cluster: $CLUSTER_NAME  |  Region: $REGION  |  Context: $EKS_CONTEXT" -ForegroundColor Cyan
    Write-Host ""
    kubectl config get-contexts
    Write-Host ""
    kubectl get nodes
    Write-Host ""
    kubectl get pods -A --no-headers | Select-String "tipsbank"
    Write-Host ""
    kubectl get ingress -A
}

function Show-Summary {
    $domain = Get-NLB
    if (-not $domain) { $domain = "<NLB-hostname>" }
    Write-Host ""
    Write-Host "Testes:" -ForegroundColor Yellow
    Write-Host "  kubectl --context $EKS_CONTEXT get nodes" -ForegroundColor White
    Write-Host "  curl -k https://$domain/" -ForegroundColor White
    Write-Host "  curl -k https://$domain/contas/contas" -ForegroundColor White
    Write-Host ""
    Write-Host "Destruir quando nao estiver usando:" -ForegroundColor Yellow
    Write-Host "  .\scripts\cluster-eks.ps1 destroy" -ForegroundColor White
}

function Get-EKSKubeconfig {
    param([switch]$Merge)

    Write-Host "[kubeconfig] Exportando kubeconfig para '$EKS_CONTEXT'..." -ForegroundColor Cyan

    $localKubeconfig = Join-Path (Get-Location) "kubeconfig-eks"

    # Export to a standalone file
    $env:KUBECONFIG = $localKubeconfig
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION --alias $EKS_CONTEXT
    if ($LASTEXITCODE -ne 0) { throw "aws eks update-kubeconfig falhou" }
    Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue

    Write-Host "  Kubeconfig salvo em $localKubeconfig" -ForegroundColor Green

    if ($Merge) {
        Write-Host "  Mesclando com ~/.kube/config..." -ForegroundColor Cyan
        $defaultKubeconfig = "$env:USERPROFILE\.kube\config"
        $kubeDir = Split-Path -Parent $defaultKubeconfig
        if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null }

        if (Test-Path $defaultKubeconfig) {
            $backup = "$defaultKubeconfig.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -Path $defaultKubeconfig -Destination $backup
            Write-Host "  Backup: $backup" -ForegroundColor DarkGray

            # Remove stale eks-tipsbank entries before merging
            $env:KUBECONFIG = $defaultKubeconfig
            kubectl config delete-cluster $EKS_CONTEXT   2>&1 | Out-Null
            kubectl config delete-context $EKS_CONTEXT   2>&1 | Out-Null
            Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue
        }

        $env:KUBECONFIG = "$localKubeconfig;$defaultKubeconfig"
        kubectl config view --flatten | Set-Content -Path "$defaultKubeconfig.tmp" -Encoding UTF8
        Move-Item -Path "$defaultKubeconfig.tmp" -Destination $defaultKubeconfig -Force
        Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue

        Write-Host "  Merge concluido." -ForegroundColor Green
    } else {
        Write-Host "  Para mesclar: .\scripts\cluster-eks.ps1 kubeconfig -Merge" -ForegroundColor DarkGray
        Write-Host "  Para usar diretamente: `$env:KUBECONFIG = '$localKubeconfig'" -ForegroundColor DarkGray
    }

    kubectl config use-context $EKS_CONTEXT
    Write-Host "  Context ativo: $EKS_CONTEXT" -ForegroundColor Green
}

function Remove-EKSCluster {
    $confirm = Read-Host "Destruir cluster '$CLUSTER_NAME' em $REGION? Isso e irreversivel. (yes/no)"
    if ($confirm -ne "yes") { Write-Host "Cancelado."; return }
    Write-Host "Destruindo cluster EKS (5-10 min)..." -ForegroundColor Yellow
    eksctl delete cluster --name $CLUSTER_NAME --region $REGION
    kubectl config delete-context $EKS_CONTEXT 2>&1 | Out-Null
    Write-Host "Cluster destruido." -ForegroundColor Green
}

function Show-Help {
    Write-Host @"

EKS Cluster Management -- TipsBank

Usage: .\scripts\cluster-eks.ps1 [command]

Commands:
  create              Create EKS cluster, install addons and deploy all apps
  destroy             Delete the EKS cluster (irreversible, prompts for confirmation)
  status              Show contexts, nodes, pods and ingresses
  addons              Install/upgrade Helm addons only (ingress-nginx, cert-manager, nfs-ganesha)
  deploy              Deploy/redeploy all app manifests (cluster must already exist)
  kubeconfig          Export kubeconfig to kubeconfig-eks in current directory
    -Merge            Merge into default ~/.kube/config
  help                Show this help message

"@
}

# Main
switch ($Command.ToLower()) {
    "create" {
        Test-Prerequisites
        Save-LocalContext
        New-EKSCluster
        Invoke-FullDeploy
        Write-Host "`nStatus final:" -ForegroundColor Cyan
        Show-Status
        Show-Summary
    }
    "destroy" {
        Test-Prerequisites
        Remove-EKSCluster
    }
    "status" {
        kubectl config use-context $EKS_CONTEXT 2>$null
        Show-Status
        Show-Summary
    }
    "addons" {
        Test-Prerequisites
        kubectl config use-context $EKS_CONTEXT
        Install-Addons
    }
    "deploy" {
        Test-Prerequisites
        kubectl config use-context $EKS_CONTEXT
        Invoke-AppDeploy
        Show-Status
        Show-Summary
    }
    "kubeconfig" { Get-EKSKubeconfig -Merge:$Merge }
    default { Show-Help }
}

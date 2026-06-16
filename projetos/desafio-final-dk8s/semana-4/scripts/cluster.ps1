# cluster.ps1 -- Gerencia o cluster do TipsBank (EKS ou Vagrant/kubeadm).
#
# Unifica os antigos cluster-eks.ps1 e cluster-vagrant.ps1 em um unico script.
# O primeiro argumento escolhe o provider; o segundo, o comando.
#
# Pre-requisitos (eks):    aws configure, eksctl, helm, kubectl
# Pre-requisitos (vagrant): vagrant, virtualbox, helm, kubectl
#
# Execute a partir da raiz do projeto (semana-4/):
#   .\scripts\cluster.ps1 eks create
#   .\scripts\cluster.ps1 eks destroy
#   .\scripts\cluster.ps1 vagrant create
#   .\scripts\cluster.ps1 vagrant ssh worker
#   .\scripts\cluster.ps1 vagrant kubeconfig -Merge

param(
    [Parameter(Position=0)]
    [string]$Provider = "help",      # eks | vagrant

    [Parameter(Position=1)]
    [string]$Command = "help",

    [Parameter(Position=2)]
    [string]$Node = "control-plane",

    [switch]$Merge
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT        = Split-Path -Parent $SCRIPT_DIR

# Load local AWS credentials if present (never committed -- see .gitignore)
$_envFile = Join-Path $SCRIPT_DIR ".env-aws.ps1"
if (Test-Path $_envFile) { . $_envFile }

# EKS settings
$EKSDIR        = "$ROOT\eksctl"
$CLUSTER_NAME  = "tipsbank"
$REGION        = "us-east-2"
$EKS_CONTEXT   = "eks-tipsbank"

# Vagrant / kubeadm settings
$VAGRANT_DIR   = Join-Path $ROOT "vagrant"
$LOCAL_CONTEXT = "kubeadm-local"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Print-Info    { param([string]$m) Write-Host "INFO: $m"    -ForegroundColor Blue }
function Print-Success { param([string]$m) Write-Host "SUCCESS: $m" -ForegroundColor Green }
function Print-Warning { param([string]$m) Write-Host "WARNING: $m" -ForegroundColor Yellow }
function Print-Error   { param([string]$m) Write-Host "ERROR: $m"   -ForegroundColor Red }
function Print-Header {
    param([string]$m)
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Blue
    Write-Host $m -ForegroundColor Blue
    Write-Host "=========================================" -ForegroundColor Blue
    Write-Host ""
}

# Returns the kubectl context name for the active provider.
function Get-ClusterContext {
    if ($Provider -eq "eks") { return $EKS_CONTEXT } else { return $LOCAL_CONTEXT }
}

# ---------------------------------------------------------------------------
# Shared commands (provider-agnostic, branch on $Provider only via -Env/context)
# ---------------------------------------------------------------------------
function Install-Addons {
    Print-Header "Installing Helm Addons ($Provider)"
    & "$SCRIPT_DIR\install-addons.ps1" -Env $Provider
    if ($LASTEXITCODE -ne 0) { throw "install-addons.ps1 falhou" }
    Print-Success "Addons instalados (ingress-nginx, cert-manager, nfs-ganesha)."
}

function Invoke-AppDeploy {
    Print-Header "Deploying TipsBank Apps ($Provider)"
    & "$SCRIPT_DIR\deploy-apps.ps1" -Env $Provider
    if ($LASTEXITCODE -ne 0) { throw "deploy-apps.ps1 falhou" }
    Print-Success "Apps implantados."
}

function Invoke-FullDeploy {
    Install-Addons
    Invoke-AppDeploy
}

function Invoke-GerarCerts {
    Print-Header "Generating RBAC Kubeconfigs ($Provider)"
    kubectl config use-context (Get-ClusterContext) | Out-Null
    & "$SCRIPT_DIR\gerar-certificados.ps1"
    if ($LASTEXITCODE -ne 0) { throw "gerar-certificados.ps1 falhou" }
    Print-Success "Kubeconfigs gerados em evidencias\kubeconfigs\"
}

# ===========================================================================
# EKS provider
# ===========================================================================
function Test-PrerequisitesEKS {
    Print-Info "Verificando pre-requisitos (eks)..."
    foreach ($cmd in @("aws", "eksctl", "kubectl", "helm")) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "'$cmd' nao encontrado. Instale antes de continuar."
        }
    }
    $awsAccount = aws sts get-caller-identity --query Account --output text 2>$null
    if (-not $awsAccount) { throw "AWS CLI nao autenticado. Execute 'aws configure'." }
    Print-Success "AWS Account: $awsAccount"
}

function Get-NLB {
    if ($env:TIPSBANK_NLB) { return $env:TIPSBANK_NLB }
    # 2>&1 + Where-Object filters PS5.1 NativeCommandError records without displaying them
    $result = kubectl get svc ingress-nginx-controller -n ingress-nginx `
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>&1 |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    if ($LASTEXITCODE -eq 0) { return $result } else { return $null }
}

function Save-LocalContext {
    Print-Info "Garantindo context '$LOCAL_CONTEXT'..."
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $prevCtx = kubectl config current-context 2>&1 |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    $ErrorActionPreference = $prevEap
    if ($prevCtx -and $prevCtx -ne $LOCAL_CONTEXT -and $prevCtx -ne $EKS_CONTEXT) {
        kubectl config rename-context $prevCtx $LOCAL_CONTEXT | Out-Null
        Print-Success "Renomeado '$prevCtx' -> '$LOCAL_CONTEXT'"
    } else {
        Print-Info "Context '$LOCAL_CONTEXT' ja configurado"
    }
}

function Remove-StaleCFStacks {
    $stacks = @("eksctl-$CLUSTER_NAME-cluster", "eksctl-$CLUSTER_NAME-nodegroup-workers")
    foreach ($stack in $stacks) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $status = aws cloudformation describe-stacks --stack-name $stack --region $REGION --query Stacks[0].StackStatus --output text 2>&1 |
            Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
        $ErrorActionPreference = $prevEap
        if ($status -and $status -ne "DELETE_COMPLETE") {
            Print-Warning "Stack orfa encontrada: $stack ($status) -- deletando..."
            aws cloudformation delete-stack --stack-name $stack --region $REGION
            Print-Info "Aguardando delecao de $stack..."
            aws cloudformation wait stack-delete-complete --stack-name $stack --region $REGION
            Print-Success "$stack deletada."
        }
    }
}

function New-EKSCluster {
    Print-Header "Criando cluster EKS '$CLUSTER_NAME' em $REGION (15-20 min)"

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $clusterStatus = aws eks describe-cluster --name $CLUSTER_NAME --region $REGION `
        --query "cluster.status" --output text 2>&1 |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    $ErrorActionPreference = $prevEap
    if ($clusterStatus -eq "ACTIVE") {
        Print-Warning "Cluster '$CLUSTER_NAME' ja existe e esta ACTIVE. Pulando criacao."
        Get-EKSKubeconfig -Merge
        return
    }

    # Limpar stacks orfas antes de criar (evita AlreadyExistsException)
    Remove-StaleCFStacks

    eksctl create cluster -f "$EKSDIR\cluster.yaml"
    if ($LASTEXITCODE -ne 0) { throw "eksctl create cluster falhou" }

    $eksCtx = kubectl config get-contexts -o name 2>$null |
              Where-Object { $_ -match $CLUSTER_NAME -and $_ -ne $LOCAL_CONTEXT } |
              Select-Object -First 1
    if ($eksCtx -and $eksCtx -ne $EKS_CONTEXT) {
        kubectl config rename-context $eksCtx $EKS_CONTEXT | Out-Null
        Print-Success "Renomeado '$eksCtx' -> '$EKS_CONTEXT'"
    }
    kubectl config use-context $EKS_CONTEXT
    Write-Host ""
    kubectl get nodes
}

function Get-EKSKubeconfig {
    param([switch]$Merge)

    Print-Header "Exportando kubeconfig para '$EKS_CONTEXT'"

    $localKubeconfig = Join-Path (Get-Location) "kubeconfig-eks"

    # Export to a standalone file
    $env:KUBECONFIG = $localKubeconfig
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION --alias $EKS_CONTEXT
    if ($LASTEXITCODE -ne 0) { throw "aws eks update-kubeconfig falhou" }
    Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue

    Print-Success "Kubeconfig salvo em $localKubeconfig"

    if ($Merge) {
        Print-Info "Mesclando com ~/.kube/config..."
        $defaultKubeconfig = "$env:USERPROFILE\.kube\config"
        $kubeDir = Split-Path -Parent $defaultKubeconfig
        if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null }

        # Remove lock file stale que eksctl deixa apos interrupcoes
        $lockFile = "$defaultKubeconfig.lock"
        if (Test-Path $lockFile) {
            Remove-Item $lockFile -Force
            Print-Info "Lock file removido: $lockFile"
        }

        if (Test-Path $defaultKubeconfig) {
            $backup = "$defaultKubeconfig.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -Path $defaultKubeconfig -Destination $backup
            Print-Info "Backup: $backup"

            # Remove stale eks-tipsbank entries before merging (so deleta se existir)
            $env:KUBECONFIG = $defaultKubeconfig
            $existingCtx = kubectl config get-contexts -o name 2>$null
            if ($existingCtx -contains $EKS_CONTEXT) {
                kubectl config delete-context $EKS_CONTEXT | Out-Null
                kubectl config delete-cluster $EKS_CONTEXT | Out-Null
            }
            Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue
        }

        $env:KUBECONFIG = "$localKubeconfig;$defaultKubeconfig"
        kubectl config view --flatten | Set-Content -Path "$defaultKubeconfig.tmp" -Encoding UTF8
        Move-Item -Path "$defaultKubeconfig.tmp" -Destination $defaultKubeconfig -Force
        Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue

        Print-Success "Merge concluido."
    } else {
        Print-Info "Para mesclar: .\scripts\cluster.ps1 eks kubeconfig -Merge"
        Print-Info "Para usar diretamente: `$env:KUBECONFIG = '$localKubeconfig'"
    }

    kubectl config use-context $EKS_CONTEXT
    Print-Success "Context ativo: $EKS_CONTEXT"
}

function Remove-EKSCluster {
    $confirm = Read-Host "Destruir cluster '$CLUSTER_NAME' em $REGION? Isso e irreversivel. (yes/no)"
    if ($confirm -ne "yes") { Print-Info "Cancelado."; return }
    Print-Warning "Destruindo cluster EKS (5-10 min)..."
    eksctl delete cluster --name $CLUSTER_NAME --region $REGION
    $existingCtx = kubectl config get-contexts -o name 2>$null
    if ($existingCtx -contains $EKS_CONTEXT) {
        kubectl config delete-context $EKS_CONTEXT | Out-Null
        kubectl config delete-cluster $EKS_CONTEXT | Out-Null
    }
    Print-Success "Cluster destruido."
}

function Show-StatusEKS {
    Print-Header "Cluster: $CLUSTER_NAME  |  Region: $REGION  |  Context: $EKS_CONTEXT"
    kubectl config get-contexts
    Write-Host ""
    kubectl get nodes
    Write-Host ""
    kubectl get pods -A --no-headers | Select-String "tipsbank"
    Write-Host ""
    kubectl get ingress -A
}

function Show-SummaryEKS {
    $domain = Get-NLB
    if (-not $domain) { $domain = "<NLB-hostname>" }
    Write-Host ""
    Write-Host "Testes:" -ForegroundColor Yellow
    Write-Host "  kubectl --context $EKS_CONTEXT get nodes" -ForegroundColor White
    Write-Host "  curl -k https://$domain/" -ForegroundColor White
    Write-Host "  curl -k https://$domain/contas/contas" -ForegroundColor White
    Write-Host ""
    Write-Host "Destruir quando nao estiver usando:" -ForegroundColor Yellow
    Write-Host "  .\scripts\cluster.ps1 eks destroy" -ForegroundColor White
}

# ===========================================================================
# Vagrant / kubeadm provider
# ===========================================================================
function Load-Env {
    $envFile = Join-Path $SCRIPT_DIR ".env-vagrant"
    if (Test-Path $envFile) {
        Print-Info "Loading configuration from .env-vagrant..."
        Get-Content $envFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^\s*#' -or -not $line) { return }
            if ($line -match '^export\s+([\w_]+)=(.+)') {
                $varName = $matches[1]
                $varValue = $matches[2].Trim().Trim('"').Trim("'")
                if ($varValue -match '^([^#]+)') {
                    $varValue = $matches[1].Trim()
                }
                [Environment]::SetEnvironmentVariable($varName, $varValue, 'Process')
            }
        }
        Print-Success "Configuration loaded"
    } else {
        Print-Warning "No .env-vagrant file found, using defaults"
    }
}

function Show-Config {
    Print-Header "Current Configuration"
    $nodeCount  = if ($env:NODE_COUNT)  { $env:NODE_COUNT }  else { "1" }
    $cpMemory   = if ($env:CP_MEMORY)   { $env:CP_MEMORY }   else { "4096" }
    $cpCpus     = if ($env:CP_CPUS)     { $env:CP_CPUS }     else { "4" }
    $nodeMemory = if ($env:NODE_MEMORY) { $env:NODE_MEMORY } else { "4096" }
    $nodeCpus   = if ($env:NODE_CPUS)   { $env:NODE_CPUS }   else { "2" }
    $enableGui  = if ($env:ENABLE_GUI)  { $env:ENABLE_GUI }  else { "false" }
    $provider   = if ($env:PROVIDER)    { $env:PROVIDER }    else { "virtualbox" }

    Write-Host "Nodes:              $nodeCount"
    Write-Host "Control Plane RAM:  $cpMemory MB"
    Write-Host "Control Plane CPUs: $cpCpus"
    Write-Host "Node RAM:           $nodeMemory MB"
    Write-Host "Node CPUs:          $nodeCpus"
    Write-Host "GUI Enabled:        $enableGui"
    Write-Host "Provider:           $provider"
    Write-Host ""
    try {
        $totalRam = [int]$cpMemory + ([int]$nodeCount * [int]$nodeMemory)
        $totalGb = [math]::Round($totalRam / 1024, 1)
        Write-Host "Total RAM needed:   $totalRam MB (~$totalGb GB)"
    } catch {
        Print-Warning "Could not calculate total RAM."
    }
}

function Wait-For-Nodes {
    Print-Info "Waiting for all nodes to be Ready (max 3 minutes)..."
    $maxAttempts = 36
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        try {
            $notReadyNodes = vagrant ssh control-plane -c "kubectl get nodes --no-headers" 2>$null | Where-Object { $_ -notmatch "Ready" }
            if (-not $notReadyNodes) {
                Print-Success "All nodes are Ready!"
                vagrant ssh control-plane -c "kubectl get nodes -o wide"
                return $true
            }
        } catch {}
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 5
    }
    Write-Host ""
    Print-Error "Timeout waiting for nodes to become Ready."
    return $false
}

function Wait-For-Pods {
    Print-Info "Waiting for all system pods to be Running (max 3 minutes)..."
    $maxAttempts = 36
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        try {
            $notReadyPods = vagrant ssh control-plane -c "kubectl get pods -A --no-headers" 2>$null | Where-Object { $_ -notmatch "Running" -and $_ -notmatch "Completed" }
            if (-not $notReadyPods) {
                Print-Success "All system pods are Running or Completed!"
                vagrant ssh control-plane -c "kubectl get pods -A"
                return $true
            }
        } catch {}
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 5
    }
    Write-Host ""
    Print-Error "Timeout waiting for pods to become ready."
    return $false
}

function New-VagrantCluster {
    Print-Header "Creating Kubernetes Cluster (vagrant)"
    Load-Env
    Show-Config

    Print-Info "Starting VMs..."
    vagrant up

    if ($LASTEXITCODE -ne 0) { Print-Error "Vagrant up command failed."; return }

    Print-Success "VMs created successfully!"
    if ((Wait-For-Nodes) -and (Wait-For-Pods)) {
        Print-Success "Cluster is ready!"
        Print-Info "Running final validation..."
        Validate-Cluster
        Print-Info "Refreshing kubeconfig before addon install..."
        Get-VagrantKubeconfig -Merge
        Install-Addons
    } else {
        Print-Error "Cluster did not become healthy in time."
    }
}

function Remove-VagrantCluster {
    Print-Header "Destroying Kubernetes Cluster (vagrant)"
    $confirm = Read-Host "Are you sure? This will delete all VMs. (yes/no)"
    if ($confirm -eq "yes") {
        vagrant destroy -f
        Print-Success "Cluster destroyed."
    } else {
        Print-Info "Destroy cancelled."
    }
}

function Show-StatusVagrant {
    Print-Header "Cluster Status (vagrant)"
    Print-Info "VM Status:"
    vagrant status
    Write-Host ""
    $status = vagrant status | Out-String
    if ($status -match "running") {
        Print-Info "Kubernetes Nodes:"
        vagrant ssh control-plane -c "kubectl get nodes -o wide" 2>$null
        Write-Host ""
        Print-Info "System Pods:"
        vagrant ssh control-plane -c "kubectl get pods -A" 2>$null
    }
}

function Validate-Cluster {
    Print-Header "Validating Cluster"
    vagrant ssh control-plane -c "sudo /vagrant/scripts/validate-cluster.sh"
}

function SSH-Node {
    param([string]$NodeName = "control-plane")
    Print-Info "Connecting to $NodeName..."
    vagrant ssh $NodeName
}

function Restart-Cluster {
    Print-Header "Restarting Cluster"
    vagrant halt
    vagrant up
    if ($LASTEXITCODE -eq 0) {
        Print-Success "VMs restarted."
        Wait-For-Nodes
        Wait-For-Pods
    } else {
        Print-Error "VMs failed to restart."
    }
}

function Provision-Cluster {
    Print-Header "Provisioning Cluster"
    vagrant provision
    Print-Success "Provisioning complete."
}

function Show-Logs {
    param([string]$NodeName = "control-plane")
    Print-Header "Logs from $NodeName"
    if ($NodeName -eq "control-plane") {
        Print-Info "Kubeadm init log:"
        vagrant ssh control-plane -c "cat /root/kubeinit.log 2>/dev/null || echo 'Not found'"
    } else {
        Print-Info "Kubeadm join log:"
        vagrant ssh $NodeName -c "cat /tmp/kubeadm-join.log 2>/dev/null || echo 'Not found'"
    }
    Write-Host ""
    Print-Info "Kubelet logs (last 20 lines):"
    vagrant ssh $NodeName -c "sudo journalctl -u kubelet -n 20 --no-pager"
}

function Get-VagrantKubeconfig {
    param(
        [switch]$Merge,
        [string]$ClusterName = "kubeadm-local"
    )

    Print-Header "Getting Kubeconfig (vagrant)"

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Print-Error "kubectl is required for this operation. Please install it first."
        return
    }

    $localKubeconfig = Join-Path (Get-Location) "kubeconfig"
    $originalKubeconfig = $env:KUBECONFIG

    Print-Info "Extracting kubeconfig from control-plane..."
    vagrant ssh control-plane -c "cat ~/.kube/config" | Set-Content -Path $localKubeconfig -Encoding UTF8

    Print-Info "Adapting kubeconfig for local access..."

    # Rename kubernetes-admin -> <ClusterName>-admin BEFORE loading via kubectl.
    # This prevents credential collisions when merging multiple cluster kubeconfigs
    # that all use the default kubeadm user name "kubernetes-admin".
    $uniqueUserName = "$ClusterName-admin"
    $content = Get-Content -Path $localKubeconfig -Raw
    $content = $content -replace '\bkubernetes-admin\b', $uniqueUserName
    # Remove certificate-authority-data (incompatible with insecure-skip-tls-verify)
    $content = $content -replace '(?m)^\s*certificate-authority-data:.*\r?\n', ''
    $content | Set-Content -Path $localKubeconfig -Encoding UTF8

    $env:KUBECONFIG = $localKubeconfig

    # Create new cluster entry with correct name, server and TLS settings
    & kubectl config set-cluster $ClusterName --server="https://192.168.10.100:6443" --insecure-skip-tls-verify=true | Out-Null

    # Create new context pointing to the renamed cluster and set it as current
    & kubectl config set-context $ClusterName --cluster=$ClusterName --user=$uniqueUserName | Out-Null
    & kubectl config use-context $ClusterName | Out-Null

    # Remove original "kubernetes" entries (kubectl rename-cluster does not exist)
    & kubectl config delete-cluster kubernetes 2>&1 | Out-Null
    & kubectl config delete-context "$uniqueUserName@kubernetes" 2>&1 | Out-Null

    if ($originalKubeconfig) { $env:KUBECONFIG = $originalKubeconfig }
    else { Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue }

    Print-Success "Standalone kubeconfig saved to $localKubeconfig"

    if ($Merge) {
        Print-Info "Merging into default kubeconfig..."
        $defaultKubeconfig = "$env:USERPROFILE\.kube\config"
        $kubeDir = Split-Path -Parent $defaultKubeconfig
        if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null }

        if (Test-Path $defaultKubeconfig) {
            $backupFile = "$defaultKubeconfig.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Print-Info "Backing up current config to $backupFile"
            Copy-Item -Path $defaultKubeconfig -Destination $backupFile

            # Remove any existing entries with this cluster name to avoid conflicts
            $env:KUBECONFIG = $defaultKubeconfig
            & kubectl config delete-cluster $ClusterName 2>&1 | Out-Null
            & kubectl config delete-context $ClusterName 2>&1 | Out-Null
            # Remove stale user from a previous merge of this same cluster
            & kubectl config delete-user $uniqueUserName 2>&1 | Out-Null
            Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue
        }

        # Local config first so its credentials take precedence over any stale duplicate user entries
        $env:KUBECONFIG = "$localKubeconfig;$defaultKubeconfig"
        & kubectl config view --flatten | Set-Content -Path "$defaultKubeconfig.tmp" -Encoding UTF8
        Move-Item -Path "$defaultKubeconfig.tmp" -Destination $defaultKubeconfig -Force

        if ($originalKubeconfig) { $env:KUBECONFIG = $originalKubeconfig }
        else { Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue }

        kubectl config use-context $ClusterName

        Print-Success "Merge complete!"
        Print-Info "Run 'kubectl config use-context $ClusterName' to activate."
    } else {
        Print-Info "To merge: .\scripts\cluster.ps1 vagrant kubeconfig -Merge"
        Print-Info "To use directly: `$env:KUBECONFIG = '$localKubeconfig'"
    }
}

# ===========================================================================
# Help
# ===========================================================================
function Show-Help {
    Write-Host @"

Cluster Management -- TipsBank

Usage: .\scripts\cluster.ps1 <provider> <command> [options]

Providers:
  eks           Amazon EKS (eksctl + aws)
  vagrant       Local kubeadm cluster (vagrant + virtualbox)

Shared commands:
  create        Create cluster, install addons (and deploy apps)
  destroy       Destroy the cluster
  status        Show cluster status (contexts/VMs, nodes, pods)
  addons        Install/upgrade Helm addons (ingress-nginx, cert-manager, nfs-ganesha)
  deploy        Deploy/redeploy all app manifests (cluster must already exist)
  certs         Generate RBAC kubeconfigs
  kubeconfig    Export kubeconfig for local access
    -Merge      Merge into the default ~/.kube/config
  help          Show this help message

Vagrant-only commands:
  validate      Validate cluster health
  restart       Restart the cluster and wait for readiness
  provision     Re-run provisioners
  ssh [node]    SSH into a node (default: control-plane)
  logs [node]   Show logs from a node
  config        Show current configuration

Examples:
  .\scripts\cluster.ps1 eks create
  .\scripts\cluster.ps1 eks destroy
  .\scripts\cluster.ps1 vagrant create
  .\scripts\cluster.ps1 vagrant ssh worker
  .\scripts\cluster.ps1 vagrant kubeconfig -Merge

"@
}

# ===========================================================================
# Main dispatch
# ===========================================================================
$prov = $Provider.ToLower()
$cmd  = $Command.ToLower()

if ($prov -in @("help", "-h", "--help", "/?")) { Show-Help; return }

if ($prov -notin @("eks", "vagrant")) {
    Print-Error "Provider invalido: '$Provider'. Use 'eks' ou 'vagrant'."
    Show-Help
    exit 1
}

# Point vagrant at the Vagrantfile directory regardless of where this script is called from
if ($prov -eq "vagrant") { $env:VAGRANT_CWD = $VAGRANT_DIR }

switch ($prov) {
    "eks" {
        switch ($cmd) {
            "create" {
                Test-PrerequisitesEKS
                Save-LocalContext
                New-EKSCluster
                Install-Addons
                #Invoke-AppDeploy
                Show-StatusEKS
                Show-SummaryEKS
            }
            "destroy" {
                Test-PrerequisitesEKS
                Remove-EKSCluster
            }
            "status" {
                kubectl config use-context $EKS_CONTEXT 2>$null
                Show-StatusEKS
                Show-SummaryEKS
            }
            "addons" {
                Test-PrerequisitesEKS
                kubectl config use-context $EKS_CONTEXT
                Install-Addons
            }
            "deploy" {
                Test-PrerequisitesEKS
                kubectl config use-context $EKS_CONTEXT
                Invoke-AppDeploy
                Show-StatusEKS
                Show-SummaryEKS
            }
            "certs"      { Invoke-GerarCerts }
            "kubeconfig" { Get-EKSKubeconfig -Merge:$Merge }
            default      { Show-Help }
        }
    }
    "vagrant" {
        switch ($cmd) {
            "create"     { New-VagrantCluster }
            "destroy"    { Remove-VagrantCluster }
            "status"     { Show-StatusVagrant }
            "validate"   { Validate-Cluster }
            "restart"    { Restart-Cluster }
            "addons"     { Install-Addons }
            "deploy"     { Invoke-AppDeploy }
            "provision"  { Provision-Cluster }
            "ssh"        { SSH-Node $Node }
            "certs"      { Invoke-GerarCerts }
            "kubeconfig" { Get-VagrantKubeconfig -Merge:$Merge }
            "logs"       { Show-Logs $Node }
            "config"     { Load-Env; Show-Config }
            default      { Show-Help }
        }
    }
}

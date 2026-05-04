# Kubernetes Cluster Management Script (PowerShell 5.1+ Compatible)
# Simplifies common Vagrant operations

param(
    [Parameter(Position=0)]
    [string]$Command = "help",
    
    [Parameter(Position=1)]
    [string]$Node = "control-plane",

    [switch]$Merge
)

# Functions
function Print-Info {
    param([string]$Message)
    Write-Host "INFO: $Message" -ForegroundColor Blue
}

function Print-Success {
    param([string]$Message)
    Write-Host "SUCCESS: $Message" -ForegroundColor Green
}

function Print-Warning {
    param([string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Print-Error {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Print-Header {
    param([string]$Message)
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Blue
    Write-Host $Message -ForegroundColor Blue
    Write-Host "=========================================" -ForegroundColor Blue
    Write-Host ""
}

# Load .env if exists
function Load-Env {
    if (Test-Path .env) {
        Print-Info "Loading configuration from .env..."
        Get-Content .env | ForEach-Object {
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
        Print-Warning "No .env file found, using defaults"
    }
}

# Show current configuration
function Show-Config {
    Print-Header "Current Configuration"
    
    $nodeCount = if ($env:NODE_COUNT) { $env:NODE_COUNT } else { "1" }
    $cpMemory = if ($env:CP_MEMORY) { $env:CP_MEMORY } else { "4096" }
    $cpCpus = if ($env:CP_CPUS) { $env:CP_CPUS } else { "4" }
    $nodeMemory = if ($env:NODE_MEMORY) { $env:NODE_MEMORY } else { "4096" }
    $nodeCpus = if ($env:NODE_CPUS) { $env:NODE_CPUS } else { "2" }
    $enableGui = if ($env:ENABLE_GUI) { $env:ENABLE_GUI } else { "false" }
    $provider = if ($env:PROVIDER) { $env:PROVIDER } else { "virtualbox" }
    
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

# Create cluster
function Create-Cluster {
    Print-Header "Creating Kubernetes Cluster"
    Load-Env
    Show-Config
    
    Print-Info "Starting VMs..."
    vagrant up
    
    if ($LASTEXITCODE -eq 0) {
        Print-Success "VMs created successfully!"
        if ((Wait-For-Nodes) -and (Wait-For-Pods)) {
            Print-Success "Cluster is ready!"
            Print-Info "Running final validation..."
            Validate-Cluster
        } else {
            Print-Error "Cluster did not become healthy in time."
        }
    } else {
        Print-Error "Vagrant up command failed."
    }
}

# Destroy cluster
function Destroy-Cluster {
    Print-Header "Destroying Kubernetes Cluster"
    $confirm = Read-Host "Are you sure? This will delete all VMs. (yes/no)"
    if ($confirm -eq "yes") {
        vagrant destroy -f
        Print-Success "Cluster destroyed."
    } else {
        Print-Info "Destroy cancelled."
    }
}

# Status
function Show-Status {
    Print-Header "Cluster Status"
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

# Validate cluster
function Validate-Cluster {
    Print-Header "Validating Cluster"
    vagrant ssh control-plane -c "sudo /vagrant/scripts/validate-cluster.sh"
}

# SSH to node
function SSH-Node {
    param([string]$NodeName = "control-plane")
    Print-Info "Connecting to $NodeName..."
    vagrant ssh $NodeName
}

# Get kubeconfig
function Get-Kubeconfig {
    param(
        [switch]$Merge,
        [string]$ClusterName = "vagrant-k8s"
    )

    Print-Header "Getting Kubeconfig"

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Print-Error "kubectl is required for this operation. Please install it first."
        return
    }

    $localKubeconfig = Join-Path (Get-Location) "kubeconfig"
    $originalKubeconfig = $env:KUBECONFIG

    Print-Info "Extracting kubeconfig from control-plane..."
    vagrant ssh control-plane -c "cat ~/.kube/config" | Set-Content -Path $localKubeconfig -Encoding UTF8

    Print-Info "Adapting kubeconfig for local access..."
    $env:KUBECONFIG = $localKubeconfig

    # Get the user name from the extracted config
    $userName = & kubectl config view --raw -o jsonpath='{.users[0].name}'

    # Create new cluster entry with correct name, server and TLS settings
    & kubectl config set-cluster $ClusterName --server="https://192.168.10.100:6443" --insecure-skip-tls-verify=true | Out-Null

    # Remove certificate-authority-data (incompatible with insecure-skip-tls-verify)
    $content = Get-Content -Path $localKubeconfig -Raw
    $content = $content -replace '(?m)^\s*certificate-authority-data:.*\r?\n', ''
    $content | Set-Content -Path $localKubeconfig -Encoding UTF8

    # Create new context pointing to the renamed cluster and set it as current
    & kubectl config set-context $ClusterName --cluster=$ClusterName --user=$userName | Out-Null
    & kubectl config use-context $ClusterName | Out-Null

    # Remove original "kubernetes" entries (kubectl rename-cluster does not exist)
    & kubectl config delete-cluster kubernetes 2>&1 | Out-Null
    & kubectl config delete-context "kubernetes-admin@kubernetes" 2>&1 | Out-Null

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
            $clusters = & kubectl config get-clusters 2>$null
            if ($clusters -match "(?m)^\s*$([regex]::Escape($ClusterName))\s*$") {
                & kubectl config delete-cluster $ClusterName 2>&1 | Out-Null
            }
            $contexts = & kubectl config get-contexts -o name 2>$null
            if ($contexts -match "(?m)^\s*$([regex]::Escape($ClusterName))\s*$") {
                & kubectl config delete-context $ClusterName 2>&1 | Out-Null
            }
            Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue
        }

        # Merge both files and save
        $env:KUBECONFIG = "$defaultKubeconfig;$localKubeconfig"
        & kubectl config view --flatten | Set-Content -Path "$defaultKubeconfig.tmp" -Encoding UTF8
        Move-Item -Path "$defaultKubeconfig.tmp" -Destination $defaultKubeconfig -Force

        if ($originalKubeconfig) { $env:KUBECONFIG = $originalKubeconfig }
        else { Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue }

        Print-Success "Merge complete!"
        Print-Info "Run 'kubectl config use-context $ClusterName' to activate."
    } else {
        Print-Info "To merge: .\cluster.ps1 kubeconfig -Merge"
        Print-Info "To use directly: `$env:KUBECONFIG = '$localKubeconfig'"
    }
}

# Restart cluster
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

# Provision
function Provision-Cluster {
    Print-Header "Provisioning Cluster"
    vagrant provision
    Print-Success "Provisioning complete."
}

# Logs
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

# Help
function Show-Help {
    Write-Host @"

Kubernetes Cluster Management Script (PowerShell)

Usage: .\cluster.ps1 [command] [options]

Commands:
  create        Create a new cluster and wait for it to be ready
  destroy       Destroy the cluster
  status        Show cluster status (VMs, nodes, and pods)
  validate      Validate cluster health
  restart       Restart the cluster and wait for readiness
  provision     Re-run provisioners
  ssh [node]    SSH into a node (default: control-plane)
  kubeconfig    Get kubeconfig for local access
    -Merge      Merge the new config with your default kubeconfig
  logs [node]   Show logs from a node
  config        Show current configuration
  help          Show this help message

"@
}

# Main
$cmd = if ($Command) { $Command.ToLower() } else { "help" }

switch ($cmd) {
    "create"     { Create-Cluster }
    "destroy"    { Destroy-Cluster }
    "status"     { Show-Status }
    "validate"   { Validate-Cluster }
    "restart"    { Restart-Cluster }
    "provision"  { Provision-Cluster }
    "ssh"        { SSH-Node $Node }
    "kubeconfig" { Get-Kubeconfig -Merge:$Merge }
    "logs"       { Show-Logs $Node }
    "config"     { Load-Env; Show-Config }
    default      { Show-Help }
}

# deploy-apps.ps1 -- Deploy do TipsBank via manifests kubectl ou Helm chart.
#
# Modos:
#   -Mode direct  Aplica os YAMLs de k8s/ em ordem (comportamento original)
#   -Mode helm    Instala/atualiza via Helm chart (recomendado)
#
# Ambientes:
#   -Env vagrant  Cluster kubeadm/Vagrant  (context: kubeadm-local)
#   -Env eks      Cluster EKS/AWS          (context: eks-tipsbank)
#   -Env auto     Detecta pelo providerID do node (padrao)
#
# Tipo de ambiente (apenas -Mode helm):
#   -EnvType dev   usa values-<env>-dev.yaml   (padrao)
#   -EnvType prod  usa values-<env>-prod.yaml
#
# Exemplos:
#   .\scripts\deploy-apps.ps1                                    # direct + auto-detect
#   .\scripts\deploy-apps.ps1 -Mode helm -Env vagrant            # helm dev vagrant
#   .\scripts\deploy-apps.ps1 -Mode helm -Env eks -EnvType prod  # helm prod EKS
#   .\scripts\deploy-apps.ps1 -Mode helm -Env eks -ChartVersion 1.0.1
#
# Pre-requisito: instale os addons antes do primeiro deploy:
#   .\scripts\install-addons.ps1 -Env <eks|vagrant>

param(
    [ValidateSet("eks", "vagrant", "auto")]
    [string]$Env = "auto",

    [ValidateSet("direct", "helm")]
    [string]$Mode = "direct",

    [ValidateSet("dev", "prod")]
    [string]$EnvType = "dev",

    [string]$ChartRef     = "oci://registry-1.docker.io/romulow22/tipsbank",
    [string]$ChartVersion = "1.0.3",
    [string]$ReleaseName  = "tipsbank"
)

$ErrorActionPreference = "Stop"
$ROOT  = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$K8S   = "$ROOT\k8s"
$HELM  = "$ROOT\helm\tipsbank"

$EKS_CONTEXT   = "eks-tipsbank"
$LOCAL_CONTEXT = "kubeadm-local"

# ---------------------------------------------------------------------------
# Auto-detectar ambiente
# ---------------------------------------------------------------------------
if ($Env -eq "auto") {
    $providerID = kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>$null
    $Env = if ($providerID -match "^aws://") { "eks" } else { "vagrant" }
    Write-Host "  Ambiente detectado: $Env" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Garantir context correto
# ---------------------------------------------------------------------------
$targetContext = if ($Env -eq "eks") { $EKS_CONTEXT } else { $LOCAL_CONTEXT }
kubectl config use-context $targetContext | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Contexto '$targetContext' nao encontrado. Execute 'cluster-eks.ps1 kubeconfig' primeiro."
}
Write-Host "Context: $targetContext" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# NLB hostname (EKS only)
# ---------------------------------------------------------------------------
$DOMAIN = ""
if ($Env -eq "eks") {
    $DOMAIN = if ($env:TIPSBANK_NLB) { $env:TIPSBANK_NLB } else {
        kubectl get svc ingress-nginx-controller -n ingress-nginx `
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
    }
    if (-not $DOMAIN) {
        throw "NLB hostname nao disponivel. Execute 'install-addons.ps1 -Env eks' primeiro."
    }
    Write-Host "NLB: $DOMAIN" -ForegroundColor DarkGray
}

$pgTimeout = if ($Env -eq "eks") { "300s" } else { "120s" }

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host " TipsBank -- Deploy  [env: $Env | mode: $Mode$(if ($Mode -eq 'helm') { " | type: $EnvType" })]" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# ===========================================================================
# MODE: HELM
# ===========================================================================
if ($Mode -eq "helm") {

    $valuesFile = "$HELM\values-$Env-$EnvType.yaml"
    if (-not (Test-Path $valuesFile)) {
        throw "Values file nao encontrado: $valuesFile"
    }

    Write-Host "[helm] Values file : $valuesFile" -ForegroundColor DarkGray
    Write-Host "[helm] Chart       : $ChartRef version $ChartVersion" -ForegroundColor DarkGray
    Write-Host "[helm] Release     : $ReleaseName" -ForegroundColor DarkGray
    Write-Host ""

    $helmArgs = @(
        "upgrade", "--install", $ReleaseName,
        $ChartRef,
        "--version", $ChartVersion,
        "--values", $valuesFile,
        "--wait", "--timeout", "10m", "--debug"
    )

    # No EKS, injetar o FQDN do NLB nos hosts de ingress
    if ($Env -eq "eks") {
        $helmArgs += "--set", "ingress.appHost=$DOMAIN"
        $helmArgs += "--set", "ingress.apiHost=$DOMAIN"
        Write-Host "[helm] ingress.appHost = $DOMAIN" -ForegroundColor DarkGray
        Write-Host "[helm] ingress.apiHost = $DOMAIN" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  Executando helm upgrade --install..." -ForegroundColor Yellow
    & helm @helmArgs
    if ($LASTEXITCODE -ne 0) { throw "helm upgrade --install falhou" }

    Write-Host ""
    Write-Host "================================================" -ForegroundColor Green
    Write-Host " Helm deploy concluido  [env: $Env | $EnvType]" -ForegroundColor Green
    Write-Host "================================================" -ForegroundColor Green
    Write-Host ""

    # URLs de acesso
    Write-Host "  URLs de acesso:" -ForegroundColor Cyan
    if ($Env -eq "eks") {
        Write-Host "  App  : https://$DOMAIN/" -ForegroundColor White
        Write-Host "  API  : https://$DOMAIN/contas/health/live" -ForegroundColor White
        Write-Host "  API  : https://$DOMAIN/transacoes/health/live" -ForegroundColor White
        Write-Host "  API  : https://$DOMAIN/auditoria/health/live" -ForegroundColor White
    } else {
        Write-Host "  App  : https://app.tipsbank.local/" -ForegroundColor White
        Write-Host "  API  : https://api.tipsbank.local/contas/health/live" -ForegroundColor White
        Write-Host "  API  : https://api.tipsbank.local/transacoes/health/live" -ForegroundColor White
        Write-Host "  API  : https://api.tipsbank.local/auditoria/health/live" -ForegroundColor White
    }
    Write-Host ""
    kubectl get pods -A --no-headers | Select-String "tipsbank"
    return
}

# ===========================================================================
# MODE: DIRECT (kubectl apply)
# ===========================================================================

function Apply([string]$file) {
    Write-Host "  kubectl apply $((Split-Path $file -Leaf))" -ForegroundColor DarkGray
    kubectl apply -f $file
    if ($LASTEXITCODE -ne 0) { throw "Falhou: $file" }
}

function ApplyStatefulSet([string]$file) {
    Write-Host "  kubectl apply (statefulset) $((Split-Path $file -Leaf))" -ForegroundColor DarkGray
    $out = kubectl apply -f $file 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
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
            -replace "app\.tipsbank\.local",    $DOMAIN `
            -replace "api\.tipsbank\.local",    $DOMAIN `
            -replace "locust\.tipsbank\.local", $DOMAIN `
            -replace "tipsbank-app-tls",        "tipsbank-eks-tls" `
            -replace "tipsbank-api-tls",        "tipsbank-eks-tls" |
        kubectl apply -f -
    } else {
        kubectl apply -f $file
    }
    if ($LASTEXITCODE -ne 0) { throw "Falhou ingress: $file" }
}

# [0/8] Kyverno Policies
Write-Host "[0/8] Kyverno ClusterPolicies" -ForegroundColor Cyan
Apply "$K8S\kyverno\disallow-root-user.yaml"
Apply "$K8S\kyverno\disallow-latest-tag.yaml"
Apply "$K8S\kyverno\require-labels.yaml"
Apply "$K8S\kyverno\mutate-security-context.yaml"
Apply "$K8S\kyverno\generate-default-deny-netpol.yaml"
Apply "$K8S\kyverno\disallow-untrusted-registries.yaml"

# [1/8] Namespaces
Write-Host "`n[1/8] Namespaces" -ForegroundColor Cyan
Apply "$K8S\00-namespaces.yaml"

# [2/8] tipsbank-contas
Write-Host "`n[2/8] tipsbank-contas" -ForegroundColor Cyan
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

Write-Host "  Aguardando postgres-0 Ready (max $pgTimeout)..." -ForegroundColor Yellow
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

ApplyStatefulSet "$K8S\tipsbank-contas\postgres-replica-statefulset.yaml"
Apply "$K8S\tipsbank-contas\hpa-api-contas.yaml"

# [3/8] tipsbank-transacoes
Write-Host "`n[3/8] tipsbank-transacoes" -ForegroundColor Cyan
Apply "$K8S\tipsbank-transacoes\secret-db.yaml"
Apply "$K8S\tipsbank-transacoes\configmap-app.yaml"
Apply "$K8S\tipsbank-transacoes\api-transacoes-service.yaml"
Apply "$K8S\tipsbank-transacoes\api-transacoes-deployment.yaml"
ApplyIngress "$K8S\tipsbank-transacoes\ingress-api-transacoes.yaml"
Apply "$K8S\tipsbank-transacoes\api-transacoes-v2-service.yaml"
Apply "$K8S\tipsbank-transacoes\api-transacoes-v2-deployment.yaml"
ApplyIngress "$K8S\tipsbank-transacoes\ingress-api-transacoes-canary.yaml"
Apply "$K8S\tipsbank-transacoes\netpol.yaml"
Apply "$K8S\tipsbank-transacoes\hpa-api-transacoes.yaml"

# [4/8] tipsbank-auditoria
Write-Host "`n[4/8] tipsbank-auditoria" -ForegroundColor Cyan
Apply "$K8S\tipsbank-auditoria\pvc-auditoria.yaml"
Apply "$K8S\tipsbank-auditoria\auditoria-service.yaml"
Apply "$K8S\tipsbank-auditoria\auditoria-deployment.yaml"
ApplyIngress "$K8S\tipsbank-auditoria\ingress-api-auditoria.yaml"
Apply "$K8S\tipsbank-auditoria\netpol.yaml"
Apply "$K8S\tipsbank-auditoria\hpa-auditoria.yaml"

# [5/8] tipsbank-web
Write-Host "`n[5/8] tipsbank-web" -ForegroundColor Cyan
Apply "$K8S\tipsbank-web\configmap-nginx.yaml"
Apply "$K8S\tipsbank-web\web-service.yaml"
Apply "$K8S\tipsbank-web\web-deployment.yaml"
ApplyIngress "$K8S\tipsbank-web\ingress-app.yaml"
Apply "$K8S\tipsbank-web\netpol.yaml"

# [6/8] monitoring + locust
Write-Host "`n[6/8] monitoring + locust" -ForegroundColor Cyan
Apply "$K8S\tipsbank-monitoring\daemonset-node-logger.yaml"
Apply "$K8S\locust\locust-deployment.yaml"
ApplyIngress "$K8S\locust\locust-ingress.yaml"

# [7/8] RBAC
Write-Host "`n[7/8] RBAC" -ForegroundColor Cyan
Apply "$K8S\rbac\serviceaccounts.yaml"
Apply "$K8S\rbac\roles.yaml"
Apply "$K8S\rbac\clusterroles.yaml"
Apply "$K8S\rbac\rolebindings.yaml"
Apply "$K8S\rbac\clusterrolebindings.yaml"

Write-Host ""
Write-Host "[8/8] Certificados X.509 (manual)" -ForegroundColor Cyan
Write-Host "  Execute: .\scripts\gerar-certificados.ps1" -ForegroundColor DarkGray
Write-Host "  Kubeconfigs gerados em: evidencias\kubeconfigs\" -ForegroundColor DarkGray

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host " Deploy concluido  [env: $Env | mode: direct]" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
kubectl get pods -A --no-headers | Select-String "tipsbank"

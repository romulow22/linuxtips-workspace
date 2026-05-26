# gerar-certificados.ps1
# Gera kubeconfigs para os 4 perfis RBAC do TipsBank.
#
# Modo automatico:
#   EKS (aws://...)  -> ServiceAccount tokens (EKS nao assina CSRs de usuario)
#   kubeadm/vagrant  -> Certificados X.509 via CSR API
#
# Pre-requisito (modo kubeadm): openssl no PATH (vem com Git for Windows)
# Pre-requisito (modo EKS):     kubectl apply -f k8s/rbac/  ja executado
#
# Execute a partir da raiz do projeto (semana-4):
#   .\scripts\gerar-certificados.ps1
#
# Saida:
#   evidencias\kubeconfigs\operador-contas.kubeconfig
#   evidencias\kubeconfigs\operador-transacoes.kubeconfig
#   evidencias\kubeconfigs\auditor-global.kubeconfig
#   evidencias\kubeconfigs\sre.kubeconfig
#   evidencias\kubeconfigs\certs\  <-- chaves privadas (modo kubeadm), nao commitar!

$ErrorActionPreference = "Stop"

$ROOT      = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$CERTS_DIR = "$ROOT\evidencias\kubeconfigs\certs"
$KUBE_DIR  = "$ROOT\evidencias\kubeconfigs"

New-Item -ItemType Directory -Force -Path $CERTS_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $KUBE_DIR  | Out-Null

# Garante que chaves privadas nao entrem no git
$gitignore = "$ROOT\.gitignore"
if (Test-Path $gitignore) {
    $content = Get-Content $gitignore -Raw
    if ($content -notmatch "evidencias/kubeconfigs/certs") {
        Add-Content $gitignore "`nevidencias/kubeconfigs/certs/"
        Write-Host ".gitignore atualizado: evidencias/kubeconfigs/certs/ ignorado" -ForegroundColor DarkGray
    }
}

# Informacoes do cluster
$CLUSTER_SERVER = kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
$CLUSTER_NAME   = kubectl config view --minify -o jsonpath='{.clusters[0].name}'
Write-Host "Cluster: $CLUSTER_NAME ($CLUSTER_SERVER)" -ForegroundColor Cyan

# Detectar ambiente
$providerID = kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>$null
$isEKS      = $providerID -match "^aws://"
$modeLabel  = if ($isEKS) { "EKS (SA tokens)" } else { "kubeadm (X.509)" }
Write-Host "Modo:    $modeLabel" -ForegroundColor Cyan
Write-Host ""

# Extrair CA do cluster uma vez (usada por ambos os modos)
# Kubeconfigs gerados com insecure-skip-tls-verify (ex: kubeadm-local via vagrant)
# nao embitem certificate-authority-data — nesse caso busca o CA do cluster diretamente.
$caBase64 = kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
if ($caBase64) {
    $caBytes = [Convert]::FromBase64String($caBase64)
} else {
    Write-Host "  certificate-authority-data ausente no kubeconfig; obtendo CA do cluster..." -ForegroundColor DarkGray
    $caPemLines = kubectl get configmap kube-root-ca.crt -n kube-public -o jsonpath='{.data.ca\.crt}' 2>$null
    if (-not $caPemLines) { throw "Nao foi possivel obter o CA do cluster (kube-root-ca.crt)." }
    # Normaliza CRLF -> LF para que o PEM seja parseado corretamente em todos os SO
    $caPem = ($caPemLines -join "`n").TrimEnd() + "`n"
    $caBytes = [System.Text.Encoding]::UTF8.GetBytes($caPem)
}
$CA_FILE = [IO.Path]::GetTempFileName()
[IO.File]::WriteAllBytes($CA_FILE, $caBytes)

# ---------------------------------------------------------------
# Helper: montar kubeconfig a partir de credenciais ja prontas
# ---------------------------------------------------------------
function MontarKubeconfig([string]$Name, [hashtable]$CredArgs) {
    $kubeconfigFile = "$KUBE_DIR\$Name.kubeconfig"

    kubectl config set-cluster $CLUSTER_NAME `
        --server=$CLUSTER_SERVER `
        --certificate-authority=$CA_FILE `
        --embed-certs=true `
        --kubeconfig=$kubeconfigFile
    if ($LASTEXITCODE -ne 0) { throw "set-cluster falhou para $Name" }

    $credCmd = @("config", "set-credentials", $Name, "--kubeconfig=$kubeconfigFile")
    foreach ($k in $CredArgs.Keys) { $credCmd += "$k=$($CredArgs[$k])" }
    & kubectl @credCmd
    if ($LASTEXITCODE -ne 0) { throw "set-credentials falhou para $Name" }

    kubectl config set-context "${Name}@${CLUSTER_NAME}" `
        --cluster=$CLUSTER_NAME `
        --user=$Name `
        --kubeconfig=$kubeconfigFile
    kubectl config use-context "${Name}@${CLUSTER_NAME}" `
        --kubeconfig=$kubeconfigFile

    Write-Host "   Kubeconfig: $kubeconfigFile" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------
# Modo EKS: ServiceAccount token (nao-expirante via Secret)
# ---------------------------------------------------------------
function CriarKubeconfigToken([string]$Name, [string]$SAName, [string]$SANamespace) {
    Write-Host ">>> Kubeconfig SA-token para: $Name" -ForegroundColor Green

    # Criar Secret de token estatico (nao expira, diferente de kubectl create token)
    $secretName = "${SAName}-kubeconfig-token"
    $secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $secretName
  namespace: $SANamespace
  annotations:
    kubernetes.io/service-account.name: $SAName
type: kubernetes.io/service-account-token
"@
    $secretYaml | kubectl apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Criacao do Secret token falhou para $Name" }

    # Aguardar token ser populado pelo controller (normalmente < 5s)
    Write-Host "   Aguardando token..." -ForegroundColor DarkGray
    $token = $null
    for ($i = 1; $i -le 15; $i++) {
        $tokenB64 = "$(kubectl get secret $secretName -n $SANamespace -o jsonpath='{.data.token}' 2>$null)".Trim()
        if ($tokenB64) {
            $tokenBytes = [Convert]::FromBase64String($tokenB64)
            $token = [System.Text.Encoding]::UTF8.GetString($tokenBytes)
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $token) { throw "Token para $Name nao disponivel em 30s." }

    Write-Host "   Token obtido (SA: $SAName / ns: $SANamespace)" -ForegroundColor DarkGray
    MontarKubeconfig $Name @{ "--token" = $token }
}

# ---------------------------------------------------------------
# Modo kubeadm: certificado X.509 via CSR API
# ---------------------------------------------------------------
$OPENSSL = $null
if (-not $isEKS) {
    $candidates = @(
        "openssl",
        "$env:ProgramFiles\Git\usr\bin\openssl.exe",
        "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
        "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe",
        "C:\Program Files\Git\usr\bin\openssl.exe",
        "C:\Program Files\Git\mingw64\bin\openssl.exe"
    )
    foreach ($c in $candidates) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { $OPENSSL = $c; break }
    }
    if (-not $OPENSSL) {
        throw "openssl nao encontrado. Instale Git for Windows (https://git-scm.com) ou adicione openssl ao PATH."
    }
    Write-Host "openssl: $OPENSSL" -ForegroundColor DarkGray
}

function CriarUsuario([string]$User, [string]$Group) {
    $keyFile = "$CERTS_DIR\$User.key"
    $csrFile = "$CERTS_DIR\$User.csr"
    $crtFile = "$CERTS_DIR\$User.crt"

    Write-Host ">>> Certificado X.509 para: $User" -ForegroundColor Green

    # 1. Chave privada
    & $OPENSSL genrsa -out $keyFile 2048 2>$null
    if ($LASTEXITCODE -ne 0) { throw "openssl genrsa falhou para $User" }

    # 2. CSR
    & $OPENSSL req -new -key $keyFile -out $csrFile -subj "/CN=$User/O=$Group" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "openssl req falhou para $User" }

    # 3. Encode CSR em base64 (sem quebras de linha)
    $csrBytes  = [IO.File]::ReadAllBytes($csrFile)
    $csrBase64 = [Convert]::ToBase64String($csrBytes)

    # 4. Criar CertificateSigningRequest no Kubernetes
    kubectl delete csr $User --ignore-not-found | Out-Null

    $yaml = @"
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $User
spec:
  request: $csrBase64
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
    - client auth
"@
    $yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply CSR falhou para $User" }

    # 5. Aprovar
    kubectl certificate approve $User
    if ($LASTEXITCODE -ne 0) { throw "kubectl certificate approve falhou para $User" }

    # 6. Aguardar e extrair certificado (ate 90s)
    Write-Host "   Aguardando emissao do certificado..." -ForegroundColor DarkGray
    $cert = $null
    for ($i = 1; $i -le 30; $i++) {
        $cert = "$(kubectl get csr $User -o jsonpath='{.status.certificate}')".Trim()
        if ($cert) { break }
        Write-Host ("   . {0}s" -f ($i * 3)) -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
    }
    if (-not $cert) { throw "Certificado para $User nao foi emitido em 90s." }

    $certBytes = [Convert]::FromBase64String($cert)
    [IO.File]::WriteAllBytes($crtFile, $certBytes)
    Write-Host "   Certificado salvo: $crtFile" -ForegroundColor DarkGray

    MontarKubeconfig $User @{
        "--client-key"         = $keyFile
        "--client-certificate" = $crtFile
        "--embed-certs"        = "true"
    }
}

# ---------------------------------------------------------------
# Criar os 4 usuarios
# ---------------------------------------------------------------
if ($isEKS) {
    CriarKubeconfigToken "operador-contas"     "user-operador-contas"     "tipsbank-contas"
    CriarKubeconfigToken "operador-transacoes" "user-operador-transacoes" "tipsbank-transacoes"
    CriarKubeconfigToken "auditor-global"      "user-auditor-global"      "tipsbank-auditoria"
    CriarKubeconfigToken "sre"                 "user-sre"                 "tipsbank-contas"
} else {
    CriarUsuario "operador-contas"     "tipsbank-ops"
    CriarUsuario "operador-transacoes" "tipsbank-ops"
    CriarUsuario "auditor-global"      "tipsbank-audit"
    CriarUsuario "sre"                 "tipsbank-sre"   # cluster-admin via ClusterRoleBinding by username, nao por grupo
}

# Limpeza
Remove-Item $CA_FILE -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " Kubeconfigs gerados com sucesso! [$modeLabel]" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Kubeconfigs em: $KUBE_DIR\" -ForegroundColor Green
Get-ChildItem "$KUBE_DIR\*.kubeconfig" | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host ""
Write-Host "Verificacao rapida:"
Write-Host "  kubectl --kubeconfig=$KUBE_DIR\operador-contas.kubeconfig get pods -n tipsbank-contas"
Write-Host "  kubectl --kubeconfig=$KUBE_DIR\auditor-global.kubeconfig get pods -A"
Write-Host ""
if ($isEKS) {
    Write-Host "NOTA: Modo EKS -- kubeconfigs usam SA tokens (nao-expirantes)." -ForegroundColor Yellow
    Write-Host "Para X.509 puro, use um cluster kubeadm onde o CA key esta acessivel." -ForegroundColor Yellow
} else {
    Write-Host "IMPORTANTE: $CERTS_DIR\ contem chaves privadas." -ForegroundColor Yellow
    Write-Host "Ja adicionado ao .gitignore. NAO faca commit dessas chaves." -ForegroundColor Yellow
}

# Verifica critério de aceite da etapa 1.6:
#   "Após 100 transferências, a soma das linhas em todos os arquivos
#    bate com o número de eventos disparados"
#
# Uso: .\scripts\verify-etapa-1.6.ps1
# Pré-requisito: NFS montado, PVC Bound, pods auditoria Running 3/3

$ORIGEM  = "11111111-1111-1111-1111-111111111111"  # Jeferson Fernando (saldo: 10000)
$DESTINO = "22222222-2222-2222-2222-222222222222"  # LinuxTips SA
$VALOR   = "1.00"
$N       = 100

# Bloco Python para contar todas as linhas de eventos-*.jsonl
$PY_COUNT = "import glob; lines=[l for f in sorted(glob.glob('/data/eventos-*.jsonl')) for l in open(f).readlines() if l.strip()]; print(len(lines))"

function Count-AuditoriaLines {
    $pods = kubectl get pods -n tipsbank-auditoria -l app=auditoria `
              -o jsonpath='{.items[*].metadata.name}'
    $results = @{}
    foreach ($pod in $pods.Split(' ')) {
        $n = kubectl exec -n tipsbank-auditoria $pod -- python3 -c $PY_COUNT
        $results[$pod] = [int]$n.Trim()
    }
    return $results
}

# ── 1. Contagem ANTES ────────────────────────────────────────────────────────
Write-Host "`n[1/4] Contagem de eventos ANTES das transferências"
$before = Count-AuditoriaLines
foreach ($kv in $before.GetEnumerator()) {
    Write-Host "  $($kv.Key) -> $($kv.Value) linhas"
}
$beforeTotal = ($before.Values | Measure-Object -Sum).Sum / $before.Count
Write-Host "  Baseline: $beforeTotal eventos"

# ── 2. Port-forward api-transacoes ──────────────────────────────────────────
Write-Host "`n[2/4] Abrindo port-forward api-transacoes -> localhost:8081"
$pf = Start-Job -ScriptBlock {
    kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 8081:8080
}
Start-Sleep -Seconds 3

# ── 3. Disparar N transferências ────────────────────────────────────────────
Write-Host "`n[3/4] Disparando $N transferências de R$ $VALOR ..."
$body = @{ origem_id = $ORIGEM; destino_id = $DESTINO; valor = $VALOR } | ConvertTo-Json
$ok   = 0
$fail = 0
for ($i = 1; $i -le $N; $i++) {
    try {
        $resp = Invoke-RestMethod -Method Post `
                    -Uri "http://localhost:8081/transferencias" `
                    -ContentType "application/json" `
                    -Body $body -ErrorAction Stop
        if ($resp.status -eq "concluida") { $ok++ } else { $fail++ }
    } catch {
        $fail++
    }
    if ($i % 10 -eq 0) { Write-Host "  $i/$N concluídas (ok=$ok fail=$fail)" }
}
Write-Host "  Resultado: $ok OK  /  $fail falhas"

Stop-Job $pf -PassThru | Remove-Job

# ── 4. Contagem DEPOIS e verificação ────────────────────────────────────────
Write-Host "`n[4/4] Contagem de eventos DEPOIS das transferências"
Start-Sleep -Seconds 2   # aguarda flush do arquivo no NFS
$after = Count-AuditoriaLines

$allCounts = $after.Values | Select-Object -Unique
$delta     = ($allCounts | Select-Object -First 1) - $beforeTotal

Write-Host ""
foreach ($kv in $after.GetEnumerator()) {
    Write-Host "  $($kv.Key) -> $($kv.Value) linhas"
}
Write-Host ""
if ($allCounts.Count -eq 1) {
    Write-Host "[OK] Todos os pods veem o mesmo arquivo NFS ($($allCounts[0]) linhas)"
} else {
    Write-Host "[ERRO] Pods com contagens diferentes: $($allCounts -join ', ')"
}

if ($delta -eq $ok) {
    Write-Host "[OK] Delta ($delta linhas) == transferências OK ($ok) -- critério satisfeito"
} else {
    Write-Host "[AVISO] Delta=$delta  OK=$ok  Falhas=$fail"
    Write-Host "        (se falhas > 0, saldo insuficiente ou serviço indisponível)"
}

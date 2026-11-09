# bootstrap.ps1
# Reface Argo CD + aplicatia verstapen intr-un cluster Kubernetes gol (Docker Desktop).
# Ruleaza din radacina proiectului:  .\bootstrap.ps1
# Scriptul poate fi rulat de mai multe ori fara probleme.
# (Mesajele sunt fara diacritice, ca PowerShell 5.1 sa nu le strice.)

function Step($text, [scriptblock]$cmd) {
    Write-Host ""
    Write-Host "==> $text" -ForegroundColor Cyan
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "Pasul a esuat: $text" }
}

$ArgoInstall = "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
$AppFile = Join-Path $PSScriptRoot "argocd\application.yaml"

if (-not (Test-Path $AppFile)) {
    throw "Nu gasesc $AppFile. Ruleaza scriptul din radacina proiectului (dupa git pull)."
}

Step "Folosesc contextul docker-desktop" { kubectl config use-context docker-desktop }
Step "Verific ca nodul este Ready" { kubectl wait --for=condition=Ready node/docker-desktop --timeout=120s }

Step "Creez namespace-ul argocd (daca lipseste)" {
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
}
Step "Instalez Argo CD" {
    kubectl apply -n argocd --server-side --force-conflicts -f $ArgoInstall
}
Step "Opresc dex si notifications (economisesc resurse)" {
    kubectl scale deployment argocd-dex-server argocd-notifications-controller -n argocd --replicas=0
}

Step "Astept CRD-ul Application" {
    kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
}
Step "Astept argocd-redis" {
    kubectl rollout status deployment/argocd-redis -n argocd --timeout=300s
}
Step "Astept argocd-repo-server" {
    kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
}
Step "Astept argocd-server" {
    kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
}
Step "Astept argocd-application-controller" {
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
}

Step "Aplic aplicatia verstapen (Argo preia restul din Git)" {
    kubectl apply -f $AppFile
}

Write-Host ""
Write-Host "==> Astept sincronizarea aplicatiei (maxim 5 minute)" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 10
    $sync   = kubectl get application verstapen -n argocd -o jsonpath="{.status.sync.status}" 2>$null
    $health = kubectl get application verstapen -n argocd -o jsonpath="{.status.health.status}" 2>$null
    Write-Host "    sync=$sync  health=$health"
} while (-not ($sync -eq "Synced" -and $health -eq "Healthy") -and (Get-Date) -lt $deadline)

Write-Host ""
if ($sync -eq "Synced" -and $health -eq "Healthy") {
    Write-Host "Gata: aplicatia este Synced si Healthy. Site: http://localhost:8080" -ForegroundColor Green
} else {
    Write-Host "Aplicatia nu este inca Synced/Healthy. Verifica: kubectl get applications -n argocd" -ForegroundColor Yellow
}

$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>$null
if ($b64) {
    $pass = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
    Write-Host ""
    Write-Host "Interfata Argo: ruleaza  kubectl port-forward svc/argocd-server -n argocd 8443:443"
    Write-Host "apoi deschide https://localhost:8443"
    Write-Host "Utilizator: admin   Parola initiala: $pass"
    Write-Host "(Parola e doar pentru clusterul tau local. Schimb-o din User Info si nu o distribui.)"
}

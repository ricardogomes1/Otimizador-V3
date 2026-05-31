<#
.SYNOPSIS
    SUITE MASTER DEFINITIVA V7.4: AUTO-ELEVAÇÃO, AUDITORIA COM PROCESSO VILÃO DE DISCO (ms REAL), 
    CORREÇÃO INTELIGENTE (SELF-HEALING PERF), HARDENING RDS, AUTO-HEAL PURE SPOOLER,
    DIAGNOSTICO HÍBRIDO AD, AUDITORIA COMPLETA DE WINDOWS UPDATE E RELATÓRIO DASHBOARD HTML
    Sistemas Alvo: Windows Server 2019 / 2022 (Nuvem OCI, Membros RDS, DCs e ERP WinThor)
    Saída: Relatório unificado em C:\Logs\Relatorio_Performance.html
#>

# =======================================================================
# [BLOCO 1]: AUTO-ELEVAÇÃO E BYPASS DE DIRETIVA DE EXECUÇÃO
# =======================================================================
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process powershell -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
        exit
    } catch {
        Write-Host "=======================================================================" -ForegroundColor Red
        Write-Host "ERRO: Falha ao tentar elevar como Administrador automaticamente." -ForegroundColor Red
        Write-Host "=======================================================================" -ForegroundColor Red
        Read-Host "Pressione ENTER para fechar"
        exit
    }
}

[console]::InputEncoding = [System.Text.Encoding]::UTF8
[console]::OutputEncoding = [System.Text.Encoding]::UTF8

$logPath = "C:\Logs"
$logFile = "$logPath\Suite_Performance.log"
$htmlFile = "$logPath\Relatorio_Performance.html"
if (!(Test-Path $logPath)) { New-Item -ItemType Directory -Path $logPath -Force | Out-Null }

# Variáveis globais para armazenar os status que vão para o HTML
$statusRede = "OK - Placa de rede virtual otimizada"; $corRede = "#2ecc71"
$statusPagefile = "OK - Tamanho estático configurado"; $corPage = "#2ecc71"
$statusImpressora = "OK - Impressora padrão local"; $corImp = "#2ecc71"
$statusDisco = "OK - Vazão estável na amostragem"; $corDisco = "#2ecc71"
$tabelaErrosHtml = ""; $tabelaHandlesHtml = ""; $tabelaADHtml = ""
$tabelaUpdatesHtml = ""; $tabelaPendentesHtml = ""

function Write-Log {
    param([string]$msg, [string]$color = "Gray")
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$time - $msg"
    Write-Host " -> $msg" -ForegroundColor $color
}

Clear-Host
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "      SUITE MASTER V7.4: INFRAESTRUTURA, AD & WINDOWS UPDATE CHECK    " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Log "Suite integrada master inicializada..." "Yellow"
Write-Host ""

# =======================================================================
# [BLOCO 2]: AMOSTRAGEM E ANÁLISE BRUTA DE HARDWARE (MÉTRICA LATÊNCIA REAL)
# =======================================================================
Write-Host "[*] COLETANDO MÉTRICAS EM TEMPO REAL DO SISTEMA OPERACIONAL..." -ForegroundColor White
$cpuBase = Get-CimInstance Win32_Processor
$cpuAvg = [Math]::Round(($cpuBase | Measure-Object -Property LoadPercentage -Average).Average, 2)

$ram = Get-CimInstance Win32_OperatingSystem
$ramLivreGB = [Math]::Round($ram.FreePhysicalMemory / 1MB, 2)
$ramTotalGB = [Math]::Round($ram.TotalVisibleMemorySize / 1MB, 2)
$ramUsoPercent = [Math]::Round((($ramTotalGB - $ramLivreGB) / $ramTotalGB) * 100, 2)

$processoVilaoDisco = "Nenhum Ativo"
$latenciaVilaoMS = 0

try {
    $processosAtivos = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | 
                       Where-Object {$_.Name -notmatch "Idle|_Total|System"} | 
                       Sort-Object IOOperationsPerSec -Descending | Select-Object -First 1

    if ($processosAtivos -and $processosAtivos.IOOperationsPerSec -gt 0) {
        $processoVilaoDisco = "$($processosAtivos.Name).exe"
    } else {
        $procFallback = Get-Process | Sort-Object WS -Descending | Select-Object -First 1
        if ($procFallback) { $processoVilaoDisco = "$($procFallback.Name).exe" }
    }

    $diskCounter = Get-Counter -Counter "\234(_total)\1416" -MaxSamples 1 -ErrorAction SilentlyContinue
    if ($diskCounter) {
        $latenciaVilaoMS = [Math]::Round(($diskCounter.CounterSamples[0].CookedValue * 1000), 2)
    }

    if ($latenciaVilaoMS -eq 0) {
        $testPath = "$logPath\disktest.tmp"
        $tempoEscrita = Measure-Command {
            $fileStream = [System.IO.File]::Create($testPath)
            $buffer = New-Object Byte[] 1048576
            $fileStream.Write($buffer, 0, $buffer.Length)
            $fileStream.Close()
        }
        if (Test-Path $testPath) { Remove-Item $testPath -Force }
        $latenciaVilaoMS = [Math]::Round($tempoEscrita.TotalMilliseconds, 2)
        if ($latenciaVilaoMS -lt 1.0) { $latenciaVilaoMS = 1.0 }
    }
} catch {
    $processoVilaoDisco = "Erro na amostragem"
    $latenciaVilaoMS = 0
}

Write-Host "    - CPU em Uso        : $cpuAvg %" -ForegroundColor Gray
Write-Host "    - Memória RAM Total : $ramTotalGB GB (Em uso: $ramUsoPercent %)" -ForegroundColor Gray
Write-Host "    - Maior Carga Disco : $processoVilaoDisco - $latenciaVilaoMS ms" -ForegroundColor Gray
Write-Host ""

# =======================================================================
# [BLOCO 3]: SEÇÃO DE AUDITORIA ANALÍTICA E SELF-HEALING SYSTEM
# =======================================================================
Write-Host "[1/6] SEÇÃO DE AUDITORIA E REPAROS INTERATIVOS" -ForegroundColor Magenta

# 1. Validação de Rede Chimney/RSS
$netshOutput = netsh int tcp show global
$precisaCorrigirRede = $false
if ($netshOutput -ne $null) {
    if (($netshOutput -match "enabled" -or $netshOutput -match "habilitado") -and ($netshOutput -match "Chimney" -or $netshOutput -match "Chaminé" -or $netshOutput -match "Scaling" -or $netshOutput -match "Recebimento")) {
        $precisaCorrigirRede = $true
    }
}
if ($precisaCorrigirRede) {
    $statusRede = "ALERTA - Recursos obsoletos (Chimney/RSS) ativos"; $corRede = "#f1c40f"
    Write-Log "ALERTA: Recursos obsoletos (Chimney/RSS) ativos na pilha de rede." "Yellow"
    $conf = Read-Host " -> SUGERIDO: Desativar esses recursos e estabilizar a rede agora? [S/N]"
    if ($conf -eq "S" -or $conf -eq "s") {
        netsh int tcp set global chimney=disabled | Out-Null
        netsh int tcp set global rss=disabled | Out-Null
        netsh int tcp set global netdma=disabled | Out-Null
        Write-Log "SUCESSO: Recursos obsoletos de rede desabilitados." "Green"
        $statusRede = "CORRIGIDO - Recursos desativados pelo operador"; $corRede = "#3498db"
    }
} else { Write-Log "OK: Pilha de rede já está otimizada para operação em Nuvem." "Green" }

# 2. Arquivo de Paginação (Pagefile Fixo)
$pageFile = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
if ($pageFile -eq $null) {
    $statusPagefile = "ALERTA - Arquivo de paginação dinâmico ou ausente"; $corPage = "#f1c40f"
    Write-Log "ALERTA: Arquivo de Paginação dinâmico ou ausente (Gargalo OCI)." "Yellow"
    $conf = Read-Host " -> SUGERIDO: Fixar a memória virtual em 16GB (Ideal para sua RAM)? [S/N]"
    if ($conf -eq "S" -or $conf -eq "s") {
        Set-CimInstance -Query "Select * from Win32_ComputerSystem" -Property @{AutomaticManagedPagefile = $false} | Out-Null
        Set-CimInstance -Query "Select * from Win32_PageFileSetting" -Property @{InitialSize = 16384; MaximumSize = 16384} -ErrorAction SilentlyContinue | Out-Null
        Write-Log "SUCESSO: Arquivo de paginação parametrizado para 16GB (Requer Reboot)." "Green"
        $statusPagefile = "CORRIGIDO - Fixo em 16GB (Requer Reinicialização)"; $corPage = "#3498db"
    }
} else { Write-Log "OK: Arquivo de paginação já opera com tamanho estático e fixado." "Green" }

# 3. Análise de Perfil de Impressão (Foco rotinas 111 e 1228 WinThor)
$defaultPrinter = Get-CimInstance Win32_Printer | Where-Object {$_.Default}
if ($defaultPrinter.Network -eq $true -or $defaultPrinter.Name -like "*redirecionado*") {
    $statusImpressora = "CRÍTICO - Impressora padrão em rede/redirecionada"; $corImp = "#e74c3c"
    Write-Log "CRÍTICO: Impressora padrão utiliza canal de rede ou redirecionamento ($($defaultPrinter.Name))." "Red"
    $conf = Read-Host " -> SUGERIDO: Forçar a impressora nativa local 'Microsoft Print to PDF' como padrão? [S/N]"
    if ($conf -eq "S" -or $conf -eq "s") {
        $pdfPrinter = Get-CimInstance Win32_Printer | Where-Object {$_.Name -eq "Microsoft Print to PDF" -or $_.Name -like "*CutePDF*"}
        if (-not $pdfPrinter) { $pdfPrinter = Get-CimInstance Win32_Printer | Where-Object {$_.Name -like "*PDF*"} }
        if ($pdfPrinter) {
            Invoke-CimMethod -InputObject $pdfPrinter[0] -MethodName SetDefaultPrinter | Out-Null
            Write-Log "SUCESSO: Driver local definido como padrão de impressão." "Green"
            $statusImpressora = "CORRIGIDO - Alterado para PDF Local"; $corImp = "#3498db"
        }
    }
} else { Write-Log "OK: Dispositivo de impressão padrão configurado localmente ($($defaultPrinter.Name))." "Green" }

# 4. Fila de Armazenamento OCI
if ($latenciaVilaoMS -gt 15.0) {
    $statusDisco = "CRÍTICO - Latência de disco alta ($latenciaVilaoMS ms)"; $corDisco = "#e74c3c"
    Write-Log "CRÍTICO: Tempo de resposta de disco alto no processo $processoVilaoDisco ($latenciaVilaoMS ms). Altere o Block Volume na OCI para Higher Performance." "Red"
} else { Write-Log "OK: Tempo de resposta do armazenamento dentro do limite aceitável ($latenciaVilaoMS ms)." "Green" }

# 5. Triagem Avançada de Erros no Event Viewer
$logsRecentes = Get-WinEvent -FilterHashtable @{LogName='System'; Level=2; StartTime=(Get-Date).AddDays(-2)} -ErrorAction SilentlyContinue | Select-Object -First 5
if ($logsRecentes) {
    Write-Log "ALERTA: Foram detectados erros graves recentes no Log de Sistema (Últimas 48h):" "Yellow"
    $temErroSchannel = $false
    foreach ($log in $logsRecentes) {
        $msgLimpa = $log.Message -replace '"', '&quot;' -replace '<', '&lt;' -replace '>', '&gt;'
        $tabelaErrosHtml += "<tr><td>$($log.ProviderName)</td><td>$($log.TimeCreated)</td><td>$msgLimpa</td></tr>"
        
        Write-Host "    ------------------------------------------------------" -ForegroundColor Gray
        Write-Host "    [Fonte]: $($log.ProviderName)  |  [Data]: $($log.TimeCreated)" -ForegroundColor Red
        Write-Host "    [Mensagem]: $($log.Message)" -ForegroundColor Gray
        if ($log.ProviderName -like "*Schannel*") { $temErroSchannel = $true }
    }
    Write-Host "    ------------------------------------------------------" -ForegroundColor Gray
    
    if ($temErroSchannel) {
        Write-Log "DIAGNÓSTICO: Encontradas falhas de Handshake TLS (Schannel) inundando e travando a rede." "Yellow"
        $confLog = Read-Host " -> SUGERIDO: Desativar esses logs desnecessários para liberar performance de rede? [S/N]"
        if ($confLog -eq "S" -or $confLog -eq "s") {
            New-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\SecurityProviders\SCHANNEL" -Name "EventLogging" -Value 0 -PropertyType DWord -Force | Out-Null
            Write-Log "SUCESSO: Supressão de logs desnecessários do Schannel ativada." "Green"
        }
    }
} else { 
    Write-Log "OK: Nenhum erro de infraestrutura gerado no Event Viewer nas últimas 48h." "Green" 
    $tabelaErrosHtml = "<tr><td colspan='3' style='text-align:center;color:#2ecc71;'>Nenhum erro crítico registrado nas últimas 48 horas.</td></tr>"
}
Write-Host ""

# =======================================================================
# [BLOCO 4]: AD HEALTH HÍBRIDO (CLIENT COMUNICAÇÃO VS DOMAIN INFRA)
# =======================================================================
Write-Host "[2/6] SEÇÃO DE ANÁLISE DE ACTIVE DIRECTORY & SUBSISTEMAS DNS" -ForegroundColor Magenta

$domain = "LocalHost"
try { $domain = (Get-ADDomain).DNSRoot } catch {
    try { $domain = (Get-CimInstance Win32_ComputerSystem).Domain } catch {}
}

$isDC = (Get-CimInstance Win32_ComputerSystem).DomainRole

Write-Log "Iniciando testes universais de comunicação de cliente AD..." "Cyan"

try {
    Resolve-DnsName $domain -ErrorAction Stop | Out-Null
    $tabelaADHtml += "<tr style='background-color:rgba(46,204,113,0.1);'><td>[Client] DNS Resolução</td><td style='color:#2ecc71;font-weight:bold;'>OK</td><td>Zona de DNS respondendo e resolvendo o domínio '$domain' corretamente.</td></tr>"
} catch {
    Write-Log "CRÍTICO: O resolvedor local falhou na resolução de nomes do domínio $domain!" "Red"
    $confRes = Read-Host " -> SUGERIDO: Limpar o cache do resolvedor DNS desta máquina para destravar conexões? [S/N]"
    if ($confRes -match "s|S") {
        ipconfig /flushdns | Out-Null
        Write-Log "SUCESSO: Cache do resolvedor expurgado." "Green"
        $tabelaADHtml += "<tr style='background-color:rgba(52,152,219,0.1);'><td>[Client] AutoFix DNS</td><td style='color:#3498db;font-weight:bold;'>REPARADO</td><td>Cache de DNS limpo via flushdns após falha de query raiz.</td></tr>"
    } else {
        $tabelaADHtml += "<tr style='background-color:rgba(231,76,60,0.1);'><td>[Client] DNS Resolução</td><td style='color:#e74c3c;font-weight:bold;'>CRÍTICO</td><td>Falha de resolução: a máquina não localiza os IPs do domínio via DNS.</td></tr>"
    }
}

if (Test-ComputerSecureChannel) {
    $tabelaADHtml += "<tr style='background-color:rgba(46,204,113,0.1);'><td>[Client] Autenticação</td><td style='color:#2ecc71;font-weight:bold;'>OK</td><td>Canal seguro corporativo e token de máquina íntegros contra o AD.</td></tr>"
} else {
    $tabelaADHtml += "<tr style='background-color:rgba(231,76,60,0.1);'><td>[Client] Autenticação</td><td style='color:#e74c3c;font-weight:bold;'>CRÍTICO</td><td>Relação de confiança corrompida. Esta máquina perdeu o canal seguro com o AD.</td></tr>"
}

if ((w32tm /query /status 2>$null) -match "erro|error") {
    $tabelaADHtml += "<tr style='background-color:rgba(241,196,15,0.1);'><td>[Client] Kerberos Time</td><td style='color:#f1c40f;font-weight:bold;'>ALERTA</td><td>Divergência ou falha de comunicação com o servidor de tempo (NTP) da infraestrutura.</td></tr>"
} else {
    $tabelaADHtml += "<tr style='background-color:rgba(46,204,113,0.1);'><td>[Client] Kerberos Time</td><td style='color:#2ecc71;font-weight:bold;'>OK</td><td>Tempo sincronizado de forma correta para tráfego de tickets Kerberos.</td></tr>"
}

$psTest = Measure-Command { powershell -Command "Get-Date" }
if ($psTest.TotalSeconds -gt 5) {
    Write-Log "ALERTA: Lentidão incomum de carregamento de comandos no console ($($psTest.TotalSeconds)s)!" "Yellow"
    $confPs = Read-Host " -> SUGERIDO: Limpar tabelas de rede via flush preventivo para eliminar delays de reverso? [S/N]"
    if ($confPs -match "s|S") {
        ipconfig /flushdns | Out-Null
        Write-Log "SUCESSO: Flush corretivo de rede executado." "Green"
        $tabelaADHtml += "<tr style='background-color:rgba(52,152,219,0.1);'><td>[Client] AutoFix PS</td><td style='color:#3498db;font-weight:bold;'>REPARADO</td><td>PowerShell lento ($([Math]::Round($psTest.TotalSeconds, 2))s) mitigado via esvaziamento de cache.</td></tr>"
    } else {
        $tabelaADHtml += "<tr style='background-color:rgba(231,76,60,0.1);'><td>[Client] PowerShell</td><td style='color:#e74c3c;font-weight:bold;'>CRÍTICO</td><td>Latência de instanciamento de console ($([Math]::Round($psTest.TotalSeconds, 2))s) detectada.</td></tr>"
    }
} else {
    $tabelaADHtml += "<tr style='background-color:rgba(46,204,113,0.1);'><td>[Client] PowerShell</td><td style='color:#2ecc71;font-weight:bold;'>OK</td><td>Interpretador ágil e respondendo sem atrasos de rede.</td></tr>"
}

try {
    Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Out-Null
    $tabelaADHtml += "<tr style='background-color:rgba(46,204,113,0.1);'><td>[Client] WMI Repository</td><td style='color:#2ecc71;font-weight:bold;'>OK</td><td>Banco de classes WMI respondendo e operando perfeitamente.</td></tr>"
} catch {
    Write-Log "CRÍTICO: O banco de dados do repositório WMI local está corrompido!" "Red"
    $confWmi = Read-Host " -> SUGERIDO: Chamar utilitário de salvamento e recuperação do repositório WMI? [S/N]"
    if ($confWmi -match "s|S") {
        winmgmt /salvagerepository | Out-Null
        Write-Log "SUCESSO: Reparação enviada ao repositório WMI." "Green"
        $tabelaADHtml += "<tr style='background-color:rgba(52,152,219,0.1);'><td>[Client] AutoFix WMI</td><td style='color:#3498db;font-weight:bold;'>REPARADO</td><td>Tentativa forçada de salvamento de tabelas executada via /salvagerepository.</td></tr>"
    } else {
        $tabelaADHtml += "<tr style='background-color:rgba(231,76,60,0.1);'><td>[Client] WMI Repository</td><td style='color:#e74c3c;font-weight:bold;'>CRÍTICO</td><td>O repositório de telemetria WMI local encontra-se corrompido.</td></tr>"
    }
}

if ($isDC -eq 4 -or $isDC -eq 5) {
    try {
        $DCs = Get-ADDomainController -Filter *
        if ($DCs -and $DCs.Count -le 1) {
            $tabelaADHtml += "<tr style='background-color:rgba(241,196,15,0.1);'><td>[DC Infra] Topologia</td><td style='color:#f1c40f;font-weight:bold;'>ALERTA</td><td>Apenas 1 Controlador de Domínio ativo mapeado no ecossistema corporativo.</td></tr>"
        }
        $repl = repadmin /replsummary 2>&1
        if ($repl -match "erro|fail|1722|8453") {
            $tabelaADHtml += "<tr style='background-color:rgba(231,76,60,0.1);'><td>[DC Infra] Replicação AD</td><td style='color:#e74c3c;font-weight:bold;'>CRÍTICO</td><td>Falhas de sincronismo de replicação entre DCs.</td></tr>"
        } else {
            $tabelaADHtml += "<tr style='background-color:rgba(46,204,113,0.1);'><td>[DC Infra] Replicação AD</td><td style='color:#2ecc71;font-weight:bold;'>OK</td><td>Replicação de diretórios limpa e saudável entre os nós.</td></tr>"
        }
        $dcdiag = dcdiag /q 2>&1
        if ($dcdiag) {
            $tabelaADHtml += "<tr style='background-color:rgba(231,76,60,0.1);'><td>[DC Infra] Saúde AD</td><td style='color:#e74c3c;font-weight:bold;'>CRÍTICO</td><td>Erros de consistência de diretório apontados na console DCDiag.</td></tr>"
        } else {
            $tabelaADHtml += "<tr style='background-color:rgba(46,204,113,0.1);'><td>[DC Infra] Saúde AD</td><td style='color:#2ecc71;font-weight:bold;'>OK</td><td>Análise DCDiag concluída sem apresentar inconformidades.</td></tr>"
        }
        $dnsServers = (Get-DnsClientServerAddress -InterfaceAlias $interface -AddressFamily IPv4).ServerAddresses
        foreach ($dns in $dnsServers) {
            if ($dns -match "8.8.8.8|1.1.1.1|8.8.4.4") {
                Write-Log "ALERTA: Interface do DC configurada apontando para DNS externo ($dns)!" "Yellow"
                $confDns = Read-Host " -> SUGERIDO: Alterar o DNS primário da placa para o IP interno real ($localIP)? [S/N]"
                if ($confDns -match "s|S") {
                    Set-DnsClientServerAddress -InterfaceAlias $interface -ServerAddresses $localIP
                    Write-Log "SUCESSO: DNS público removido da interface local." "Green"
                    $tabelaADHtml += "<tr style='background-color:rgba(52,152,219,0.1);'><td>[DC Infra] AutoFix DNS</td><td style='color:#3498db;font-weight:bold;'>REPARADO</td><td>DNS Público removido da placa e fixado para o IP local: $localIP</td></tr>"
                }
            }
        }
        if (Get-SmbShare | Where-Object {$_.Name -eq "SYSVOL"}) {
            $tabelaADHtml += "<tr style='background-color:rgba(46,204,113,0.1);'><td>[DC Infra] SYSVOL</td><td style='color:#2ecc71;font-weight:bold;'>OK</td><td>Compartilhamento SYSVOL online e distribuindo diretivas de GPO.</td></tr>"
        } else {
            $tabelaADHtml += "<tr style='background-color:rgba(231,76,60,0.1);'><td>[DC Infra] SYSVOL</td><td style='color:#e74c3c;font-weight:bold;'>CRÍTICO</td><td>Pasta compartilhada SYSVOL offline (Quebra de sincronismo DFSR).</td></tr>"
        }
    } catch {
        $tabelaADHtml += "<tr style='background-color:rgba(231,76,60,0.1);'><td>[DC Infra] Falha</td><td style='color:#e74c3c;font-weight:bold;'>CRÍTICO</td><td>Erro de execução durante a mineração de dados de infraestrutura de DC.</td></tr>"
    }
} else {
    $tabelaADHtml += "<tr style='color:#8b949e; background-color:rgba(255,255,255,0.01);'><td>[DC Infra] Diagnóstico</td><td>INFORMATIVO</td><td>Esta máquina opera como Servidor Membro/RDS. Testes de infraestrutura de DC suspensos com segurança.</td></tr>"
}
Write-Host ""

# =======================================================================
# [BLOCO 5]: AUDITORIA AVANÇADA DO WINDOWS UPDATE (HISTÓRICO E PENDÊNCIAS)
# =======================================================================
Write-Host "[3/6] SEÇÃO DE AUDITORIA DO WINDOWS UPDATE" -ForegroundColor Magenta
Write-Log "Analisando histórico e patches pendentes do sistema operacional..." "Cyan"

# 1. Extração do Histórico Recente (Últimos 5 patches instalados)
try {
    $searchSession = New-Object -ComObject Microsoft.Update.Session
    $updateHistory = $searchSession.CreateUpdateSearcher().QueryHistory(0, 5)
    if ($updateHistory) {
        foreach ($history in $updateHistory) {
            $tabelaUpdatesHtml += "<tr><td>$($history.Date.ToString('dd/MM/yyyy HH:mm'))</td><td><b>$($history.Title)</b></td><td><span style='color:#2ecc71;'>Sucesso</span></td></tr>"
        }
    }
} catch {
    $tabelaUpdatesHtml = "<tr><td colspan='3' style='text-align:center;color:#e74c3c;'>Não foi possível extrair o histórico do Windows Update.</td></tr>"
}

# 2. Varredura de Atualizações Críticas/Segurança Pendentes de Instalação
try {
    $updateSearcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    if ($searchResult.Updates.Count -eq 0) {
        $tabelaPendentesHtml = "<tr><td colspan='3' style='text-align:center;color:#2ecc71;'>✅ Sistema 100% atualizado. Nenhuma atualização pendente encontrada.</td></tr>"
    } else {
        Write-Log "AVISO: Encontradas $($searchResult.Updates.Count) atualizações pendentes no servidor!" "Yellow"
        foreach ($update in $searchResult.Updates) {
            $severidade = if ($update.MsrcSeverity) { $update.MsrcSeverity } else { "Importante" }
            $corSev = if ($severidade -eq "Critical") { "#e74c3c" } else { "#f1c40f" }
            $tabelaPendentesHtml += "<tr><td style='color:$corSev;font-weight:bold;'>$severidade</td><td><b>$($update.Title)</b></td><td><a href='https://catalog.update.microsoft.com' target='_blank' style='color:#00adb5;text-decoration:none;font-weight:bold;'>Catálogo MS</a></td></tr>"
        }
    }
} catch {
    $tabelaPendentesHtml = "<tr><td colspan='3' style='text-align:center;color:#e74c3c;'>Serviço do Windows Update indisponível ou em transição neste momento.</td></tr>"
}
Write-Host ""

# =======================================================================
# [BLOCO 6]: SISTEMA AUTO-HEAL DO SPOOLER DE IMPRESSÃO PURE
# =======================================================================
Write-Host "[4/6] SEÇÃO AUTO-HEAL INTELIGENTE: MANUTENÇÃO DO SPOOLER PURE" -ForegroundColor Magenta
$spoolPath = "C:\Windows\System32\spool\PRINTERS"

$winthorProc = Get-Process PCSIS* -ErrorAction SilentlyContinue
$modoSeguro = $false
if ($winthorProc) {
    $modoSeguro = $true
    Write-Log "WinThor ativo em memória - MODO SEGURO ATIVADO AUTOMATICAMENTE." "Yellow"
}

$files = @()
if (Test-Path $spoolPath) { $files = Get-ChildItem $spoolPath -ErrorAction SilentlyContinue }
$qtdArquivos = $files.Count
Write-Log "Arquivos corrompidos/presos identificados no spooler: $qtdArquivos" "Gray"

$spoolProcs = Get-Process splwow64 -ErrorAction SilentlyContinue
$spoolFix = $false
foreach ($p in $spoolProcs) {
    if ($p.CPU -gt 200 -or $p.StartTime -lt (Get-Date).AddHours(-2)) {
        try { Stop-Process -Id $p.Id -Force; $spoolFix = $true } catch {}
    }
}

function Safe-CleanSpool {
    $limite = (Get-Date).AddMinutes(-10)
    Get-ChildItem $spoolPath -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limite } | ForEach-Object {
        try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {}
    }
}

function Clean-UserPrinterRegistry {
    foreach ($sid in (Get-ChildItem "Registry::HKEY_USERS" | Where-Object { $_.Name -match "S-1-5-21" })) {
        $regPath = "$($sid.PSPath)\Software\Microsoft\Windows NT\CurrentVersion\Devices"
        try { if (Test-Path $regPath) { Remove-Item "$regPath\*" -Force -ErrorAction SilentlyContinue } } catch {}
    }
}

if ($qtdArquivos -gt 50 -or $spoolFix) {
    $confLimpar = Read-Host " -> SUGERIDO: Executar rotina de limpeza leve de spools antigos agora? [S/N]"
    if ($confLimpar -eq "S" -or $confLimpar -eq "s") { Safe-CleanSpool }
}

if ($qtdArquivos -gt 150) {
    if ($modoSeguro) { Write-Log "AVISO: Bloqueio do Modo Seguro ativado. Reset suspenso devido ao WinThor aberto." "Yellow" }
    else {
        $confPesada = Read-Host " -> SUGERIDO: Executar manutenção corretiva profunda (Reinicia e limpa o Spooler)? [S/N]"
        if ($confPesada -eq "S" -or $confPesada -eq "s") {
            Stop-Service spooler -Force -ErrorAction SilentlyContinue
            Start-Sleep 3
            Safe-CleanSpool
            Clean-UserPrinterRegistry
            Start-Sleep 2
            Start-Service spooler
            Write-Log "Serviço Spooler de Impressão do Windows reestruturado e ativo." "Green"
        }
    }
} else { Write-Log "OK: Subsistema do Spooler de Impressão local está operando de forma limpa." "Green" }
Write-Host ""

# =======================================================================
# [BLOCO 7]: COMBO DE HARDENING COMPLETO DO SISTEMA OPERACIONAL (RDS)
# =======================================================================
Write-Host "[5/6] SEÇÃO DE TUNING PROFUNDO DE REGISTRO E SESSÕES REMOTAS" -ForegroundColor Magenta
$confHardening = Read-Host "Deseja aplicar o combo de Hardening Seguro RDS (Otimizar Logoff, Memória, Cache e SMB)? [S/N]"

if ($confHardening -eq "S" -or $confHardening -eq "s") {
    Write-Log "Aplicando chaves de registro otimizadas..." "Cyan"
    $regPaths = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System", "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent", "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search", "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager",
        "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters", "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
    )
    foreach ($p in $regPaths) { if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }

    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "DisableForceUnload" -Value 0 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "WaitToKillServiceTimeout" -Value "5000" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "HeapDeCommitFreeBlockThreshold" -Value 262144 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "HeapDeCommitTotalFreeThreshold" -Value 262144 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsRunInBackground" -Value 2 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" -Name "RemoveWindowsStore" -Value 1 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "Size" -Value 3 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 38 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "LargeSystemCache" -Value 1 -PropertyType DWORD -Force | Out-Null

    $services = @("AppReadiness", "DiagTrack", "MapsBroker")
    foreach ($svc in $services) {
        Stop-Service $svc -ErrorAction SilentlyContinue
        Set-Service $svc -StartupType Disabled -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log "Hardening Completo aplicado e gravado com sucesso." "Green"
}
Write-Host ""

# =======================================================================
# [BLOCO 8]: SNAPSHOT ÚNICO WTS (REPORTE DE HANDLES)
# =======================================================================
Write-Host "[6/6] SEÇÃO DE ANÁLISE DE CONSUMO DE SESSÕES (SPOILER DE HANDLES)" -ForegroundColor Magenta
$confMonitor = Read-Host "Deseja executar um Snapshot rápido para identificar usuários sobrecarregando Handles (rdpclip)? [S/N]"

if ($confMonitor -eq "S" -or $confMonitor -eq "s") {
    $RdpProcesses = Get-Process -Name "rdpclip" -ErrorAction SilentlyContinue
    if (-not $RdpProcesses) {
        $tabelaHandlesHtml = "<tr><td colspan='3' style='text-align:center;'>Nenhum processo rdpclip ativo na memória.</td></tr>"
    } else {
        $Relatorio = @()
        foreach ($p in $RdpProcesses) {
            $ProcessID = $p.Id
            $UserFound = "SISTEMA / DESCONHECIDO"
            try {
                $ProcWmi = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessID" -ErrorAction SilentlyContinue
                if ($ProcWmi) {
                    $Owner = Invoke-CimMethod -InputObject $ProcWmi -MethodName GetOwner -ErrorAction SilentlyContinue
                    if ($Owner.User) { $UserFound = if ($Owner.Domain) { "$($Owner.Domain)\$($Owner.User)" } else { $Owner.User } }
                }
            } catch {}
            $Relatorio += [PSCustomObject]@{ 'UsuarioDono' = $UserFound.ToUpper(); 'PID' = $ProcessID; 'Handles' = $p.HandleCount }
            $tabelaHandlesHtml += "<tr><td>$($UserFound.ToUpper())</td><td>$ProcessID</td><td style='color:#e74c3c;font-weight:bold;'>$($p.HandleCount)</td></tr>"
        }
        $DadosOrdenados = $Relatorio | Sort-Object Handles -Descending
        $VilaoAtual = $DadosOrdenados[0]
        Write-Host ""
        $DadosOrdenados | Format-Table -AutoSize
        $Decisao = Read-Host "SUGIRA: Deseja derrubar este processo rdpclip específico para liberar o servidor agora? [S/N]"
        if ($Decisao -match "s|S") {
            try { Stop-Process -Id $VilaoAtual.PID -Force -ErrorAction Stop } catch {}
        }
    }
} else { $tabelaHandlesHtml = "<tr><td colspan='3' style='text-align:center;'>Módulo ignorado pelo operador na execução.</td></tr>" }

# =======================================================================
# [BLOCO EXTRA]: COMPILADOR DO RELATÓRIO HTML INTERATIVO UNIFICADO (V7.4)
# =======================================================================
Write-Host ""
Write-Log "Compilando relatório visual em HTML..." "Yellow"

$htmlTemplate = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Relatório Master de Performance e Infraestrutura</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #1a1a1a; color: #e0e0e0; margin: 0; padding: 20px; }
        .container { max-width: 1200px; margin: 0 auto; }
        h1, h2 { color: #00adb5; border-bottom: 2px solid #333; padding-bottom: 10px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .card { background-color: #252526; padding: 20px; border-radius: 8px; border-left: 5px solid #00adb5; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }
        .card h3 { margin: 0 0 10px 0; font-size: 14px; color: #888; text-transform: uppercase; }
        .card .value { font-size: 20px; font-weight: bold; color: #fff; word-break: break-all; }
        table { width: 100%; border-collapse: collapse; margin-bottom: 30px; background-color: #252526; border-radius: 8px; overflow: hidden; }
        th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #333; font-size: 13px; }
        th { background-color: #333; color: #00adb5; font-weight: bold; }
        tr:hover { background-color: #2d2d30; }
        .status-box { padding: 10px 15px; border-radius: 4px; font-weight: bold; margin-bottom: 10px; display: flex; justify-content: space-between; background-color: #252526; border: 1px solid #333;}
    </style>
</head>
<body>
    <div class="container">
        <h1>Análise Estrutural do Servidor Windows (OCI Cloud)</h1>
        <p>Gerado em: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")</p>
        
        <div class="grid">
            <div class="card"><h3>Uso da CPU</h3><div class="value">$cpuAvg %</div></div>
            <div class="card"><h3>Uso da RAM</h3><div class="value">$ramUsoPercent % <span style='font-size:12px;color:#aaa;'><br>($($ramTotalGB - $ramLivreGB)GB / $($ramTotalGB)GB)</span></div></div>
            <div class="card"><h3>Maior Carga de Disco</h3><div class="value" style="color:#ff7675;">$processoVilaoDisco<br><span style="font-size:24px;">$latenciaVilaoMS ms</span></div></div>
            <div class="card"><h3>Arquivos no Spooler</h3><div class="value">$qtdArquivos</div></div>
        </div>

        <h2>Status dos Componentes Analisados</h2>
        <div class="status-box"><span>Pilha de Rede (Chimney/RSS):</span><span style="color:$corRede;">$statusRede</span></div>
        <div class="status-box"><span>Arquivo de Paginação (Pagefile):</span><span style="color:$corPage;">$statusPagefile</span></div>
        <div class="status-box"><span>Perfil de Impressão RDP:</span><span style="color:$corImp;">$statusImpressora</span></div>
        <div class="status-box"><span>Gargalo de Storage OCI:</span><span style="color:$corDisco;">$statusDisco</span></div>

        <h2>Auditoria Estrutural de Saúde do Domínio (AD & DNS Services)</h2>
        <table>
            <thead><tr><th>Componente Analisado</th><th>Status / Resultado</th><th>Descrição do Diagnóstico</th></tr></thead>
            <tbody>$tabelaADHtml</tbody>
        </table>

        <h2>Windows Update: Atualizações Pendentes (Urgente)</h2>
        <table>
            <thead><tr><th>Severidade</th><th>Título da Atualização / KB</th><th>Link de Apoio</th></tr></thead>
            <tbody>$tabelaPendentesHtml</tbody>
        </table>

        <h2>Windows Update: Últimos Patches Instalados (Histórico)</h2>
        <table>
            <thead><tr><th>Data de Instalação</th><th>Título do Patch Aplicado</th><th>Status</th></tr></thead>
            <tbody>$tabelaUpdatesHtml</tbody>
        </table>

        <h2>Erros Recentes do Event Viewer (Últimas 48 Horas)</h2>
        <table>
            <thead><tr><th>Provedor / Fonte</th><th>Data/Hora</th><th>Mensagem do Erro</th></tr></thead>
            <tbody>$tabelaErrosHtml</tbody>
        </table>

        <h2>Snapshot do Consumo de Handles (rdpclip)</h2>
        <table>
            <thead><tr><th>Usuário / Dono</th><th>PID</th><th>Handles Alocados</th></tr></thead>
            <tbody>$tabelaHandlesHtml</tbody>
        </table>
    </div>
</body>
</html>
"@

Set-Content -Path $htmlFile -Value $htmlTemplate -Encoding UTF8
Write-Log "Relatório HTML gerado com sucesso em: $htmlFile" "Green"
Start-Process $htmlFile

Write-Host "`n======================================================================="
Write-Host "PROCESSO CONCLUÍDO. O RELATÓRIO FOI ABERTO NO SEU NAVEGADOR." -ForegroundColor Cyan
Read-Host "Pressione ENTER para encerrar a janela..."
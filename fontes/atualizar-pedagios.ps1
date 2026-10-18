# Atualiza a base de pedágios do app (pedagios.js) a partir do OpenStreetMap.
# Uso: powershell -ExecutionPolicy Bypass -File atualizar-pedagios.ps1
# Também roda toda semana no GitHub (.github/workflows/atualizar-pedagios.yml), com PowerShell 7 no Linux.
$ErrorActionPreference = 'Stop'
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$bruto = Join-Path $aqui 'osm-pedagios-br.json'
$saida = Join-Path (Split-Path -Parent $aqui) 'pedagios.js'

if (-not $env:SEM_DOWNLOAD) {
  $q = @'
[out:json][timeout:180];
area["ISO3166-1"="BR"]["admin_level"="2"]->.br;
(node["barrier"="toll_booth"](area.br); way["barrier"="toll_booth"](area.br); node["highway"="toll_gantry"](area.br););
out center tags;
'@
  # Servidores públicos do Overpass: se um estiver ocupado, tenta o próximo
  $servidores = 'https://overpass-api.de/api/interpreter', 'https://overpass.kumi.systems/api/interpreter', 'https://overpass.private.coffee/api/interpreter'
  # O curl é preferido: ele cai para IPv4 quando o IPv6 não funciona (comum nas máquinas do GitHub) e repete sozinho
  $curl = Get-Command curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $consulta = Join-Path ([IO.Path]::GetTempPath()) 'consulta-pedagios.txt'
  [IO.File]::WriteAllText($consulta, $q)
  $ok = $false
  foreach ($rodada in 1..3) {
    foreach ($url in $servidores) {
      if ($curl) {
        & $curl.Source -sS -f -4 --retry 2 --retry-delay 15 --max-time 300 -A 'RachaDaViagem/1.0 (projeto pessoal)' --data-urlencode "data@$consulta" -o $bruto $url
        if ($LASTEXITCODE -eq 0) { $ok = $true } else { Write-Warning "Falhou em $url (curl $LASTEXITCODE)" }
      } else {
        try {
          Invoke-WebRequest -UseBasicParsing -Method Post -Uri $url -UserAgent 'RachaDaViagem/1.0 (projeto pessoal)' `
            -ContentType 'application/x-www-form-urlencoded' -Body ('data=' + [uri]::EscapeDataString($q)) -OutFile $bruto -TimeoutSec 300
          $ok = $true
        } catch { Write-Warning "Falhou em $url : $($_.Exception.Message)" }
      }
      if ($ok) { break }
    }
    if ($ok) { break }
    Start-Sleep -Seconds 60
  }
  if (-not $ok) { throw 'Nenhum servidor do Overpass respondeu.' }
}

$inv = [Globalization.CultureInfo]::InvariantCulture
$j = Get-Content $bruto -Raw -Encoding UTF8 | ConvertFrom-Json
# Proteção: uma resposta incompleta não pode apagar a base que já funciona
if ($j.elements.Count -lt 800) { throw "Resposta suspeita: só $($j.elements.Count) praças." }
$linhas = foreach ($e in $j.elements) {
  $t = $e.tags
  if ($e.type -eq 'node') { $lat = $e.lat; $lon = $e.lon } else { $lat = $e.center.lat; $lon = $e.center.lon }
  # Valor para carro de passeio (null quando a praça não tem valor no mapa)
  $valor = 'null'
  if ($t.charge) {
    $m = [regex]::Match($t.charge, '([\d.,]+)\s*BRL\s*/\s*motorcar')
    if (-not $m.Success) { $m = [regex]::Match($t.charge, '^([\d.,]+)\s*BRL\s*$') }
    if ($m.Success) { $valor = ([double]::Parse($m.Groups[1].Value.Replace(',', '.'), $inv)).ToString('0.00', $inv) }
  }
  # Sentidos cobrados, em graus (vazio = cobra em qualquer sentido)
  $dirs = @()
  if ($t.direction) { $dirs = @($t.direction -split ';' | Where-Object { $_ -match '^\d+(\.\d+)?$' } | ForEach-Object { [int][double]::Parse($_, $inv) }) }
  $nome = @($t.name, $t.note, $t.operator) | Where-Object { $_ } | Select-Object -First 1
  if (-not $nome) { $nome = 'Pedágio' }
  if ($t.operator -and $nome -ne $t.operator) { $nome = "$nome ($($t.operator))" }
  $tipo = if ($t.highway -eq 'toll_gantry') { 'p' } else { 'c' }
  # O PowerShell 7 transforma datas do JSON em DateTime: volta para AAAA-MM-DD
  $conf = $t.check_date
  if ($conf -is [datetime]) { $conf = $conf.ToString('yyyy-MM-dd', $inv) }
  '[{0},{1},{2},[{3}],{4},"{5}","{6}"]' -f ([double]$lat).ToString('0.######', $inv), ([double]$lon).ToString('0.######', $inv), $valor, ($dirs -join ','),
    (ConvertTo-Json ([string]$nome) -Compress), $tipo, $conf
}
$data = Get-Date -Format 'yyyy-MM-dd'
$js = "// Praças de pedágio do Brasil (OpenStreetMap, © colaboradores do OpenStreetMap, ODbL). Gerado em $data.`n" +
      "// [lat, lon, valor carro (R$), sentidos cobrados (graus), nome, c=cabine p=pórtico, conferido em]`n" +
      "window.PEDAGIOS_DATA = '$data';`nwindow.PEDAGIOS = [`n" + ($linhas -join ",`n") + "`n];`n"
[IO.File]::WriteAllText($saida, $js, (New-Object Text.UTF8Encoding($false)))
"praças: $($linhas.Count)  ->  $saida  ($((Get-Item $saida).Length) bytes)"

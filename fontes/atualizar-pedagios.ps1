# Atualiza a base de pedágios do app (pedagios.js) a partir do OpenStreetMap.
# Uso: powershell -ExecutionPolicy Bypass -File atualizar-pedagios.ps1
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
  Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://overpass-api.de/api/interpreter' -UserAgent 'RachaDaViagem/1.0 (projeto pessoal)' `
    -ContentType 'application/x-www-form-urlencoded' -Body ('data=' + [uri]::EscapeDataString($q)) -OutFile $bruto -TimeoutSec 300
}

$inv = [Globalization.CultureInfo]::InvariantCulture
$j = Get-Content $bruto -Raw -Encoding UTF8 | ConvertFrom-Json
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
  '[{0},{1},{2},[{3}],{4},"{5}","{6}"]' -f ([double]$lat).ToString('0.######', $inv), ([double]$lon).ToString('0.######', $inv), $valor, ($dirs -join ','),
    (ConvertTo-Json ([string]$nome) -Compress), $tipo, $t.check_date
}
$data = Get-Date -Format 'yyyy-MM-dd'
$js = "// Praças de pedágio do Brasil (OpenStreetMap, © colaboradores do OpenStreetMap, ODbL). Gerado em $data.`n" +
      "// [lat, lon, valor carro (R$), sentidos cobrados (graus), nome, c=cabine p=pórtico, conferido em]`n" +
      "window.PEDAGIOS_DATA = '$data';`nwindow.PEDAGIOS = [`n" + ($linhas -join ",`n") + "`n];`n"
[IO.File]::WriteAllText($saida, $js, (New-Object Text.UTF8Encoding($false)))
"praças: $($linhas.Count)  ->  $saida  ($((Get-Item $saida).Length) bytes)"

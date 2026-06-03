<#
Script Adı  : File Server Detaylı Durum Raporu
Hazırlayan  : İbrahim TONCA
Web         : www.ibrahimtonca.com
Açıklama    : File Server paylaşım alanı, kapasite kullanımı, dosya/klasör yapısı, NTFS yetkileri ve genel sağlık durumunu HTML rapor olarak oluşturur.

Yasal Uyarı :
Bu script kaynak gösterilmeden paylaşılamaz, çoğaltılamaz veya farklı platformlarda yayınlanamaz.
Scriptin kullanımı ve doğabilecek sonuçlar tamamen kullanıcının sorumluluğundadır.
#>

$RootPath = "\\FILESERVER\PAYLASIM"
$ReportFolder = "C:\Raporlar"

$TopCount = 50
$RecentDays = 30
$OldFileYears = 3
$VeryOldFileYears = 5
$LargeFileThresholdGB = 1
$LongPathWarningLength = 240

$IncludeFirstLevelPermissionReport = $true

$MaxEmptyFolderRows = 1000
$MaxEmptyFileRows = 1000
$MaxErrorRows = 1000

$FolderSizeMode = "FirstLevel"
$FolderSizeProgressInterval = 10000

$SendMailReport = $true
$SmtpServer = "smtp.example.com"
$SmtpPort = 25
$MailFrom = "rapor@ornek.com"
$MailTo = @(
    "alici1@ornek.com",
    "alici2@ornek.com"
)
$AttachReportToMail = $true
$MailLogPath = Join-Path $ReportFolder "Mail_Hata_Log.txt"

$OpenReportAfterCreate = $false



[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Errors = New-Object System.Collections.Generic.List[Object]
$AllFiles = New-Object System.Collections.Generic.List[Object]
$AllFolders = New-Object System.Collections.Generic.List[Object]

if (!(Test-Path -Path $ReportFolder)) {
    New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
}


function Convert-BytesToReadable {
    param(
        [Nullable[Double]]$Bytes
    )

    if ($null -eq $Bytes) {
        return "0 B"
    }

    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    }
    elseif ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
    else {
        return "{0:N0} B" -f $Bytes
    }
}

function Convert-ToPercent {
    param(
        [double]$Value,
        [double]$Total
    )

    if ($Total -le 0) {
        return "0%"
    }

    return "{0:N2}%" -f (($Value / $Total) * 100)
}

function Get-RiskClass {
    param(
        [double]$Value,
        [double]$Warning,
        [double]$Critical,
        [switch]$Reverse
    )

    if ($Reverse) {
        if ($Value -le $Critical) {
            return "critical"
        }
        elseif ($Value -le $Warning) {
            return "warning"
        }
        else {
            return "good"
        }
    }
    else {
        if ($Value -ge $Critical) {
            return "critical"
        }
        elseif ($Value -ge $Warning) {
            return "warning"
        }
        else {
            return "good"
        }
    }
}

function HtmlEncode {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-DuplicatePathsHtml {
    param(
        [string]$FileName,
        [object[]]$Paths
    )

    $pathList = @($Paths)
    $count = $pathList.Count
    $encodedFileName = HtmlEncode $FileName
    $encodedExportText = HtmlEncode ($pathList -join [Environment]::NewLine)
    $listItems = ($pathList | ForEach-Object { "<li>" + (HtmlEncode $_) + "</li>" }) -join ""

    return @"
<div class="duplicate-paths-cell">
    <button type="button" class="show-duplicate-paths">Tüm yolları göster ($count)</button>
    <div class="duplicate-paths-export export-text">$encodedExportText</div>
    <div class="duplicate-paths-content">
        <div class="duplicate-paths-title">$encodedFileName</div>
        <ol>$listItems</ol>
    </div>
</div>
"@
}

function Get-SafeSum {
    param(
        [object[]]$Items,
        [string]$PropertyName
    )

    if ($null -eq $Items -or @($Items).Count -eq 0) {
        return 0
    }

    $sum = ($Items | Measure-Object -Property $PropertyName -Sum).Sum

    if ($null -eq $sum) {
        return 0
    }

    return [double]$sum
}

function Get-ShareServerInfo {
    param(
        [string]$Path
    )

    $serverName = "Bilinmiyor"
    $ipAddress = "Alınamadı"

    if ($Path -match "^\\\\([^\\]+)\\") {
        $serverName = $Matches[1]
    }

    if ($serverName -ne "Bilinmiyor") {
        try {
            $resolvedIps = [System.Net.Dns]::GetHostAddresses($serverName) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.IPAddressToString }

            if (@($resolvedIps).Count -gt 0) {
                $ipAddress = ($resolvedIps -join ", ")
            }
        }
        catch {
            $ipAddress = "Alınamadı"
        }
    }

    return [PSCustomObject]@{
        CihazAdi = $serverName
        IpAdresi = $ipAddress
    }
}

function Get-ShareDiskInfo {
    param(
        [string]$Path
    )

    $result = [PSCustomObject]@{
        KapasiteBytes   = $null
        KullanilanBytes = $null
        BosBytes        = $null
        KullanilanYuzde = "0%"
        BosYuzde        = "0%"
        Kaynak          = "Alınamadı"
        Aciklama        = "Disk kapasitesi bilgisi alınamadı."
    }

    $driveName = "KVRPT" + (Get-Random -Minimum 1000 -Maximum 9999)

    try {
        New-PSDrive -Name $driveName -PSProvider FileSystem -Root $Path -ErrorAction Stop | Out-Null
        $psDrive = Get-PSDrive -Name $driveName -ErrorAction Stop

        if ($null -ne $psDrive.Free -and $null -ne $psDrive.Used) {
            $capacity = [double]$psDrive.Free + [double]$psDrive.Used

            if ($capacity -gt 0) {
                $result.KapasiteBytes = $capacity
                $result.KullanilanBytes = [double]$psDrive.Used
                $result.BosBytes = [double]$psDrive.Free
                $result.KullanilanYuzde = Convert-ToPercent -Value $result.KullanilanBytes -Total $capacity
                $result.BosYuzde = Convert-ToPercent -Value $result.BosBytes -Total $capacity
                $result.Kaynak = "PSDrive"
                $result.Aciklama = "UNC paylaşımı üzerinden kapasite bilgisi alındı."
            }
        }
    }
    catch {
        $result.Aciklama = "UNC üzerinden kapasite alınamadı. CIM/WMI yöntemi denenecek."
    }
    finally {
        try {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }

    if ($null -eq $result.KapasiteBytes) {
        try {
            if ($Path -match "^\\\\([^\\]+)\\([^\\]+)") {
                $serverName = $Matches[1]
                $shareName = $Matches[2].Replace("'", "''")

                $share = Get-CimInstance -ComputerName $serverName -ClassName Win32_Share -Filter "Name='$shareName'" -ErrorAction Stop

                if ($null -ne $share.Path) {
                    $driveRoot = [System.IO.Path]::GetPathRoot($share.Path)
                    $driveId = $driveRoot.TrimEnd("\")

                    $logicalDisk = Get-CimInstance -ComputerName $serverName -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveId'" -ErrorAction Stop

                    if ($null -ne $logicalDisk.Size -and $null -ne $logicalDisk.FreeSpace) {
                        $capacity = [double]$logicalDisk.Size
                        $free = [double]$logicalDisk.FreeSpace
                        $used = $capacity - $free

                        if ($capacity -gt 0) {
                            $result.KapasiteBytes = $capacity
                            $result.KullanilanBytes = $used
                            $result.BosBytes = $free
                            $result.KullanilanYuzde = Convert-ToPercent -Value $used -Total $capacity
                            $result.BosYuzde = Convert-ToPercent -Value $free -Total $capacity
                            $result.Kaynak = "CIM / WMI"
                            $result.Aciklama = "$serverName sunucusundaki $driveId diski üzerinden kapasite bilgisi alındı."
                        }
                    }
                }
            }
        }
        catch {
            $result.Aciklama = "Disk kapasitesi bilgisi alınamadı. Yetki, firewall, WinRM veya WMI/CIM erişimi gerekebilir."
        }
    }

    return $result
}

function Get-FolderPermissionReport {
    param(
        [string]$Path,
        [switch]$IncludeFirstLevelFolders
    )

    $PermissionResults = New-Object System.Collections.Generic.List[Object]
    $TargetFolders = New-Object System.Collections.Generic.List[Object]

    try {
        if (Test-Path -Path $Path) {
            $TargetFolders.Add((Get-Item -Path $Path -Force))
        }
    }
    catch {
        $Errors.Add([PSCustomObject]@{
            Yol  = $Path
            Hata = $_.Exception.Message
            Tip  = "Yetki okuma - ana klasör"
        })
    }

    if ($IncludeFirstLevelFolders) {
        try {
            $FirstLevelFolders = Get-ChildItem -Path $Path -Directory -Force -ErrorAction SilentlyContinue

            foreach ($folder in $FirstLevelFolders) {
                $TargetFolders.Add($folder)
            }
        }
        catch {
            $Errors.Add([PSCustomObject]@{
                Yol  = $Path
                Hata = $_.Exception.Message
                Tip  = "Yetki okuma - birinci seviye klasörler"
            })
        }
    }

    foreach ($folder in $TargetFolders) {
        try {
            $Acl = Get-Acl -Path $folder.FullName -ErrorAction Stop

            foreach ($access in $Acl.Access) {
                $rights = $access.FileSystemRights

                $CanRead = (
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0) -or
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne 0) -or
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0) -or
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
                )

                $CanWrite = (
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::Write) -ne 0) -or
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0) -or
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
                )

                $CanModify = (
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0) -or
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
                )

                $FullControl = (
                    (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
                )

                $PermissionResults.Add([PSCustomObject]@{
                    KlasorYolu        = $folder.FullName
                    KullaniciGrup     = $access.IdentityReference.Value
                    YetkiTipi         = [string]$access.FileSystemRights
                    OkumaYetkisi      = if ($CanRead) { "Evet" } else { "Hayır" }
                    YazmaYetkisi      = if ($CanWrite) { "Evet" } else { "Hayır" }
                    DegistirmeYetkisi = if ($CanModify) { "Evet" } else { "Hayır" }
                    TamKontrol        = if ($FullControl) { "Evet" } else { "Hayır" }
                    IzinDurumu        = if ($access.AccessControlType -eq "Allow") { "İzin Verildi" } else { "Engellendi" }
                    Kalitim           = if ($access.IsInherited) { "Kalıtımsal" } else { "Doğrudan Tanımlı" }
                    UygulamaAlani     = [string]$access.PropagationFlags
                    DevralmaAlani     = [string]$access.InheritanceFlags
                })
            }
        }
        catch {
            $Errors.Add([PSCustomObject]@{
                Yol  = $folder.FullName
                Hata = $_.Exception.Message
                Tip  = "Yetki okuma"
            })
        }
    }

    return $PermissionResults
}

function New-ReportTable {
    param(
        [string]$Title,
        [object[]]$Data,
        [object[]]$Columns,
        [string]$EmptyMessage = "Veri bulunamadı.",
        [scriptblock]$GroupByExpression = $null
    )

    $tableId = "tbl_" + ([guid]::NewGuid().ToString("N"))

    $html = @"
<div class="section">
<h2>$Title</h2>
<div class="table-tools">
    <input type="text" class="table-search" placeholder="Tabloda ara..." data-table="$tableId">
    <select class="table-page-size" data-table="$tableId">
        <option value="10" selected>10 satır</option>
        <option value="25">25 satır</option>
        <option value="50">50 satır</option>
        <option value="100">100 satır</option>
        <option value="999999">Tümü</option>
    </select>
    <div class="export-tools">
        <span>Dışarı Aktar:</span>
        <button type="button" class="export-pdf" data-table="$tableId">PDF</button>
        <button type="button" class="export-excel" data-table="$tableId">Excel</button>
        <button type="button" class="export-csv" data-table="$tableId">CSV</button>
    </div>
</div>
"@

    if ($null -eq $Data -or @($Data).Count -eq 0) {
        $html += "<p><span class='badge'>$EmptyMessage</span></p></div>"
        return $html
    }

    $html += "<div class='table-scroll'><table id='$tableId' class='report-table'><thead><tr>"

    foreach ($col in $Columns) {
        $html += "<th>" + (HtmlEncode $col.Header) + "</th>"
    }

    $html += "</tr></thead><tbody>"

    $groupClassMap = @{}
    $groupIndex = 0

    foreach ($row in $Data) {
        $rowClass = ""

        if ($null -ne $GroupByExpression) {
            try {
                $groupValue = & $GroupByExpression $row
            }
            catch {
                $groupValue = ""
            }

            $groupKey = [string]$groupValue

            if (!$groupClassMap.ContainsKey($groupKey)) {
                $groupClassMap[$groupKey] = "group-color-" + (($groupIndex % 8) + 1)
                $groupIndex++
            }

            $rowClass = $groupClassMap[$groupKey]
        }

        if ([string]::IsNullOrWhiteSpace($rowClass)) {
            $html += "<tr>"
        }
        else {
            $html += "<tr class='$rowClass'>"
        }

        foreach ($col in $Columns) {
            try {
                $value = & $col.Expression $row
            }
            catch {
                $value = ""
            }

            $rawHtml = $false

            if ($col.ContainsKey("RawHtml")) {
                $rawHtml = [bool]$col.RawHtml
            }

            if ($rawHtml) {
                $html += "<td>" + [string]$value + "</td>"
            }
            else {
                $html += "<td>" + (HtmlEncode $value) + "</td>"
            }
        }

        $html += "</tr>"
    }

    $html += @"
</tbody></table></div>
<div class="pager" data-table="$tableId">
    <button class="prev-page" data-table="$tableId">Önceki</button>
    <span class="page-info" data-table="$tableId"></span>
    <button class="next-page" data-table="$tableId">Sonraki</button>
</div>
</div>
"@

    return $html
}


if (!(Test-Path -Path $RootPath)) {
    Write-Host "HATA: Dizin bulunamadı veya erişilemiyor: $RootPath" -ForegroundColor Red
    exit 1
}

$ServerInfo = Get-ShareServerInfo -Path $RootPath
$SafeDeviceName = $ServerInfo.CihazAdi -replace '[\/:*?"<>|]', '_'
$ReportFileDate = Get-Date -Format "dd.MM.yyyy-HH.mm"
$ReportFileName = "FileServer_${SafeDeviceName}_Raporu_${ReportFileDate}.html"
$ReportPath = Join-Path -Path $ReportFolder -ChildPath $ReportFileName

Write-Host "Raporlama başlıyor..." -ForegroundColor Cyan
Write-Host "Taranan dizin : $RootPath"
Write-Host "Cihaz adı     : $($ServerInfo.CihazAdi)"
Write-Host "Rapor çıkışı  : $ReportPath"
Write-Host ""


Write-Host "Disk kapasitesi bilgisi alınıyor..." -ForegroundColor Yellow
$DiskInfo = Get-ShareDiskInfo -Path $RootPath


Write-Host "Klasörler okunuyor..." -ForegroundColor Yellow

try {
    $FolderErrors = $null
    $Folders = Get-ChildItem -Path $RootPath -Directory -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable FolderErrors

    foreach ($folder in $Folders) {
        $AllFolders.Add($folder)
    }

    if ($null -ne $FolderErrors) {
        foreach ($err in $FolderErrors) {
            $Errors.Add([PSCustomObject]@{
                Yol  = $err.TargetObject
                Hata = $err.Exception.Message
                Tip  = "Klasör okuma"
            })
        }
    }
}
catch {
    $Errors.Add([PSCustomObject]@{
        Yol  = $RootPath
        Hata = $_.Exception.Message
        Tip  = "Klasör okuma"
    })
}


Write-Host "Dosyalar okunuyor..." -ForegroundColor Yellow

try {
    $FileErrors = $null
    $Files = Get-ChildItem -Path $RootPath -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable FileErrors

    foreach ($file in $Files) {
        $AllFiles.Add($file)
    }

    if ($null -ne $FileErrors) {
        foreach ($err in $FileErrors) {
            $Errors.Add([PSCustomObject]@{
                Yol  = $err.TargetObject
                Hata = $err.Exception.Message
                Tip  = "Dosya okuma"
            })
        }
    }
}
catch {
    $Errors.Add([PSCustomObject]@{
        Yol  = $RootPath
        Hata = $_.Exception.Message
        Tip  = "Dosya okuma"
    })
}


Write-Host "Ana klasör ve birinci seviye klasör yetkileri okunuyor..." -ForegroundColor Yellow

if ($IncludeFirstLevelPermissionReport) {
    $MainFolderPermissionReport = Get-FolderPermissionReport -Path $RootPath -IncludeFirstLevelFolders
}
else {
    $MainFolderPermissionReport = Get-FolderPermissionReport -Path $RootPath
}

$ReadPermissionCount = @($MainFolderPermissionReport | Where-Object {
    $_.OkumaYetkisi -eq "Evet" -and $_.IzinDurumu -eq "İzin Verildi"
}).Count

$WritePermissionCount = @($MainFolderPermissionReport | Where-Object {
    $_.YazmaYetkisi -eq "Evet" -and $_.IzinDurumu -eq "İzin Verildi"
}).Count

$ModifyPermissionCount = @($MainFolderPermissionReport | Where-Object {
    $_.DegistirmeYetkisi -eq "Evet" -and $_.IzinDurumu -eq "İzin Verildi"
}).Count

$FullControlPermissionCount = @($MainFolderPermissionReport | Where-Object {
    $_.TamKontrol -eq "Evet" -and $_.IzinDurumu -eq "İzin Verildi"
}).Count

$ExplicitPermissionCount = @($MainFolderPermissionReport | Where-Object {
    $_.Kalitim -eq "Doğrudan Tanımlı"
}).Count

$DenyPermissionCount = @($MainFolderPermissionReport | Where-Object {
    $_.IzinDurumu -eq "Engellendi"
}).Count


Write-Host "KPI değerleri hesaplanıyor..." -ForegroundColor Yellow

$TotalFolders = $AllFolders.Count
$TotalFiles = $AllFiles.Count
$TotalSizeBytes = Get-SafeSum -Items $AllFiles -PropertyName "Length"

$AverageFileSizeBytes = 0
if ($TotalFiles -gt 0) {
    $AverageFileSizeBytes = $TotalSizeBytes / $TotalFiles
}

$LargeFiles = $AllFiles | Where-Object { $_.Length -ge ($LargeFileThresholdGB * 1GB) }
$RecentFiles = $AllFiles | Where-Object { $_.LastWriteTime -ge (Get-Date).AddDays(-$RecentDays) }
$OldFiles = $AllFiles | Where-Object { $_.LastWriteTime -lt (Get-Date).AddYears(-$OldFileYears) }
$VeryOldFiles = $AllFiles | Where-Object { $_.LastWriteTime -lt (Get-Date).AddYears(-$VeryOldFileYears) }
$EmptyFiles = $AllFiles | Where-Object { $_.Length -eq 0 }
$LongPathFiles = $AllFiles | Where-Object { $_.FullName.Length -ge $LongPathWarningLength }
$LongPathFolders = $AllFolders | Where-Object { $_.FullName.Length -ge $LongPathWarningLength }

$HiddenFiles = $AllFiles | Where-Object {
    ($_.Attributes -band [System.IO.FileAttributes]::Hidden) -eq [System.IO.FileAttributes]::Hidden
}

$SystemFiles = $AllFiles | Where-Object {
    ($_.Attributes -band [System.IO.FileAttributes]::System) -eq [System.IO.FileAttributes]::System
}

$ReadOnlyFiles = $AllFiles | Where-Object {
    ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) -eq [System.IO.FileAttributes]::ReadOnly
}

$ArchiveFiles = $AllFiles | Where-Object {
    $_.Extension.ToLower() -in ".zip", ".rar", ".7z", ".tar", ".gz"
}

$MediaFiles = $AllFiles | Where-Object {
    $_.Extension.ToLower() -in ".mp4", ".avi", ".mkv", ".mov", ".wmv", ".mp3", ".wav", ".flac", ".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff"
}

$OfficeFiles = $AllFiles | Where-Object {
    $_.Extension.ToLower() -in ".doc", ".docx", ".xls", ".xlsx", ".xlsm", ".ppt", ".pptx", ".pdf"
}

$ExecutableFiles = $AllFiles | Where-Object {
    $_.Extension.ToLower() -in ".exe", ".msi", ".bat", ".cmd", ".ps1", ".vbs", ".js"
}

$MailArchiveFiles = $AllFiles | Where-Object {
    $_.Extension.ToLower() -in ".pst", ".ost", ".eml", ".msg"
}

$DiskImageFiles = $AllFiles | Where-Object {
    $_.Extension.ToLower() -in ".iso", ".vhd", ".vhdx", ".img"
}

$TempFiles = $AllFiles | Where-Object {
    $_.Extension.ToLower() -in ".tmp", ".temp", ".bak", ".old", ".log" -or $_.Name -like "~*"
}


Write-Host "Boş klasörler kontrol ediliyor..." -ForegroundColor Yellow

$EmptyFolders = foreach ($folder in $AllFolders) {
    try {
        $itemCount = @(Get-ChildItem -Path $folder.FullName -Force -ErrorAction Stop).Count

        if ($itemCount -eq 0) {
            [PSCustomObject]@{
                KlasorYolu      = $folder.FullName
                SonDegisiklik   = $folder.LastWriteTime
                OlusturmaTarihi = $folder.CreationTime
            }
        }
    }
    catch {
        $Errors.Add([PSCustomObject]@{
            Yol  = $folder.FullName
            Hata = $_.Exception.Message
            Tip  = "Boş klasör kontrolü"
        })
    }
}


Write-Host "Klasör boyutları hesaplanıyor... Mod: $FolderSizeMode" -ForegroundColor Yellow

$NormalizedRoot = $RootPath.TrimEnd("\")
$FolderStatsMap = @{}

function Add-FolderStatKey {
    param(
        [string]$FolderPath,
        [datetime]$LastWriteTime
    )

    $key = $FolderPath.TrimEnd("\")

    if (!$FolderStatsMap.ContainsKey($key)) {
        $FolderStatsMap[$key] = [PSCustomObject]@{
            KlasorYolu      = $key
            DosyaSayisi     = 0
            ToplamBoyutByte = 0
            ToplamBoyut     = "0 B"
            SonDegisiklik   = $LastWriteTime
            YolUzunlugu     = $key.Length
        }
    }
}

if ($FolderSizeMode -eq "None") {
    $FolderSizeStats = @()
}
elseif ($FolderSizeMode -eq "FirstLevel") {
    Add-FolderStatKey -FolderPath $NormalizedRoot -LastWriteTime (Get-Date)

    foreach ($folder in $AllFolders) {
        $relativeFolder = $folder.FullName.Replace($NormalizedRoot, "").Trim("\")

        if (![string]::IsNullOrWhiteSpace($relativeFolder) -and (($relativeFolder -split "\\").Count -eq 1)) {
            Add-FolderStatKey -FolderPath $folder.FullName -LastWriteTime $folder.LastWriteTime
        }
    }

    $processedFiles = 0

    foreach ($file in $AllFiles) {
        $processedFiles++

        if (($FolderSizeProgressInterval -gt 0) -and (($processedFiles % $FolderSizeProgressInterval) -eq 0)) {
            Write-Host "Klasör boyutu işleniyor: $processedFiles / $TotalFiles dosya" -ForegroundColor DarkGray
        }

        if ($null -eq $file.DirectoryName) {
            continue
        }

        $dir = $file.DirectoryName.TrimEnd("\")

        if (!$dir.StartsWith($NormalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $relative = $dir.Substring($NormalizedRoot.Length).Trim("\")

        if ([string]::IsNullOrWhiteSpace($relative)) {
            $statKey = $NormalizedRoot
        }
        else {
            $firstSegment = ($relative -split "\\", 2)[0]
            $statKey = Join-Path -Path $NormalizedRoot -ChildPath $firstSegment
        }

        if (!$FolderStatsMap.ContainsKey($statKey)) {
            Add-FolderStatKey -FolderPath $statKey -LastWriteTime (Get-Date)
        }

        $FolderStatsMap[$statKey].DosyaSayisi += 1
        $FolderStatsMap[$statKey].ToplamBoyutByte += [double]$file.Length
    }

    $FolderSizeStats = foreach ($item in $FolderStatsMap.Values) {
        $item.ToplamBoyut = Convert-BytesToReadable $item.ToplamBoyutByte
        $item
    }
}
else {
    Add-FolderStatKey -FolderPath $NormalizedRoot -LastWriteTime (Get-Date)

    foreach ($folder in $AllFolders) {
        Add-FolderStatKey -FolderPath $folder.FullName -LastWriteTime $folder.LastWriteTime
    }

    $processedFiles = 0

    foreach ($file in $AllFiles) {
        $processedFiles++

        if (($FolderSizeProgressInterval -gt 0) -and (($processedFiles % $FolderSizeProgressInterval) -eq 0)) {
            Write-Host "Klasör boyutu işleniyor: $processedFiles / $TotalFiles dosya" -ForegroundColor DarkGray
        }

        if ($null -eq $file.DirectoryName) {
            continue
        }

        $dir = $file.DirectoryName.TrimEnd("\")

        while (
            $null -ne $dir -and
            $dir.Length -ge $NormalizedRoot.Length -and
            $dir.StartsWith($NormalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            if (!$FolderStatsMap.ContainsKey($dir)) {
                Add-FolderStatKey -FolderPath $dir -LastWriteTime (Get-Date)
            }

            $FolderStatsMap[$dir].DosyaSayisi += 1
            $FolderStatsMap[$dir].ToplamBoyutByte += [double]$file.Length

            $parent = Split-Path -Path $dir -Parent

            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) {
                break
            }

            $dir = $parent.TrimEnd("\")
        }
    }

    $FolderSizeStats = foreach ($item in $FolderStatsMap.Values) {
        $item.ToplamBoyut = Convert-BytesToReadable $item.ToplamBoyutByte
        $item
    }
}


$TopLargestFolders = $FolderSizeStats |
    Where-Object { $_.KlasorYolu -ne $NormalizedRoot } |
    Sort-Object ToplamBoyutByte -Descending |
    Select-Object -First $TopCount

$TopLargestFiles = $AllFiles |
    Sort-Object Length -Descending |
    Select-Object -First $TopCount |
    ForEach-Object {
        [PSCustomObject]@{
            DosyaAdi        = $_.Name
            DosyaYolu       = $_.FullName
            KlasorYolu      = $_.DirectoryName
            Boyut           = Convert-BytesToReadable $_.Length
            SonDegisiklik   = $_.LastWriteTime
            OlusturmaTarihi = $_.CreationTime
            Uzanti          = if ([string]::IsNullOrWhiteSpace($_.Extension)) { "[Uzantısız]" } else { $_.Extension }
        }
    }

$RecentChangedFiles = $AllFiles |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $TopCount |
    ForEach-Object {
        [PSCustomObject]@{
            DosyaAdi      = $_.Name
            DosyaYolu     = $_.FullName
            Boyut         = Convert-BytesToReadable $_.Length
            SonDegisiklik = $_.LastWriteTime
            Uzanti        = if ([string]::IsNullOrWhiteSpace($_.Extension)) { "[Uzantısız]" } else { $_.Extension }
        }
    }

$OldestFiles = $AllFiles |
    Sort-Object LastWriteTime |
    Select-Object -First $TopCount |
    ForEach-Object {
        [PSCustomObject]@{
            DosyaAdi      = $_.Name
            DosyaYolu     = $_.FullName
            Boyut         = Convert-BytesToReadable $_.Length
            SonDegisiklik = $_.LastWriteTime
            Uzanti        = if ([string]::IsNullOrWhiteSpace($_.Extension)) { "[Uzantısız]" } else { $_.Extension }
        }
    }

$EmptyFileReport = $EmptyFiles |
    Sort-Object FullName |
    Select-Object -First $MaxEmptyFileRows |
    ForEach-Object {
        [PSCustomObject]@{
            DosyaAdi        = $_.Name
            DosyaYolu       = $_.FullName
            Boyut           = Convert-BytesToReadable $_.Length
            SonDegisiklik   = $_.LastWriteTime
            OlusturmaTarihi = $_.CreationTime
        }
    }

$EmptyFolderReport = $EmptyFolders |
    Sort-Object KlasorYolu |
    Select-Object -First $MaxEmptyFolderRows

$LongPathFileReport = $LongPathFiles |
    Sort-Object { $_.FullName.Length } -Descending |
    Select-Object -First $TopCount |
    ForEach-Object {
        [PSCustomObject]@{
            DosyaAdi      = $_.Name
            DosyaYolu     = $_.FullName
            YolUzunlugu   = $_.FullName.Length
            Boyut         = Convert-BytesToReadable $_.Length
            SonDegisiklik = $_.LastWriteTime
        }
    }

$ExtensionStats = $AllFiles |
    Group-Object Extension |
    Sort-Object Count -Descending |
    Select-Object -First $TopCount |
    ForEach-Object {
        $sum = Get-SafeSum -Items $_.Group -PropertyName "Length"

        [PSCustomObject]@{
            Uzanti      = if ([string]::IsNullOrWhiteSpace($_.Name)) { "[Uzantısız]" } else { $_.Name }
            DosyaSayisi = $_.Count
            ToplamBoyut = Convert-BytesToReadable $sum
        }
    }

$CategoryStats = @(
    [PSCustomObject]@{
        Kategori    = "Office / PDF Dosyaları"
        DosyaSayisi = @($OfficeFiles).Count
        ToplamBoyut = Convert-BytesToReadable (Get-SafeSum -Items $OfficeFiles -PropertyName "Length")
    }
    [PSCustomObject]@{
        Kategori    = "Medya Dosyaları"
        DosyaSayisi = @($MediaFiles).Count
        ToplamBoyut = Convert-BytesToReadable (Get-SafeSum -Items $MediaFiles -PropertyName "Length")
    }
    [PSCustomObject]@{
        Kategori    = "Arşiv Dosyaları"
        DosyaSayisi = @($ArchiveFiles).Count
        ToplamBoyut = Convert-BytesToReadable (Get-SafeSum -Items $ArchiveFiles -PropertyName "Length")
    }
    [PSCustomObject]@{
        Kategori    = "Çalıştırılabilir / Script Dosyaları"
        DosyaSayisi = @($ExecutableFiles).Count
        ToplamBoyut = Convert-BytesToReadable (Get-SafeSum -Items $ExecutableFiles -PropertyName "Length")
    }
    [PSCustomObject]@{
        Kategori    = "Mail Arşiv Dosyaları"
        DosyaSayisi = @($MailArchiveFiles).Count
        ToplamBoyut = Convert-BytesToReadable (Get-SafeSum -Items $MailArchiveFiles -PropertyName "Length")
    }
    [PSCustomObject]@{
        Kategori    = "Disk İmaj Dosyaları"
        DosyaSayisi = @($DiskImageFiles).Count
        ToplamBoyut = Convert-BytesToReadable (Get-SafeSum -Items $DiskImageFiles -PropertyName "Length")
    }
    [PSCustomObject]@{
        Kategori    = "Geçici / Log / Yedek Dosyalar"
        DosyaSayisi = @($TempFiles).Count
        ToplamBoyut = Convert-BytesToReadable (Get-SafeSum -Items $TempFiles -PropertyName "Length")
    }
)

$DuplicateFileNames = $AllFiles |
    Group-Object Name |
    Where-Object { $_.Count -gt 1 } |
    Sort-Object Count -Descending |
    Select-Object -First $TopCount |
    ForEach-Object {
        $duplicatePaths = @($_.Group | Sort-Object FullName | ForEach-Object { $_.FullName })

        [PSCustomObject]@{
            DosyaAdi     = $_.Name
            TekrarSayisi = $_.Count
            TumYollar    = $duplicatePaths -join [Environment]::NewLine
            YollarModal  = New-DuplicatePathsHtml -FileName $_.Name -Paths $duplicatePaths
        }
    }

$MonthlyActivity = $AllFiles |
    Group-Object { $_.LastWriteTime.ToString("yyyy-MM") } |
    Sort-Object Name -Descending |
    Select-Object -First 24 |
    ForEach-Object {
        $sum = Get-SafeSum -Items $_.Group -PropertyName "Length"

        [PSCustomObject]@{
            Ay          = $_.Name
            DosyaSayisi = $_.Count
            ToplamBoyut = Convert-BytesToReadable $sum
        }
    }

$DeepestFolders = $AllFolders |
    ForEach-Object {
        $relative = $_.FullName.Replace($NormalizedRoot, "").Trim("\")
        $depth = 0

        if (![string]::IsNullOrWhiteSpace($relative)) {
            $depth = ($relative -split "\\").Count
        }

        [PSCustomObject]@{
            KlasorYolu    = $_.FullName
            Derinlik      = $depth
            YolUzunlugu   = $_.FullName.Length
            SonDegisiklik = $_.LastWriteTime
        }
    } |
    Sort-Object Derinlik -Descending |
    Select-Object -First $TopCount

$ErrorReport = $Errors |
    Select-Object -First $MaxErrorRows

$ErrorCount = $Errors.Count


$UsedPercentNumber = 0
$FreePercentNumber = 0

if ($null -ne $DiskInfo.KapasiteBytes -and $DiskInfo.KapasiteBytes -gt 0) {
    $UsedPercentNumber = ($DiskInfo.KullanilanBytes / $DiskInfo.KapasiteBytes) * 100
    $FreePercentNumber = ($DiskInfo.BosBytes / $DiskInfo.KapasiteBytes) * 100
}

$DiskUsedClass = Get-RiskClass -Value $UsedPercentNumber -Warning 80 -Critical 90
$DiskFreeClass = Get-RiskClass -Value $FreePercentNumber -Warning 20 -Critical 10 -Reverse
$LargeFileClass = Get-RiskClass -Value @($LargeFiles).Count -Warning 10 -Critical 50
$OldFileClass = Get-RiskClass -Value @($OldFiles).Count -Warning 100 -Critical 1000
$EmptyFolderClass = Get-RiskClass -Value @($EmptyFolders).Count -Warning 50 -Critical 200
$EmptyFileClass = Get-RiskClass -Value @($EmptyFiles).Count -Warning 50 -Critical 500
$LongPathClass = Get-RiskClass -Value (@($LongPathFiles).Count + @($LongPathFolders).Count) -Warning 1 -Critical 50
$FullControlClass = Get-RiskClass -Value $FullControlPermissionCount -Warning 1 -Critical 10
$DenyPermissionClass = Get-RiskClass -Value $DenyPermissionCount -Warning 1 -Critical 5


$Css = @'
<style>
body {
    font-family: Segoe UI, Arial, sans-serif;
    background: #f3f6fa;
    margin: 0;
    color: #1f2937;
}

.header {
    background: linear-gradient(135deg, #111827, #334155);
    color: white;
    padding: 30px;
}

.header h1 {
    margin: 0;
    font-size: 30px;
}

.header p {
    margin: 8px 0 0 0;
    color: #d1d5db;
}

.container {
    padding: 24px;
}

.report-meta {
    display: grid;
    grid-template-columns: repeat(3, minmax(180px, 1fr));
    gap: 12px;
    background: white;
    border-left: 6px solid #3b82f6;
    border-radius: 10px;
    padding: 14px;
    margin-bottom: 20px;
    box-shadow: 0 6px 18px rgba(0,0,0,0.08);
}

.report-meta-item .label {
    display: block;
    font-size: 12px;
    color: #64748b;
    text-transform: uppercase;
    letter-spacing: .05em;
    font-weight: 600;
    margin-bottom: 5px;
}

.report-meta-item .value {
    color: #111827;
    font-weight: 700;
    word-break: break-word;
}

.kpi-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(185px, 1fr));
    gap: 12px;
    margin-bottom: 20px;
}

.kpi {
    --accent: #475569;
    --accent-soft: #f8fafc;
    position: relative;
    overflow: hidden;
    border-radius: 8px;
    padding: 13px 14px 12px 14px;
    background: linear-gradient(180deg, var(--accent-soft), #ffffff 64%);
    border: 1px solid #dbe3ee;
    border-left: 5px solid var(--accent);
    box-shadow: 0 4px 12px rgba(15,23,42,0.07);
    min-height: 76px;
}

.kpi::before {
    content: "";
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 3px;
    background: var(--accent);
    opacity: .9;
}

.kpi .label {
    position: relative;
    font-size: 11px;
    color: #526174;
    text-transform: uppercase;
    letter-spacing: .04em;
    font-weight: 700;
    line-height: 1.25;
}

.kpi .value {
    position: relative;
    font-size: 22px;
    line-height: 1.16;
    font-weight: 750;
    margin-top: 6px;
    color: #0f172a;
    word-break: break-word;
}

.kpi .sub {
    position: relative;
    margin-top: 5px;
    color: #64748b;
    font-size: 11px;
    line-height: 1.3;
}

.good {
    --accent: #16803c;
    --accent-soft: #f0fdf4;
}

.warning {
    --accent: #b45309;
    --accent-soft: #fff7ed;
}

.critical {
    --accent: #b91c1c;
    --accent-soft: #fef2f2;
}

.blue {
    --accent: #1d4ed8;
    --accent-soft: #eff6ff;
}

.purple {
    --accent: #6d28d9;
    --accent-soft: #f5f3ff;
}

.gray {
    --accent: #475569;
    --accent-soft: #f8fafc;
}

.section {
    background: white;
    margin-bottom: 24px;
    border-radius: 14px;
    padding: 18px;
    box-shadow: 0 6px 18px rgba(0,0,0,0.08);
}

.section h2 {
    margin-top: 0;
    color: #111827;
    border-bottom: 1px solid #e5e7eb;
    padding-bottom: 10px;
}

.table-tools {
    display: flex;
    gap: 12px;
    margin-bottom: 12px;
    flex-wrap: wrap;
}

.table-search {
    padding: 9px 12px;
    border: 1px solid #cbd5e1;
    border-radius: 8px;
    width: 320px;
    max-width: 100%;
}

.table-page-size {
    padding: 9px 12px;
    border: 1px solid #cbd5e1;
    border-radius: 8px;
}

.export-tools {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    color: #475569;
    font-size: 13px;
}

.export-tools button {
    padding: 8px 11px;
    border: 1px solid #cbd5e1;
    border-radius: 8px;
    background: #f8fafc;
    color: #111827;
    cursor: pointer;
    font-weight: 600;
}

.export-tools button:hover {
    background: #e2e8f0;
}

.show-duplicate-paths {
    padding: 7px 10px;
    border: 1px solid #2563eb;
    border-radius: 8px;
    background: #eff6ff;
    color: #1d4ed8;
    cursor: pointer;
    font-weight: 700;
}

.show-duplicate-paths:hover {
    background: #dbeafe;
}

.duplicate-paths-export,
.duplicate-paths-content {
    display: none;
}

.modal-overlay {
    position: fixed;
    inset: 0;
    display: none;
    align-items: center;
    justify-content: center;
    padding: 24px;
    background: rgba(15,23,42,0.58);
    z-index: 9999;
}

.modal-overlay.open {
    display: flex;
}

.modal-box {
    width: min(980px, 96vw);
    max-height: 88vh;
    background: white;
    border-radius: 8px;
    box-shadow: 0 24px 70px rgba(15,23,42,0.35);
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.modal-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 14px 16px;
    border-bottom: 1px solid #e5e7eb;
    background: #f8fafc;
}

.modal-head h3 {
    margin: 0;
    font-size: 16px;
    color: #111827;
}

.modal-close {
    padding: 6px 10px;
    border: 1px solid #cbd5e1;
    border-radius: 8px;
    background: white;
    cursor: pointer;
    font-weight: 700;
}

.modal-body {
    padding: 16px;
    overflow: auto;
}

.modal-body .duplicate-paths-title {
    font-weight: 700;
    margin-bottom: 12px;
    color: #111827;
    word-break: break-word;
}

.modal-body ol {
    margin: 0;
    padding-left: 22px;
}

.modal-body li {
    margin-bottom: 7px;
    word-break: break-word;
    white-space: pre-wrap;
}

.table-scroll {
    overflow-x: auto;
    border: 1px solid #e5e7eb;
    border-radius: 10px;
}

table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
}

th {
    background: #334155;
    color: white;
    padding: 10px;
    text-align: left;
    cursor: pointer;
    user-select: none;
    white-space: nowrap;
}

th:hover {
    background: #1f2937;
}

td {
    padding: 6px 9px;
    border-bottom: 1px solid #e5e7eb;
    vertical-align: top;
    word-break: break-word;
    white-space: normal;
    line-height: 1.25;
}

tr:nth-child(even) {
    background: #f8fafc;
}

tr:hover {
    background: #eef2ff;
}

tr.group-color-1 {
    background: #f0f9ff;
}

tr.group-color-2 {
    background: #f0fdf4;
}

tr.group-color-3 {
    background: #fff7ed;
}

tr.group-color-4 {
    background: #fdf2f8;
}

tr.group-color-5 {
    background: #f5f3ff;
}

tr.group-color-6 {
    background: #ecfdf5;
}

tr.group-color-7 {
    background: #fffbeb;
}

tr.group-color-8 {
    background: #f8fafc;
}

tr.group-color-1:hover,
tr.group-color-2:hover,
tr.group-color-3:hover,
tr.group-color-4:hover,
tr.group-color-5:hover,
tr.group-color-6:hover,
tr.group-color-7:hover,
tr.group-color-8:hover {
    background: #e0f2fe;
}

.badge {
    display: inline-block;
    padding: 4px 8px;
    border-radius: 999px;
    background: #e5e7eb;
    font-size: 12px;
}

.pager {
    margin-top: 10px;
    display: flex;
    gap: 10px;
    align-items: center;
}

.pager button {
    padding: 7px 12px;
    border: 1px solid #cbd5e1;
    border-radius: 8px;
    background: #f8fafc;
    cursor: pointer;
}

.pager button:hover {
    background: #e2e8f0;
}

.page-info {
    color: #475569;
    font-size: 13px;
}

.footer {
    text-align: center;
    color: #6b7280;
    padding: 20px;
    font-size: 12px;
}

@media print {
    .table-tools, .pager {
        display: none;
    }

    .section {
        page-break-inside: avoid;
    }
}
</style>
'@


$Js = @'
<script>
document.addEventListener("DOMContentLoaded", function () {
    const tableStates = {};

    function getRows(table) {
        return Array.from(table.querySelectorAll("tbody tr"));
    }

    function getCellText(cell) {
        const exportText = cell.querySelector(".export-text");
        return exportText ? exportText.textContent.trim() : cell.innerText.trim();
    }

    function getRowSearchText(row) {
        return Array.from(row.children).map(getCellText).join(" ").toLowerCase();
    }

    function applyTable(tableId) {
        const table = document.getElementById(tableId);
        if (!table) return;

        if (!tableStates[tableId]) {
            tableStates[tableId] = {
                page: 1,
                sortIndex: null,
                sortAsc: true
            };
        }

        const state = tableStates[tableId];
        const searchBox = document.querySelector('.table-search[data-table="' + tableId + '"]');
        const pageSizeBox = document.querySelector('.table-page-size[data-table="' + tableId + '"]');
        const pageInfo = document.querySelector('.page-info[data-table="' + tableId + '"]');

        const query = searchBox ? searchBox.value.toLowerCase() : "";
        const pageSize = pageSizeBox ? parseInt(pageSizeBox.value) : 25;

        let rows = getRows(table);
        rows.forEach(row => row.style.display = "none");

        let filtered = rows.filter(row => getRowSearchText(row).includes(query));

        if (state.sortIndex !== null) {
            filtered.sort(function (a, b) {
                let av = a.children[state.sortIndex].innerText.trim();
                let bv = b.children[state.sortIndex].innerText.trim();

                let an = parseFloat(av.replace(",", ".").replace(/[^0-9.-]/g, ""));
                let bn = parseFloat(bv.replace(",", ".").replace(/[^0-9.-]/g, ""));

                let result;

                if (!isNaN(an) && !isNaN(bn)) {
                    result = an - bn;
                } else {
                    result = av.localeCompare(bv, "tr");
                }

                return state.sortAsc ? result : -result;
            });
        }

        const totalPages = Math.max(1, Math.ceil(filtered.length / pageSize));

        if (state.page > totalPages) {
            state.page = totalPages;
        }

        const start = (state.page - 1) * pageSize;
        const end = start + pageSize;

        filtered.slice(start, end).forEach(row => row.style.display = "");

        if (pageInfo) {
            pageInfo.textContent = "Sayfa " + state.page + " / " + totalPages + " - Toplam satır: " + filtered.length;
        }
    }

    function getTableTitle(table) {
        const section = table.closest(".section");
        const heading = section ? section.querySelector("h2") : null;
        return heading ? heading.innerText.trim() : "Tablo";
    }

    function sanitizeFileName(value) {
        return value
            .replace(/[\\/:*?"<>|]+/g, "_")
            .replace(/\s+/g, "_")
            .replace(/^_+|_+$/g, "")
            .substring(0, 120) || "Tablo";
    }

    function getTableData(table) {
        const headers = Array.from(table.querySelectorAll("thead th")).map(th => th.innerText.trim());
        const rows = Array.from(table.querySelectorAll("tbody tr")).map(row =>
            Array.from(row.children).map(getCellText)
        );

        return { headers, rows };
    }

    function downloadBlob(content, mimeType, fileName) {
        const blob = new Blob([content], { type: mimeType });
        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = fileName;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
    }

    function csvValue(value) {
        const text = String(value || "").replace(/\r?\n/g, " | ");
        return '"' + text.replace(/"/g, '""') + '"';
    }

    function exportTableCsv(tableId) {
        const table = document.getElementById(tableId);
        if (!table) return;

        const title = getTableTitle(table);
        const data = getTableData(table);
        const lines = [data.headers, ...data.rows].map(row => row.map(csvValue).join(";"));
        downloadBlob("\ufeff" + lines.join("\r\n"), "text/csv;charset=utf-8", sanitizeFileName(title) + ".csv");
    }

    function htmlValue(value) {
        return String(value || "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/\r?\n/g, "<br>");
    }

    function exportTableExcel(tableId) {
        const table = document.getElementById(tableId);
        if (!table) return;

        const title = getTableTitle(table);
        const data = getTableData(table);
        const headerHtml = data.headers.map(value => "<th>" + htmlValue(value) + "</th>").join("");
        const rowHtml = data.rows.map(row =>
            "<tr>" + row.map(value => "<td>" + htmlValue(value) + "</td>").join("") + "</tr>"
        ).join("");

        const workbook = '\ufeff<html><head><meta charset="UTF-8"></head><body>' +
            "<table border='1'><thead><tr>" + headerHtml + "</tr></thead><tbody>" + rowHtml + "</tbody></table>" +
            "</body></html>";

        downloadBlob(workbook, "application/vnd.ms-excel;charset=utf-8", sanitizeFileName(title) + ".xls");
    }

    function exportTablePdf(tableId) {
        const table = document.getElementById(tableId);
        if (!table) return;

        const title = getTableTitle(table);
        const data = getTableData(table);
        const headerHtml = data.headers.map(value => "<th>" + htmlValue(value) + "</th>").join("");
        const rowHtml = data.rows.map(row =>
            "<tr>" + row.map(value => "<td>" + htmlValue(value) + "</td>").join("") + "</tr>"
        ).join("");

        const printWindow = window.open("", "_blank");
        if (!printWindow) return;

        printWindow.document.write(
            '<!DOCTYPE html><html lang="tr"><head><meta charset="UTF-8"><title>' + htmlValue(title) + '</title>' +
            '<style>body{font-family:Segoe UI,Arial,sans-serif;color:#111827;padding:20px;}h1{font-size:20px;}table{width:100%;border-collapse:collapse;font-size:11px;}th{background:#334155;color:white;}th,td{border:1px solid #cbd5e1;padding:6px;text-align:left;vertical-align:top;word-break:break-word;}td{white-space:pre-line;}@media print{@page{size:landscape;margin:10mm;}}</style>' +
            '</head><body><h1>' + htmlValue(title) + '</h1><table><thead><tr>' + headerHtml + '</tr></thead><tbody>' + rowHtml + '</tbody></table></body></html>'
        );
        printWindow.document.close();
        printWindow.focus();
        setTimeout(function () {
            printWindow.print();
        }, 250);
    }

    function openDuplicatePathsModal(button) {
        const modal = document.getElementById("duplicatePathsModal");
        const body = document.getElementById("duplicatePathsModalBody");
        const content = button.closest(".duplicate-paths-cell").querySelector(".duplicate-paths-content");

        if (!modal || !body || !content) return;

        body.innerHTML = content.innerHTML;
        modal.classList.add("open");
        modal.setAttribute("aria-hidden", "false");
    }

    function closeDuplicatePathsModal() {
        const modal = document.getElementById("duplicatePathsModal");
        const body = document.getElementById("duplicatePathsModalBody");

        if (!modal || !body) return;

        modal.classList.remove("open");
        modal.setAttribute("aria-hidden", "true");
        body.innerHTML = "";
    }

    document.querySelectorAll(".report-table").forEach(function (table) {
        const tableId = table.id;

        tableStates[tableId] = {
            page: 1,
            sortIndex: null,
            sortAsc: true
        };

        table.querySelectorAll("th").forEach(function (th, index) {
            th.addEventListener("click", function () {
                const state = tableStates[tableId];

                if (state.sortIndex === index) {
                    state.sortAsc = !state.sortAsc;
                } else {
                    state.sortIndex = index;
                    state.sortAsc = true;
                }

                state.page = 1;
                applyTable(tableId);
            });
        });

        applyTable(tableId);
    });

    document.querySelectorAll(".table-search").forEach(function (input) {
        input.addEventListener("input", function () {
            const tableId = input.getAttribute("data-table");
            tableStates[tableId].page = 1;
            applyTable(tableId);
        });
    });

    document.querySelectorAll(".table-page-size").forEach(function (select) {
        select.addEventListener("change", function () {
            const tableId = select.getAttribute("data-table");
            tableStates[tableId].page = 1;
            applyTable(tableId);
        });
    });

    document.querySelectorAll(".prev-page").forEach(function (button) {
        button.addEventListener("click", function () {
            const tableId = button.getAttribute("data-table");

            if (tableStates[tableId].page > 1) {
                tableStates[tableId].page--;
                applyTable(tableId);
            }
        });
    });

    document.querySelectorAll(".next-page").forEach(function (button) {
        button.addEventListener("click", function () {
            const tableId = button.getAttribute("data-table");
            tableStates[tableId].page++;
            applyTable(tableId);
        });
    });

    document.querySelectorAll(".export-csv").forEach(function (button) {
        button.addEventListener("click", function () {
            exportTableCsv(button.getAttribute("data-table"));
        });
    });

    document.querySelectorAll(".export-excel").forEach(function (button) {
        button.addEventListener("click", function () {
            exportTableExcel(button.getAttribute("data-table"));
        });
    });

    document.querySelectorAll(".export-pdf").forEach(function (button) {
        button.addEventListener("click", function () {
            exportTablePdf(button.getAttribute("data-table"));
        });
    });

    document.querySelectorAll(".show-duplicate-paths").forEach(function (button) {
        button.addEventListener("click", function () {
            openDuplicatePathsModal(button);
        });
    });

    document.querySelectorAll(".modal-close").forEach(function (button) {
        button.addEventListener("click", closeDuplicatePathsModal);
    });

    document.querySelectorAll(".modal-overlay").forEach(function (modal) {
        modal.addEventListener("click", function (event) {
            if (event.target === modal) {
                closeDuplicatePathsModal();
            }
        });
    });

    document.addEventListener("keydown", function (event) {
        if (event.key === "Escape") {
            closeDuplicatePathsModal();
        }
    });
});
</script>
'@


Write-Host "HTML tabloları hazırlanıyor..." -ForegroundColor Yellow

$TablesHtml = ""

$TablesHtml += New-ReportTable `
    -Title "Ana Klasör ve Birinci Seviye Klasör Okuma / Yazma Yetkileri" `
    -Data $MainFolderPermissionReport `
    -Columns @(
        @{ Header = "Klasör Yolu"; Expression = { param($x) $x.KlasorYolu } },
        @{ Header = "Kullanıcı / Grup"; Expression = { param($x) $x.KullaniciGrup } },
        @{ Header = "Yetki Tipi"; Expression = { param($x) $x.YetkiTipi } },
        @{ Header = "Uygulama Alanı"; Expression = { param($x) $x.UygulamaAlani } },
        @{ Header = "Devralma Alanı"; Expression = { param($x) $x.DevralmaAlani } }
    ) `
    -GroupByExpression { param($x) $x.KlasorYolu }

$TablesHtml += New-ReportTable `
    -Title "En Büyük Klasörler" `
    -Data $TopLargestFolders `
    -Columns @(
        @{ Header = "Klasör Yolu"; Expression = { param($x) $x.KlasorYolu } },
        @{ Header = "Dosya Sayısı"; Expression = { param($x) $x.DosyaSayisi } },
        @{ Header = "Toplam Boyut"; Expression = { param($x) $x.ToplamBoyut } },
        @{ Header = "Son Değişiklik"; Expression = { param($x) $x.SonDegisiklik } },
        @{ Header = "Yol Uzunluğu"; Expression = { param($x) $x.YolUzunlugu } }
    )

$TablesHtml += New-ReportTable `
    -Title "En Büyük Dosyalar" `
    -Data $TopLargestFiles `
    -Columns @(
        @{ Header = "Dosya Adı"; Expression = { param($x) $x.DosyaAdi } },
        @{ Header = "Dosya Yolu"; Expression = { param($x) $x.DosyaYolu } },
        @{ Header = "Boyut"; Expression = { param($x) $x.Boyut } },
        @{ Header = "Uzantı"; Expression = { param($x) $x.Uzanti } },
        @{ Header = "Son Değişiklik"; Expression = { param($x) $x.SonDegisiklik } },
        @{ Header = "Oluşturma Tarihi"; Expression = { param($x) $x.OlusturmaTarihi } }
    )

$TablesHtml += New-ReportTable `
    -Title "Boş Klasörler" `
    -Data $EmptyFolderReport `
    -Columns @(
        @{ Header = "Klasör Yolu"; Expression = { param($x) $x.KlasorYolu } },
        @{ Header = "Son Değişiklik"; Expression = { param($x) $x.SonDegisiklik } },
        @{ Header = "Oluşturma Tarihi"; Expression = { param($x) $x.OlusturmaTarihi } }
    )

$TablesHtml += New-ReportTable `
    -Title "Boş Dosyalar" `
    -Data $EmptyFileReport `
    -Columns @(
        @{ Header = "Dosya Adı"; Expression = { param($x) $x.DosyaAdi } },
        @{ Header = "Dosya Yolu"; Expression = { param($x) $x.DosyaYolu } },
        @{ Header = "Boyut"; Expression = { param($x) $x.Boyut } },
        @{ Header = "Son Değişiklik"; Expression = { param($x) $x.SonDegisiklik } },
        @{ Header = "Oluşturma Tarihi"; Expression = { param($x) $x.OlusturmaTarihi } }
    )

$TablesHtml += New-ReportTable `
    -Title "Uzantıya Göre Dosya Dağılımı" `
    -Data $ExtensionStats `
    -Columns @(
        @{ Header = "Uzantı"; Expression = { param($x) $x.Uzanti } },
        @{ Header = "Dosya Sayısı"; Expression = { param($x) $x.DosyaSayisi } },
        @{ Header = "Toplam Boyut"; Expression = { param($x) $x.ToplamBoyut } }
    )

$TablesHtml += New-ReportTable `
    -Title "Kategori Bazlı Dosya Özeti" `
    -Data $CategoryStats `
    -Columns @(
        @{ Header = "Kategori"; Expression = { param($x) $x.Kategori } },
        @{ Header = "Dosya Sayısı"; Expression = { param($x) $x.DosyaSayisi } },
        @{ Header = "Toplam Boyut"; Expression = { param($x) $x.ToplamBoyut } }
    )

$TablesHtml += New-ReportTable `
    -Title "En Son Değiştirilen Dosyalar" `
    -Data $RecentChangedFiles `
    -Columns @(
        @{ Header = "Dosya Adı"; Expression = { param($x) $x.DosyaAdi } },
        @{ Header = "Dosya Yolu"; Expression = { param($x) $x.DosyaYolu } },
        @{ Header = "Boyut"; Expression = { param($x) $x.Boyut } },
        @{ Header = "Uzantı"; Expression = { param($x) $x.Uzanti } },
        @{ Header = "Son Değişiklik"; Expression = { param($x) $x.SonDegisiklik } }
    )

$TablesHtml += New-ReportTable `
    -Title "En Eski Değişiklik Tarihine Sahip Dosyalar" `
    -Data $OldestFiles `
    -Columns @(
        @{ Header = "Dosya Adı"; Expression = { param($x) $x.DosyaAdi } },
        @{ Header = "Dosya Yolu"; Expression = { param($x) $x.DosyaYolu } },
        @{ Header = "Boyut"; Expression = { param($x) $x.Boyut } },
        @{ Header = "Uzantı"; Expression = { param($x) $x.Uzanti } },
        @{ Header = "Son Değişiklik"; Expression = { param($x) $x.SonDegisiklik } }
    )

$TablesHtml += New-ReportTable `
    -Title "Uzun Yol Uyarısı Olan Dosyalar" `
    -Data $LongPathFileReport `
    -Columns @(
        @{ Header = "Dosya Adı"; Expression = { param($x) $x.DosyaAdi } },
        @{ Header = "Dosya Yolu"; Expression = { param($x) $x.DosyaYolu } },
        @{ Header = "Yol Uzunluğu"; Expression = { param($x) $x.YolUzunlugu } },
        @{ Header = "Boyut"; Expression = { param($x) $x.Boyut } },
        @{ Header = "Son Değişiklik"; Expression = { param($x) $x.SonDegisiklik } }
    )

$TablesHtml += New-ReportTable `
    -Title "Aynı İsimli Dosya Analizi" `
    -Data $DuplicateFileNames `
    -Columns @(
        @{ Header = "Dosya Adı"; Expression = { param($x) $x.DosyaAdi } },
        @{ Header = "Tekrar Sayısı"; Expression = { param($x) $x.TekrarSayisi } },
        @{ Header = "Tüm Dosya Yolları"; Expression = { param($x) $x.YollarModal }; RawHtml = $true }
    )

$TablesHtml += New-ReportTable `
    -Title "Aylık Değişiklik Aktivitesi" `
    -Data $MonthlyActivity `
    -Columns @(
        @{ Header = "Ay"; Expression = { param($x) $x.Ay } },
        @{ Header = "Dosya Sayısı"; Expression = { param($x) $x.DosyaSayisi } },
        @{ Header = "Toplam Boyut"; Expression = { param($x) $x.ToplamBoyut } }
    )

$TablesHtml += New-ReportTable `
    -Title "En Derin Klasörler" `
    -Data $DeepestFolders `
    -Columns @(
        @{ Header = "Klasör Yolu"; Expression = { param($x) $x.KlasorYolu } },
        @{ Header = "Derinlik"; Expression = { param($x) $x.Derinlik } },
        @{ Header = "Yol Uzunluğu"; Expression = { param($x) $x.YolUzunlugu } },
        @{ Header = "Son Değişiklik"; Expression = { param($x) $x.SonDegisiklik } }
    )

$ReportDate = Get-Date
$RunUser = "$env:USERDOMAIN\$env:USERNAME"


Write-Host "HTML rapor oluşturuluyor..." -ForegroundColor Yellow

$HtmlReportTitle = "FIRMA-ADI - $($ServerInfo.CihazAdi) Raporu"
$EncodedHtmlReportTitle = HtmlEncode $HtmlReportTitle

$Html = @"
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<title>$EncodedHtmlReportTitle</title>
$Css
</head>
<body>

<div class="header">
    <h1>$EncodedHtmlReportTitle</h1>
    <p>Rapor Tarihi: $($ReportDate.ToString("dd.MM.yyyy HH:mm"))</p>
    <p>Raporu Oluşturan Kullanıcı: $(HtmlEncode $RunUser)</p>
</div>

<div class="container">

<div class="kpi-grid">

    <div class="kpi blue">
        <div class="label">Ana Dizin</div>
        <div class="value" style="font-size:16px;">$(HtmlEncode $RootPath)</div>
        <div class="sub">Raporlanan paylaşım</div>
    </div>

    <div class="kpi blue">
        <div class="label">Cihaz Adı</div>
        <div class="value" style="font-size:18px;">$(HtmlEncode $ServerInfo.CihazAdi)</div>
        <div class="sub">UNC paylaşım sunucusu</div>
    </div>

    <div class="kpi blue">
        <div class="label">Server IP Adresi</div>
        <div class="value" style="font-size:18px;">$(HtmlEncode $ServerInfo.IpAdresi)</div>
        <div class="sub">DNS üzerinden çözümlenen IPv4 adresi</div>
    </div>

    <div class="kpi purple">
        <div class="label">Toplam Disk Kapasitesi</div>
        <div class="value">$(Convert-BytesToReadable $DiskInfo.KapasiteBytes)</div>
        <div class="sub">Kaynak: $(HtmlEncode $DiskInfo.Kaynak)</div>
    </div>

    <div class="kpi $DiskUsedClass">
        <div class="label">Kullanılan Alan</div>
        <div class="value">$(Convert-BytesToReadable $DiskInfo.KullanilanBytes)</div>
        <div class="sub">Kullanım oranı: $($DiskInfo.KullanilanYuzde)</div>
    </div>

    <div class="kpi $DiskFreeClass">
        <div class="label">Boş Alan</div>
        <div class="value">$(Convert-BytesToReadable $DiskInfo.BosBytes)</div>
        <div class="sub">Boş alan oranı: $($DiskInfo.BosYuzde)</div>
    </div>

    <div class="kpi blue">
        <div class="label">Toplam Dosya</div>
        <div class="value">$TotalFiles</div>
        <div class="sub">Okunabilen dosya sayısı</div>
    </div>

    <div class="kpi blue">
        <div class="label">Toplam Klasör</div>
        <div class="value">$TotalFolders</div>
        <div class="sub">Okunabilen klasör sayısı</div>
    </div>

    <div class="kpi $LargeFileClass">
        <div class="label">$LargeFileThresholdGB GB Üzeri Dosya</div>
        <div class="value">$(@($LargeFiles).Count)</div>
        <div class="sub">Büyük dosya kontrolü</div>
    </div>

    <div class="kpi good">
        <div class="label">Son $RecentDays Günde Değişen Dosya</div>
        <div class="value">$(@($RecentFiles).Count)</div>
        <div class="sub">Aktif kullanım göstergesi</div>
    </div>

    <div class="kpi $OldFileClass">
        <div class="label">$OldFileYears Yıldan Eski Dosya</div>
        <div class="value">$(@($OldFiles).Count)</div>
        <div class="sub">Arşiv / temizlik adayı</div>
    </div>

    <div class="kpi $OldFileClass">
        <div class="label">$VeryOldFileYears Yıldan Eski Dosya</div>
        <div class="value">$(@($VeryOldFiles).Count)</div>
        <div class="sub">Uzun süredir değişmeyen dosyalar</div>
    </div>

    <div class="kpi $EmptyFolderClass">
        <div class="label">Boş Klasör</div>
        <div class="value">$(@($EmptyFolders).Count)</div>
        <div class="sub">İçinde dosya/klasör olmayan klasörler</div>
    </div>

    <div class="kpi $EmptyFileClass">
        <div class="label">Boş Dosya</div>
        <div class="value">$(@($EmptyFiles).Count)</div>
        <div class="sub">0 byte dosyalar</div>
    </div>

    <div class="kpi $LongPathClass">
        <div class="label">Uzun Yol Uyarısı</div>
        <div class="value">$(@($LongPathFiles).Count + @($LongPathFolders).Count)</div>
        <div class="sub">$LongPathWarningLength karakter ve üzeri yollar</div>
    </div>

    <div class="kpi gray">
        <div class="label">Gizli Dosya</div>
        <div class="value">$(@($HiddenFiles).Count)</div>
        <div class="sub">Hidden attribute</div>
    </div>

    <div class="kpi gray">
        <div class="label">Sistem Dosyası</div>
        <div class="value">$(@($SystemFiles).Count)</div>
        <div class="sub">System attribute</div>
    </div>

</div>

$TablesHtml

</div>

<div class="footer">
    $EncodedHtmlReportTitle
</div>

<div id="duplicatePathsModal" class="modal-overlay" aria-hidden="true">
    <div class="modal-box" role="dialog" aria-modal="true" aria-labelledby="duplicatePathsModalTitle">
        <div class="modal-head">
            <h3 id="duplicatePathsModalTitle">Tekrar Eden Dosya Yolları</h3>
            <button type="button" class="modal-close">Kapat</button>
        </div>
        <div id="duplicatePathsModalBody" class="modal-body"></div>
    </div>
</div>

$Js

</body>
</html>
"@


$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ReportPath, $Html, $Utf8NoBomEncoding)

Write-Host ""
Write-Host "Rapor başarıyla oluşturuldu:" -ForegroundColor Green
Write-Host $ReportPath -ForegroundColor Green


if ($SendMailReport) {
    Write-Host "Rapor mail olarak gönderiliyor..." -ForegroundColor Yellow

    $MailSubject = "Paylasim $($ServerInfo.CihazAdi) Raporu $(Get-Date -Format 'dd.MM.yyyy - HH:mm')"

    $MailBody = @"
Merhaba,
Paylasim $RootPath detaylı raporu oluşturulmuştur.

Cihaz Adı: $($ServerInfo.CihazAdi)
Server IP Adresi: $($ServerInfo.IpAdresi)

HTML rapor ektedir.
"@

    try {
        $mailParams = @{
            SmtpServer  = $SmtpServer
            Port        = $SmtpPort
            From        = $MailFrom
            To          = $MailTo
            Subject     = $MailSubject
            Body        = $MailBody
            Encoding    = [System.Text.Encoding]::UTF8
            ErrorAction = "Stop"
        }

        if ($AttachReportToMail -and (Test-Path -Path $ReportPath)) {
            $mailParams.Attachments = $ReportPath
        }

        $ReportExists = Test-Path -Path $ReportPath
        $ReportSize = 0
        if ($ReportExists) {
            $ReportSize = (Get-Item -Path $ReportPath).Length
        }

        Add-Content -Path $MailLogPath -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Mail gönderiliyor. Alicilar: $($MailTo -join ', ') | Ek: $ReportPath | EkVar: $ReportExists | BoyutByte: $ReportSize"

        Send-MailMessage @mailParams

        Write-Host "Mail başarıyla gönderildi: $($MailTo -join ', ')" -ForegroundColor Green
        Add-Content -Path $MailLogPath -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Mail başarıyla gönderildi: $($MailTo -join ', ')"
    }
    catch {
        $MailError = "Mail gönderilemedi: $($_.Exception.Message)"
        Write-Host $MailError -ForegroundColor Red
        Add-Content -Path $MailLogPath -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $MailError"
    }
}

if ($OpenReportAfterCreate) {
    Invoke-Item $ReportPath
}

<#
Script Adı  : File Server Detaylı Durum Raporu
Hazırlayan  : İbrahim TONCA
Web         : www.ibrahimtonca.com
Açıklama    : File Server paylaşım alanı, kapasite kullanımı, dosya/klasör yapısı, NTFS yetkileri ve genel sağlık durumunu HTML rapor olarak oluşturur.

Yasal Uyarı :
Bu script kaynak gösterilmeden paylaşılamaz, çoğaltılamaz veya farklı platformlarda yayınlanamaz.
Scriptin kullanımı ve doğabilecek sonuçlar tamamen kullanıcının sorumluluğundadır.
#>

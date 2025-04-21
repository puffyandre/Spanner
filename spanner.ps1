# =========================
# CONFIGURATION SECTION
# =========================

$sourceFolders = @(
    "C:\Users\User\Downloads",
	"C:\Users\User\Documents\SourceFolder2",
	"C:\SourceFolder3"
)

$bufferMB = 100          # Avoid using 100% of disk
$blockSize = 1MB         # Chunk size for file copying
$logFile = "CopyLog.csv" # Log file path

# =========================
# FUNCTION DEFINITIONS
# =========================

function Get-RelativePath {
    param ($filePath, $basePaths)
    foreach ($base in $basePaths) {
        if ($filePath -like "$base*") {
            return $filePath.Substring($base.Length).TrimStart('\')
        }
    }
    return $null
}

function Prompt-ForDrive {
    param ($promptText)
    while ($true) {
        $driveLetter = Read-Host $promptText
        if (Test-Path "$driveLetter\") {
            return "$driveLetter\"
        } else {
            Write-Host "Drive '$driveLetter' not found. Please try again." -ForegroundColor Yellow
        }
    }
}

function Copy-FileWithProgress {
    param ($source, $destination, $fileSize)
    $sourceStream = [System.IO.File]::OpenRead($source)
    $destStream = [System.IO.File]::Create($destination)
    $buffer = New-Object byte[] $blockSize
    $totalRead = 0

    try {
        do {
            $bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -gt 0) {
                $destStream.Write($buffer, 0, $bytesRead)
                $totalRead += $bytesRead
                $percent = [math]::Round(($totalRead / $fileSize) * 100, 2)
                Write-Progress -Activity "Copying file" -Status "$percent% complete" -PercentComplete $percent
            }
        } while ($bytesRead -gt 0)
    } finally {
        $sourceStream.Close()
        $destStream.Close()
        Write-Progress -Activity "Copying file" -Completed
    }
}

function Log-CopyResult {
    param ($status, $relativePath, $sourcePath, $destPath, $size)
    $entry = [PSCustomObject]@{
        Status       = $status
        RelativePath = $relativePath
        SourcePath   = $sourcePath
        Destination  = $destPath
        SizeBytes    = $size
        Timestamp    = (Get-Date)
    }
    $entry | Export-Csv -Path $logFile -Append -NoTypeInformation
}

# =========================
# MAIN SCRIPT
# =========================

# Init log
if (Test-Path $logFile) { Remove-Item $logFile }
"Status,RelativePath,SourcePath,Destination,SizeBytes,Timestamp" | Out-File $logFile

# Build file list
$allFiles = @()
foreach ($folder in $sourceFolders) {
    if (Test-Path $folder) {
        $files = Get-ChildItem -Path $folder -Recurse -File
        $allFiles += $files
    } else {
        Write-Warning "Source folder '$folder' not found. Skipping."
    }
}

if ($allFiles.Count -eq 0) {
    Write-Error "No files found in source folders. Exiting."
    exit
}

Write-Host "Found $($allFiles.Count) files to copy.`n"
$destDrive = Prompt-ForDrive -promptText "Insert destination drive (e.g. F:) and press Enter"

# Overall progress
$totalFiles = $allFiles.Count
$index = 0

foreach ($file in $allFiles) {
    $index++
    $globalPercent = [math]::Round(($index / $totalFiles) * 100, 2)
    Write-Progress -Activity "Overall Progress" -Status "$index of $totalFiles files" -PercentComplete $globalPercent

    $relativePath = Get-RelativePath -filePath $file.FullName -basePaths $sourceFolders
    if (-not $relativePath) {
        Write-Warning "Could not determine relative path for '$($file.FullName)'. Skipping."
        Log-CopyResult -status "Skipped (NoRelPath)" -relativePath "" -sourcePath $file.FullName -destPath "" -size $file.Length
        continue
    }

    $destPath = Join-Path $destDrive $relativePath
    $destFolder = Split-Path $destPath -Parent

    # Skip if exists and same size
    if (Test-Path $destPath) {
        $existingSize = (Get-Item $destPath).Length
        if ($existingSize -eq $file.Length) {
            Write-Host "Skipping (already exists): $relativePath"
            Log-CopyResult -status "Skipped" -relativePath $relativePath -sourcePath $file.FullName -destPath $destPath -size $file.Length
            continue
        }
    }

    # Check free space
    $driveLetter = $destDrive.Substring(0,1)
    $freeSpace = (Get-PSDrive -Name $driveLetter).Free
    $bufferBytes = $bufferMB * 1MB

    if ($file.Length + $bufferBytes -gt $freeSpace) {
        Write-Host "`nDrive $destDrive does not have enough space for '$relativePath' ($([math]::Round($file.Length / 1MB, 2)) MB)." -ForegroundColor Yellow
        $destDrive = Prompt-ForDrive -promptText "Insert new destination drive and press Enter"
        $driveLetter = $destDrive.Substring(0,1)
        $freeSpace = (Get-PSDrive -Name $driveLetter).Free
        $destPath = Join-Path $destDrive $relativePath
        $destFolder = Split-Path $destPath -Parent
    }

    if (-not (Test-Path $destFolder)) {
        New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
    }

    Write-Host "`nCopying: $relativePath"
    try {
        Copy-FileWithProgress -source $file.FullName -destination $destPath -fileSize $file.Length
        Log-CopyResult -status "Copied" -relativePath $relativePath -sourcePath $file.FullName -destPath $destPath -size $file.Length
    }
    catch {
        Write-Warning "Failed to copy '$($file.FullName)': $_"
        Log-CopyResult -status "Failed" -relativePath $relativePath -sourcePath $file.FullName -destPath $destPath -size $file.Length
    }
}

Write-Progress -Activity "Overall Progress" -Completed
Write-Host "`n✅ All files processed. Log saved to '$logFile'" -ForegroundColor Green

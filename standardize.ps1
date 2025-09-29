param(
	[Parameter(Mandatory=$true)]
	[string]$Dir,

	[Parameter(Mandatory=$true)]
	[string]$Out
)

New-Item -ItemType Directory -Force -Path "$Out" | Out-Null

$files = Get-ChildItem -Path $Dir -Recurse -Filter "*.wav"
foreach ($file in $files) {
	try {
		Write-Host "$($file.FullName)"

		Write-Host "ffmpeg -i $($file.FullName) -c:a pcm_f32le $($Out)/$($file.Name)"
		ffmpeg -i "$($file.FullName)" -c:a pcm_f32le "$($Out)/$($file.Name)"
				
	} catch {
		Write-Host "WRN: convert ($($file.FullName)): $($_.Exception.Message)" -ForegroundColor yellow
	}
}

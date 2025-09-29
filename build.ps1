if (Test-Path -Path "bin/beach") {
  try {
    # Attempt to remove the file
    Remove-Item -Path "bin/beach.exe" -Force
    Write-Host "DEL: prev beach.exe" -ForegroundColor green
  } catch {
    # Handle any errors during deletion
    Write-Host "ERR: delete previous beach.exe: $_" -ForegroundColor red
		exit 1
  }
}

$shader_bindings = Get-ChildItem -Path ./src -Filter '*_glsl.odin' -Recurse 
foreach ($binding in $shader_bindings) {
	 try {
        Remove-Item -Path $binding.FullName -Force
        Write-Host "DEL: $($binding.FullName)" -ForegroundColor green
    } catch {
        Write-Host "ERR: delete ($($binding.FullName)): $($_.Exception.Message)" -ForegroundColor red
				exit 1
    }
}

$shaders = Get-ChildItem -Path ./src -Filter '*.glsl' -Recurse 
foreach ($shader in $shaders) {
		try {
			# TODO: glsl430 needs to change probs
			sokol-shdc -i "$($shader.FullName)" -o "$($shader.Directory)/$($shader.BaseName)_glsl.odin" -f sokol_odin -l hlsl5
			Write-Host "GEN: $($shader.Directory)\$($shader.BaseName)_glsl.odin" -ForegroundColor green
    } catch {
        Write-Host "ERR: generate shader ($($shader.FullName)): $($_.Exception.Message)" -ForegroundColor red
				exit 1
    }
}



try {
	New-Item -ItemType Directory -Force -Path .\bin | Out-Null
	odin build ./src -debug -out:bin/beach.exe
	if (Test-Path -Path "bin/beach.exe") {
		Write-Host "BLD: bin/beach.exe" -ForegroundColor green
	} else {
		Write-Host "ERR: build bin/beach.exe: $_" -ForegroundColor red
		exit 1
	}
} catch {
	Write-Host "ERR: build bin/beach.exe: $_" -ForegroundColor red
	exit 1
}

./bin/beach ./assets/audio-f32

#!/usr/bin/env bash

shader_bindings=$(find . -name '*_glsl.odin' | xargs -I {} rm -f {})

shaders=$(find ./src -name '*.glsl')
for shader in "${shaders[@]}"; do
	name=$(basename -- "$shader" .glsl)
	dir=$(dirname $shader)
	sokol-shdc -i "$shader" -o "${dir}/${name}_glsl.odin" -f sokol_odin -l glsl430
	if [ $? != 0 ];then
		echo "[error]: $shader"
		exit 1
	fi
done

bin=beach
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
	bin="beach.exe"
fi

test -f beach && rm beach
odin build ./src -debug -out:${bin}
./${bin} ./assets/audio

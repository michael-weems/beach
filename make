#!/usr/bin/env bash

shader_bindings=$(find . -name '*_glsl.odin')
for binding in "${shader_bindings[@]}"; do
	echo "rm -fr $binding"
	# TODO:
done

shaders=$(find . -name '*.glsl')
for shader in "${shaders[@]}"; do
	name=$(basename -- "$shader" .glsl)
	dir=$(dirname $shader)
	sokol-shdc -i "$shader" -o "${dir}/${name}_glsl.odin" -f sokol_odin -l glsl430
	if [ $? != 0 ];then
		echo "[error]: $shader"
		exit 1
	fi
done

[ -f beach ] && rm beach
odin build . -debug
./beach audio

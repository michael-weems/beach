cmake_minimum_required(VERSION 4.0)
project(beach)

add_executable(beach
   ./src/main.cpp
   ./src/main.hpp
   ./src/ansi_colors.hpp
   ./src/wav.cpp
   ./src/wav.hpp
)
target_include_directories(beach PUBLIC
   ./src
)

set_target_properties(beach PROPERTIES
   OUTPUT_NAME "bin/beach$<$<CONFIG:Debug>:d>"
)


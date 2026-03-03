cmake_minimum_required(VERSION 4.0)
project(beach)

add_executable(beach
   PUBLIC FILE_SET HEADERS
   BASE_DIRS ./src
   ./src/main.hpp
   ./src/ansi_colors.hpp
   ./src/wav.hpp

   PRIVATE
   ./src/main.cpp
   ./src/wav.cpp
)

target_set_properties(beach PROPERTIES
   OUTPUT_NAME "bin/beach$<$<CONFIG:Debug>:d>"
)


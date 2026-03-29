#ifndef FILES_HPP
#define FILES_HPP

#include "ctx.hpp"

#include <filesystem>

namespace files
{
   struct error
   {
      bool has_error;
      std::string msg;
   }

   error sizeof_directory(std::filesystem::path filepath, std::uintmax_t *out_size)
};
#endif // FILES_HPP

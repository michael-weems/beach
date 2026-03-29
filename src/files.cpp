#include "files.hpp"
#include "ctx.hpp"

#include <filesystem>

namespace files
{
   error sizeof_directory(std::filesystem::path filepath, std::uintmax_t *out_size)
   {
      error e{};

      *out_size = 0;
      try 
      {
         for (const auto& entry : fs::directory_iterator(directory_path)) 
         {
            if (entry.is_regular_file()) 
            {
                *out_size += entry.file_size();
            }
         }
      } 
      catch (const fs::filesystem_error& e) 
      {
         e.has_error = true;
         e.msg = "filesystem: " + e.what();
      }

      return e;
   }
};
